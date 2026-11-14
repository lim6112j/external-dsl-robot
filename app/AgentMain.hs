{-# LANGUAGE OverloadedStrings #-}
-- | The @robotdsl-agent@ entry point.
--
-- Thin on purpose: it parses flags, assembles the pieces from the library, and
-- runs warp. All the interesting behaviour lives in "RobotDSL.Agent.Server"
-- and "RobotDSL.Agent.Loop".
module Main (main) where

import Control.Monad (when)
import Data.Maybe (fromMaybe)
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import System.Directory (doesFileExist)
import System.Environment (getArgs, lookupEnv)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)

import Network.HTTP.Client (ManagerSettings(..), newManager, responseTimeoutMicro)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.Wai.Handler.Warp (defaultSettings, runSettings, setFdCacheDuration,
                                 setHost, setPort)

import RobotDSL.Agent.Client
import RobotDSL.Agent.Context
import RobotDSL.Agent.Fleet
import RobotDSL.Agent.Server
import RobotDSL.Emit
import RobotDSL.Version

main :: IO ()
main = do
  args <- getArgs
  opts <- case parseArgs args of
    Left err -> die err
    Right o  -> pure o
  run opts

data Options = Options
  { optPort     :: !Int
  , optHost     :: !String
  , optModel    :: !Text
  , optBaseUrl  :: !Text
  , optApiKey   :: !(Maybe Text)
  , optMaxTok   :: !Int
  , optMap      :: !(Maybe FilePath)
  , optFleet    :: !(Maybe Text)
  -- ^ Base URL of the fleet-control gateway, e.g. @http://127.0.0.1:8080@.
  -- When given, the map and the robot list are read from it live.
  , optGwToken  :: !(Maybe Text)
  -- ^ Bearer token for the gateway, when it was started with @--api-token@.
  , optStt      :: !FilePath
  , optWebDir   :: !FilePath
  , optMfr      :: !Text
  , optSerial   :: !Text
  }

defaultOptions :: Options
defaultOptions = Options
  { optPort    = 8790
  , optHost    = "127.0.0.1"
  , optModel   = "openai/gpt-4.1-mini"
  , optBaseUrl = "https://openrouter.ai/api/v1"
  , optApiKey  = Nothing
  , optMaxTok  = 2048
  , optMap     = Nothing
  , optFleet   = Nothing
  , optGwToken = Nothing
  , optStt     = "tools" </> "stt" </> "stt"
  , optWebDir  = "web"
  , optMfr     = "acme"
  , optSerial  = "AMR-001"
  }

run :: Options -> IO ()
run opts = do
  key <- case optApiKey opts of
    Just k  -> pure k
    Nothing -> do
      env <- lookupEnv "OPENROUTER_API_KEY"
      case env of
        Just k  -> pure (T.pack k)
        Nothing -> die "no API key: pass --api-key or set OPENROUTER_API_KEY"

  -- The manager is created first because resolving the map may need it: with
  -- --fleet the map is fetched from the gateway instead of read from a file.
  mgr <- newManager (tlsManagerSettings
                       { managerResponseTimeout = responseTimeoutMicro (120 * 1000000) })

  gwToken <- case optGwToken opts of
    Just t  -> pure (Just t)
    Nothing -> fmap T.pack <$> lookupEnv "ROBOT_GATEWAY_TOKEN"

  let fleet = case optFleet opts of
        Nothing -> Nothing
        Just url -> Just (FleetConfig url gwToken)

  vocabR <- case fleet of
    Nothing -> loadVocabulary (optMap opts)
    Just fc -> fmap (fmap vocabularyFrom) (fetchMap mgr fc)
  vocab <- case vocabR of
    Left err -> die err
    Right v  -> pure v

  now <- getCurrentTime
  let stamp = T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%3QZ" now)
      mapId = fromMaybe "" (vocMapId vocab)
      ctx = EmitContext
              { ecManufacturer = optMfr opts
              , ecSerialNumber = optSerial opts
              , ecHeaderId     = 1
              , ecTimestamp    = stamp
              , ecVersion      = protocolVersion
              , ecMapId        = if T.null mapId then Nothing else Just mapId
              }

  when (null (vocNodes vocab)) $
    hPutStrLn stderr "note: no map supplied, so the generator has no node ids to work from."
  when (optHost opts /= "127.0.0.1") $
    hPutStrLn stderr "warning: binding to a non-loopback host exposes the agent without authentication."

  let client = ClientConfig
        { ccApiKey    = key
        , ccModel     = optModel opts
        , ccBaseUrl   = optBaseUrl opts
        , ccMaxTokens = optMaxTok opts
        }

  st <- newAppState mgr client vocab fleet ctx (optWebDir opts) (optStt opts)
  ready <- doesFileExist (optStt opts)

  hPutStrLn stderr $ "robotdsl-agent listening on http://" ++ optHost opts
                      ++ ":" ++ show (optPort opts)
  hPutStrLn stderr $ "  model:      " ++ T.unpack (ccModel client)
  hPutStrLn stderr $ "  map:        " ++ maybe "(none)" T.unpack (vocMapId vocab)
                      ++ " (" ++ show (length (vocNodes vocab)) ++ " nodes)"
  hPutStrLn stderr $ "  voice:      " ++ (if ready
                                            then "ready"
                                            else "not built (run tools/stt/build.sh)")

  runSettings (setFdCacheDuration 3600
               $ setHost (fromString (optHost opts))
               $ setPort (optPort opts)
               $ defaultSettings)
              (app st)

-- ---------------------------------------------------------------------------
-- Flag parsing
-- ---------------------------------------------------------------------------

parseArgs :: [String] -> Either String Options
parseArgs = go defaultOptions
  where
    -- The signature matters: without it GHC cannot tell that `o { field = v }`
    -- is a record update rather than a separate argument.
    go :: Options -> [String] -> Either String Options
    go o [] = Right o
    go o (a : as) = case a of
      "--port"          -> need as $ \v as' -> rd "port" v $ \n -> go (o { optPort = n }) as'
      "--host"          -> need as $ \v as' -> go (o { optHost = v }) as'
      "--model"         -> need as $ \v as' -> go (o { optModel = T.pack v }) as'
      "--base-url"      -> need as $ \v as' -> go (o { optBaseUrl = T.pack v }) as'
      "--api-key"       -> need as $ \v as' -> go (o { optApiKey = Just (T.pack v) }) as'
      "--max-tokens"    -> need as $ \v as' -> rd "max-tokens" v $ \n -> go (o { optMaxTok = n }) as'
      "--map"           -> need as $ \v as' -> go (o { optMap = Just v }) as'
      "--fleet"         -> need as $ \v as' -> go (o { optFleet = Just (T.pack v) }) as'
      "--gateway-token" -> need as $ \v as' -> go (o { optGwToken = Just (T.pack v) }) as'
      "--stt"           -> need as $ \v as' -> go (o { optStt = v }) as'
      "--web-dir"       -> need as $ \v as' -> go (o { optWebDir = v }) as'
      "--manufacturer"  -> need as $ \v as' -> go (o { optMfr = T.pack v }) as'
      "--serial-number" -> need as $ \v as' -> go (o { optSerial = T.pack v }) as'
      "--help"          -> Left usage
      _
        | take 2 a == "--" -> Left ("unknown option '" ++ a ++ "'")
        | otherwise        -> Left ("unexpected argument '" ++ a ++ "'")

    need (v : as) k = k v as
    need [] _ = Left "option needs a value"

    -- The continuation takes just the parsed number; the remaining arguments
    -- are already in scope where the flag is matched.
    rd :: String -> String -> (Int -> Either String Options)
       -> Either String Options
    rd name v k = case reads v of
      [(n, "")] -> k n
      _         -> Left ("--" ++ name ++ " expects an integer, got '" ++ v ++ "'")

usage :: String
usage = unlines
  [ "robotdsl-agent - chat or voice to robotdsl, compiling to VDA 5050 v3.0.0"
  , ""
  , "Usage: robotdsl-agent [options]"
  , ""
  , "  --port N             port to listen on (default 8790)"
  , "  --host H             address to bind (default 127.0.0.1)"
  , "  --model M            OpenRouter model id"
  , "                        (default openai/gpt-4.1-mini)"
  , "  --base-url U         OpenAI-compatible base URL"
  , "                        (default https://openrouter.ai/api/v1)"
  , "  --api-key K          OpenRouter key (default: $OPENROUTER_API_KEY)"
  , "  --max-tokens N       per-call cap (default 2048)"
  , "  --map PATH           VDA 5050 map JSON, giving the generator the real"
  , "                        node ids. Use when there is no gateway."
  , "  --fleet URL          base URL of the fleet-control gateway, e.g."
  , "                        http://127.0.0.1:8080. Reads the map and the"
  , "                        robot list live, which beats --map."
  , "  --gateway-token K    bearer token for the gateway (default:"
  , "                        $ROBOT_GATEWAY_TOKEN)"
  , "  --stt PATH           voice helper binary (default tools/stt/stt)"
  , "  --web-dir DIR        where index.html lives (default web)"
  , "  --manufacturer M     manufacturer for emitted messages"
  , "  --serial-number S    serial number for emitted messages"
  ]

die :: String -> IO a
die msg = do
  hPutStrLn stderr ("error: " ++ msg)
  exitFailure
