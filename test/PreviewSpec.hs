{-# LANGUAGE OverloadedStrings #-}
-- | Tests for the map preview.
--
-- The property that matters is that a mission is *shown*, not gatekept: a node
-- or hop the map does not know is reported inside the preview so the operator
-- can see the gap. Only a source with nothing to preview at all is refused.
module PreviewSpec (tests) where

import Data.Text (Text)
import qualified Data.Text as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

import RobotDSL.Agent.Context
import RobotDSL.Agent.Preview

tests :: IO [TestTree]
tests = pure [testGroup "preview" previewTests]

previewTests :: [TestTree]
previewTests =
  [ testCase "an order lays out as nodes and hops in travel order" $ do
      case previewSource previewVocab previewDsl of
        Left errs -> assertFailure (unlines errs)
        Right pv -> do
          assertEqual "nodes in order"
            [ ("RK-AW", Just (1.0, 2.0))
            , ("AS-3M", Just (3.0, 4.0))
            , ("CHG-01", Just (5.0, 6.0))
            ] (pvNodes pv)
          assertEqual "hops are consecutive pairs"
            [("RK-AW", "AS-3M"), ("AS-3M", "CHG-01")] (pvHops pv)
          assertEqual "nothing unplaced" [] (pvUnplaced pv)
          assertEqual "no warnings" [] (pvWarnings pv)

  , testCase "base nodes are released and horizon nodes are not" $ do
      case previewSource previewVocab previewDsl of
        Left errs -> assertFailure (unlines errs)
        Right pv ->
          assertEqual "released flags" [True, True, False] (pvReleased pv)

  , testCase "a node the map does not name is reported, not rejected" $ do
      case previewSource previewVocab unknownNodeDsl of
        Left errs -> assertFailure ("preview refused: " ++ unlines errs)
        Right pv -> do
          assertEqual "no coordinate for an unknown node"
            [("NOPE", Nothing)] (pvNodes pv)
          assertBool "node reported" (any (T.isInfixOf "NOPE") (pvUnplaced pv))

  , testCase "a hop the map does not connect is reported" $ do
      let voc = previewVocab { vocEdgePairs = [("RK-AW", "AS-3M")] }
      case previewSource voc previewDsl of
        Left errs -> assertFailure (unlines errs)
        Right pv ->
          assertBool "hop reported"
            (any (T.isInfixOf "no edge from AS-3M to CHG-01") (pvUnplaced pv))

  , testCase "a rejected hop names what the node does reach" $ do
      -- 이웃 정보가 함께 가야 생성기가 중간 노드를 채울 수 있다.
      -- 이 문장은 생성 루프가 모델에 되돌리는 그 문장이다.
      let voc = previewVocab
                   { vocEdgePairs = [("RK-AW", "AS-3M"), ("AS-3M", "AS-2M")] }
      case previewSource voc previewDsl of
        Left errs -> assertFailure (unlines errs)
        Right pv ->
          assertBool "the reachable neighbours are named"
            (any (T.isInfixOf "from AS-3M the map connects only to AS-2M")
                 (pvUnplaced pv))

  , testCase "a node with no outgoing edge is said to have none" $ do
      -- 이웃이 없으면 목록이 비어 문장이 깨지므로 별도의 문구를 쓴다.
      let voc = previewVocab { vocEdgePairs = [("CHG-01", "RK-AW")] }
      case previewSource voc previewDsl of
        Left errs -> assertFailure (unlines errs)
        Right pv ->
          assertBool "no dangling comma"
            (any (T.isInfixOf "has no outgoing edge on this map at all")
                 (pvUnplaced pv))

  , testCase "a map with no edges reports no hops at all" $ do
      -- Otherwise every hop would be flagged and bury the real problem.
      let voc = previewVocab { vocEdgePairs = [] }
      case previewSource voc previewDsl of
        Left errs -> assertFailure (unlines errs)
        Right pv -> assertEqual "nothing reported" [] (pvUnplaced pv)

  , testCase "a zone set is warned about, because nothing can carry it" $ do
      case previewSource previewVocab zoneDsl of
        Left errs -> assertFailure (unlines errs)
        Right pv ->
          assertBool "zone warning present"
            (any (T.isInfixOf "zoneSet") (pvWarnings pv))

  , testCase "an edge constraint is warned about" $ do
      case previewSource previewVocab edgeConstraintDsl of
        Left errs -> assertFailure (unlines errs)
        Right pv ->
          assertBool "speed warning present"
            (any (T.isInfixOf "maximumSpeed") (pvWarnings pv))

  , testCase "a second order is warned about" $ do
      case previewSource previewVocab twoOrdersDsl of
        Left errs -> assertFailure (unlines errs)
        Right pv ->
          assertBool "only the first is previewed"
            (any (T.isInfixOf "only the first") (pvWarnings pv))

  , testCase "a source with no order has nothing to preview" $ do
      case previewSource previewVocab noOrderDsl of
        Left _ -> pure ()
        Right pv -> assertFailure ("expected a refusal, got " ++ show pv)

  , testCase "a source that does not parse is reported" $ do
      case previewSource previewVocab "order \"o1\" {" of
        Left _ -> pure ()
        Right pv -> assertFailure ("expected a refusal, got " ++ show pv)
  ]

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

previewVocab :: Vocabulary
previewVocab = Vocabulary
  { vocMapId     = Just "plant-b"
  , vocNodes     = ["RK-AW", "AS-3M", "CHG-01"]
  , vocEdges     = []
  , vocEdgePairs = [("RK-AW", "AS-3M"), ("AS-3M", "CHG-01")]
  , vocScope     = Nothing
  , vocPositions = [ ("RK-AW", (1.0, 2.0))
                   , ("AS-3M", (3.0, 4.0))
                   , ("CHG-01", (5.0, 6.0))
                   ]
  }

-- | A three-stop mission: two released, one waiting in the horizon.
previewDsl :: Text
previewDsl = T.unlines
  [ "robot \"acme\" \"AMR-001\""
  , "map \"plant-b\""
  , "order \"o1\" {"
  , "  base {"
  , "    node \"RK-AW\" at (1.0, 2.0) {"
  , "      action \"pick\""
  , "    }"
  , "    go to \"AS-3M\" at (3.0, 4.0) {"
  , "      action \"drop\""
  , "    }"
  , "  }"
  , "  horizon {"
  , "    node \"CHG-01\" at (5.0, 6.0)"
  , "  }"
  , "}"
  ]

unknownNodeDsl :: Text
unknownNodeDsl = T.unlines
  [ "robot \"acme\" \"AMR-001\""
  , "map \"plant-b\""
  , "order \"o1\" {"
  , "  base {"
  , "    node \"NOPE\" at (0.0, 0.0)"
  , "  }"
  , "}"
  ]

zoneDsl :: Text
zoneDsl = T.unlines
  [ "robot \"acme\" \"AMR-001\""
  , "map \"plant-b\""
  , "order \"o1\" {"
  , "  base {"
  , "    node \"RK-AW\" at (1.0, 2.0)"
  , "  }"
  , "}"
  , "zoneset \"zs\" on map \"plant-b\" {"
  , "  zone \"z\" blocked {"
  , "    polygon (0, 0) (5, 0) (5, 5)"
  , "  }"
  , "}"
  ]

edgeConstraintDsl :: Text
edgeConstraintDsl = T.unlines
  [ "robot \"acme\" \"AMR-001\""
  , "map \"plant-b\""
  , "order \"o1\" {"
  , "  base {"
  , "    node \"RK-AW\" at (1.0, 2.0)"
  , "    go to \"AS-3M\" at (3.0, 4.0) speed 0.5"
  , "  }"
  , "}"
  ]

twoOrdersDsl :: Text
twoOrdersDsl = T.unlines
  [ "robot \"acme\" \"AMR-001\""
  , "map \"plant-b\""
  , "order \"o1\" {"
  , "  base {"
  , "    node \"RK-AW\" at (1.0, 2.0)"
  , "  }"
  , "}"
  , "order \"o2\" {"
  , "  base {"
  , "    node \"CHG-01\" at (5.0, 6.0)"
  , "  }"
  , "}"
  ]

noOrderDsl :: Text
noOrderDsl = T.unlines
  [ "robot \"acme\" \"AMR-001\""
  , "map \"plant-b\""
  ]
