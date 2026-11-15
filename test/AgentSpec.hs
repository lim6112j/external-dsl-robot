{-# LANGUAGE OverloadedStrings #-}
-- | Tests for the agent layer.
--
-- The one hard requirement is that nothing here talks to OpenRouter. Both the
-- loop and the server are exercised against a local stub that speaks the same
-- OpenAI-compatible dialect, so the tests are deterministic and free.
module AgentSpec (tests) where

import Control.Monad (forM_, unless, when)
import Data.Aeson (Value(..), encode, object, (.=))
import qualified Data.Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import qualified Data.Vector as V

import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory (doesFileExist, removeFile)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

import Network.HTTP.Client (Manager, defaultManagerSettings, httpLbs,
                            newManager, parseRequest, responseBody,
                            responseStatus)
import Network.HTTP.Simple (setRequestBodyLBS, setRequestHeader,
                            setRequestMethod)
import Network.HTTP.Types (hContentType, status200, status404, statusCode)
import Network.Wai (Application, lazyRequestBody, pathInfo, requestMethod,
                    responseLBS)
import Network.Wai.Handler.Warp (Port, testWithApplication)

import RobotDSL.Agent.Client
import RobotDSL.Agent.Context
import RobotDSL.Agent.Fleet (FleetConfig(..), RobotRef(..))
import RobotDSL.Agent.Loop
import RobotDSL.Agent.Prompt
import RobotDSL.Agent.Server
import RobotDSL.Emit
import RobotDSL.Version

tests :: IO [TestTree]
tests = pure
  [ testGroup "prompt"
      [ testCase "system prompt carries the map vocabulary" $ do
          let vocab = Vocabulary (Just "plant-b") ["RK-AM", "CHG-01"] []
                              [("RK-AM", "CHG-01")] Nothing
                              [("RK-AM", (1.0, 2.0)), ("CHG-01", (3.0, 4.0))]
              p = systemPrompt Nothing vocab
          assertBool "mapId present" (T.isInfixOf "plant-b" p)
          assertBool "node RK-AM present" (T.isInfixOf "RK-AM" p)
          assertBool "node CHG-01 present" (T.isInfixOf "CHG-01" p)
      , testCase "system prompt carries the action catalogue" $ do
          let p = systemPrompt Nothing emptyVocabulary
          forM_ standardActions $ \a ->
            assertBool ("action missing: " <> T.unpack a) (T.isInfixOf a p)
      , testCase "system prompt names every zone type" $ do
          let p = systemPrompt Nothing emptyVocabulary
          forM_ zoneTypes $ \z ->
            assertBool ("zone type missing: " <> T.unpack z) (T.isInfixOf z p)
      , testCase "system prompt carries the traversable hops" $ do
          let vocab = Vocabulary (Just "plant-b") ["RK-AW", "AS-3M"] []
                         [("RK-AW", "AS-3M")] Nothing []
              p = systemPrompt Nothing vocab
          assertBool "hop RK-AW -> AS-3M present" (T.isInfixOf "RK-AW -> AS-3M" p)
      , testCase "a scope narrows the prompt vocabulary" $ do
          let full = Vocabulary (Just "plant-b") ["RK-AW", "AS-3M"] []
                              [("RK-AW", "AS-3M")] Nothing []
              vocab = applyScope (Just ["RK-AW"]) full
              p = systemPrompt Nothing vocab
          assertBool "scoped node kept" (T.isInfixOf "RK-AW" p)
          assertBool "out-of-scope node dropped" (not (T.isInfixOf "AS-3M" p))
          assertBool "scope is stated" (T.isInfixOf "scope:" p)
          assertEqual "scope is recorded" (Just ["RK-AW"]) (vocScope vocab)
          assertEqual "hop outside the scope is dropped" [] (vocEdgePairs vocab)
      , testCase "the prompt names the selected robot" $ do
          let robot = RobotRef "acme:AMR-001" "acme" "AMR-001" (Just "plant-b") True True "order-7"
              sec = robotSection (Just robot)
          assertBool "robotId present" (T.isInfixOf "acme:AMR-001" sec)
          assertBool "serialNumber present" (T.isInfixOf "AMR-001" sec)
          assertBool "state reported" (T.isInfixOf "driving order order-7" sec)
          assertBool "an absent robot is stated plainly"
              (T.isInfixOf "No robot is selected" (robotSection Nothing))
      , testCase "cleanOutput strips a language-tagged fence" $ do
          let src = T.unlines ["robot \"a\" \"b\"", "order \"o\" {"]
          assertEqual "fence stripped" src (cleanOutput (fence "robotdsl" src))
      , testCase "cleanOutput strips a bare fence" $ do
          let src = T.unlines ["robot \"a\" \"b\""]
          assertEqual "fence stripped" src (cleanOutput (fence "" src))
      , testCase "cleanOutput drops prose before the first declaration" $ do
          let src = T.unlines ["robot \"a\" \"b\"", "map \"m\""]
              dirty = "Sure! Here is the DSL you asked for:\n" <> src
          assertEqual "prose dropped" src (cleanOutput dirty)
      , testCase "cleanOutput handles prose, fence and trailing fence" $ do
          let src = T.unlines ["robot \"a\" \"b\"", "order \"o\" { node \"n\" at (0,0) }"]
              dirty = "Here you go:\n" <> fence "robotdsl" src
          assertEqual "all stripped" src (cleanOutput dirty)
      , testCase "cleanOutput leaves clean input untouched" $ do
          let src = T.unlines ["robot \"a\" \"b\"", "map \"m\""]
          assertEqual "unchanged" src (cleanOutput src)
      ]

  , testGroup "context"
      [ testCase "loads the sibling warehouse map" $ do
          r <- loadVocabulary (Just mapPath)
          case r of
            Left err -> assertFailure err
            Right v -> do
              assertEqual "mapId" (Just "plant-b/l1") (vocMapId v)
              assertEqual "35 nodes" 35 (length (vocNodes v))
              assertBool "RK-AM known" ("RK-AM" `elem` vocNodes v)
      , testCase "no map gives an empty vocabulary, not an error" $ do
          r <- loadVocabulary Nothing
          case r of
            Left err -> assertFailure err
            Right v -> do
              assertEqual "no mapId" Nothing (vocMapId v)
              assertEqual "no nodes" [] (vocNodes v)
      , testCase "a missing map file is an error" $ do
          r <- loadVocabulary (Just "/nonexistent/map.json")
          case r of
            Left _  -> pure ()
            Right _ -> assertFailure "expected an error for a missing map"
      ]

  , testGroup "loop"
      [ testCase "succeeds on the first attempt" $ withStub (const goodDsl) $ \st -> do
          r <- runLoop (loopCfg st) [] "랙에서 컨베이어로"
          assertOk r
          assertEqual "one attempt" 1 (lrAttempts r)
      , testCase "retries after a parse failure" $ withStub attemptOkOnSecond $ \st -> do
          r <- runLoop (loopCfg st) [] "랙에서 컨베이어로"
          assertOk r
          assertEqual "two attempts" 2 (lrAttempts r)
          calls <- readIORef (stubCalls st)
          assertEqual "two calls" 2 (length calls)
      , testCase "gives up after three attempts" $ withStub (const garbage) $ \st -> do
          r <- runLoop (loopCfg st) [] "뭐라뭐라"
          assertNotOk r
          assertEqual "three attempts" 3 (lrAttempts r)
          assertBool "errors reported" (not (null (lrErrors r)))
          calls <- readIORef (stubCalls st)
          assertEqual "three calls" 3 (length calls)
      , testCase "a failing attempt feeds its error back" $ withStub attemptOkOnSecond $ \st -> do
          r <- runLoop (loopCfg st) [] "랙에서 컨베이어로"
          assertOk r
          calls <- readIORef (stubCalls st)
          assertEqual "two calls" 2 (length calls)
          -- 스텁은 요청을 최신순으로 쌓으므로 head 가 두 번째 호출이다.
          assertBool "second call carries the rejection"
                     (T.isInfixOf "rejected" (messagesText (head calls)))
      , testCase "retries a route the map cannot carry" $ withStub attemptOkOnThird $ \st -> do
          -- 맵이 못 나르는 홉을 내면 재시도하여 두 번째에서 성공해야 한다.
          -- 이 검사가 없으면 생성기는 유효하지만 주행 불가한 임무를
          -- 성공으로 돌려보낸다.
          r <- runLoop (loopCfg st) [] "랙에서 컨베이어로"
          assertOk r
          assertEqual "two attempts" 2 (lrAttempts r)
          calls <- readIORef (stubCalls st)
          assertEqual "two calls" 2 (length calls)
          -- 스텁은 요청을 최신순으로 쌓으므로 head 가 두 번째 호출이다.
          assertBool "the rejection names the unreachable hop"
                     (T.isInfixOf "there is no edge from RK-AM to STG-01"
                                 (messagesText (head calls)))
          -- 이웃 정보가 함께 가야 재시도가 산 길을 찾을 수 있다.
          assertBool "the rejection names what RK-AM does reach"
                     (T.isInfixOf "from RK-AM the map connects only to CHG-01"
                                 (messagesText (head calls)))

      , testCase "gives up when the route stays undrivable" $
          withStub (const badRouteDsl) $ \st -> do
            r <- runLoop (loopCfg st) [] "랙에서 컨베이어로"
            assertNotOk r
            assertEqual "three attempts" 3 (lrAttempts r)
            assertBool "the failure is the unroutable hop"
                       (any (T.isInfixOf "there is no edge from RK-AM to STG-01")
                            (lrErrors r))
            -- 실패해도 마지막 소스는 남겨두어 운영자가 손으로 고칠 수 있다.
            assertBool "the last source is kept" (not (T.null (lrDsl r)))

      , testCase "injects the robot declaration the model omitted" $ withStub (const noRobotDsl) $ \st -> do
          r <- runLoop (loopCfg st) [] "멈춰"
          assertOk r
          let order = head (lrMessages r)
          assertEqual "manufacturer injected" "acme" (strField order "manufacturer")
          assertEqual "serialNumber injected" "AMR-001" (strField order "serialNumber")
      , testCase "reports token usage" $ withStub (const goodDsl) $ \st -> do
          r <- runLoop (loopCfg st) [] "랙에서 컨베이어로"
          case lrUsage r of
            Nothing     -> assertFailure "expected usage"
            Just (p, c) -> do
              assertBool "prompt tokens" (p > 0)
              assertBool "completion tokens" (c > 0)
      ]

  , testGroup "server"
      [ testCase "GET /api/context reports the map with coordinates" $ withServer $ \port mgr -> do
          v <- getJson mgr (baseUrl port <> "/api/context")
          assertEqual "hasMap" (Just True) (boolField v "hasMap")
          assertEqual "two drawable nodes" 2 (length (arrField v "nodes"))
          assertEqual "one edge pair" 1 (length (arrField v "edges"))
          assertBool "node carries coordinates"
                     (any (\o -> objLookup "x" o /= Nothing
                               && objLookup "y" o /= Nothing)
                          (arrField v "nodes"))
          assertEqual "no fleet configured" 0 (length (arrField v "robots"))
      , testCase "POST /api/command returns generated DSL" $ withServer $ \port mgr -> do
          v <- postJson mgr (baseUrl port <> "/api/command")
                 (object ["text" .= ("랙에서 컨베이어로" :: Text)
                         , "sessionId" .= ("t1" :: Text)])
          assertEqual "ok" (Just True) (boolField v "ok")
          assertBool "dsl present" (not (T.null (strField v "dsl")))
          assertBool "messages present" (not (null (arrField v "messages")))
          -- 미리보기가 함께 와야 UI 가 경로를 그릴 수 있다.
          case objLookup "preview" v of
            Nothing -> assertFailure "no preview in the response"
            Just pv -> do
              assertEqual "two nodes on the route" 2 (length (arrField pv "nodes"))
              assertEqual "one hop between them" 1 (length (arrField pv "hops"))
              assertEqual "both released" [True, True] (boolsField pv "released")
              assertEqual "nothing unplaced" 0 (length (arrField pv "unplaced"))
              assertEqual "no warnings" 0 (length (arrField pv "warnings"))
      , testCase "POST /api/command rejects a body with no text" $ withServer $ \port mgr -> do
          v <- postJson mgr (baseUrl port <> "/api/command") (object [])
          assertEqual "not ok" (Just False) (boolField v "ok")
          assertBool "error given" (not (T.null (strField v "error")))
      , testCase "POST /api/compile recompiles edited DSL" $ withServer $ \port mgr -> do
          v <- postJson mgr (baseUrl port <> "/api/compile") (object ["dsl" .= goodDsl])
          assertEqual "ok" (Just True) (boolField v "ok")
          assertBool "messages present" (not (null (arrField v "messages")))
          case objLookup "preview" v of
            Nothing -> assertFailure "no preview in the compile response"
            Just pv ->
              assertEqual "route is drawn again" 2 (length (arrField pv "nodes"))
      , testCase "POST /api/compile reports errors for bad DSL" $ withServer $ \port mgr -> do
          v <- postJson mgr (baseUrl port <> "/api/compile")
                 (object ["dsl" .= ("nonsense" :: Text)])
          assertEqual "not ok" (Just False) (boolField v "ok")
          assertBool "errors given" (not (null (arrField v "errors")))
      , testCase "POST /api/save refuses a path that escapes the directory" $ withServer $ \port mgr -> do
          v <- postJson mgr (baseUrl port <> "/api/save")
                 (object ["dsl" .= goodDsl, "path" .= ("../escape.robot" :: Text)])
          assertEqual "not ok" (Just False) (boolField v "ok")
          assertBool "error given" (not (T.null (strField v "error")))
      , testCase "POST /api/save refuses an absolute path" $ withServer $ \port mgr -> do
          v <- postJson mgr (baseUrl port <> "/api/save")
                 (object ["dsl" .= goodDsl, "path" .= ("/tmp/escape.robot" :: Text)])
          assertEqual "not ok" (Just False) (boolField v "ok")
      , testCase "POST /api/save refuses DSL that does not validate" $ withServer $ \port mgr -> do
          v <- postJson mgr (baseUrl port <> "/api/save")
                 (object ["dsl" .= ("nonsense" :: Text), "path" .= ("x.robot" :: Text)])
          assertEqual "not ok" (Just False) (boolField v "ok")
          exists <- doesFileExist "x.robot"
          assertBool "no file written" (not exists)
      , testCase "POST /api/save writes a valid file" $ withServer $ \port mgr -> do
          let path = "agent-spec-saved.robot"
          v <- postJson mgr (baseUrl port <> "/api/save")
                 (object ["dsl" .= goodDsl, "path" .= path])
          assertEqual "ok" (Just True) (boolField v "ok")
          exists <- doesFileExist path
          assertBool "file written" exists
          when exists (removeFile path)
      , testCase "POST /api/reset clears the session" $ withServer $ \port mgr -> do
          v <- postJson mgr (baseUrl port <> "/api/reset")
                 (object ["sessionId" .= ("t1" :: Text)])
          assertEqual "ok" (Just True) (boolField v "ok")
      , testCase "a follow-up command sees the earlier turn" $ withStub (const goodDsl) $ \stub -> do
          -- 이 테스트만 스텁의 기록된 요청을 직접 본다.
          testWithApplication (serverApp (stubMgr stub) (stubCfg stub)) $ \port -> do
            let mgr = stubMgr stub
                url = baseUrl port <> "/api/command"
            _ <- postJson mgr url (object ["text" .= ("랙에서 컨베이어로" :: Text)
                                          , "sessionId" .= ("t9" :: Text)])
            _ <- postJson mgr url (object ["text" .= ("마지막 노드를 충전소로 바꿔줘" :: Text)
                                          , "sessionId" .= ("t9" :: Text)])
            calls <- readIORef (stubCalls stub)
            assertEqual "two calls" 2 (length calls)
            -- 두 번째 요청은 첫 어시스턴트 턴이 붙어 메시지가 더 많다.
            -- (문자열 포함 여부로는 판단할 수 없다. few-shot 예시에도
            --  order-pallet-1 이 나오기 때문.)
            assertBool "second call carries the earlier turn"
                       (messageCount (head calls) > messageCount (last calls))
      , testCase "the agent never writes to the fleet gateway" $
        withServerAndGateway $ \port mgr _ seen -> do
          -- 읽기는 허용된다: 맵과 로봇을 조회한다.
          _ <- getJson mgr (baseUrl port <> "/api/context")
          _ <- postJson mgr (baseUrl port <> "/api/command")
                 (object ["text" .= ("랙에서 컨베이어로" :: Text)
                         , "sessionId" .= ("np" :: Text)])
          _ <- postJson mgr (baseUrl port <> "/api/compile")
                 (object ["dsl" .= goodDsl])
          reqs <- readIORef seen
          let writes = [ e | e@(m, _) <- reqs, m /= "GET" ]
          assertEqual "no write ever reached the gateway" [] writes
          -- 읽기가 실제로 일어났는지도 확인한다. 위 단정이 우연히 비어서가
          -- 아님을 보이기 위해.
          -- 맵은 시작 시 한 번 읽히므로(또는 --map 으로 공급되므로), 이
          -- 런타임 경로에서 게이트웨이에 묻는 것은 로봇 목록뿐이다.
          assertBool "the robots were read"
                     (any ((== "/api/robots") . snd) reqs)

    , testCase "a map that appears after startup is picked up" $
        -- 회귀: 맵은 예전에 시작 시 한 번만 가져왔다. 그래이트웨이보다 먼저
        -- 뜬 에이전트는 영원히 맵이 비어 있었고, 화면에 이유가 없었다.
        -- 이제 매 요청마다 다시 읽으므로 나중에 뜬 게이트웨이도 보인다.
        withStub (const goodDsl) $ \stub -> do
          seen <- newIORef []
          testWithApplication (pure (gatewayRecorder seen)) $ \gwPort ->
            testWithApplication
              (serverAppWithNoMap
                 (Just (FleetConfig
                          (T.pack ("http://127.0.0.1:" ++ show gwPort)) Nothing))
                 (stubMgr stub) (stubCfg stub))
              $ \port -> do
                let mgr = stubMgr stub
                    url = baseUrl port <> "/api/context"
                v <- getJson mgr url
                assertBool "the map arrived from the gateway"
                           (not (null (arrField v "nodes")))
                assertBool "the node ids are the gateway's"
                           (any (\n -> strField n "id" == "RK-AM")
                                (arrField v "nodes"))
                assertEqual "no fleet error" Nothing (strFieldMaybe v "fleetError")

    , testCase "a gateway that is unreachable keeps the map it had" $
        -- 일시적으로 끊긴 게이트웨이가 어휘를 비우면 안 된다. 노드 id 가 사라지면
        -- 생성기는 이름을 지어내는 쪽으로 돌아간다.
        withStub (const goodDsl) $ \stub -> do
          testWithApplication
            (serverAppWith
               (Just (FleetConfig (T.pack "http://127.0.0.1:9") Nothing))
               (stubMgr stub) (stubCfg stub))
            $ \port -> do
              let mgr = stubMgr stub
                  url = baseUrl port <> "/api/context"
              v <- getJson mgr url
              assertBool "the startup map is kept"
                         (not (null (arrField v "nodes")))
              assertBool "the operator is told the fleet did not answer"
                         (isJust (strFieldMaybe v "fleetError"))

    , testCase "the picked robot reaches the generator" $
        withServerAndGateway $ \port mgr stub _ -> do
          _ <- postJson mgr (baseUrl port <> "/api/command")
                 (object ["text" .= ("랙에서 컨베이어로" :: Text)
                         , "sessionId" .= ("rp" :: Text)
                         , "robotId" .= ("acme:AMR-001" :: Text)])
          calls <- readIORef (stubCalls stub)
          assertEqual "one call" 1 (length calls)
          -- 스텁은 요청을 최신순으로 쌓는다.
          assertBool "the prompt names the chosen robot"
                     (T.isInfixOf "acme:AMR-001" (messagesText (head calls)))

    , testCase "an unknown route is a 404" $ withServer $ \port mgr -> do
          code <- getRaw mgr (baseUrl port <> "/nope")
          assertEqual "404" 404 code
      ]
  ]

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

mapPath :: FilePath
mapPath = "/Users/nixos/workspace/로봇관제시스템/deploy/maps/plant-b.l1.json"

zoneTypes :: [Text]
zoneTypes =
  [ "BLOCKED", "LINE_GUIDED", "RELEASE", "COORDINATED_REPLANNING"
  , "SPEED_LIMIT", "ACTION", "PRIORITY", "PENALTY", "DIRECTED", "BIDIRECTED"
  ]

goodDsl :: Text
goodDsl = T.unlines
  [ "robot \"acme\" \"AMR-001\""
  , "map \"plant-b\""
  , "order \"order-pallet-1\" {"
  , "  base {"
  , "    node \"RK-AM\" at (12.5, 3.0) { action \"pick\" }"
  , "    go to \"CHG-01\" at (0.0, 0.0) { action \"drop\" }"
  , "  }"
  , "}"
  ]

-- | Valid apart from the missing @robot@ line, to exercise injection.
noRobotDsl :: Text
noRobotDsl = T.unlines
  [ "map \"plant-b\""
  , "order \"order-1\" {"
  , "  base { node \"RK-AM\" at (0,0) { action \"pick\" } }"
  , "}"
  ]

-- | Text that parses to nothing, forcing a retry.
garbage :: Text
garbage = "Sure! Here is your mission:\n"

attemptOkOnSecond :: Int -> Text
attemptOkOnSecond 1 = garbage
attemptOkOnSecond _ = goodDsl

-- | A route through two nodes the map does not connect.
--
-- Both node ids are real, so the parser and the validator accept this and it
-- emits a well-formed order. It just cannot be driven: the fixture map joins
-- RK-AM to CHG-01 and CHG-01 to STG-01, so RK-AM never reaches STG-01 in one
-- hop. This is the shape the generator actually produced when asked to take a
-- pallet to the conveyor — it picked two real nodes and joined them.
badRouteDsl :: Text
badRouteDsl = T.unlines
  [ "robot \"acme\" \"AMR-001\""
  , "map \"plant-b\""
  , "order \"order-pallet-1\" {"
  , "  base {"
  , "    node \"RK-AM\" at (12.5, 3.0) { action \"pick\" }"
  , "    go to \"STG-01\" at (0.0, 0.0) { action \"drop\" }"
  , "  }"
  , "}"
  ]

-- | First proposes the unroutable hop, then corrects it.
attemptOkOnThird :: Int -> Text
attemptOkOnThird 1 = badRouteDsl
attemptOkOnThird _ = goodDsl

fence :: Text -> Text -> Text
fence lang body = "```" <> lang <> "\n" <> body <> "```\n"

-- ---------------------------------------------------------------------------
-- Assertions and JSON helpers
-- ---------------------------------------------------------------------------

assertOk :: LoopResult -> IO ()
assertOk r = unless (lrOk r) $
  assertFailure ("expected success, got errors: " ++ show (lrErrors r))

assertNotOk :: LoopResult -> IO ()
assertNotOk r = when (lrOk r) $ assertFailure "expected failure"

-- | A string field that may be absent or null. Unlike 'strField' this does
-- not throw, so it can be used where the answer is expected to be Nothing.
strFieldMaybe :: Value -> Text -> Maybe Text
strFieldMaybe v k = case objLookup k v of
  Just (String s) -> Just s
  _               -> Nothing

strField :: Value -> Text -> Text
strField v k = case objLookup k v of
  Just (String s) -> s
  other           -> error ("no string field " ++ T.unpack k ++ ": " ++ show other)

boolField :: Value -> Text -> Maybe Bool
boolField v k = case objLookup k v of
  Just (Bool b) -> Just b
  _             -> Nothing

-- | A JSON array of booleans, e.g. the preview's per-node @released@ flags.
-- A non-boolean entry is dropped rather than defaulted, so a shape change
-- shows up as a short list instead of a plausible-looking wrong one.
boolsField :: Value -> Text -> [Bool]
boolsField v k = case objLookup k v of
  Just (Array a) -> [ b | Bool b <- V.toList a ]
  _              -> []

arrField :: Value -> Text -> [Value]
arrField v k = case objLookup k v of
  Just (Array a) -> V.toList a
  _              -> []

objLookup :: Text -> Value -> Maybe Value
objLookup k (Object o) = KM.lookup (Key.fromText k) o
objLookup _ _          = Nothing

-- | How many messages a recorded request carried.
messageCount :: Value -> Int
messageCount v = case objLookup "messages" v of
  Just (Array a) -> V.length a
  _              -> 0

-- | Every message content in a recorded request body, joined.
messagesText :: Value -> Text
messagesText v = case objLookup "messages" v of
  Just (Array a) -> T.unlines
    [ c | Object o <- V.toList a
        , Just (String c) <- [KM.lookup "content" o] ]
  _ -> ""

-- ---------------------------------------------------------------------------
-- A local stub speaking the OpenAI chat-completions dialect
-- ---------------------------------------------------------------------------

data Stub = Stub
  { stubMgr   :: !Manager
  , stubCfg   :: !ClientConfig
  , stubCalls :: !(IORef [Value])
  }

-- | Run @f@ against a stub whose n-th response body is @responder n@.
withStub :: (Int -> Text) -> (Stub -> IO ()) -> IO ()
withStub responder f = do
  calls <- newIORef []
  -- stubApp 은 순수 Application 이므로 IO 로 감싸 전달한다.
  testWithApplication (pure (stubApp calls responder)) $ \port -> do
    mgr <- newManager defaultManagerSettings
    let cfg = ClientConfig
          { ccApiKey    = "test-key"
          , ccModel     = "stub-model"
          , ccBaseUrl   = T.pack ("http://127.0.0.1:" ++ show port ++ "/v1")
          , ccMaxTokens = 1024
          }
    f Stub { stubMgr = mgr, stubCfg = cfg, stubCalls = calls }

-- | The stub application. Records each request body and answers with the
-- responder's text for that call number.
stubApp :: IORef [Value] -> (Int -> Text) -> Application
stubApp calls responder req respond = do
  body <- lazyRequestBody req
  case Data.Aeson.eitherDecode body of
    Left _ -> textResponse "unparseable request" req respond
    Right v -> do
      n <- atomicModifyIORef' calls (\cs -> (v : cs, length cs + 1))
      textResponse (responder n) req respond

textResponse :: Text -> Application
textResponse content _req respond =
  respond (responseLBS status200 [(hContentType, "application/json")]
              (encode (chatResponse content)))

chatResponse :: Text -> Value
chatResponse content = object
  [ "choices" .= [ object
      [ "message" .= object
          [ "role" .= ("assistant" :: Text), "content" .= content ] ] ]
  , "usage" .= object
      [ "prompt_tokens" .= (11 :: Int), "completion_tokens" .= (7 :: Int) ]
  ]

loopCfg :: Stub -> LoopConfig
loopCfg st = LoopConfig
  { lcManager = stubMgr st
  , lcClient  = stubCfg st
  , lcVocab   = Vocabulary (Just "plant-b") ["RK-AM", "CHG-01", "STG-01"] []
                              [("RK-AM", "CHG-01"), ("CHG-01", "STG-01")] Nothing
                              [ ("RK-AM", (1.0, 2.0)), ("CHG-01", (3.0, 4.0))
                              , ("STG-01", (5.0, 6.0)) ]
  , lcEmit    = EmitContext "acme" "AMR-001" 1 "2026-01-01T00:00:00.000Z"
                           protocolVersion (Just "plant-b")
  , lcRobot   = Nothing
  , lcMfr     = Just "acme"
  , lcSerial  = Just "AMR-001"
  }

-- ---------------------------------------------------------------------------
-- Server fixture
-- ---------------------------------------------------------------------------

-- | The robotdsl server, wired to a stub that always returns a valid order.
withServer :: (Port -> Manager -> IO ()) -> IO ()
withServer f = withStub (const goodDsl) $ \stub -> do
  testWithApplication (serverApp (stubMgr stub) (stubCfg stub)) $
    \port -> f port (stubMgr stub)

serverApp :: Manager -> ClientConfig -> IO Application
serverApp = serverAppWith Nothing

-- | As 'serverApp', but pointed at a gateway.
--
-- @fleet@ is @Nothing@ for every test that does not care, so the default
-- stays "no gateway" rather than "some gateway".
serverAppWith :: Maybe FleetConfig -> Manager -> ClientConfig -> IO Application
serverAppWith fleet mgr client = serverAppWithVocab fleet mgr client testVocab

-- | The agent with an empty vocabulary, as if it had started before the
-- gateway was up.
serverAppWithNoMap :: Maybe FleetConfig -> Manager -> ClientConfig -> IO Application
serverAppWithNoMap fleet mgr client = serverAppWithVocab fleet mgr client emptyVocabulary

serverAppWithVocab
  :: Maybe FleetConfig -> Manager -> ClientConfig -> Vocabulary -> IO Application
serverAppWithVocab fleet mgr client vocab = do
  let emitCtx = EmitContext "acme" "AMR-001" 1 "2026-01-01T00:00:00.000Z"
                            protocolVersion (Just "plant-b")
  st <- newAppState mgr client vocab fleet emitCtx "web" ""
  pure (app st)

testVocab :: Vocabulary
testVocab = Vocabulary (Just "plant-b") ["RK-AM", "CHG-01"] []
                      [("RK-AM", "CHG-01")] Nothing
                      [("RK-AM", (1.0, 2.0)), ("CHG-01", (3.0, 4.0))]

baseUrl :: Port -> String
baseUrl port = "http://127.0.0.1:" ++ show port

-- | A stub of the fleet-control gateway that records every request it is
-- given.
--
-- It answers the two reads the agent makes and nothing else, so a test can
-- assert that no write ever arrived. This is the property that makes Phase 1
-- safe: the agent can read the fleet, but it cannot move a robot.
gatewayRecorder :: IORef [(String, String)] -> Application
gatewayRecorder seen req respond =
  case (requestMethod req, pathInfo req) of
    ("GET", ["api", "map"]) -> do
      atomicModifyIORef' seen (\c -> (("GET", "/api/map") : c, ()))
      respond (responseLBS status200 [(hContentType, "application/json")]
                 (encode gatewayMapJson))
    ("GET", ["api", "robots"]) -> do
      atomicModifyIORef' seen (\c -> (("GET", "/api/robots") : c, ()))
      respond (responseLBS status200 [(hContentType, "application/json")]
                 (encode gatewayRobotsJson))
    _ -> do
      let entry = ( T.unpack (TE.decodeUtf8 (requestMethod req))
                  , T.unpack (T.intercalate "/" (pathInfo req)) )
      atomicModifyIORef' seen (\c -> (entry : c, ()))
      respond (responseLBS status404 [(hContentType, "text/plain")] "no")

gatewayMapJson :: Value
gatewayMapJson = object
  [ "mapId" .= ("plant-b" :: Text)
  , "nodes" .= object
      [ "RK-AM" .= object ["x" .= (1.0 :: Double), "y" .= (2.0 :: Double)]
      , "CHG-01" .= object ["x" .= (3.0 :: Double), "y" .= (4.0 :: Double)]
      ]
  , "edges" .= [ object ["from" .= ("RK-AM" :: Text), "to" .= ("CHG-01" :: Text)] ]
  ]

gatewayRobotsJson :: Value
gatewayRobotsJson = object
  [ "robots" .=
    [ object
        [ "robotId" .= ("acme:AMR-001" :: Text)
        , "manufacturer" .= ("acme" :: Text)
        , "serialNumber" .= ("AMR-001" :: Text)
        , "connection" .= ("ONLINE" :: Text)
        , "driving" .= False
        , "orderId" .= ("" :: Text)
        ]
    ]
  ]

-- | The agent, wired to a stub model and a recording gateway.
--
-- Nesting the two warp instances is fine: each 'testWithApplication' takes its
-- own ephemeral port. The gateway is only reachable from this test, so a write
-- to it could not be anything but the agent's own doing.
withServerAndGateway
  :: (Port -> Manager -> Stub -> IORef [(String, String)] -> IO ()) -> IO ()
withServerAndGateway f = withStub (const goodDsl) $ \stub -> do
  seen <- newIORef []
  testWithApplication (pure (gatewayRecorder seen)) $ \gwPort ->
    testWithApplication
      (serverAppWith
         (Just (FleetConfig
                  (T.pack ("http://127.0.0.1:" ++ show gwPort)) Nothing))
         (stubMgr stub) (stubCfg stub))
      $ \port -> f port (stubMgr stub) stub seen

-- ---------------------------------------------------------------------------
-- HTTP helpers
-- ---------------------------------------------------------------------------

postJson :: Manager -> String -> Value -> IO Value
postJson mgr url body = do
  req0 <- parseRequest url
  let req = setRequestMethod "POST"
          $ setRequestHeader hContentType ["application/json"]
          $ setRequestBodyLBS (encode body)
          $ req0
  resp <- httpLbs req mgr
  decodeOrFail url (responseBody resp)

getJson :: Manager -> String -> IO Value
getJson mgr url = do
  req0 <- parseRequest url
  resp <- httpLbs req0 mgr
  decodeOrFail url (responseBody resp)

getRaw :: Manager -> String -> IO Int
getRaw mgr url = do
  req0 <- parseRequest url
  resp <- httpLbs req0 mgr
  pure (statusCode (responseStatus resp))

decodeOrFail :: String -> BL.ByteString -> IO Value
decodeOrFail url bs = case Data.Aeson.eitherDecode bs of
  Left err -> assertFailure ("bad JSON from " ++ url ++ ": " ++ err)
  Right v  -> pure v

