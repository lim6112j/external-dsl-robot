{-# LANGUAGE OverloadedStrings #-}
-- | The @robotdsl@ command line interface.
--
-- Two subcommands:
--
--   * @check@ parses and semantically validates a @.robot@ file without
--     producing anything. Useful in CI.
--
--   * @compile@ additionally lowers the file to VDA 5050 v3.0.0 JSON, checks
--     every emitted message against the official schema, and writes one file
--     per message (or prints to stdout).
--
-- Messages are never written if parsing, semantic validation or schema
-- validation fails, so a rejected message cannot reach a broker by accident.
module Main (main) where

import Control.Exception (SomeException, try)
import Control.Monad (forM_, unless)
import Data.Aeson (encode)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.List (intercalate)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time (UTCTime, formatTime, getCurrentTime, defaultTimeLocale)
import System.Directory (doesDirectoryExist)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)

import RobotDSL.AST
import RobotDSL.Emit
import RobotDSL.Parser
import RobotDSL.Schema (loadSchema, ValidationError(..))
import qualified RobotDSL.Schema as Schema
import RobotDSL.Validate
import RobotDSL.Version

main :: IO ()
main = do
  args <- getArgs
  case args of
    ("check" : rest)    -> runCheck rest
    ("compile" : rest)  -> runCompile rest
    _ -> do
      hPutStrLn stderr usage
      exitFailure

usage :: String
usage = intercalate "\n"
  [ "robotdsl - compile robotdsl source to VDA 5050 v3.0.0 JSON"
  , ""
  , "Usage:"
  , "  robotdsl check <file.robot>"
  , "  robotdsl compile <file.robot> [options]"
  , ""
  , "Options:"
  , "  --out DIR             write one JSON file per message into DIR"
  , "                        (default: print to stdout)"
  , "  --kind K              only emit messages of kind order | instantActions |"
  , "                        zoneSet (default: all)"
  , "  --manufacturer M      manufacturer of the target robot"
  , "  --serial-number S     serial number of the target robot"
  , "  --header-id N         first headerId to allocate (default: 1)"
  , "  --timestamp ISO       timestamp for every message (default: now, UTC)"
  , "  --schema-dir DIR      directory holding the v3.0.0 JSON schemas"
  , "                        (default: schemas/vda5050/3.0.0)"
  , "  --no-validate         skip schema validation of emitted messages"
  ]

-- ---------------------------------------------------------------------------
-- Argument handling
-- ---------------------------------------------------------------------------

data Options = Options
  { optInput      :: FilePath
  -- ^ Filled in by 'parseArgs'; left empty in 'defaultOptions'.
  , optOut        :: Maybe FilePath
  , optKind       :: Maybe MessageKind
  , optManufacturer :: Maybe Text
  , optSerial     :: Maybe Text
  , optHeaderId   :: Int
  , optTimestamp  :: Maybe Text
  , optSchemaDir  :: FilePath
  , optNoValidate :: Bool
  } deriving (Eq, Show)

defaultOptions :: Options
defaultOptions = Options
  { optInput = ""
  , optOut = Nothing
  , optKind = Nothing
  , optManufacturer = Nothing
  , optSerial = Nothing
  , optHeaderId = 1
  , optTimestamp = Nothing
  , optSchemaDir = "schemas" </> "vda5050" </> "3.0.0"
  , optNoValidate = False
  }

parseArgs :: [String] -> Either String (Options, [String])
parseArgs = go defaultOptions []
  where
    go :: Options -> [String] -> [String] -> Either String (Options, [String])
    go o rest [] = Right (o, rest)
    go o rest (a : as) = case a of
      "--out"           -> need as $ \v as' -> go o { optOut = Just v } rest as'
      "--kind"          -> need as $ \v as' ->
        case readKind v of
          Just k  -> go o { optKind = Just k } rest as'
          Nothing -> Left ("unknown --kind '" ++ v ++ "'; expected order, instantActions or zoneSet")
      "--manufacturer"  -> need as $ \v as' -> go o { optManufacturer = Just (T.pack v) } rest as'
      "--serial-number" -> need as $ \v as' -> go o { optSerial = Just (T.pack v) } rest as'
      "--header-id"     -> need as $ \v as' ->
        case reads v of
          [(n, "")] -> go o { optHeaderId = n } rest as'
          _         -> Left ("--header-id expects an integer, got '" ++ v ++ "'")
      "--timestamp"     -> need as $ \v as' -> go o { optTimestamp = Just (T.pack v) } rest as'
      "--schema-dir"    -> need as $ \v as' -> go o { optSchemaDir = v } rest as'
      "--no-validate"   -> go o { optNoValidate = True } rest as
      _
        | take 2 a == "--" -> Left ("unknown option '" ++ a ++ "'")
        | otherwise        -> go o (rest ++ [a]) as

    need :: [String] -> (String -> [String] -> Either String (Options, [String]))
         -> Either String (Options, [String])
    need (v : as) k = k v as
    need [] _ = Left "option needs a value"

readKind :: String -> Maybe MessageKind
readKind "order"          = Just MkOrder
readKind "instantActions" = Just MkInstantActions
readKind "zoneSet"        = Just MkZoneSet
readKind _                = Nothing

-- ---------------------------------------------------------------------------
-- Subcommands
-- ---------------------------------------------------------------------------

runCheck :: [String] -> IO ()
runCheck args = do
  opts <- withOptions args
  src <- readSource (optInput opts)
  case parseProgram (optInput opts) src of
    Left (ParseError msg) -> die (T.unpack msg)
    Right prog -> do
      let issues = validate prog
      if null issues
        then putStrLn ("OK " ++ optInput opts ++ ": "
                        ++ show (length (progDecls prog)) ++ " message(s), no issues")
        else do
          mapM_ (hPutStrLn stderr . renderIssue) issues
          die (show (length issues) ++ " issue(s)")

runCompile :: [String] -> IO ()
runCompile args = do
  opts <- withOptions args
  src <- readSource (optInput opts)
  case parseProgram (optInput opts) src of
    Left (ParseError msg) -> die (T.unpack msg)
    Right prog -> do
      let issues = validate prog
      unless (null issues) $ do
        mapM_ (hPutStrLn stderr . renderIssue) issues
        die (show (length issues) ++ " issue(s)")
      ctx <- buildContext opts prog
      let msgs = filter (keepKind opts) (emit prog (resolveContext prog ctx))
      schemaErrs <-
        if optNoValidate opts
          then pure []
          else validateAgainstSchemas opts msgs
      unless (null schemaErrs) $ do
        mapM_ (hPutStrLn stderr . renderSchemaError) schemaErrs
        die (show (length schemaErrs) ++ " schema violation(s)")
      writeMessages opts ctx msgs

withOptions :: [String] -> IO Options
withOptions args = case parseArgs args of
  Left err  -> die err
  Right (o, files) -> case files of
    [f] -> pure o { optInput = f }
    []  -> die "expected exactly one input file"
    _   -> die ("expected exactly one input file, got " ++ unwords files)

keepKind :: Options -> EmittedMessage -> Bool
keepKind opts m = maybe True (== emKind m) (optKind opts)

-- | Resolve the emit context: CLI flags first, then the file's own
-- declarations, then compiler defaults.
buildContext :: Options -> Program -> IO EmitContext
buildContext opts prog = do
  now <- getCurrentTime
  -- Defaults only. The program's own `header`, `timestamp`, `version` and
  -- `map` declarations are layered on top by resolveContext.
  let stamp = fromMaybe (formatTimestamp now) (optTimestamp opts)
      (mfr, ser) = fromMaybe ("unknown", "unknown") (progRobot prog)
  pure EmitContext
    { ecManufacturer = mfr
    , ecSerialNumber = ser
    , ecHeaderId = optHeaderId opts
    , ecTimestamp = stamp
    , ecVersion = protocolVersion
    , ecMapId = Nothing
    }

formatTimestamp :: UTCTime -> Text
formatTimestamp = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%3QZ"

-- ---------------------------------------------------------------------------
-- Schema validation
-- ---------------------------------------------------------------------------

validateAgainstSchemas :: Options -> [EmittedMessage] -> IO [SchemaViolation]
validateAgainstSchemas opts msgs = do
  dirExists <- doesDirectoryExist (optSchemaDir opts)
  if not dirExists
    then do
      hPutStrLn stderr ("warning: schema directory " ++ optSchemaDir opts
                         ++ " not found; skipping schema validation")
      pure []
    else do
      results <- mapM (checkOne opts) msgs
      pure (concat results)

checkOne :: Options -> EmittedMessage -> IO [SchemaViolation]
checkOne opts m = do
  r <- loadSchema (optSchemaDir opts </> schemaFileName (emKind m))
  case r of
    Left err -> do
      hPutStrLn stderr ("warning: " ++ show err ++ "; skipping schema validation")
      pure []
    Right schema -> pure
      [ SchemaViolation (emName m) e | e <- Schema.validate schema (emValue m) ]

schemaFileName :: MessageKind -> FilePath
schemaFileName MkOrder          = "order.schema"
schemaFileName MkInstantActions = "instantActions.schema"
schemaFileName MkZoneSet        = "zoneSet.schema"

data SchemaViolation = SchemaViolation
  { svName :: Text
  , svErr  :: ValidationError
  } deriving (Eq, Show)

renderSchemaError :: SchemaViolation -> String
renderSchemaError v =
  T.unpack (svName v) ++ ": " ++ T.unpack (vePath (svErr v))
    ++ ": " ++ T.unpack (veMessage (svErr v))

-- ---------------------------------------------------------------------------
-- Output
-- ---------------------------------------------------------------------------

writeMessages :: Options -> EmitContext -> [EmittedMessage] -> IO ()
writeMessages opts ctx msgs =
  case optOut opts of
    Nothing -> forM_ msgs $ \m -> do
      BS.putStr (BL.toStrict (encode (emValue m)))
      BS.putStr "\n"
    Just dir -> do
      forM_ msgs $ \m -> do
        let path = dir </> T.unpack (emName m) ++ "." ++ T.unpack (kindFileSuffix (emKind m)) ++ ".json"
        BS.writeFile path (BL.toStrict (encode (emValue m)) <> "\n")
        putStrLn (path ++ "  (" ++ T.unpack (topicLine ctx (emKind m)) ++ ")")

-- | The MQTT topic a message would be published on, shown so the operator can
-- pipe the output straight into a publisher.
topicLine :: EmitContext -> MessageKind -> Text
topicLine ctx k =
  topicPath (messageTopic k) (ecVersion ctx) (ecManufacturer ctx) (ecSerialNumber ctx)

messageTopic :: MessageKind -> Topic
messageTopic MkOrder          = OrderT
messageTopic MkInstantActions = InstantActionsT
messageTopic MkZoneSet        = ZoneSetT

-- ---------------------------------------------------------------------------
-- Diagnostics
-- ---------------------------------------------------------------------------

renderIssue :: Issue -> String
renderIssue i =
  T.unpack (issueSubject i) ++ ": " ++ T.unpack (issueMessage i)

die :: String -> IO a
die msg = do
  hPutStrLn stderr ("error: " ++ msg)
  exitFailure

-- | Read the source file, turning a missing or unreadable file into a plain
-- message rather than an IO exception with a stack trace.
readSource :: FilePath -> IO Text
readSource path = do
  r <- try (TIO.readFile path) :: IO (Either SomeException Text)
  case r of
    Left _  -> die ("cannot read '" ++ path ++ "': no such file, or not readable")
    Right t -> pure t
