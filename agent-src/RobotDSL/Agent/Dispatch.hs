{-# LANGUAGE OverloadedStrings #-}
-- | Plan a fleet-gateway mission from validated robotdsl source.
--
-- The gateway does not accept a VDA 5050 order: it takes the route itself and
-- assembles the order, deriving @headerId@, edges and geometry from its map.
-- This module is the bridge — it lowers the DSL's waypoints into that shape.
--
-- Nothing here talks to the gateway. Planning is pure and every reason a
-- mission cannot be driven is a rejection, not a warning: unlike the Phase 1
-- preview, a plan that reaches this module is on its way to a real robot.
module RobotDSL.Agent.Dispatch
  ( DispatchOutcome(..)
  , DispatchConfig(..)
  , planOrder
  , dispatchOrder
  , actionValueJSON
  , blockingTypeJSON
  ) where

import Data.Aeson (Value(..), object, (.=))
import qualified Data.Aeson.Key as Key
import Data.IORef (IORef, modifyIORef', readIORef)
import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V

import RobotDSL.AST
import RobotDSL.Agent.Context (Vocabulary)
import RobotDSL.Agent.Fleet (FleetConfig, RobotRef(..), fetchRobots, postJson)
import RobotDSL.Agent.Loop (LoopConfig(..), parseValidate)
import RobotDSL.Agent.Preview (Preview(..), preview)

-- | A mission ready for the gateway.
data DispatchOutcome = DispatchOutcome
  { doRequest :: !Value
  -- ^ The exact @OrderRequest@ JSON body.
  , doOrderId :: !Text
  -- ^ The order id, kept separately for duplicate detection.
  } deriving (Eq, Show)

-- | Turn a source file into one gateway order, or explain why it cannot run.
--
-- The parse/validate path is the same one the generation loop and the save
-- route use, so a mission cannot bypass validation by arriving here. The
-- preview's reasons are reused verbatim: the operator sees the same sentence
-- in the UI and in a rejection.
planOrder :: Vocabulary -> LoopConfig -> RobotRef -> Text
          -> Either [Text] DispatchOutcome
planOrder voc cfg robot src = do
  prog <- parseValidate cfg src
  let orders = [o | DeclOrder o <- progDecls prog]
      pvErrs = case preview voc prog of
        Left errs -> map T.pack errs
        Right pv  -> pvUnplaced pv ++ pvWarnings pv
      identityErrs = case progRobot prog of
        Just (m, s)
          | (m, s) /= (rrManufacturer robot, rrSerialNumber robot) ->
              [ "the DSL addresses " <> m <> ":" <> s
                  <> " but the selected robot is " <> rrRobotId robot ]
        _ -> []
      orderErrs = case orders of
        []  -> ["there is no order to dispatch"]
        [_] -> []
        ns  -> ["this file declares " <> tshow (length ns)
                  <> " orders; dispatch needs exactly one"]
      waypoints = case orders of
        (o : _) -> waypointsOf o
        _       -> []
      nodeErrs = if null waypoints
                   then ["the order has no nodes to dispatch"]
                   else []
      reasons = pvErrs ++ identityErrs ++ orderErrs ++ nodeErrs
  case (reasons, orders) of
    ([], o : _) -> Right (DispatchOutcome
      (requestOf robot o waypoints) (ordId o))
    (_, _) -> Left reasons

-- | Everything the IO half of dispatch needs. The manager and the seen-order
-- list are shared with the rest of the agent, so two dispatch calls in one
-- session cannot publish the same order twice.
data DispatchConfig = DispatchConfig
  { dcLoop         :: !LoopConfig
  , dcFleet        :: !FleetConfig
  , dcRobot        :: !RobotRef
  , dcAllowPublish :: !Bool
  -- ^ When False, a publish request is answered as a dry run. The agent has
  -- no authentication; this is the explicit opt-in before anything moves.
  , dcSeenOrders   :: !(IORef [Text])
  }

-- | Check the plan against the live fleet, then either dry run or publish.
--
-- The order matters: an invalid mission is rejected before a single read,
-- and a robot the gateway does not know is never sent an order. A gateway
-- that cannot be reached is a reason to stop, never an empty fleet to trust.
dispatchOrder :: DispatchConfig -> Text -> Bool
              -> IO (Either [Text] (Value, Bool))
dispatchOrder cfg src dryRun =
  case planOrder (lcVocab (dcLoop cfg)) (dcLoop cfg) (dcRobot cfg) src of
    Left errs -> pure (Left errs)
    Right outcome -> do
      let mgr = lcManager (dcLoop cfg)
          rid = rrRobotId (dcRobot cfg)
      known <- fetchRobots mgr (dcFleet cfg)
      case known of
        Left e -> pure (Left ["could not check the selected robot: " <> T.pack e])
        Right robots -> case find ((== rid) . rrRobotId) robots of
          Nothing -> pure (Left ["robot " <> rid <> " is not in the fleet"])
          Just r
            | not (rrOnline r) ->
                pure (Left ["robot " <> rid <> " is offline"])
            | otherwise -> publishChecked mgr outcome rid
  where
    publishChecked mgr outcome rid = do
      seen <- readIORef (dcSeenOrders cfg)
      let oid = doOrderId outcome
      if oid `elem` seen
        then pure (Left ["duplicate orderId " <> oid
                           <> " was already dispatched in this session"])
        else if dryRun || not (dcAllowPublish cfg)
          then pure (Right (dryResponse outcome, True))
          else do
            sent <- postJson mgr (dcFleet cfg) "/api/orders" (doRequest outcome)
            case sent of
              Left e -> pure (Left [T.pack e])
              Right gatewayValue -> do
                modifyIORef' (dcSeenOrders cfg) (++ [oid])
                pure (Right (publishResponse outcome gatewayValue, False))

dryResponse :: DispatchOutcome -> Value
dryResponse outcome = object
  [ "ok"      .= True
  , "dryRun"  .= True
  , "request" .= doRequest outcome
  ]

publishResponse :: DispatchOutcome -> Value -> Value
publishResponse outcome gatewayValue = object
  [ "ok"       .= True
  , "dryRun"   .= False
  , "request"  .= doRequest outcome
  , "gateway"  .= gatewayValue
  ]

-- | Nodes in travel order, with the segment's release flag. Edge steps are
-- dropped: the gateway rebuilds every edge from consecutive node ids.
waypointsOf :: Order -> [(Bool, Node)]
waypointsOf o =
  [ (segReleased seg, n)
  | seg <- ordSegments o
  , StepNode n <- segSteps seg
  ]

requestOf :: RobotRef -> Order -> [(Bool, Node)] -> Value
requestOf robot o waypoints = object $
  [ "manufacturer"   .= rrManufacturer robot
  , "serialNumber"   .= rrSerialNumber robot
  , "orderId"        .= ordId o
  , "orderUpdateId"  .= ordUpdateId o
  , "nodes"          .= map waypointJSON waypoints
  ] ++ maybe [] (\d -> ["orderDescription" .= d]) (ordDescriptor o)

waypointJSON :: (Bool, Node) -> Value
waypointJSON (released, n) = object
  [ "nodeId"   .= nodeId n
  , "released" .= released
  , "actions"  .= map actionJSON (nodeActions n)
  ]

actionJSON :: Action -> Value
actionJSON a = object $
  [ "actionType"   .= actType a
  , "blockingType" .= blockingTypeJSON (actBlocking a)
  ] ++
    [ "parameters" .= object
        [ (Key.fromText k, actionValueJSON v) | (k, v) <- actParameters a ]
    | not (null (actParameters a))
    ]
  -- Deliberately no actionId: the gateway numbers missing ids itself and
  -- rejects duplicates. An id derived from the action type would collide.

blockingTypeJSON :: BlockingType -> Text
blockingTypeJSON BtNone   = "NONE"
blockingTypeJSON BtSoft   = "SOFT"
blockingTypeJSON BtSingle = "SINGLE"
blockingTypeJSON BtHard   = "HARD"

actionValueJSON :: ActionValue -> Value
actionValueJSON (AVString s) = String s
actionValueJSON (AVNumber n) = Number n
actionValueJSON (AVBool b)   = Bool b
actionValueJSON (AVArray xs) = Array (V.fromList (map actionValueJSON xs))

tshow :: Show a => a -> Text
tshow = T.pack . show
