{-# LANGUAGE OverloadedStrings #-}
-- | Tests for the read-only gateway client.
--
-- Every test runs against a local stub that speaks the gateway's dialect, so
-- nothing here reaches a real fleet-control system. What is under test is the
-- one thing the agent cannot afford to get wrong: that reading the fleet is
-- safe, and that a gateway which is down or unhelpful is reported rather than
-- mistaken for an empty fleet.
module FleetSpec (tests) where

import Data.Aeson (Value(..), encode, object, (.=))
import qualified Data.Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

import Network.HTTP.Client (Manager, defaultManagerSettings, newManager)
import Network.HTTP.Types (Status, hAuthorization, hContentType, status200,
                            status400, status404)
import Network.Wai (Application, Request, lazyRequestBody, pathInfo,
                    requestHeaders, requestMethod, responseLBS)
import Network.Wai.Handler.Warp (testWithApplication)

import RobotDSL.Agent.Fleet

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

tests :: IO [TestTree]
tests = pure [testGroup "fleet" (fleetTests ++ postTests)]

fleetTests :: [TestTree]
fleetTests =
  [ testCase "the map is returned verbatim" $ withGateway $ \mgr cfg log -> do
      r <- fetchMap mgr cfg
      case r of
        Left e -> assertFailure e
        Right v -> do
          assertEqual "mapId" (Just "plant-b/l1") (strOf v "mapId")
          assertEqual "one node" 1 (countOf v "nodes")
          assertEqual "one edge" 1 (countOf v "edges")
          _ <- readIORef log
          pure ()

  , testCase "robots are parsed with identity and state" $ withGateway $ \mgr cfg _ -> do
      r <- fetchRobots mgr cfg
      case r of
        Left e -> assertFailure e
        Right rs -> do
          assertEqual "two robots" 2 (length rs)
          let online = filter rrOnline rs
          assertEqual "one online" 1 (length online)
          let r1 = head online
          assertEqual "robotId" "acme:AMR-001" (rrRobotId r1)
          assertEqual "manufacturer" "acme" (rrManufacturer r1)
          assertEqual "serialNumber" "AMR-001" (rrSerialNumber r1)
          assertEqual "mapId" (Just "plant-b/l1") (rrMapId r1)
          assertEqual "driving" True (rrDriving r1)
          assertEqual "current order" "order-9" (rrOrderId r1)
          -- 오프라인 로봇은 보고되되, 온라인으로 세지 않는다.
          let offline = filter (not . rrOnline) rs
          assertEqual "one offline" 1 (length offline)
          assertEqual "offline order is empty" "" (rrOrderId (head offline))

  , testCase "a robot with no identity is dropped, not half-parsed" $ withGateway $ \mgr cfg _ -> do
      r <- fetchRobots mgr cfg
      case r of
        Left e -> assertFailure e
        Right rs ->
          assertBool "the nameless robot is gone"
            (not (any (T.isInfixOf "AMR-003") (map rrRobotId rs)))

  , testCase "the bearer token is sent when one is configured" $ withGateway $ \mgr cfg log -> do
      r <- fetchMap mgr cfg { fcToken = Just "s3cret" }
      case r of
        Left e -> assertFailure e
        Right _ -> do
          auths <- readIORef log
          assertEqual "one request, one bearer" ["Bearer s3cret"] auths

  , testCase "no token means no Authorization header" $ withGateway $ \mgr cfg log -> do
      _ <- fetchMap mgr cfg
      auths <- readIORef log
      assertEqual "nothing sent" [] auths

  , testCase "a non-200 is reported as an operator-readable reason" $
      withGatewayAt status404 $ \mgr cfg _ -> do
        r <- fetchMap mgr cfg
        case r of
          Left e -> assertBool ("reason names the status: " ++ e)
                              ("404" `T.isInfixOf` T.pack e)
          Right _ -> assertFailure "expected a refusal"

  , testCase "an unreachable gateway is reported, not mistaken for empty" $ do
      mgr <- newManager defaultManagerSettings
      r <- fetchRobots mgr (FleetConfig "http://127.0.0.1:1" Nothing)
      case r of
        Left e -> assertBool ("reason is readable: " ++ e) (not (null e))
        Right rs -> assertFailure ("expected a refusal, got " ++ show rs)
  ]

postTests :: [TestTree]
postTests =
  [ testCase "a POST sends the exact JSON body" $
      withPostGateway $ \mgr cfg writes -> do
        let body = object ["orderId" .= ("order-test" :: Text)]
        r <- postJson mgr cfg "/api/orders" body
        case r of
          Left e -> assertFailure e
          Right v -> assertEqual "published" (Just "published") (strOf v "status")
        ws <- readIORef writes
        assertEqual "one order posted" 1 (length ws)
        let seen = head ws
        assertEqual "POST" "POST" (spMethod seen)
        assertEqual "body" body (spBody seen)
        assertBool "JSON content type"
          (any (T.isInfixOf "application/json") (spContentType seen))

  , testCase "the bearer token is sent on a POST too" $
      withPostGateway $ \mgr cfg writes -> do
        _ <- postJson mgr cfg { fcToken = Just "s3cret" } "/api/orders"
               (object ["orderId" .= ("o" :: Text)])
        ws <- readIORef writes
        assertEqual "one bearer" ["Bearer s3cret"] (spAuth (head ws))

  , testCase "a refused POST reports the status and the gateway reason" $
      withPostGatewayAt status400 $ \mgr cfg _ -> do
        r <- postJson mgr cfg "/api/orders" (object ["orderId" .= ("o" :: Text)])
        case r of
          Left e -> do
            assertBool ("status in reason: " ++ e) ("400" `T.isInfixOf` T.pack e)
            assertBool ("body in reason: " ++ e) ("gateway refused it" `T.isInfixOf` T.pack e)
          Right _ -> assertFailure "expected a refusal"
  ]

-- ---------------------------------------------------------------------------
-- Stub gateway
-- ---------------------------------------------------------------------------

-- | A gateway answering the two reads the agent makes.
--
-- The callback receives the manager, the config pointing at the stub, and the
-- log of @Authorization@ headers the stub was given — so a test can assert
-- what was sent without any global state.
--
-- @st@ is the status to answer with, so a failure path is exercised without a
-- second stub.
withGateway :: (Manager -> FleetConfig -> IORef [Text] -> IO ()) -> IO ()
withGateway = withGatewayAt status200

withGatewayAt :: Status -> (Manager -> FleetConfig -> IORef [Text] -> IO ()) -> IO ()
withGatewayAt st f = do
  authLog <- newIORef []
  testWithApplication (pure (gatewayApp authLog st)) $ \port -> do
    mgr <- newManager defaultManagerSettings
    let base = T.pack ("http://127.0.0.1:" ++ show port)
    f mgr (FleetConfig base Nothing) authLog

gatewayApp :: IORef [Text] -> Status -> Application
gatewayApp authLog st req respond =
  case pathInfo req of
    ["api", "map"] -> do
      recordAuth authLog req
      respond (responseLBS st [(hContentType, "application/json")]
                 (encode mapJson))
    ["api", "robots"] -> do
      recordAuth authLog req
      respond (responseLBS st [(hContentType, "application/json")]
                 (encode robotsJson))
    _ -> respond (responseLBS status404 [] "")

recordAuth :: IORef [Text] -> Request -> IO ()
recordAuth log req = atomicModifyIORef' log (\l -> (l ++ auths, ()))
  where
    auths = [ TE.decodeUtf8 v
            | (h, v) <- requestHeaders req, h == hAuthorization ]

-- | What the gateway recorder saw on one write.
data SeenPost = SeenPost
  { spMethod      :: !Text
  , spBody        :: !Value
  , spAuth        :: ![Text]
  , spContentType :: ![Text]
  } deriving (Eq, Show)

withPostGateway :: (Manager -> FleetConfig -> IORef [SeenPost] -> IO ()) -> IO ()
withPostGateway = withPostGatewayAt status200

withPostGatewayAt :: Status -> (Manager -> FleetConfig -> IORef [SeenPost] -> IO ()) -> IO ()
withPostGatewayAt st f = do
  writes <- newIORef []
  testWithApplication (pure (postGatewayApp writes st)) $ \port -> do
    mgr <- newManager defaultManagerSettings
    let base = T.pack ("http://127.0.0.1:" ++ show port)
    f mgr (FleetConfig base Nothing) writes

postGatewayApp :: IORef [SeenPost] -> Status -> Application
postGatewayApp writes st req respond =
  case pathInfo req of
    ["api", "orders"] -> do
      raw <- lazyRequestBody req
      let seen = SeenPost
            { spMethod = TE.decodeUtf8 (requestMethod req)
            , spBody = either (const Null) id (Data.Aeson.eitherDecode raw)
            , spAuth = [ TE.decodeUtf8 v
                       | (h, v) <- requestHeaders req, h == hAuthorization ]
            , spContentType = [ TE.decodeUtf8 v
                              | (h, v) <- requestHeaders req, h == hContentType ]
            }
      atomicModifyIORef' writes (\ws -> (ws ++ [seen], ()))
      respond (responseLBS st [(hContentType, "application/json")]
        (if st == status200
           then encode (object ["status" .= ("published" :: Text)])
           else "gateway refused it"))
    _ -> respond (responseLBS status404 [] "")

-- | The map the stub serves: one node, one edge, so counts are unambiguous.
mapJson :: Value
mapJson = object
  [ "mapId" .= ("plant-b/l1" :: Text)
  , "nodes" .= object
      [ "RK-AM" .= object ["x" .= (1.0 :: Double), "y" .= (2.0 :: Double)] ]
  , "edges" .= [ object
      [ "from" .= ("RK-AM" :: Text), "to" .= ("CHG-01" :: Text) ] ]
  ]

-- | Two robots: one online and driving, one offline.
--
-- A third entry with no @robotId@ is present to prove it is dropped rather
-- than half-parsed into a robot that cannot be addressed.
robotsJson :: Value
robotsJson = object
  [ "robots" .=
    [ object
        [ "robotId"      .= ("acme:AMR-001" :: Text)
        , "manufacturer" .= ("acme" :: Text)
        , "serialNumber" .= ("AMR-001" :: Text)
        , "mapId"        .= ("plant-b/l1" :: Text)
        , "connection"   .= ("ONLINE" :: Text)
        , "driving"      .= True
        , "orderId"      .= ("order-9" :: Text)
        ]
    , object
        [ "robotId"      .= ("acme:AMR-002" :: Text)
        , "manufacturer" .= ("acme" :: Text)
        , "serialNumber" .= ("AMR-002" :: Text)
        , "connection"   .= ("OFFLINE" :: Text)
        , "driving"      .= False
        , "orderId"      .= ("" :: Text)
        ]
    , object
        [ "manufacturer" .= ("acme" :: Text)
        , "serialNumber" .= ("AMR-003" :: Text)
        , "connection"   .= ("ONLINE" :: Text)
        ]
    ]
  ]

-- ---------------------------------------------------------------------------
-- JSON helpers
-- ---------------------------------------------------------------------------

strOf :: Value -> Text -> Maybe Text
strOf v k = case v of
  Object o -> case KM.lookup (Key.fromText k) o of
    Just (String s) -> Just s
    _               -> Nothing
  _ -> Nothing

-- | How many entries a named object or array holds.
countOf :: Value -> Text -> Int
countOf v k = case v of
  Object o -> case KM.lookup (Key.fromText k) o of
    Just (Object n) -> KM.size n
    Just (Array a)  -> length a
    _               -> 0
  _ -> 0
