{-# LANGUAGE OverloadedStrings #-}
-- | Lay a generated mission out on the map it will run on.
--
-- The emitted VDA 5050 order carries no edge endpoints: "RobotDSL.Emit" has
-- nothing to derive them from, because the DSL's @Edge@ records only the
-- constraints of a hop, never its two ends. The preview is therefore the only
-- place an operator can see the route as a connected path — which nodes, in
-- what order, released or still waiting.
--
-- This module is read-only. It never publishes and never writes, so a mission
-- cannot be dispatched from here. Nodes and hops the map does not know are
-- reported rather than rejected: Phase 1 does not dispatch, and an operator
-- shown a gap can act on it, whereas an error only stops them.
module RobotDSL.Agent.Preview
  ( Preview(..)
  , preview
  , previewSource
  ) where

import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T

import RobotDSL.Agent.Context (Vocabulary(..))
import RobotDSL.AST
import RobotDSL.Parser (ParseError(..), parseProgram)

-- | One mission laid out on the map.
data Preview = Preview
  { pvNodes :: ![(Text, Maybe (Double, Double))]
  -- ^ Travel order. 'Nothing' means the map does not name the node, so it
  -- cannot be drawn; the reason is in 'pvUnplaced'.
  , pvHops :: ![(Text, Text)]
  -- ^ Consecutive node pairs, in travel order. The fleet gateway derives its
  -- own edges from exactly these pairs.
  , pvReleased :: ![Bool]
  -- ^ Aligned with 'pvNodes': True for the base, False for the horizon.
  , pvUnplaced :: ![Text]
  -- ^ Every node id and hop the map does not know.
  , pvWarnings :: ![Text]
  -- ^ Constructs the fleet-control gateway cannot express, so they would not
  -- survive a dispatch. Advisory only: Phase 1 does not dispatch.
  , pvWaste :: ![Text]
  -- ^ A route that works but wanders. Advisory only, and deliberately not a
  -- judgement: whether a detour is wanted is the operator's call, not this
  -- module's. See 'routeWaste'.
  } deriving (Eq, Show)

-- | Preview an already-parsed program.
--
-- Returns @Left@ only when there is nothing to preview at all — no order, or an
-- order with no nodes. Everything else is reported inside the 'Preview'.
preview :: Vocabulary -> Program -> Either [String] Preview
preview voc prog =
  case declOrders (progDecls prog) of
    [] -> Left ["no order to preview: the source declares no order"]
    (o : more) ->
      case routeOf o of
        [] -> Left ["the order has no nodes, so there is no route to draw"]
        route ->
          let ids  = map snd route
              hops = zip ids (drop 1 ids)
          in Right Preview
               { pvNodes     = map (placeNode voc) route
               , pvHops      = hops
               , pvReleased  = map fst route
               , pvUnplaced  = concatMap (unplacedNode voc) ids
                            ++ concatMap (unplacedHop voc) hops
               , pvWarnings  = zoneWarnings (progDecls prog)
                            ++ edgeWarningsOf o
                            ++ extraOrderWarning more
               , pvWaste     = routeWaste ids
               }

-- | Parse, then preview.
--
-- The parser is the authority on validity, so a source that does not parse is
-- reported here instead of producing a half-drawn route.
previewSource :: Vocabulary -> Text -> Either [String] Preview
previewSource voc src = case parseProgram "<preview>" src of
  Left (ParseError msg) -> Left [T.unpack msg]
  Right prog -> preview voc prog

-- ---------------------------------------------------------------------------
-- Route
-- ---------------------------------------------------------------------------

declOrders :: [Decl] -> [Order]
declOrders ds = [o | DeclOrder o <- ds]

-- | Flatten an order's segments into @(released, nodeId)@ in travel order.
--
-- The traversal matches the one "RobotDSL.Emit" performs, so the preview draws
-- the same route the emitted message describes. Edges are deliberately not
-- collected: the DSL records only their constraints, never their endpoints, so
-- the hops come from the node sequence instead.
routeOf :: Order -> [(Bool, Text)]
routeOf o =
  [ (segReleased seg, nodeId n)
  | seg <- ordSegments o
  , StepNode n <- segSteps seg
  ]

placeNode :: Vocabulary -> (Bool, Text) -> (Text, Maybe (Double, Double))
placeNode voc (_, nid) = (nid, lookup nid (vocPositions voc))

-- | Where a route that works nonetheless wanders.
--
-- A node visited more than once is the signal. It is not a mistake on its own
-- — a mission that picks at A, drops at B and returns to A is legitimate, and
-- only the operator knows which this is — but it is the shape a generator
-- produces when it cannot plan a path: asked to go from AS-1W to AS-4E via
-- DOOR-IN, it produced a route that reached DOOR-IN, came back through the
-- node it had just left, and then took a different column. Every hop on it was
-- real, so nothing else would have flagged it.
--
-- This deliberately does not compute a shortest path and compare. The operator
-- may well have meant to detour; reporting a detour as wrong would be this
-- module second-guessing the mission. It reports the fact and lets the
-- operator judge.
routeWaste :: [Text] -> [Text]
routeWaste ids =
  [ nid <> " is visited " <> T.pack (show (count nid)) <> " times"
      <> ", so the robot backtracks through it"
  | nid <- repeated
  ]
  where
    repeated = [n | n <- nubOrd ids, count n > 1]
    count n = length (filter (== n) ids)

-- | Order-preserving deduplication, so a repeated node is reported at the
-- position it first appears rather than in hash order.
nubOrd :: [Text] -> [Text]
nubOrd = go []
  where
    go _    []     = []
    go seen (x:xs)
      | x `elem` seen = go seen xs
      | otherwise     = x : go (x : seen) xs
-- | A node the map does not name cannot be drawn, so it is reported rather
-- than silently placed at the origin.
unplacedNode :: Vocabulary -> Text -> [Text]
unplacedNode voc nid
  | nid `elem` vocNodes voc = []
  | otherwise = ["node " <> nid <> " is not on the map"]

-- | A hop between two nodes the map does know, but which the map does not
-- connect, cannot be driven.
--
-- When the map carries no edges at all there is nothing to check against, and
-- reporting every hop would bury the real problem, so that case is skipped. A
-- hop touching an unknown node is already covered by 'unplacedNode'.
--
-- The message names what @a@ does reach, because a route the map cannot carry
-- is usually a route with the intermediate nodes left out: "RK-AM to CONV-OUT"
-- is not a hop the map knows, but RK-AM reaches RK-AE and RK-AW. This is the
-- same sentence the generation loop feeds back to the model, so the operator
-- and the generator are told the same thing and cannot drift apart.
unplacedHop :: Vocabulary -> (Text, Text) -> [Text]
unplacedHop voc (a, b)
  | null (vocEdgePairs voc) = []
  | a `notElem` vocNodes voc || b `notElem` vocNodes voc = []
  | (a, b) `elem` vocEdgePairs voc = []
  | otherwise =
      [ "there is no edge from " <> a <> " to " <> b
          <> neighbourHint voc a
      ]

-- | What a node reaches in one hop, phrased for a hop that was rejected.
neighbourHint :: Vocabulary -> Text -> Text
neighbourHint voc a = case neighboursOf voc a of
  [] -> "; " <> a <> " has no outgoing edge on this map at all"
  ns -> "; from " <> a <> " the map connects only to "
          <> T.intercalate ", " ns
          <> ", so travel through those nodes"

-- | The nodes reachable from one node in a single hop.
neighboursOf :: Vocabulary -> Text -> [Text]
neighboursOf voc a = [b | (x, b) <- vocEdgePairs voc, x == a]

-- ---------------------------------------------------------------------------
-- Warnings
-- ---------------------------------------------------------------------------

zoneWarnings :: [Decl] -> [Text]
zoneWarnings ds
  | null zss  = []
  | otherwise =
      [ "the fleet gateway has no zoneSet endpoint, so the "
          <> T.pack (show (length zss))
          <> " zone set(s) here will not reach the robot"
      ]
  where zss = [z | DeclZoneSet z <- ds]

extraOrderWarning :: [Order] -> [Text]
extraOrderWarning more
  | null more = []
  | otherwise =
      [ "this file declares " <> T.pack (show (1 + length more))
          <> " orders; only the first is previewed"
      ]

edgeWarningsOf :: Order -> [Text]
edgeWarningsOf o = concat
  [ edgeWarnings i e
  | (i, StepEdge e) <- zip [0 ..] (concatMap segSteps (ordSegments o))
  ]

-- | What the fleet gateway drops from an edge.
--
-- It rebuilds every edge itself from the map — @e1@, @e2@, ... — with no
-- actions and no constraints. Anything the DSL put on an edge is therefore lost
-- on the way to a robot, which the operator should know before asking for a
-- dispatch. The index matches the emitted @sequenceId@, so a warning names the
-- same edge the operator sees in the JSON.
edgeWarnings :: Int -> Edge -> [Text]
edgeWarnings i e =
  [ "edge " <> T.pack (show i) <> ": " <> name
      <> " is dropped by the fleet gateway"
  | (name, True) <- edgeConstraints e ]
  ++ [ "edge " <> T.pack (show i) <> ": "
         <> T.pack (show (length (edgeActions e)))
         <> " action(s) here are dropped by the fleet gateway"
     | not (null (edgeActions e))
     ]

edgeConstraints :: Edge -> [(Text, Bool)]
edgeConstraints e =
  [ ("maximumSpeed", isJust (edgeMaxSpeed e))
  , ("maximumMobileRobotHeight", isJust (edgeMaxMobileRobotHeight e))
  , ("minimumLoadHandlingDeviceHeight", isJust (edgeMinLoadHandlingDeviceHeight e))
  , ("orientation", isJust (edgeOrientation e))
  , ("orientationType", isJust (edgeOrientationType e))
  , ("direction", isJust (edgeDirection e))
  , ("reachOrientationBeforeEntering", isJust (edgeReachOrientationBeforeEntering e))
  , ("maxRotationSpeed", isJust (edgeMaxRotationSpeed e))
  , ("trajectory", isJust (edgeTrajectory e))
  , ("length", isJust (edgeLength e))
  , ("corridor", isJust (edgeCorridor e))
  ]
