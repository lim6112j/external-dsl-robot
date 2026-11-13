{-# LANGUAGE OverloadedStrings #-}
-- | Emitter tests: the standard's mandatory bookkeeping.
module EmitSpec (tests) where

import Data.Aeson (Value(..))
import qualified Data.Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Vector as V
import Data.Text (Text)
import qualified Data.Text as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

import RobotDSL.AST
import RobotDSL.Emit
import RobotDSL.Parser
import RobotDSL.Version

tests :: IO [TestTree]
tests = pure
  [ testGroup "emitting"
      [ testCase "sequenceId puts nodes on even and edges on odd" $ do
          msgs <- emitOne (linesOf
              [ "robot \"acme\" \"AMR-001\""
              , "map \"plant-b\""
              , "order \"o1\" {"
              , "  node \"n0\" at (0,0)"
              , "  edge \"e1\""
              , "  node \"n1\" at (1,1)"
              , "  edge \"e2\""
              , "  node \"n2\" at (2,2)"
              , "}"
              ])
          let nodes = objectList msgs "nodes"
              edges = objectList msgs "edges"
          assertEqual "node count" 3 (length nodes)
          assertEqual "edge count" 2 (length edges)
          assertEqual "node sequenceIds" [0, 2, 4]
                       (map (intField "sequenceId") nodes)
          assertEqual "edge sequenceIds" [1, 3]
                       (map (intField "sequenceId") edges)

      , testCase "sequenceId continues across base and horizon" $ do
          msgs <- emitOne (linesOf
              [ "robot \"acme\" \"AMR-001\""
              , "map \"plant-b\""
              , "order \"o1\" {"
              , "  base { node \"a\" at (0,0) edge \"e1\" node \"b\" at (1,1) }"
              , "  horizon { edge \"e2\" node \"c\" at (2,2) }"
              , "}"
              ])
          assertEqual "nodes" [0, 2, 4]
                       (map (intField "sequenceId") (objectList msgs "nodes"))
          assertEqual "edges" [1, 3]
                       (map (intField "sequenceId") (objectList msgs "edges"))

      , testCase "released marks base versus horizon" $ do
          msgs <- emitOne (linesOf
              [ "robot \"acme\" \"AMR-001\""
              , "map \"plant-b\""
              , "order \"o1\" {"
              , "  base { node \"a\" at (0,0) }"
              , "  horizon { node \"b\" at (1,1) }"
              , "}"
              ])
          assertEqual "released flags" [True, False]
                       (map (boolField "released") (objectList msgs "nodes"))

      , testCase "actionIds are unique and stable within a message" $ do
          msgs <- emitOne (linesOf
              [ "robot \"acme\" \"AMR-001\""
              , "map \"plant-b\""
              , "order \"o1\" {"
              , "  node \"a\" at (0,0) {"
              , "    action \"pick\""
              , "    action \"drop\""
              , "  }"
              , "  edge \"e1\" { action \"pick\" }"
              , "  node \"b\" at (1,1) { action \"initPosition\" }"
              , "}"
              ])
          let ids = concatMap actionIds (objectList msgs "nodes")
                      ++ concatMap actionIds (objectList msgs "edges")
          -- Numbering follows the route: node a, edge e1, node b. The test
          -- lists node ids before edge ids, so the edge's id sorts last here.
          assertEqual "ids" ["pick-1", "drop-2", "initposition-4", "pick-3"] ids
          assertEqual "no duplicates" (length ids) (length (dedupe ids))

      , testCase "actionIds are unique across every zone action group" $ do
          msgs <- emitOne (linesOf
              [ "robot \"acme\" \"AMR-001\""
              , "map \"plant-b\""
              , "zoneset \"z\" on map \"plant-b\" {"
              , "  zone \"h\" action {"
              , "    entry { action \"beaconOn\" action \"log\" }"
              , "    during { action \"log\" }"
              , "    exit { action \"beaconOff\" }"
              , "    polygon (0,0) (1,0) (1,1)"
              , "  }"
              , "}"
              ])
          let z = case msgs of
                    [m] -> case emValue m of
                      Object o -> case KM.lookup "zoneSet" o of
                        Just (Object zs) -> case KM.lookup "zones" zs of
                          Just (Array a) -> V.toList a
                          _ -> []
                        _ -> []
                      _ -> []
                    _ -> []
              zoneIds = concatMap (\v -> actionIdsOf v "entryActions"
                                         ++ actionIdsOf v "duringActions"
                                         ++ actionIdsOf v "exitActions") z
          assertEqual "ids" ["beaconon-1", "log-2", "log-3", "beaconoff-4"] zoneIds

      , testCase "edgeIds are synthesised when unnamed" $ do
          msgs <- emitOne (linesOf
              [ "robot \"acme\" \"AMR-001\""
              , "map \"plant-b\""
              , "order \"o1\" { node \"a\" at (0,0) edge node \"b\" at (1,1) }"
              ])
          assertEqual "generated id" "edge-1" (textField "edgeId" (head (objectList msgs "edges")))

      , testCase "mapId is inherited from the file-level map" $ do
          msgs <- emitOne (linesOf
              [ "robot \"acme\" \"AMR-001\""
              , "map \"plant-b\""
              , "order \"o1\" { node \"a\" at (0,0) }"
              ])
          let n = head (objectList msgs "nodes")
          case lookupField "nodePosition" n of
            Just (Object p) ->
              assertEqual "mapId" "plant-b" (textField "mapId" (Object p))
            other -> assertFailure ("no nodePosition: " ++ show other)

      , testCase "mapId can be overridden per node" $ do
          msgs <- emitOne (linesOf
              [ "robot \"acme\" \"AMR-001\""
              , "map \"plant-b\""
              , "order \"o1\" { node \"a\" at (0,0) on map \"plant-b-l2\" }"
              ])
          let n = head (objectList msgs "nodes")
          case lookupField "nodePosition" n of
            Just (Object p) ->
              assertEqual "mapId" "plant-b-l2" (textField "mapId" (Object p))
            other -> assertFailure ("no nodePosition: " ++ show other)

      , testCase "priorityFactor is emitted without the schema's stray space" $ do
          msgs <- emitOne (linesOf
              [ "robot \"acme\" \"AMR-001\""
              , "map \"plant-b\""
              , "zoneset \"z\" on map \"plant-b\" {"
              , "  zone \"p\" priority factor 0.8 { polygon (0,0) (1,0) (1,1) }"
              , "}"
              ])
          let z = head (zoneList msgs)
          assertEqual "key present" (Just (Number 0.8))
                       (KM.lookup "priorityFactor" (asObject z))
          assertBool "no stray-space key"
                     (not (KM.member "priorityFactor " (asObject z)))

      , testCase "edges use reachOrientationBeforeEntering, not rotationAllowed" $ do
          msgs <- emitOne (linesOf
              [ "robot \"acme\" \"AMR-001\""
              , "map \"plant-b\""
              , "order \"o1\" { node \"a\" at (0,0) edge \"e\" reachbefore true node \"b\" at (1,1) }"
              ])
          let e = head (objectList msgs "edges")
          assertEqual "field" (Just (Bool True))
                       (KM.lookup "reachOrientationBeforeEntering" (asObject e))
          assertBool "no v2 field"
                     (not (KM.member "rotationAllowed" (asObject e)))

      , testCase "headerId is allocated per topic" $ do
          msgs <- emitOne (linesOf
              [ "robot \"acme\" \"AMR-001\""
              , "map \"plant-b\""
              , "zoneset \"z1\" on map \"plant-b\" { zone \"a\" blocked { polygon (0,0) (1,0) (1,1) } }"
              , "zoneset \"z2\" on map \"plant-b\" { zone \"a\" blocked { polygon (0,0) (1,0) (1,1) } }"
              , "order \"o1\" { node \"a\" at (0,0) }"
              , "order \"o2\" { node \"a\" at (0,0) }"
              ])
          assertEqual "headerIds" [1, 2, 1, 2] (map (intField "headerId") (map emValue msgs))

      , testCase "an explicit header declaration wins over the CLI default" $ do
          msgs <- emitOneWith (EmitContext "acme" "AMR-001" 1 "2026-01-01T00:00:00.000Z" protocolVersion (Just "plant-b"))
                (linesOf
                    [ "robot \"acme\" \"AMR-001\""
                    , "header 42"
                    , "map \"plant-b\""
                    , "order \"o1\" { node \"a\" at (0,0) }"
                    ])
          assertEqual "headerId" 42 (intField "headerId" (emValue (head msgs)))

      , testCase "version and timestamp are filled in" $ do
          msgs <- emitOneWith (EmitContext "acme" "AMR-001" 7 "2026-11-13T12:00:00.000Z" protocolVersion (Just "plant-b"))
                "robot \"acme\" \"AMR-001\"\nmap \"plant-b\"\norder \"o1\" { node \"a\" at (0,0) }"
          assertEqual "version" "3.0.0" (textField "version" (emValue (head msgs)))
          assertEqual "timestamp" "2026-11-13T12:00:00.000Z"
                       (textField "timestamp" (emValue (head msgs)))

      , testCase "order actions keep an explicit blocking type" $ do
          msgs <- emitOne (linesOf
              [ "robot \"acme\" \"AMR-001\""
              , "map \"plant-b\""
              , "order \"o1\" { node \"a\" at (0,0) { action \"pick\" blocking NONE } }"
              ])
          let a = head (actionsOf (head (objectList msgs "nodes")))
          assertEqual "blockingType" "NONE" (textField "blockingType" a)

      , testCase "a single node with no edges is a valid order" $ do
          msgs <- emitOne "robot \"acme\" \"AMR-001\"\nmap \"plant-b\"\norder \"o1\" { node \"a\" at (0,0) }"
          assertEqual "no edges" [] (objectList msgs "edges")
          assertEqual "one node" 1 (length (objectList msgs "nodes"))
      ]
  ]

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

linesOf :: [String] -> Text
linesOf = T.pack . unlines

emitOne :: Text -> IO [EmittedMessage]
emitOne src = case parseProgram "t.robot" src of
  Right prog -> pure (emit prog (resolveContext prog testContext))
  Left (ParseError msg) -> assertFailure (T.unpack msg)

emitOneWith :: EmitContext -> Text -> IO [EmittedMessage]
emitOneWith ctx src = case parseProgram "t.robot" src of
  Right prog -> pure (emit prog (resolveContext prog ctx))
  Left (ParseError msg) -> assertFailure (T.unpack msg)

testContext :: EmitContext
testContext =
  EmitContext "acme" "AMR-001" 1 "2026-11-13T12:00:00.000Z" protocolVersion
              (Just "plant-b")

asObject :: Value -> KM.KeyMap Value
asObject (Object o) = o
asObject v = error ("expected an object, got " ++ show v)

-- | The list stored under @key@ in the first emitted message.
objectList :: [EmittedMessage] -> Text -> [Value]
objectList msgs key = case emValue (head msgs) of
  Object o -> case KM.lookup (Key.fromText key) o of
    Just (Array a) -> V.toList a
    _ -> []
  _ -> []

-- | The zones of the first emitted zoneSet message.
zoneList :: [EmittedMessage] -> [Value]
zoneList msgs = case emValue (head msgs) of
  Object o -> case KM.lookup "zoneSet" o of
    Just (Object zs) -> case KM.lookup "zones" zs of
      Just (Array a) -> V.toList a
      _ -> []
    _ -> []
  _ -> []

lookupField :: Text -> Value -> Maybe Value
lookupField k v = case v of
  Object o -> KM.lookup (Key.fromText k) o
  _ -> Nothing

intField :: Text -> Value -> Int
intField k v = case lookupField k v of
  Just (Number n) -> round n
  other -> error ("no int field " ++ T.unpack k ++ ": " ++ show other)

boolField :: Text -> Value -> Bool
boolField k v = case lookupField k v of
  Just (Bool b) -> b
  other -> error ("no bool field " ++ T.unpack k ++ ": " ++ show other)

textField :: Text -> Value -> Text
textField k v = case lookupField k v of
  Just (String s) -> s
  other -> error ("no text field " ++ T.unpack k ++ ": " ++ show other)

actionsOf :: Value -> [Value]
actionsOf v = case lookupField "actions" v of
  Just (Array a) -> V.toList a
  _ -> []

actionIds :: Value -> [Text]
actionIds = map (textField "actionId") . actionsOf

-- | Unlike a node or edge, a zone action group holds the action objects
-- directly rather than under an @actions@ key.
actionIdsOf :: Value -> Text -> [Text]
actionIdsOf v k = case lookupField k v of
  Just (Array a) -> map (textField "actionId") (V.toList a)
  _ -> []

dedupe :: Eq a => [a] -> [a]
dedupe = go []
  where
    go seen [] = reverse seen
    go seen (x : xs)
      | x `elem` seen = go seen xs
      | otherwise     = go (x : seen) xs
