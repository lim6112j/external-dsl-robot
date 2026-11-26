{-# LANGUAGE OverloadedStrings #-}
-- | Tests for turning validated DSL into the gateway's order shape.
--
-- Everything here is pure: no gateway, no broker, no model. The stub gateway
-- for the HTTP half of dispatch lives in this module from Task 3 onward.
module DispatchSpec (tests) where

import Control.Exception (evaluate)
import Data.Aeson (Value(..), encode, object, (.=))
import qualified Data.Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import Network.HTTP.Client (Manager, defaultManagerSettings, newManager)
import Network.HTTP.Types (Status, hContentType, status200, status400, status404)
import Network.Wai (Application, lazyRequestBody, pathInfo, requestMethod,
                    responseLBS)
import Network.Wai.Handler.Warp (testWithApplication)
import qualified Data.Vector as V

import RobotDSL.Agent.Client (ClientConfig(..))
import RobotDSL.Agent.Context (Vocabulary(..))
import RobotDSL.Agent.Dispatch
import RobotDSL.Agent.Fleet (FleetConfig(..), RobotRef(..))
import RobotDSL.Agent.Loop (LoopConfig(..))
import RobotDSL.AST (ActionValue(..))
import RobotDSL.Emit (EmitContext(..))
import RobotDSL.Version (protocolVersion)

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

tests :: IO [TestTree]
tests = pure [testGroup "dispatch"
               (planTests ++ valueTests ++ ioTests)]

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

-- ---------------------------------------------------------------------------
-- Dispatch IO: robot check, duplicates, dry run, publish
-- ---------------------------------------------------------------------------

ioTests :: [TestTree]
ioTests =
  [ testCase "a dry run echoes the request and writes nothing" $
      withDispatchGateway status200 onlineRobots $ \mgr fleet calls -> do
        (cfg, _) <- mkDispatchCfg mgr fleet True
        r <- dispatchOrder cfg mission True
        case r of
          Left errs -> assertFailure ("unexpected rejection: " ++ show errs)
          Right (resp, dry) -> do
            assertEqual "dry run" True dry
            assertEqual "no dry-run flag in response" (Just True) (boolField resp "dryRun")
            let req = objField resp "request"
            assertEqual "orderId echoed" (Just "order-test") (req >>= (`strField` "orderId"))
        cs <- readIORef calls
        assertEqual "zero posts" 0 (length cs)

  , testCase "without --allow-dispatch a requested publish is still dry" $
      withDispatchGateway status200 onlineRobots $ \mgr fleet calls -> do
        (cfg, _) <- mkDispatchCfg mgr fleet False
        r <- dispatchOrder cfg mission False
        case r of
          Left errs -> assertFailure ("unexpected rejection: " ++ show errs)
          Right (_, dry) -> assertEqual "forced dry run" True dry
        cs <- readIORef calls
        assertEqual "zero posts" 0 (length cs)

  , testCase "an allowed publish posts the planned body once" $
      withDispatchGateway status200 onlineRobots $ \mgr fleet calls -> do
        (cfg, seen) <- mkDispatchCfg mgr fleet True
        r <- dispatchOrder cfg mission False
        case r of
          Left errs -> assertFailure ("unexpected rejection: " ++ show errs)
          Right (resp, dry) -> do
            assertEqual "not dry" False dry
            assertEqual "gateway status" (Just "published")
              (objField resp "gateway" >>= (`strField` "status"))
        cs <- readIORef calls
        assertEqual "one post" 1 (length cs)
        assertEqual "orders path" "/api/orders" (scPath (head cs))
        expected <- doRequest <$> planned mission
        assertEqual "body equals the plan" expected (scBody (head cs))
        ids <- readIORef seen
        assertEqual "order id remembered" ["order-test"] ids

  , testCase "a second publish of the same order id is refused" $
      withDispatchGateway status200 onlineRobots $ \mgr fleet calls -> do
        (cfg, _) <- mkDispatchCfg mgr fleet True
        _ <- dispatchOrder cfg mission False
        second <- dispatchOrder cfg mission False
        case second of
          Left errs -> do
            assertBool "duplicate named" (any ("duplicate" `T.isInfixOf`) errs)
            assertBool "order id named" (any ("order-test" `T.isInfixOf`) errs)
          Right _ -> assertFailure "a duplicate order id was published"
        cs <- readIORef calls
        assertEqual "still one post" 1 (length cs)

  , testCase "a gateway refusal is reported and does not burn the order id" $
      withDispatchGateway status400 onlineRobots $ \mgr fleet calls -> do
        (cfg, seen) <- mkDispatchCfg mgr fleet True
        r <- dispatchOrder cfg mission False
        case r of
          Left errs -> assertBool ("reason: " ++ show errs)
            (any ("gateway refused it" `T.isInfixOf`) errs)
          Right _ -> assertFailure "a refused order was reported as published"
        cs <- readIORef calls
        assertEqual "one post" 1 (length cs)
        ids <- readIORef seen
        assertEqual "order id not remembered" [] ids

  , testCase "a robot missing from the fleet is not dispatched to" $
      withDispatchGateway status200 emptyRobots $ \mgr fleet calls -> do
        (cfg, _) <- mkDispatchCfg mgr fleet True
        r <- dispatchOrder cfg mission False
        assertLeftContaining "AMR-001" r
        cs <- readIORef calls
        assertEqual "zero posts" 0 (length cs)

  , testCase "an offline robot is not dispatched to" $
      withDispatchGateway status200 offlineRobots $ \mgr fleet calls -> do
        (cfg, _) <- mkDispatchCfg mgr fleet True
        r <- dispatchOrder cfg mission False
        assertLeftContaining "offline" r
        cs <- readIORef calls
        assertEqual "zero posts" 0 (length cs)

  , testCase "an unreachable gateway is reported, not treated as an empty fleet" $ do
      mgr <- newManager defaultManagerSettings
      (cfg, _) <- mkDispatchCfg mgr (FleetConfig "http://127.0.0.1:1" Nothing) True
      r <- dispatchOrder cfg mission False
      assertLeftContaining "robot" r

  , testCase "an instant action dry run writes nothing" $
      withDispatchGateway status200 onlineRobots $ \mgr fleet calls -> do
        (cfg, _) <- mkDispatchCfg mgr fleet True
        r <- sendInstant cfg ["startPause"] True
        case r of
          Left errs -> assertFailure ("unexpected rejection: " ++ show errs)
          Right (resp, dry) -> do
            assertEqual "dry run" True dry
            assertEqual "action echoed" (Just "startPause")
              (case objField resp "request" of
                 Just req -> case arrField req "actions" of
                   (a : _) -> strField a "actionType"
                   _ -> Nothing
                 _ -> Nothing)
        cs <- readIORef calls
        assertEqual "zero posts" 0 (length cs)

  , testCase "an allowed instant action posts to the robot route" $
      withDispatchGateway status200 onlineRobots $ \mgr fleet calls -> do
        (cfg, _) <- mkDispatchCfg mgr fleet True
        r <- sendInstant cfg ["startPause", "stateRequest"] False
        case r of
          Left errs -> assertFailure ("unexpected rejection: " ++ show errs)
          Right (_, dry) -> assertEqual "not dry" False dry
        cs <- readIORef calls
        assertEqual "one post" 1 (length cs)
        assertEqual "robot route"
          "/api/robots/acme:AMR-001/instant-actions" (scPath (head cs))
        assertEqual "two actions" 2 (length (arrField (scBody (head cs)) "actions"))
        assertEqual "first action type" (Just "startPause")
          (strField (head (arrField (scBody (head cs)) "actions")) "actionType")

  , testCase "an empty instant action list is rejected" $
      withDispatchGateway status200 onlineRobots $ \mgr fleet calls -> do
        (cfg, _) <- mkDispatchCfg mgr fleet True
        r <- sendInstant cfg [] False
        assertLeftContaining "at least one" r
        cs <- readIORef calls
        assertEqual "zero posts" 0 (length cs)

  , testCase "a DSL rejected by the plan never reaches the gateway" $
      withDispatchGateway status200 onlineRobots $ \mgr fleet calls -> do
        (cfg, _) <- mkDispatchCfg mgr fleet True
        let bad = mission <> T.unlines
              [ "zoneset \"zs\" {"
              , "  zone \"z\" blocked { polygon (0, 0) (1, 0) (0, 1) }"
              , "}"
              ]
        r <- dispatchOrder cfg bad False
        assertLeftContaining "zone" r
        cs <- readIORef calls
        assertEqual "zero posts" 0 (length cs)

  ]

data SeenCall = SeenCall
  { scMethod :: !Text
  , scPath   :: !Text
  , scBody   :: !Value
  } deriving (Eq, Show)

onlineRobots :: Value
onlineRobots = robotsWith "ONLINE"

offlineRobots :: Value
offlineRobots = robotsWith "OFFLINE"

emptyRobots :: Value
emptyRobots = object ["robots" .= ([] :: [Value])]

robotsWith :: Text -> Value
robotsWith conn = object
  [ "robots" .=
      [ object
          [ "robotId"      .= ("acme:AMR-001" :: Text)
          , "manufacturer" .= ("acme" :: Text)
          , "serialNumber" .= ("AMR-001" :: Text)
          , "mapId"        .= ("plant-b" :: Text)
          , "connection"   .= conn
          , "driving"      .= False
          , "orderId"      .= ("" :: Text)
          ]
      ]
  ]

withDispatchGateway :: Status -> Value
                    -> (Manager -> FleetConfig -> IORef [SeenCall] -> IO ()) -> IO ()
withDispatchGateway st robots f = do
  calls <- newIORef []
  testWithApplication (pure (dispatchGatewayApp st robots calls)) $ \port -> do
    mgr <- newManager defaultManagerSettings
    let base = T.pack ("http://127.0.0.1:" ++ show port)
    f mgr (FleetConfig base Nothing) calls

dispatchGatewayApp :: Status -> Value -> IORef [SeenCall] -> Application
dispatchGatewayApp st robots calls req respond =
  case (requestMethod req, pathInfo req) of
    ("GET", ["api", "robots"]) ->
      respond (responseLBS status200 [(hContentType, "application/json")]
                 (encode robots))
    ("POST", ["api", "orders"]) -> do
      raw <- lazyRequestBody req
      -- Warp may drop the chunks after the response; force the body here.
      _ <- evaluate (BL.length raw)
      let body = either (const Null) id (Data.Aeson.eitherDecode raw)
      atomicModifyIORef' calls
        (\cs -> (cs ++ [SeenCall "POST" "/api/orders" body], ()))
      respond (responseLBS st [(hContentType, "application/json")]
        (if st == status200
           then encode (object [ "status" .= ("published" :: Text)
                               , "orderId" .= ("order-test" :: Text)
                               , "robotId" .= ("acme:AMR-001" :: Text)
                               , "headerId" .= (1 :: Int)
                               , "waypoints" .= (3 :: Int) ])
           else encode (object [ "error" .= ("invalid_order" :: Text)
                               , "reasons" .= (["gateway refused it"] :: [Text]) ])))
    ("POST", ["api", "robots", rid, "instant-actions"]) -> do
      raw <- lazyRequestBody req
      _ <- evaluate (BL.length raw)
      let body = either (const Null) id (Data.Aeson.eitherDecode raw)
          path = "/api/robots/" ++ T.unpack rid ++ "/instant-actions"
      atomicModifyIORef' calls (\cs -> (cs ++ [SeenCall "POST" (T.pack path) body], ()))
      respond (responseLBS status200 [(hContentType, "application/json")]
        (encode (object [ "status" .= ("published" :: Text)
                        , "robotId" .= rid
                        , "headerId" .= (1 :: Int)
                        , "actions" .= (["startPause"] :: [Text]) ])))
    _ -> respond (responseLBS status404 [] "")

mkDispatchCfg :: Manager -> FleetConfig -> Bool
              -> IO (DispatchConfig, IORef [Text])
mkDispatchCfg mgr fleet allow = do
  c <- mkCfg
  seen <- newIORef []
  pure ( DispatchConfig
           { dcLoop = c { lcManager = mgr }
           , dcFleet = fleet
           , dcRobot = robot
           , dcAllowPublish = allow
           , dcSeenOrders = seen
           }
       , seen )

assertLeftContaining :: Text -> Either [Text] a -> IO ()
assertLeftContaining want r = case r of
  Left errs -> assertBool
    ("reason should contain " ++ T.unpack want ++ ": " ++ show errs)
    (any (want `T.isInfixOf`) errs)
  Right _ -> assertFailure ("expected a rejection containing " ++ T.unpack want)
