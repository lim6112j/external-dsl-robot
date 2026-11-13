{-# LANGUAGE OverloadedStrings #-}
-- | Lower the AST into VDA 5050 v3.0.0 JSON messages.
--
-- This module owns every piece of the standard's mandatory bookkeeping that
-- the language does not make the operator write:
--
--   * @headerId@ allocation, per topic, incremented per message;
--   * @sequenceId@ numbering, shared between nodes and edges so that nodes
--     land on even and edges on odd values in traversal order;
--   * @actionId@ generation, unique within a message and derived from the
--     action type so it stays readable and diffable;
--   * @edgeId@ synthesis when the operator did not name the edge.
--
-- It deliberately does /not/ second-guess the source: whatever @blockingType@
-- the program says is what gets emitted. Run "RobotDSL.Validate" first, which
-- is where context-dependent rules (such as instant actions requiring
-- @blockingType: \"NONE\"@) are enforced.
module RobotDSL.Emit
  ( EmitContext(..)
  , MessageKind(..)
  , EmittedMessage(..)
  , emit
  , resolveContext
  , kindFileSuffix
  ) where

import Control.Monad.State.Strict (State, evalState, get, put)
import Data.Aeson (Value(..), object, (.=))
import qualified Data.Aeson
import Data.Char (isAlphaNum, toLower)
import qualified Data.Map.Strict as Map
import qualified Data.Vector as V
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import RobotDSL.AST
import RobotDSL.Version

-- | Everything the emitter needs that is not in the source file: who the
-- message is for, and the header bookkeeping.
data EmitContext = EmitContext
  { ecManufacturer :: !Text
  , ecSerialNumber :: !Text
  , ecHeaderId     :: !Int
  , ecTimestamp    :: !Text
  , ecVersion      :: !ProtocolVersion
  -- ^ Default @mapId@ for node positions that do not name one.
  , ecMapId        :: !(Maybe Text)
  } deriving (Eq, Show)

data MessageKind = MkOrder | MkInstantActions | MkZoneSet
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | One emitted message, ready to be written out or published.
data EmittedMessage = EmittedMessage
  { emKind  :: !MessageKind
  , emName  :: !Text
  -- ^ Suggested file base name, derived from the declaration's id.
  , emValue :: !Value
  } deriving (Eq, Show)

-- | File-name suffix for a message kind, e.g. @order@.
kindFileSuffix :: MessageKind -> Text
kindFileSuffix MkOrder          = "order"
kindFileSuffix MkInstantActions = "instantActions"
kindFileSuffix MkZoneSet        = "zoneSet"

-- | Lower a whole program into messages, in source order.
emit :: Program -> EmitContext -> [EmittedMessage]
emit prog ctx =
  zipWith build decls (assignHeaderIds (ecHeaderId ctx) decls)
  where
    decls = progDecls prog
    build d hid = case d of
      DeclZoneSet zs -> EmittedMessage MkZoneSet (zsId zs)
                          (zoneSetJSON ctx hid zs)
      DeclOrder o    -> EmittedMessage MkOrder (ordId o)
                          (orderJSON ctx hid o)
      DeclInstant ia -> EmittedMessage MkInstantActions (instantName ia)
                          (instantJSON ctx hid ia)

instantName :: InstantActions -> Text
instantName ia = maybe "instant" id (iaId ia)

-- | Layer a program's own @header@, @timestamp@, @version@ and @map@
-- declarations over a context.
--
-- The file wins: it is the source of truth for its own messages, and the
-- context supplies only what the file leaves unset. This is what lets an
-- operator pin @headerId@ and @timestamp@ in a config file while the CLI
-- supplies sane defaults for everything else.
resolveContext :: Program -> EmitContext -> EmitContext
resolveContext prog ctx = ctx
  { ecHeaderId  = fromMaybe (ecHeaderId ctx)  (hdrHeaderId  (progHeader prog))
  , ecTimestamp = fromMaybe (ecTimestamp ctx) (hdrTimestamp (progHeader prog))
  , ecVersion   = fromMaybe (ecVersion ctx)   (hdrVersion   (progHeader prog))
  , ecMapId     = firstJust (progMapId prog) (ecMapId ctx)
  }
  where
    firstJust a b = case a of
      Just v  -> Just v
      Nothing -> b

-- | Allocate @headerId@s per topic.
--
-- The standard defines headerId per topic and increments it by one per sent
-- message, so two orders in one file get consecutive ids while a zoneSet in
-- the same file starts from the same base again.
assignHeaderIds :: Int -> [Decl] -> [Int]
assignHeaderIds base = go initial
  where
    initial = Map.fromList [(k, base) | k <- [minBound .. maxBound]]
    go _ [] = []
    go counters (d : ds) =
      let topic  = declTopic d
          hid    = counters Map.! topic
      in hid : go (Map.insert topic (hid + 1) counters) ds

declTopic :: Decl -> MessageKind
declTopic d = case d of
  DeclZoneSet{} -> MkZoneSet
  DeclOrder{}   -> MkOrder
  DeclInstant{} -> MkInstantActions

-- ---------------------------------------------------------------------------
-- Message level
-- ---------------------------------------------------------------------------

headerFields :: EmitContext -> Int -> [(Data.Aeson.Key, Value)]
headerFields ctx hid =
  [ "headerId"     .= hid
  , "timestamp"    .= ecTimestamp ctx
  , "version"      .= protocolVersionText (ecVersion ctx)
  , "manufacturer" .= ecManufacturer ctx
  , "serialNumber" .= ecSerialNumber ctx
  ]

zoneSetJSON :: EmitContext -> Int -> ZoneSet -> Value
zoneSetJSON ctx hid zs = runEmit $ do
  zones <- traverse zoneJSON (zsZones zs)
  pure $ object (headerFields ctx hid ++
    [ "zoneSet" .= object
        (  [ "zoneSetId" .= zsId zs
            , "zones"    .= zones
            , "mapId"    .= fromMaybe (fromMaybe "" (ecMapId ctx)) (zsMapId zs)
            ]
        ++ [ "zoneSetDescriptor" .= d | Just d <- [zsDescriptor zs] ]
        )
    ])

orderJSON :: EmitContext -> Int -> Order -> Value
orderJSON ctx hid o = runEmit $ do
  -- Actions are numbered in traversal order, not in the order the nodes and
  -- edges happen to be stored in the message, so an id always points at the
  -- same place in the route as it does in the source.
  let indexed = zip [0 ..] (stepPairs o)
  (nodes, edges) <- collect [] [] indexed
  pure $ object (headerFields ctx hid ++
    [ "orderId"        .= ordId o
    , "orderUpdateId"  .= ordUpdateId o
    ]
    ++ [ "orderDescription" .= d | Just d <- [ordDescriptor o] ]
    ++ [ "nodes" .= nodes, "edges" .= edges ])
  where
    collect ns es [] = pure (reverse ns, reverse es)
    collect ns es ((i, (rel, st)) : rest) = case st of
      StepNode n -> do
        v <- nodeJSON ctx i rel n
        collect (v : ns) es rest
      StepEdge e -> do
        v <- edgeJSON i rel e
        collect ns (v : es) rest

instantJSON :: EmitContext -> Int -> InstantActions -> Value
instantJSON ctx hid ia = runEmit $ do
  acts <- traverse actionJSON (iaActions ia)
  pure $ object (headerFields ctx hid ++ ["actions" .= acts])

-- | Flatten an order's segments into @(released, step)@ pairs in traversal
-- order. The traversal index doubles as the @sequenceId@, which is what puts
-- nodes on even and edges on odd values.
stepPairs :: Order -> [(Bool, Step)]
stepPairs o =
  [ (segReleased seg, step) | seg <- ordSegments o, step <- segSteps seg ]

-- ---------------------------------------------------------------------------
-- Zones
-- ---------------------------------------------------------------------------

zoneJSON :: Zone -> Emit Value
zoneJSON z = do
  extras <- zoneExtras (zoneKind z)
  pure $ object $
    [ "zoneId"   .= zoneId z
    , "zoneType" .= zoneTypeText (zoneKind z)
    ]
    ++ [ "zoneDescriptor" .= d | Just d <- [zoneDescriptor z] ]
    ++ extras
    ++ [ "vertices" .= map vertexJSON (zoneVertices z) ]

zoneTypeText :: ZoneKind -> Text
zoneTypeText k = case k of
  ZkBlocked                -> "BLOCKED"
  ZkLineGuided             -> "LINE_GUIDED"
  ZkRelease                -> "RELEASE"
  ZkCoordinatedReplanning  -> "COORDINATED_REPLANNING"
  ZkSpeedLimit{}           -> "SPEED_LIMIT"
  ZkAction{}               -> "ACTION"
  ZkPriority{}             -> "PRIORITY"
  ZkPenalty{}              -> "PENALTY"
  ZkDirected{}             -> "DIRECTED"
  ZkBidirected{}           -> "BIDIRECTED"

-- | Emitted in the monad so every action in the message shares one id counter.
zoneExtras :: ZoneKind -> Emit [(Data.Aeson.Key, Value)]
zoneExtras k = case k of
  ZkSpeedLimit s ->
    pure ["maximumSpeed" .= s]
  ZkAction entry during exit -> do
    e <- traverse actionJSON entry
    d <- traverse actionJSON during
    x <- traverse actionJSON exit
    pure
      [ "entryActions"  .= e
      , "duringActions" .= d
      , "exitActions"   .= x
      ]
  -- The official schema spells the property definition "priorityFactor "
  -- (with a trailing space) but its "required" list uses "priorityFactor".
  -- Presence is what the schema checks, so emit the clean name.
  ZkPriority f ->
    pure ["priorityFactor" .= f]
  ZkPenalty f ->
    pure ["penaltyFactor" .= f]
  ZkDirected dir lim ->
    pure
      [ "direction"  .= dir
      , "limitation" .= limitationText lim
      ]
  ZkBidirected dir lim ->
    pure
      [ "direction"  .= dir
      , "limitation" .= softLimitationText lim
      ]
  _ -> pure []
vertexJSON :: Vertex -> Value
vertexJSON (Vertex x y) = object ["x" .= x, "y" .= y]

limitationText :: Limitation -> Text
limitationText LmSoft      = "SOFT"
limitationText LmRestricted = "RESTRICTED"
limitationText LmStrict    = "STRICT"

softLimitationText :: SoftLimitation -> Text
softLimitationText SlSoft      = "SOFT"
softLimitationText SlRestricted = "RESTRICTED"

-- ---------------------------------------------------------------------------
-- Order contents
-- ---------------------------------------------------------------------------

nodeJSON :: EmitContext -> Int -> Bool -> Node -> Emit Value
nodeJSON ctx seqId released n = do
  acts <- traverse actionJSON (nodeActions n)
  pure $ object $
    [ "nodeId"     .= nodeId n
    , "sequenceId" .= seqId
    , "released"   .= released
    , "actions"    .= acts
    ]
    ++ [ "nodeDescriptor" .= d | Just d <- [nodeDescriptor n] ]
    ++ [ "nodePosition" .= nodePositionJSON ctx p | Just p <- [nodePosition n] ]

nodePositionJSON :: EmitContext -> NodePosition -> Value
nodePositionJSON ctx p = object $
  [ "x" .= npX p
  , "y" .= npY p
  , "mapId" .= fromMaybe (fromMaybe "" (ecMapId ctx)) (npMapId p)
  ]
  ++ [ "theta" .= t | Just t <- [npTheta p] ]
  ++ [ "allowedDeviationXY" .= deviationJSON d | Just d <- [npAllowedDeviationXY p] ]
  ++ [ "allowedDeviationTheta" .= t | Just t <- [npAllowedDeviationTheta p] ]

deviationJSON :: DeviationXY -> Value
deviationJSON d = object ["a" .= dvA d, "b" .= dvB d, "theta" .= dvTheta d]

edgeJSON :: Int -> Bool -> Edge -> Emit Value
edgeJSON seqId released e = do
  acts <- traverse actionJSON (edgeActions e)
  let edgeIdText = maybe ("edge-" <> T.pack (show seqId)) id (edgeId e)
  pure $ object $
    [ "edgeId"     .= edgeIdText
    , "sequenceId" .= seqId
    , "released"   .= released
    , "actions"    .= acts
    ]
    ++ [ "edgeDescriptor" .= d | Just d <- [edgeDescriptor e] ]
    ++ [ "maximumSpeed" .= v | Just v <- [edgeMaxSpeed e] ]
    ++ [ "maximumMobileRobotHeight" .= v | Just v <- [edgeMaxMobileRobotHeight e] ]
    ++ [ "minimumLoadHandlingDeviceHeight" .= v
       | Just v <- [edgeMinLoadHandlingDeviceHeight e] ]
    ++ [ "orientation" .= v | Just v <- [edgeOrientation e] ]
    ++ [ "orientationType" .= orientationTypeText t | Just t <- [edgeOrientationType e] ]
    ++ [ "direction" .= v | Just v <- [edgeDirection e] ]
    ++ [ "reachOrientationBeforeEntering" .= v
       | Just v <- [edgeReachOrientationBeforeEntering e] ]
    ++ [ "maxRotationSpeed" .= v | Just v <- [edgeMaxRotationSpeed e] ]
    ++ [ "trajectory" .= trajectoryJSON t | Just t <- [edgeTrajectory e] ]
    ++ [ "length" .= v | Just v <- [edgeLength e] ]
    ++ [ "corridor" .= corridorJSON c | Just c <- [edgeCorridor e] ]

orientationTypeText :: OrientationType -> Text
orientationTypeText OtGlobal    = "GLOBAL"
orientationTypeText OtTangential = "TANGENTIAL"

trajectoryJSON :: Trajectory -> Value
trajectoryJSON t = object $
  [ "controlPoints" .= map controlPointJSON (trajControlPoints t) ]
  ++ [ "degree" .= d | Just d <- [trajDegree t] ]
  ++ [ "knotVector" .= ks | Just ks <- [trajKnotVector t] ]

controlPointJSON :: ControlPoint -> Value
controlPointJSON c = object $
  [ "x" .= cpX c, "y" .= cpY c ]
  ++ [ "weight" .= w | Just w <- [cpWeight c] ]

corridorJSON :: Corridor -> Value
corridorJSON c = object $
  [ "leftWidth"  .= corrLeftWidth c
  , "rightWidth" .= corrRightWidth c
  ]
  ++ [ "corridorReferencePoint" .= corridorRefPointText r
     | Just r <- [corrReferencePoint c] ]
  ++ [ "releaseRequired" .= v | Just v <- [corrReleaseRequired c] ]
  ++ [ "releaseLossBehavior" .= releaseLossText v
     | Just v <- [corrReleaseLossBehavior c] ]

corridorRefPointText :: CorridorRefPoint -> Text
corridorRefPointText CrKinematicCenter = "KINEMATIC_CENTER"
corridorRefPointText CrContour         = "CONTOUR"

releaseLossText :: ReleaseLossBehavior -> Text
releaseLossText RlStop   = "STOP"
releaseLossText RlReturn = "RETURN"

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

-- | Action ids are generated by a counter threaded through a message so they
-- stay unique and stable for a given source file.
type Emit = State Int

runEmit :: Emit Value -> Value
runEmit = (`evalState` 1)

actionJSON :: Action -> Emit Value
actionJSON a = do
  n <- get
  put (n + 1)
  pure $ object $
    [ "actionId"     .= (slug (actType a) <> "-" <> T.pack (show n))
    , "actionType"   .= actType a
    , "blockingType" .= blockingTypeText (actBlocking a)
    ]
    ++ [ "actionDescriptor" .= d | Just d <- [actDescriptor a] ]
    ++ [ "actionParameters" .= map paramJSON (actParameters a)
       | not (null (actParameters a)) ]
    ++ [ "retriable" .= r | Just r <- [actRetriable a] ]

paramJSON :: (Text, ActionValue) -> Value
paramJSON (k, v) = object ["key" .= k, "value" .= actionValueJSON v]

actionValueJSON :: ActionValue -> Value
actionValueJSON (AVString s) = String s
actionValueJSON (AVNumber n) = Number n
actionValueJSON (AVBool b)   = Bool b
actionValueJSON (AVArray xs) = Array (V.fromList (map actionValueJSON xs))

blockingTypeText :: BlockingType -> Text
blockingTypeText BtNone   = "NONE"
blockingTypeText BtSoft   = "SOFT"
blockingTypeText BtSingle = "SINGLE"
blockingTypeText BtHard   = "HARD"

-- | Turn an action type into a stable, readable id fragment: @init position@
-- becomes @init-position@.
slug :: Text -> Text
slug = T.intercalate "-" . T.words . T.map sanitize
  where
    sanitize c
      | isAlphaNum c = toLower c
      | otherwise    = ' '