{-# LANGUAGE OverloadedStrings #-}
-- | The web interface.
--
-- A single wai 'Application' with a hand-rolled router: there are only a
-- handful of routes, and a framework would add a dependency whose API churns
-- more often than the routes change.
--
-- The server is deliberately thin. Every request that produces DSL goes
-- through "RobotDSL.Agent.Loop", which is where parsing and validation happen,
-- so a bad generation can never be saved or displayed as if it were valid.
module RobotDSL.Agent.Server
  ( AppState(..)
  , newAppState
  , app
  ) where

import Control.Exception (SomeException, try)
import Data.Aeson (Value(..), object, (.=))
import qualified Data.Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as BL
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (isSuffixOf)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory (doesFileExist)
import System.Exit (ExitCode(..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)

import Network.HTTP.Client (Manager)
import Network.HTTP.Types (Status, hContentType, status200,
                           status400, status404, status405, status500)
import Network.Wai (Application, Request, Response, ResponseReceived,
                    lazyRequestBody, pathInfo, requestMethod, responseLBS)

import RobotDSL.Agent.Client
import RobotDSL.Agent.Context
import RobotDSL.Agent.Loop
import RobotDSL.Agent.Prompt
import RobotDSL.Emit
import RobotDSL.Version

-- | What a route answers with.
type Respond = Response -> IO ResponseReceived

-- | Shared server state.
data AppState = AppState
  { asManager   :: !Manager
  -- ^ Connection manager, created once so TLS is not renegotiated per call.
  , asClient    :: !ClientConfig
  , asVocab     :: !Vocabulary
  , asEmitCtx   :: !EmitContext
  , asSessions  :: !(IORef [(Text, [ChatMessage])])
  -- ^ Conversation history per browser session, oldest first.
  , asWebDir    :: !FilePath
  , asSttPath   :: !FilePath
  }

newAppState :: Manager -> ClientConfig -> Vocabulary -> EmitContext -> FilePath
            -> FilePath -> IO AppState
newAppState mgr cli vocab emitCtx webDir sttPath =
  AppState mgr cli vocab emitCtx <$> newIORef [] <*> pure webDir <*> pure sttPath

app :: AppState -> Application
app st req respond =
  case (requestMethod req, pathInfo req) of
    ("GET", [])            -> serveStatic st respond "index.html"
    ("GET", ["app.js"])    -> serveStatic st respond "app.js"
    ("GET", ["style.css"]) -> serveStatic st respond "style.css"

    ("GET",  ["api", "context"]) -> handleContext st respond
    ("POST", ["api", "command"]) -> handleCommand st req respond
    ("POST", ["api", "listen"])  -> handleListen st req respond
    ("POST", ["api", "compile"]) -> handleCompile st req respond
    ("POST", ["api", "save"])    -> handleSave st req respond
    ("POST", ["api", "reset"])   -> handleReset st req respond

    (m, p)
      | m == "GET"  -> notFound respond p
      | m == "POST" -> notFound respond p
      | otherwise   -> respond (responseLBS status405
                        [(hContentType, "text/plain")] "method not allowed")

-- ---------------------------------------------------------------------------
-- Routes
-- ---------------------------------------------------------------------------

-- | The vocabulary and identity currently in use, so the UI can show the
-- operator what the generator is allowed to name.
--
-- @sttReady@ is passed in rather than derived here because it needs an IO
-- check, and reporting a helper as ready when it is not built would send the
-- operator down a dead end.
handleContext :: AppState -> Respond -> IO ResponseReceived
handleContext st respond = do
  ready <- doesFileExist (asSttPath st)
  json respond status200 (contextValue st ready)

contextValue :: AppState -> Bool -> Value
contextValue st sttReady = object
  [ "mapId"        .= vocMapId (asVocab st)
  , "nodes"        .= vocNodes (asVocab st)
  , "edges"        .= vocEdges (asVocab st)
  , "actions"      .= standardActions
  , "model"        .= ccModel (asClient st)
  , "manufacturer" .= ecManufacturer (asEmitCtx st)
  , "serialNumber" .= ecSerialNumber (asEmitCtx st)
  , "version"      .= protocolVersionText (ecVersion (asEmitCtx st))
  , "hasMap"       .= not (null (vocNodes (asVocab st)))
  , "sttReady"     .= sttReady
  ]

handleCommand :: AppState -> Request -> Respond -> IO ResponseReceived
handleCommand st req respond = do
  body <- lazyRequestBody req
  case Data.Aeson.eitherDecode body of
    Left err -> json respond status400
                  (failValue ("could not parse the request: " ++ err))
    Right v -> case field "text" v of
      Nothing -> json respond status400 (failValue "the request has no text field")
      Just txt -> do
        let sid = fromMaybe "default" (field "sessionId" v)
        history <- lookupSession st sid
        res <- runLoop (loopConfig st) history txt
        if not (lrOk res)
          then json respond status200 (object
            [ "ok"       .= False
            , "dsl"      .= lrDsl res
            , "attempts" .= lrAttempts res
            , "errors"   .= lrErrors res
            ])
          else do
            appendSession st sid
              [ ChatMessage RoleUser txt
              , ChatMessage RoleAssistant (lrDsl res)
              ]
            json respond status200 (object
              [ "ok"       .= True
              , "dsl"      .= lrDsl res
              , "messages" .= lrMessages res
              , "attempts" .= lrAttempts res
              , "usage"    .= lrUsage res
              ])

handleCompile :: AppState -> Request -> Respond -> IO ResponseReceived
handleCompile st req respond = do
  body <- lazyRequestBody req
  case Data.Aeson.eitherDecode body of
    Left err -> json respond status400
                  (failValue ("could not parse the request: " ++ err))
    Right v -> case field "dsl" v of
      Nothing -> json respond status400 (failValue "the request has no dsl field")
      Just dsl -> case finalize (loopConfig st) dsl of
        Left errs -> json respond status200 (object
          [ "ok"     .= False
          , "errors" .= errs
          ])
        Right msgs -> json respond status200 (object
          [ "ok"       .= True
          , "messages" .= msgs
          ])

handleSave :: AppState -> Request -> Respond -> IO ResponseReceived
handleSave st req respond = do
  body <- lazyRequestBody req
  case Data.Aeson.eitherDecode body of
    Left err -> json respond status400
                  (failValue ("could not parse the request: " ++ err))
    Right v -> case (field "dsl" v, field "path" v) of
      (Just dsl, Just pathText) ->
        case safePath pathText of
          Left err -> json respond status400 (failValue err)
          Right path -> case finalize (loopConfig st) dsl of
            -- Re-validate before touching the filesystem: the operator may
            -- have edited the DSL in the browser.
            Left errs -> json respond status200 (object
              [ "ok"     .= False
              , "errors" .= errs
              ])
            Right _ -> do
              r <- try (BL.writeFile path
                          (BL.fromStrict (TE.encodeUtf8 dsl) <> "\n"))
                     :: IO (Either SomeException ())
              case r of
                Left e -> json respond status500
                            (failValue ("could not write " ++ T.unpack pathText
                                          ++ ": " ++ show e))
                Right () -> json respond status200 (object
                  [ "ok"   .= True
                  , "path" .= pathText
                  ])
      _ -> json respond status400
             (failValue "the request needs both dsl and path")

handleReset :: AppState -> Request -> Respond -> IO ResponseReceived
handleReset st req respond = do
  body <- lazyRequestBody req
  case Data.Aeson.eitherDecode body of
    Left _ -> json respond status200 (object ["ok" .= True])
    Right v -> do
      dropSession st (fromMaybe "default" (field "sessionId" v))
      json respond status200 (object ["ok" .= True])

-- | Run the Swift helper, which transcribes one utterance and prints it.
--
-- The helper writes the recognised text to stdout and nothing else, so a
-- non-zero exit means the reason is on stderr.
handleListen :: AppState -> Request -> Respond -> IO ResponseReceived
handleListen st req respond = do
  _ <- lazyRequestBody req
  let path = asSttPath st
  ready <- doesFileExist path
  if not ready
    then json respond status200 (object
      [ "ok"    .= False
      , "error" .= T.pack ("the voice helper is not built. Run tools/stt/build.sh, "
                            <> "or type the request instead.")
      ])
    else do
      r <- try (readProcessWithExitCode path [] "")
             :: IO (Either SomeException (ExitCode, String, String))
      case r of
        Left e -> json respond status200 (object
          [ "ok"    .= False
          , "error" .= T.pack ("could not run the voice helper: " ++ show e)
          ])
        Right (code, out, err) -> case code of
          ExitSuccess ->
            let text = T.strip (T.pack out)
            in if T.null text
                 then json respond status200 (object
                   [ "ok"    .= False
                   , "error" .= T.pack "no speech was recognised. Try again, closer to the microphone."
                   ])
                 else json respond status200 (object
                   [ "ok"   .= True
                   , "text" .= text
                   ])
          ExitFailure n -> json respond status200 (object
            [ "ok"    .= False
            , "error" .= T.pack ("the voice helper failed (exit " ++ show n
                                   ++ "): " ++ err)
            ])

-- ---------------------------------------------------------------------------
-- Sessions
-- ---------------------------------------------------------------------------

lookupSession :: AppState -> Text -> IO [ChatMessage]
lookupSession st sid = do
  ss <- readIORef (asSessions st)
  pure (fromMaybe [] (lookup sid ss))

appendSession :: AppState -> Text -> [ChatMessage] -> IO ()
appendSession st sid turns = do
  ss <- readIORef (asSessions st)
  let prior = fromMaybe [] (lookup sid ss)
  writeIORef (asSessions st) (updateEntry sid (capTurns (prior ++ turns)) ss)

dropSession :: AppState -> Text -> IO ()
dropSession st sid = do
  ss <- readIORef (asSessions st)
  writeIORef (asSessions st) (filter ((/= sid) . fst) ss)

updateEntry :: Text -> [ChatMessage] -> [(Text, [ChatMessage])]
            -> [(Text, [ChatMessage])]
updateEntry sid v ss = case lookup sid ss of
  Nothing -> ss ++ [(sid, v)]
  Just _  -> map (\(k, old) -> if k == sid then (k, v) else (k, old)) ss

-- | Keep the last 10 user/assistant pairs so the context cannot grow without
-- bound and inflate the token cost.
capTurns :: [ChatMessage] -> [ChatMessage]
capTurns msgs
  | length msgs <= maxMessages = msgs
  | otherwise = drop (length msgs - maxMessages) msgs
  where
    maxMessages = 20

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

loopConfig :: AppState -> LoopConfig
loopConfig st = LoopConfig
  { lcManager = asManager st
  , lcClient  = asClient st
  , lcVocab   = asVocab st
  , lcEmit    = asEmitCtx st
  , lcMfr     = Just (ecManufacturer (asEmitCtx st))
  , lcSerial  = Just (ecSerialNumber (asEmitCtx st))
  }

field :: Text -> Value -> Maybe Text
field k (Object o) = case KM.lookup (Key.fromText k) o of
  Just (String s) -> Just s
  _               -> Nothing
field _ _ = Nothing

-- | Reject anything that is not a plain relative file name: no absolute paths,
-- no @..@ traversal, no home expansion.
safePath :: Text -> Either String FilePath
safePath t
  | T.null t                = Left "path is empty"
  | ".." `T.isInfixOf` t    = Left "path may not contain '..'"
  | "/" `T.isPrefixOf` t    = Left "path must be relative to the current directory"
  | "~" `T.isPrefixOf` t    = Left "path may not start with '~'"
  | otherwise               = Right (T.unpack t)

json :: Respond -> Status -> Value -> IO ResponseReceived
json respond s v =
  respond (responseLBS s [(hContentType, "application/json")]
                      (Data.Aeson.encode v))

failValue :: String -> Value
failValue msg = object ["ok" .= False, "error" .= T.pack msg]

notFound :: Respond -> [Text] -> IO ResponseReceived
notFound respond p = respond (responseLBS status404
  [(hContentType, "text/plain")]
  (BL.fromStrict (TE.encodeUtf8 ("no such route: " <> T.intercalate "/" p))))

-- | Serve a file from the web directory, guessing the content type from the
-- extension.
serveStatic :: AppState -> Respond -> FilePath -> IO ResponseReceived
serveStatic st respond name = do
  let path = asWebDir st </> name
  r <- try (BL.readFile path) :: IO (Either SomeException BL.ByteString)
  case r of
    Left _  -> respond (responseLBS status404 [(hContentType, "text/plain")] "not found")
    Right c -> respond (responseLBS status200 [(hContentType, contentTypeOf name)] c)

contentTypeOf :: FilePath -> ByteString
contentTypeOf name
  | ".html" `isSuffixOf` name = "text/html; charset=utf-8"
  | ".js"   `isSuffixOf` name = "text/javascript; charset=utf-8"
  | ".css"  `isSuffixOf` name = "text/css; charset=utf-8"
  | otherwise                 = "application/octet-stream"
