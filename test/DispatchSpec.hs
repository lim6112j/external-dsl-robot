{-# LANGUAGE OverloadedStrings #-}
-- | Tests for turning validated DSL into the gateway's order shape.
--
-- Everything here is pure: no gateway, no broker, no model. The stub gateway
-- for the HTTP half of dispatch lives in this module from Task 3 onward.
module DispatchSpec (tests) where

import Data.Aeson (Value(..), object, (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import Network.HTTP.Client (defaultManagerSettings, newManager)
import qualified Data.Vector as V

import RobotDSL.Agent.Client (ClientConfig(..))
import RobotDSL.Agent.Context (Vocabulary(..))
import RobotDSL.Agent.Dispatch
import RobotDSL.Agent.Fleet (RobotRef(..))
import RobotDSL.Agent.Loop (LoopConfig(..))
import RobotDSL.AST (ActionValue(..))
import RobotDSL.Emit (EmitContext(..))
import RobotDSL.Version (protocolVersion)

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

tests :: IO [TestTree]
tests = pure [testGroup "dispatch" (planTests ++ valueTests)]

planTests :: [TestTree]
planTests =
  [ testCase "a plan carries the order identity from the DSL" $ do
      o <- planned mission
      let r = doRequest o
      assertEqual "manufacturer" (Just "acme") (strField r "manufacturer")
      assertEqual "serialNumber" (Just "AMR-001") (strField r "serialNumber")
      assertEqual "orderId" (Just "order-test") (strField r "orderId")
      assertEqual "orderId field" "order-test" (doOrderId o)
      assertEqual "orderUpdateId" (Just (3 :: Int)) (intField r "orderUpdateId")
      assertEqual "description" (Just "test run") (strField r "orderDescription")

  , testCase "only nodes become waypoints, in travel order, with release flags" $ do
      o <- planned mission
      let ns = arrField (doRequest o) "nodes"
      assertEqual "three waypoints" 3 (length ns)
      assertEqual "nodeIds" ["RK-AM", "CHG-01", "ST-07"]
                   (mapMaybe (`strField` "nodeId") ns)
      assertEqual "released flags" [True, True, False]
                   (map (\n -> maybe False id (boolField n "released")) ns)
      assertEqual "first node has one action" 1 (length (arrField (head ns) "actions"))
      assertEqual "last node has none" 0 (length (arrField (last ns) "actions"))

  , testCase "actions carry type, blocking and parameters, never an actionId" $ do
      o <- planned mission
      let ns = arrField (doRequest o) "nodes"
          a = head (arrField (head ns) "actions")
      assertEqual "actionType" (Just "pick") (strField a "actionType")
      assertEqual "blockingType" (Just "HARD") (strField a "blockingType")
      assertEqual "no actionId" Nothing (objField a "actionId")
      let ps = objField a "parameters"
      assertBool "parameters present" (case ps of
        Just (Object km) -> not (KM.null km)
        _ -> False)
      assertEqual "loadId" (Just "KLT-42") (ps >>= (`strField` "loadId"))
      assertEqual "number parameter" (Just 2) (ps >>= (`intField` "n"))
      assertEqual "bool parameter" (Just True) (ps >>= (`boolField` "ok"))
      let dropAction = head (arrField (ns !! 1) "actions")
      assertEqual "second action type" (Just "drop") (strField dropAction "actionType")
      assertEqual "second blocking" (Just "HARD") (strField dropAction "blockingType")

  , testCase "every blocking value reaches the gateway in its enum spelling" $
      mapM_ checkBlocking
        [ ("HARD", "HARD"), ("SOFT", "SOFT")
        , ("SINGLE", "SINGLE"), ("NONE", "NONE") ]

  , testCase "an omitted robot declaration is filled from the selected robot" $ do
      let src = T.unlines (drop 1 (T.lines mission))
      o <- planned src
      assertEqual "manufacturer" (Just "acme")
        (strField (doRequest o) "manufacturer")
      assertEqual "serialNumber" (Just "AMR-001")
        (strField (doRequest o) "serialNumber")

  , testCase "a DSL naming another robot is rejected with both identities" $ do
      let src = T.replace "AMR-001" "AMR-999" mission
      assertRejects ["AMR-001", "AMR-999"] src

  , testCase "a zone set cannot be dispatched" $
      assertRejects ["zone"] (mission <> T.unlines
        [ "zoneset \"zs\" {"
        , "  zone \"z\" blocked { polygon (0, 0) (1, 0) (0, 1) }"
        , "}"
        ])

  , testCase "an edge constraint cannot be dispatched" $
      assertRejects ["maximumSpeed"]
        (T.replace "edge \"e-1\"" "edge \"e-1\" speed 0.5" mission)

  , testCase "an edge action cannot be dispatched" $
      assertRejects ["action"]
        (T.replace "edge \"e-1\"" "edge \"e-1\" { action \"beaconOn\" }" mission)

  , testCase "a hop the map does not connect cannot be dispatched" $ do
      c <- mkCfg
      let wrongHops = c { lcVocab = voc { vocEdgePairs = [("RK-AM", "ST-07")] } }
      case planOrder (lcVocab wrongHops) wrongHops robot mission of
        Left errs -> assertBool ("hop named: " ++ show errs)
                      (any ("no edge from" `T.isInfixOf`) errs)
        Right _ -> assertFailure "an unplaced hop was allowed through"

  , testCase "an unknown node cannot be dispatched" $
      assertRejects ["NOWHERE"] (T.replace "\"CHG-01\"" "\"NOWHERE\"" mission)

  , testCase "a source with no order cannot be dispatched" $
      assertRejects ["order"] "robot \"acme\" \"AMR-001\""

  , testCase "an order with no nodes cannot be dispatched" $
      assertRejects ["node"] (T.unlines
        [ "robot \"acme\" \"AMR-001\"", "order \"empty\" { base { } }" ])

  , testCase "two orders cannot be dispatched one at a time" $
      assertRejects ["2 orders", "2"] (mission <> T.unlines
        [ "order \"second\" { base { node \"RK-AM\" } }" ])

  , testCase "invalid DSL is rejected by the parser and validator" $
      assertRejects ["nonsense"] "nonsense"
  ]

valueTests :: [TestTree]
valueTests =
  [ testCase "action values become JSON scalars and arrays" $ do
      assertEqual "array" (Array (V.fromList [String "x", Bool False]))
        (actionValueJSON (AVArray [AVString "x", AVBool False]))
      assertEqual "string" (String "x") (actionValueJSON (AVString "x"))
      assertEqual "bool" (Bool True) (actionValueJSON (AVBool True))
  ]

-- ---------------------------------------------------------------------------
-- Fixtures and helpers
-- ---------------------------------------------------------------------------

mission :: Text
mission = T.unlines
  [ "robot \"acme\" \"AMR-001\""
  , "order \"order-test\" update 3 describe \"test run\" {"
  , "  base {"
  , "    node \"RK-AM\" {"
  , "      action \"pick\" blocking HARD with {"
  , "        loadId = \"KLT-42\""
  , "        n = 2"
  , "        ok = true"
  , "      }"
  , "    }"
  , "    edge \"e-1\""
  , "    node \"CHG-01\" { action \"drop\" blocking HARD }"
  , "  }"
  , "  horizon { edge \"e-2\" node \"ST-07\" }"
  , "}"
  ]

voc :: Vocabulary
voc = Vocabulary (Just "plant-b") ["RK-AM", "CHG-01", "ST-07"] []
        [("RK-AM", "CHG-01"), ("CHG-01", "ST-07")] Nothing
        [ ("RK-AM", (1.0, 2.0)), ("CHG-01", (3.0, 4.0))
        , ("ST-07", (5.0, 6.0)) ]

mkCfg :: IO LoopConfig
mkCfg = do
  mgr <- newManager defaultManagerSettings
  pure LoopConfig
    { lcManager = mgr
    , lcClient = ClientConfig "unused" "unused" "http://127.0.0.1:1" 1
    , lcVocab = voc
    , lcEmit = EmitContext "acme" "AMR-001" 1 "2026-01-01T00:00:00.000Z"
                           protocolVersion (Just "plant-b")
    , lcRobot = Nothing
    , lcMfr = Just "acme"
    , lcSerial = Just "AMR-001"
    }

robot :: RobotRef
robot = RobotRef "acme:AMR-001" "acme" "AMR-001" (Just "plant-b") True False ""

planned :: Text -> IO DispatchOutcome
planned src = do
  c <- mkCfg
  case planOrder voc c robot src of
    Left errs -> assertFailure ("unexpected rejection: " ++ T.unpack (T.intercalate " | " errs))
    Right o -> pure o

assertRejects :: [Text] -> Text -> IO ()
assertRejects wanted src = do
  c <- mkCfg
  case planOrder voc c robot src of
    Left errs -> mapM_ (\w -> assertBool
                          ("reason should contain " ++ T.unpack w ++ ": " ++ show errs)
                          (any (w `T.isInfixOf`) errs)) wanted
    Right _ -> assertFailure ("expected a rejection for: " ++ T.unpack src)

checkBlocking :: (Text, Text) -> IO ()
checkBlocking (from, want) = do
  o <- planned (T.replace "blocking HARD" ("blocking " <> from) mission)
  let ns = arrField (doRequest o) "nodes"
      a = head (arrField (head ns) "actions")
  assertEqual ("blocking " ++ T.unpack from) (Just want) (strField a "blockingType")

objField :: Value -> Text -> Maybe Value
objField (Object o) k = KM.lookup (Key.fromText k) o
objField _ _ = Nothing

strField :: Value -> Text -> Maybe Text
strField v k = case objField v k of
  Just (String s) -> Just s
  _ -> Nothing

boolField :: Value -> Text -> Maybe Bool
boolField v k = case objField v k of
  Just (Bool b) -> Just b
  _ -> Nothing

intField :: Value -> Text -> Maybe Int
intField v k = case objField v k of
  Just (Number n) -> Just (fromIntegral (floor n :: Integer))
  _ -> Nothing

arrField :: Value -> Text -> [Value]
arrField v k = case objField v k of
  Just (Array a) -> foldr (:) [] a
  _ -> []
