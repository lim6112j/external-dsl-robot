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

import Data.Text (Text)
import qualified Data.Text as T
import System.Directory (doesFileExist, removeFile)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

import Network.HTTP.Client (Manager, defaultManagerSettings, httpLbs,
                            newManager, parseRequest, responseBody,
                            responseStatus)
import Network.HTTP.Simple (setRequestBodyLBS, setRequestHeader,
                            setRequestMethod)
import Network.HTTP.Types (hContentType, status200, statusCode)
import Network.Wai (Application, lazyRequestBody, responseLBS)
import Network.Wai.Handler.Warp (Port, testWithApplication)

import RobotDSL.Agent.Client
import RobotDSL.Agent.Context
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
              p = systemPrompt vocab
          assertBool "mapId present" (T.isInfixOf "plant-b" p)
          assertBool "node RK-AM present" (T.isInfixOf "RK-AM" p)
          assertBool "node CHG-01 present" (T.isInfixOf "CHG-01" p)
      , testCase "system prompt carries the action catalogue" $ do
          let p = systemPrompt emptyVocabulary
          forM_ standardActions $ \a ->
            assertBool ("action missing: " <> T.unpack a) (T.isInfixOf a p)
      , testCase "system prompt names every zone type" $ do
          let p = systemPrompt emptyVocabulary
          forM_ zoneTypes $ \z ->
            assertBool ("zone type missing: " <> T.unpack z) (T.isInfixOf z p)
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
      [ testCase "GET /api/context reports the vocabulary" $ withServer $ \port mgr -> do
          v <- getJson mgr (baseUrl port <> "/api/context")
          assertEqual "hasMap" (Just True) (boolField v "hasMap")
          assertBool "nodes listed" (not (null (arrField v "nodes")))
      , testCase "POST /api/command returns generated DSL" $ withServer $ \port mgr -> do
          v <- postJson mgr (baseUrl port <> "/api/command")
                 (object ["text" .= ("랙에서 컨베이어로" :: Text)
                         , "sessionId" .= ("t1" :: Text)])
          assertEqual "ok" (Just True) (boolField v "ok")
          assertBool "dsl present" (not (T.null (strField v "dsl")))
          assertBool "messages present" (not (null (arrField v "messages")))
      , testCase "POST /api/command rejects a body with no text" $ withServer $ \port mgr -> do
          v <- postJson mgr (baseUrl port <> "/api/command") (object [])
          assertEqual "not ok" (Just False) (boolField v "ok")
          assertBool "error given" (not (T.null (strField v "error")))
      , testCase "POST /api/compile recompiles edited DSL" $ withServer $ \port mgr -> do
          v <- postJson mgr (baseUrl port <> "/api/compile") (object ["dsl" .= goodDsl])
          assertEqual "ok" (Just True) (boolField v "ok")
          assertBool "messages present" (not (null (arrField v "messages")))
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

strField :: Value -> Text -> Text
strField v k = case objLookup k v of
  Just (String s) -> s
  other           -> error ("no string field " ++ T.unpack k ++ ": " ++ show other)

boolField :: Value -> Text -> Maybe Bool
boolField v k = case objLookup k v of
  Just (Bool b) -> Just b
  _             -> Nothing

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
  , lcVocab   = Vocabulary (Just "plant-b") ["RK-AM", "CHG-01"] []
  , lcEmit    = EmitContext "acme" "AMR-001" 1 "2026-01-01T00:00:00.000Z"
                           protocolVersion (Just "plant-b")
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
serverApp mgr client = do
  let vocab = Vocabulary (Just "plant-b") ["RK-AM", "CHG-01"] []
      emitCtx = EmitContext "acme" "AMR-001" 1 "2026-01-01T00:00:00.000Z"
                            protocolVersion (Just "plant-b")
  st <- newAppState mgr client vocab emitCtx "web" ""
  pure (app st)

baseUrl :: Port -> String
baseUrl port = "http://127.0.0.1:" ++ show port

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

