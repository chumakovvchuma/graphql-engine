{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE DisambiguateRecordFields #-}
module Hasura.GraphQL.Execute
  ( QExecPlanResolved(..)
  , QExecPlanPartial(..)
  , getExecPlanPartial
  , extractRemoteRelArguments

  , ExecOp(..)
  , getResolvedExecPlan
  , execRemoteGQ

  , EP.PlanCache
  , EP.initPlanCache
  , EP.clearPlanCache
  , EP.dumpPlanCache
  ) where

import           Control.Exception (try)
import           Control.Lens
import qualified Data.ByteString.Lazy.Char8 as L8
import           Data.Scientific

import           Data.Has
import           Data.List.NonEmpty (NonEmpty(..))
import qualified Data.List.NonEmpty as NE
import           Data.Time
import           Debug.Trace
import           Hasura.GraphQL.Validate.Field
import           Hasura.SQL.Time

import qualified Data.HashMap.Strict.InsOrd as OHM
import qualified Data.Aeson as J
import qualified Data.CaseInsensitive as CI
import qualified Data.HashMap.Strict as Map
import qualified Data.Sequence as Seq
import qualified Data.String.Conversions as CS
import qualified Data.Text as T
import qualified Language.GraphQL.Draft.Syntax as G
import qualified Network.HTTP.Client as HTTP
import qualified Network.HTTP.Types as N
import qualified Network.Wreq as Wreq

import           Hasura.EncJSON
import           Hasura.GraphQL.Context
import           Hasura.GraphQL.Resolve.Context
import           Hasura.GraphQL.Schema
import           Hasura.GraphQL.Transport.HTTP.Protocol
import           Hasura.SQL.Value
import           Hasura.GraphQL.Validate.Types
import           Hasura.HTTP
import           Hasura.Prelude
import           Hasura.RQL.DDL.Headers
import           Hasura.RQL.Types
import           Hasura.Server.Context
import           Hasura.Server.Utils                    (bsToTxt,
                                                         filterRequestHeaders)
import           Hasura.RQL.DDL.Remote.Types

import qualified Hasura.GraphQL.Execute.LiveQuery as EL
import qualified Hasura.GraphQL.Execute.Plan as EP
import qualified Hasura.GraphQL.Execute.Query as EQ

import qualified Hasura.GraphQL.Resolve as GR
import qualified Hasura.GraphQL.Validate as VQ

-- The current execution plan of a graphql operation, it is
-- currently, either local pg execution or a remote execution
data QExecPlanPartial
  = ExPHasuraPartial !(GCtx, VQ.HasuraTopField, [G.VariableDefinition])
  | ExPRemotePartial !VQ.RemoteTopQuery

-- The current execution plan of a graphql operation, it is
-- currently, either local pg execution or a remote execution
data QExecPlanResolved
  = ExPHasura !ExecOp
  | ExPRemote !VQ.RemoteTopQuery
  | ExPMixed !ExecOp (NonEmpty RemoteRelField)

newtype RemoteRelKey =
  RemoteRelKey Int
  deriving (Eq, Ord, Show, Hashable)

data RemoteRelField =
  RemoteRelField
    { rrRemoteField :: !RemoteField
    , rrField :: !Field
    , rrPath :: !Path
    }
  deriving (Show)

newtype Path = Path (Seq.Seq G.Alias)
  deriving (Show, Monoid, Semigroup, Eq)

getExecPlanPartial
  :: (MonadError QErr m)
  => UserInfo
  -> SchemaCache
  -> Bool
  -> GQLReqParsed
  -> m (Seq.Seq QExecPlanPartial)
getExecPlanPartial userInfo sc enableAL req = do

  -- check if query is in allowlist
  when enableAL checkQueryInAllowlist

  (gCtx, _)  <- flip runStateT sc $ getGCtx role gCtxRoleMap
  queryParts <- flip runReaderT gCtx $ VQ.getQueryParts req

  topFields <- runReaderT (VQ.validateGQ queryParts) gCtx
  let varDefs = G._todVariableDefinitions $ VQ.qpOpDef queryParts
  return $
    fmap
      (\case
          VQ.HasuraTopField hasuraTopField ->
            ExPHasuraPartial (gCtx, hasuraTopField, varDefs)
          VQ.RemoteTopField remoteTopField -> ExPRemotePartial remoteTopField)
      topFields

  where
    role = userRole userInfo
    gCtxRoleMap = scGCtxMap sc

    checkQueryInAllowlist =
      -- only for non-admin roles
      when (role /= adminRole) $ do
        let notInAllowlist =
              not $ VQ.isQueryInAllowlist (_grQuery req) (scAllowlist sc)
        when notInAllowlist $ modifyQErr modErr $ throwVE "query is not allowed"

    modErr e =
      let msg = "query is not in any of the allowlists"
      in e{qeInternal = Just $ J.object [ "message" J..= J.String msg]}

-- An execution operation, in case of
-- queries and mutations it is just a transaction
-- to be executed
data ExecOp
  = ExOpQuery !LazyRespTx
  | ExOpMutation !LazyRespTx
  | ExOpSubs !EL.LiveQueryOp

getResolvedExecPlan
  :: (MonadError QErr m, MonadIO m)
  => PGExecCtx
  -> EP.PlanCache
  -> UserInfo
  -> SQLGenCtx
  -> Bool
  -> SchemaCache
  -> SchemaCacheVer
  -> GQLReqUnparsed
  -> m (Seq.Seq QExecPlanResolved)
getResolvedExecPlan pgExecCtx planCache userInfo sqlGenCtx enableAL sc scVer reqUnparsed = do
  planM <-
    liftIO $ EP.getPlan scVer (userRole userInfo) opNameM queryStr planCache
  let usrVars = userVars userInfo
  case planM
    -- plans are only for queries and subscriptions
        of
    Just plan ->
      pure . ExPHasura <$>
      case plan of
        EP.RPQuery queryPlan ->
          ExOpQuery <$> EQ.queryOpFromPlan usrVars queryVars queryPlan
        EP.RPSubs subsPlan ->
          ExOpSubs <$> EL.subsOpFromPlan pgExecCtx usrVars queryVars subsPlan
    Nothing -> noExistingPlan
  where
    GQLReq opNameM queryStr queryVars = reqUnparsed
    addPlanToCache plan =
      liftIO $
      EP.addPlan scVer (userRole userInfo) opNameM queryStr plan planCache
    noExistingPlan = do
      req <- toParsed reqUnparsed
      partialExecPlans <- getExecPlanPartial userInfo sc enableAL req
      forM partialExecPlans $ \partialExecPlan ->
        case partialExecPlan of
          ExPRemotePartial r -> pure (ExPRemote r)
          ExPHasuraPartial (gCtx, rootSelSet, varDefs) -> do
            case rootSelSet of
              VQ.HasuraTopMutation field ->
                ExPHasura . ExOpMutation <$>
                getMutOp gCtx sqlGenCtx userInfo (pure field)
              VQ.HasuraTopQuery originalField -> do
                let (constructor, alteredField) =
                      case rebuildFieldStrippingRemoteRels originalField of
                        Nothing -> (ExPHasura, originalField)
                        Just (newField, cursors) ->
                          trace
                            (unlines
                               [ "originalField = " ++ show originalField
                               , "newField = " ++ show newField
                               , "cursors = " ++ show (fmap rrPath cursors)
                               ])
                            (flip ExPMixed cursors, newField)
                (queryTx, planM) <-
                  getQueryOp gCtx sqlGenCtx userInfo (pure alteredField) varDefs
                mapM_ (addPlanToCache . EP.RPQuery) planM
                return $ constructor $ ExOpQuery queryTx
              VQ.HasuraTopSubscription fld -> do
                (lqOp, planM) <-
                  getSubsOp
                    pgExecCtx
                    gCtx
                    sqlGenCtx
                    userInfo
                    reqUnparsed
                    varDefs
                    fld
                mapM_ (addPlanToCache . EP.RPSubs) planM
                return $ ExPHasura $ ExOpSubs lqOp

-- Rebuild the field with remote relationships removed, and paths that
-- point back to them.
rebuildFieldStrippingRemoteRels ::
     VQ.Field -> Maybe (VQ.Field, NonEmpty RemoteRelField)
rebuildFieldStrippingRemoteRels =
  extract . flip runState mempty . rebuild mempty
  where
    extract (field, remoteRelFields) =
      fmap (field, ) (NE.nonEmpty remoteRelFields)
    rebuild parentPath field0 = do
      selSet <-
        traverse
          (\subfield ->
             case _fRemoteRel subfield of
               Nothing -> fmap pure (rebuild thisPath subfield)
               Just remoteField -> do
                 modify (remoteRelField :)
                 pure mempty
                 where remoteRelField =
                         RemoteRelField
                           { rrRemoteField = remoteField
                           , rrField = subfield
                           , rrPath = thisPath
                           })
          (toList (_fSelSet field0))
      pure field0 {_fSelSet = mconcat selSet}
      where
        thisPath = parentPath <> Path (pure (_fAlias field0))

-- | Get a list of fields needed from a hasura result.
neededHasuraFields
  :: RemoteField -> [FieldName]
neededHasuraFields remoteField = toList (rtrHasuraFields remoteRelationship)
  where
    remoteRelationship = rmfRemoteRelationship remoteField

-- | Extract from the Hasura results the remote relationship arguments.
extractRemoteRelArguments ::
     EncJSON
  -> NonEmpty RemoteRelField
  -> Either String ( Map.HashMap RemoteRelKey RemoteRelField
                   , Map.HashMap RemoteRelKey (Seq.Seq (Map.HashMap G.Name G.ValueConst)))
extractRemoteRelArguments encJson rels =
  case J.eitherDecode (encJToLBS encJson) of
    Left err -> Left err
    Right object ->
      case Map.lookup ("data" :: Text) object of
        Nothing ->
          Left
            ("Couldn't find `data' payload in " <> L8.unpack (J.encode object))
        Just value ->
          fmap
            (Map.fromList (toList keyedRemotes), )
            (flip execStateT mempty (extractFromResult keyedRemotes value))
  where
    keyedRemotes = NE.zip (fmap RemoteRelKey (0 :| [1 ..])) rels

-- | Extract from a given result.
extractFromResult ::
     NonEmpty (RemoteRelKey, RemoteRelField)
  -> J.Value
  -> StateT (Map.HashMap RemoteRelKey (Seq.Seq (Map.HashMap G.Name G.ValueConst))) (Either String) ()
extractFromResult keyedRemotes value =
  case value of
    J.Array values -> mapM_ (extractFromResult keyedRemotes) values
    J.Object hashmap -> do
      remotesRows :: Map.HashMap RemoteRelKey (Seq.Seq (G.Name, G.ValueConst)) <-
        foldM
          (\result (key, remotes) ->
             case Map.lookup key hashmap of
               Just subvalue -> do
                 let (remoteRelKeys, unfinishedKeyedRemotes) =
                       partitionEithers (toList remotes)
                 case NE.nonEmpty unfinishedKeyedRemotes of
                   Nothing -> pure ()
                   Just subRemotes -> do
                     extractFromResult subRemotes subvalue
                 pure
                   (foldl'
                      (\result' remoteRelKey ->
                         Map.insertWith
                           (<>)
                           remoteRelKey
                           (pure (G.Name key, valueToValueConst subvalue))
                           result')
                      result
                      remoteRelKeys)
               Nothing ->
                 lift
                   (Left
                      ("Expected key " <> show key <> " at this position: " <>
                       L8.unpack (J.encode value))))
          mempty
          (Map.toList candidates)
      mapM_
        (\(remoteRelKey, row) ->
           modify
             (Map.insertWith
                (<>)
                remoteRelKey
                (pure (Map.fromList (toList row)))))
        (Map.toList remotesRows)
    _ -> pure ()
  where
    candidates ::
         Map.HashMap Text (NonEmpty (Either RemoteRelKey ( RemoteRelKey
                                                         , RemoteRelField)))
    candidates =
      foldl'
        (\(!outerHashmap) keys ->
           foldl'
             (\(!innerHashmap) (key, remote) ->
                Map.insertWith (<>) key (pure remote) innerHashmap)
             outerHashmap
             keys)
        mempty
        (toList (fmap peelRemoteKeys keyedRemotes))

-- | Peel one layer of expected keys from the remote to be looked up
-- at the current level of the result object.
peelRemoteKeys ::
     (RemoteRelKey, RemoteRelField) -> [(Text, Either RemoteRelKey (RemoteRelKey, RemoteRelField))]
peelRemoteKeys (remoteRelKey, remoteRelField) =
  map
    (updatingRelPath . unconsPath)
    (neededHasuraFields (rrRemoteField remoteRelField))
  where
    updatingRelPath ::
         Either Text (Text, Path)
      -> (Text, Either RemoteRelKey (RemoteRelKey, RemoteRelField))
    updatingRelPath result =
      case result of
        Right (key, remainingPath) ->
          ( key
          , Right (remoteRelKey, remoteRelField {rrPath = remainingPath}))
        Left key -> (key, Left remoteRelKey)
    unconsPath :: FieldName -> Either Text (Text, Path)
    unconsPath fieldName =
      case rrPath remoteRelField of
        Path Seq.Empty -> Left (getFieldNameTxt fieldName)
        Path (G.Alias (G.Name key) Seq.:<| xs) -> Right (key, Path xs)

-- | Convert a JSON value to a GraphQL value.
valueToValueConst :: J.Value -> G.ValueConst
valueToValueConst =
  \case
    J.Array xs -> G.VCList (G.ListValueG (fmap valueToValueConst (toList xs)))
    J.String str -> G.VCString (G.StringValue str)
    -- TODO: Note the danger zone of scientific:
    J.Number sci -> either G.VCFloat G.VCInt (floatingOrInteger sci)
    J.Null -> G.VCNull
    J.Bool b -> G.VCBoolean b
    J.Object hashmap ->
      G.VCObject
        (G.ObjectValueG
           (map
              (\(key, value) ->
                 G.ObjectFieldG (G.Name key) (valueToValueConst value))
              (Map.toList hashmap)))

-- Monad for resolving a hasura query/mutation
type E m =
  ReaderT ( UserInfo
          , OpCtxMap
          , TypeMap
          , FieldMap
          , OrdByCtx
          , InsCtxMap
          , SQLGenCtx
          ) (ExceptT QErr m)

runE
  :: (MonadError QErr m)
  => GCtx
  -> SQLGenCtx
  -> UserInfo
  -> E m a
  -> m a
runE ctx sqlGenCtx userInfo action = do
  res <- runExceptT $ runReaderT action
    (userInfo, opCtxMap, typeMap, fldMap, ordByCtx, insCtxMap, sqlGenCtx)
  either throwError return res
  where
    opCtxMap = _gOpCtxMap ctx
    typeMap = _gTypes ctx
    fldMap = _gFields ctx
    ordByCtx = _gOrdByCtx ctx
    insCtxMap = _gInsCtxMap ctx

getQueryOp
  :: (MonadError QErr m)
  => GCtx
  -> SQLGenCtx
  -> UserInfo
  -> VQ.SelSet
  -> [G.VariableDefinition]
  -> m (LazyRespTx, Maybe EQ.ReusableQueryPlan)
getQueryOp gCtx sqlGenCtx userInfo fields varDefs =
  runE gCtx sqlGenCtx userInfo $ EQ.convertQuerySelSet varDefs fields

mutationRootName :: Text
mutationRootName = "mutation_root"

resolveMutSelSet
  :: ( MonadError QErr m
     , MonadReader r m
     , Has UserInfo r
     , Has OpCtxMap r
     , Has FieldMap r
     , Has OrdByCtx r
     , Has SQLGenCtx r
     , Has InsCtxMap r
     )
  => VQ.SelSet
  -> m LazyRespTx
resolveMutSelSet fields = do
  aliasedTxs <- forM (toList fields) $ \fld -> do
    fldRespTx <- case VQ._fName fld of
      "__typename" -> return $ return $ encJFromJValue mutationRootName
      _            -> liftTx <$> GR.mutFldToTx fld
    return (G.unName $ G.unAlias $ VQ._fAlias fld, fldRespTx)

  -- combines all transactions into a single transaction
  return $ toSingleTx aliasedTxs
  where
    -- A list of aliased transactions for eg
    -- [("f1", Tx r1), ("f2", Tx r2)]
    -- are converted into a single transaction as follows
    -- Tx {"f1": r1, "f2": r2}
    toSingleTx :: [(Text, LazyRespTx)] -> LazyRespTx
    toSingleTx aliasedTxs =
      fmap encJFromAssocList $
      forM aliasedTxs $ \(al, tx) -> (,) al <$> tx

getMutOp
  :: (MonadError QErr m)
  => GCtx
  -> SQLGenCtx
  -> UserInfo
  -> VQ.SelSet
  -> m LazyRespTx
getMutOp ctx sqlGenCtx userInfo selSet =
  runE ctx sqlGenCtx userInfo $ resolveMutSelSet selSet

getSubsOpM
  :: ( MonadError QErr m
     , MonadReader r m
     , Has OpCtxMap r
     , Has FieldMap r
     , Has OrdByCtx r
     , Has SQLGenCtx r
     , Has UserInfo r
     , MonadIO m
     )
  => PGExecCtx
  -> GQLReqUnparsed
  -> [G.VariableDefinition]
  -> VQ.Field
  -> m (EL.LiveQueryOp, Maybe EL.SubsPlan)
getSubsOpM pgExecCtx req varDefs fld =
  case VQ._fName fld of
    "__typename" ->
      throwVE "you cannot create a subscription on '__typename' field"
    _            -> do
      astUnresolved <- GR.queryFldToPGAST fld
      EL.subsOpFromPGAST pgExecCtx req varDefs (VQ._fAlias fld, astUnresolved)

getSubsOp
  :: ( MonadError QErr m
     , MonadIO m
     )
  => PGExecCtx
  -> GCtx
  -> SQLGenCtx
  -> UserInfo
  -> GQLReqUnparsed
  -> [G.VariableDefinition]
  -> VQ.Field
  -> m (EL.LiveQueryOp, Maybe EL.SubsPlan)
getSubsOp pgExecCtx gCtx sqlGenCtx userInfo req varDefs fld =
  runE gCtx sqlGenCtx userInfo $ getSubsOpM pgExecCtx req varDefs fld

execRemoteGQ
  :: (MonadIO m, MonadError QErr m)
  => HTTP.Manager
  -> UserInfo
  -> [N.Header]
  -> VQ.RemoteTopQuery
  -> m (HttpResponse EncJSON)
execRemoteGQ manager userInfo reqHdrs remoteTopField = do
  hdrs <- getHeadersFromConf hdrConf
  let confHdrs   = map (\(k, v) -> (CI.mk $ CS.cs k, CS.cs v)) hdrs
      clientHdrs = bool [] filteredHeaders fwdClientHdrs
      -- filter out duplicate headers
      -- priority: conf headers > resolved userinfo vars > client headers
      hdrMaps    = [ Map.fromList confHdrs
                   , Map.fromList userInfoToHdrs
                   , Map.fromList clientHdrs
                   ]
      finalHdrs  = foldr Map.union Map.empty hdrMaps
      options    = wreqOptions manager (Map.toList finalHdrs)

  gqlReq <- fieldToRequest field
  res  <- liftIO $ try $ Wreq.postWith options (show url) (encJToLBS (encJFromJValue gqlReq))
  resp <- either httpThrow return res
  let cookieHdr = getCookieHdr (resp ^? Wreq.responseHeader "Set-Cookie")
      respHdrs  = Just $ mkRespHeaders cookieHdr
  return $ HttpResponse (encJFromLBS $ resp ^. Wreq.responseBody) respHdrs

  where
    VQ.RemoteTopQuery (RemoteSchemaInfo url hdrConf fwdClientHdrs) field =
      remoteTopField

    httpThrow :: (MonadError QErr m) => HTTP.HttpException -> m a
    httpThrow err = throw500 $ T.pack . show $ err

    userInfoToHdrs = map (\(k, v) -> (CI.mk $ CS.cs k, CS.cs v)) $
                     userInfoToList userInfo
    filteredHeaders = filterUserVars $ filterRequestHeaders reqHdrs

    filterUserVars hdrs =
      let txHdrs = map (\(n, v) -> (bsToTxt $ CI.original n, bsToTxt v)) hdrs
      in map (\(k, v) -> (CI.mk $ CS.cs k, CS.cs v)) $
         filter (not . isUserVar . fst) txHdrs

    getCookieHdr = maybe [] (\h -> [("Set-Cookie", h)])

    mkRespHeaders hdrs =
      map (\(k, v) -> Header (bsToTxt $ CI.original k, bsToTxt v)) hdrs

fieldToRequest
  :: (MonadIO m, MonadError QErr m)
  => VQ.Field
  -> m GQLReqParsed
fieldToRequest field = do
  case fieldToField field of
    Right gfield ->
      pure
        (GQLReq
           { _grOperationName = Nothing
           , _grQuery =
               GQLExecDoc
                 [ G.ExecutableDefinitionOperation
                     (G.OperationDefinitionUnTyped [G.SelectionField gfield])
                 ]
           , _grVariables = Nothing -- TODO: Put variables in here?
           })
    Left err -> throw500 ("While converting remote field: " <> err)

fieldToField :: VQ.Field -> Either Text G.Field
fieldToField field = do
  args <- traverse makeArgument (Map.toList (VQ._fArguments field))
  selections <- traverse fieldToField (VQ._fSelSet field)
  pure $ G.Field
    { _fAlias = Just (VQ._fAlias field)
    , _fName = VQ._fName field
    , _fArguments = args
    , _fDirectives = []
    , _fSelectionSet = fmap G.SelectionField (toList selections)
    }

makeArgument :: (G.Name, AnnInpVal) -> Either Text G.Argument
makeArgument (gname, annInpVal) =
  do v <- annInpValToValue annInpVal
     pure $ G.Argument {_aName = gname, _aValue = v}

annInpValToValue :: AnnInpVal -> Either Text G.Value
annInpValToValue = annGValueToValue . _aivValue

annGValueToValue :: AnnGValue -> Either Text G.Value
annGValueToValue =
  \case
    AGScalar _ty mv ->
      case mv of
        Nothing -> pure G.VNull
        Just pg -> pgcolvalueToGValue pg
    AGEnum _ mval ->
      case mval of
        Nothing -> pure G.VNull
        Just enumValue -> pure (G.VEnum enumValue)
    AGObject _ mobj ->
      case mobj of
        Nothing -> pure G.VNull
        Just obj -> do
          fields <-
            traverse
              (\(k, av) -> do
                 v <- annInpValToValue av
                 pure (G.ObjectFieldG {_ofName = k, _ofValue = v}))
              (OHM.toList obj)
          pure (G.VObject (G.ObjectValueG fields))
    AGArray _ mvs ->
      case mvs of
        Nothing -> pure G.VNull
        Just vs -> G.VList . G.ListValueG <$> traverse annInpValToValue vs

pgcolvalueToGValue :: PGColValue -> Either Text G.Value
pgcolvalueToGValue colVal = case colVal of
  PGValInteger i  -> pure $ G.VInt $ fromIntegral i
  PGValSmallInt i -> pure $ G.VInt $ fromIntegral i
  PGValBigInt i   -> pure $ G.VInt $ fromIntegral i
  PGValFloat f    -> pure $ G.VFloat $ realToFrac f
  PGValDouble d   -> pure $ G.VFloat $ realToFrac d
  -- TODO: Scientific is a danger zone; use its safe conv function.
  PGValNumeric sc -> pure $ G.VFloat $ realToFrac sc
  PGValBoolean b  -> pure $ G.VBoolean b
  PGValChar t     -> pure $ G.VString (G.StringValue (T.singleton t))
  PGValVarchar t  -> pure $ G.VString (G.StringValue t)
  PGValText t     -> pure $ G.VString (G.StringValue t)
  PGValDate d     -> pure $ G.VString $ G.StringValue $ T.pack $ showGregorian d
  PGValTimeStampTZ u -> pure $
    G.VString $ G.StringValue $   T.pack $ formatTime defaultTimeLocale "%FT%T%QZ" u
  PGValTimeTZ (ZonedTimeOfDay tod tz) -> pure $
    G.VString $ G.StringValue $   T.pack (show tod ++ timeZoneOffsetString tz)
  PGNull _ -> pure G.VNull
  PGValJSON {}    -> Left "PGValJSON: cannot convert"
  PGValJSONB {}  -> Left "PGValJSONB: cannot convert"
  PGValGeo {}    -> Left "PGValGeo: cannot convert"
  PGValUnknown t -> pure $ G.VString $ G.StringValue t

demoResult :: J.Value
demoResult = J.object ["grandparent" J..= J.object ["parent" J..= J.object ["child" J..= (123 :: Int)]]]

-- > demoResult
-- Object (fromList [("grandparent",Object (fromList [("parent",Object (fromList [("child",Number 123.0)]))]))])
-- > extractPath (Path (fmap (G.Alias . G.Name) ["grandparent","parent"])) (G.Name "child") demoResult
-- Right (VCFloat 123.0)

-- | Extract a value from the path.
extractPath :: Path -> G.Name -> J.Value -> Either String G.ValueConst
extractPath (Path parents) gname@(G.Name finalKey) value =
  case parents of
    G.Alias (G.Name key) Seq.:<| restOfParents ->
      case value of
        J.Object hashmap ->
          case Map.lookup key hashmap of
            Just subvalue -> extractPath (Path restOfParents) gname subvalue
            Nothing ->
              Left
                ("extractPath: couldn't find key " <> show key <> " from path " <>
                 show parents <>
                 " in object " <>
                 L8.unpack (J.encode value))
        _ -> Left ("extractPath: initial: expected object but got: " <> show value)
    Seq.Empty ->
      case value of
        J.Object hashmap ->
          case Map.lookup finalKey hashmap of
            Just arg ->
              let !valueConst = valueToValueConst arg
               in pure valueConst
            Nothing ->
              Left
                ("extractPath: didn't find key " <> show finalKey <>
                 " from path " <>
                 show parents <>
                 " in object " <>
                 L8.unpack (J.encode value))
        _ -> Left ("extractPath: final: expected object but got: " <> show value)
