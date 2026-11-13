{-# LANGUAGE OverloadedStrings #-}
-- | Schema tests: compile every example, then check the emitted JSON against
-- the official VDA 5050 v3.0.0 schemas.
--
-- The negative cases exist to prove the validator actually rejects things; a
-- validator that always says "valid" would make the positive cases worthless.
module SchemaSpec (tests, schemaDir) where

import Control.Monad (forM, forM_)
import Data.Aeson (Value(..), object, (.=))
import qualified Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import qualified RobotDSL.Validate as V
import qualified Data.Vector as Vec
import Data.List (isInfixOf)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory (doesDirectoryExist)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

import RobotDSL.AST
import RobotDSL.Emit
import RobotDSL.Parser
import RobotDSL.Schema
import RobotDSL.Version

-- | Where the vendored schemas live, relative to the package root.
schemaDir :: FilePath
schemaDir = "schemas" </> "vda5050" </> "3.0.0"

tests :: IO [TestTree]
tests = do
  present <- doesDirectoryExist schemaDir
  if not present
    then pure
      [ testCase "schemas vendored"
          (assertFailure ("missing " ++ schemaDir))
      ]
    else do
      positive <- exampleTests
      pure
        [ testGroup "v3.0.0 schema validation"
            (positive ++ negativeTests)
        ]

negativeTests :: [TestTree]
negativeTests =
  [ testCase "a zone with too few vertices is rejected" $ do
      errs <- validateValue MkZoneSet badZone
      assertBool ("expected a minItems violation, got: " ++ show errs)
                 (any (isInfixOf "minItems") (map T.unpack (map veMessage errs)))
  , testCase "a missing required property is rejected" $ do
      errs <- validateValue MkOrder (object ["headerId" .= (1 :: Int)])
      assertBool ("expected a required-property violation, got: " ++ show errs)
                 (any (isInfixOf "required") (map T.unpack (map veMessage errs)))
  , testCase "an out-of-range number is rejected" $ do
      errs <- validateValue MkOrder (validOrderExceptTheta 9)
      assertBool ("expected a maximum violation, got: " ++ show errs)
                 (any (isInfixOf "maximum") (map T.unpack (map veMessage errs)))
  , testCase "an in-range number is accepted" $ do
      errs <- validateValue MkOrder (validOrderExceptTheta 3)
      assertEqual "clean" [] errs
  , testCase "an SPEED_LIMIT zone without maximumSpeed is rejected" $ do
      errs <- validateValue MkZoneSet (zoneSetWith
              [ object
                  [ "zoneId" .= ("s" :: Text)
                  , "zoneType" .= ("SPEED_LIMIT" :: Text)
                  , "vertices" .= triangle
                  ] ])
      assertBool ("expected a required violation, got: " ++ show errs)
                 (any (isInfixOf "maximumSpeed") (map T.unpack (map veMessage errs)))
  , testCase "an instant action with blockingType HARD is rejected" $ do
      errs <- validateValue MkInstantActions (object
                [ "headerId" .= (1 :: Int)
                , "timestamp" .= stamp
                , "version" .= ("3.0.0" :: Text)
                , "manufacturer" .= ("acme" :: Text)
                , "serialNumber" .= ("AMR-001" :: Text)
                , "actions" .= [ object
                    [ "actionId" .= ("a1" :: Text)
                    , "actionType" .= ("startPause" :: Text)
                    , "blockingType" .= ("HARD" :: Text) ] ]
                ])
      assertBool ("expected an enum violation, got: " ++ show errs)
                 (any (isInfixOf "not one of") (map T.unpack (map veMessage errs)))
  , testCase "an ill-formed timestamp is rejected" $ do
      errs <- validateValue MkOrder (object
                [ "headerId" .= (1 :: Int)
                , "timestamp" .= ("not-a-date" :: Text)
                , "version" .= ("3.0.0" :: Text)
                , "manufacturer" .= ("acme" :: Text)
                , "serialNumber" .= ("AMR-001" :: Text)
                , "orderId" .= ("o" :: Text)
                , "orderUpdateId" .= (0 :: Int)
                , "nodes" .= ([] :: [Value]), "edges" .= ([] :: [Value])
                ])
      assertBool ("expected a date-time violation, got: " ++ show errs)
                 (any (isInfixOf "ISO8601") (map T.unpack (map veMessage errs)))
  , testCase "local $ref resolution reaches the zone definition" $ do
      errs <- validateValue MkZoneSet badZone
      assertBool ("expected a minItems violation, got: " ++ show errs)
                 (not (null errs))
  ]

-- | An otherwise valid order whose single node carries the given theta.
validOrderExceptTheta :: Double -> Value
validOrderExceptTheta theta = object
  [ "headerId" .= (1 :: Int)
  , "timestamp" .= stamp
  , "version" .= ("3.0.0" :: Text)
  , "manufacturer" .= ("acme" :: Text)
  , "serialNumber" .= ("AMR-001" :: Text)
  , "orderId" .= ("o" :: Text)
  , "orderUpdateId" .= (0 :: Int)
  , "nodes" .= [ object
      [ "nodeId" .= ("n" :: Text)
      , "sequenceId" .= (0 :: Int)
      , "released" .= True
      , "nodePosition" .= object
          [ "x" .= (0 :: Double), "y" .= (0 :: Double)
          , "mapId" .= ("m" :: Text), "theta" .= theta ]
      , "actions" .= ([] :: [Value])
      ] ]
  , "edges" .= ([] :: [Value])
  ]

-- | A zoneSet wrapping the given zones.
zoneSetWith :: [Value] -> Value
zoneSetWith zones = object
  [ "headerId" .= (1 :: Int)
  , "timestamp" .= stamp
  , "version" .= ("3.0.0" :: Text)
  , "manufacturer" .= ("acme" :: Text)
  , "serialNumber" .= ("AMR-001" :: Text)
  , "zoneSet" .= object
      [ "mapId" .= ("m" :: Text)
      , "zoneSetId" .= ("z" :: Text)
      , "zones" .= zones
      ]
  ]

stamp :: Text
stamp = "2026-01-01T00:00:00.000Z"

triangle :: [Value]
triangle =
  [ object ["x" .= (0 :: Double), "y" .= (0 :: Double)]
  , object ["x" .= (1 :: Double), "y" .= (0 :: Double)]
  , object ["x" .= (1 :: Double), "y" .= (1 :: Double)]
  ]

exampleTests :: IO [TestTree]
exampleTests = forM exampleFiles $ \(name, path) ->
  pure $ testCase ("example " ++ name) $ do
    src <- TIO.readFile path
    case parseProgram path src of
      Left (ParseError msg) -> assertFailure (T.unpack msg)
      Right prog -> do
        assertEqual ("semantic issues in " ++ name) [] (V.validate prog)
        forM_ (emit prog buildCtx) $ \m -> do
          schema <- loadSchemaFor (emKind m)
          case schema of
            Left err -> assertFailure (show err)
            Right s -> assertEqual ("schema violations in " ++ name) []
                         (validate s (emValue m))

buildCtx :: EmitContext
buildCtx = EmitContext
  { ecManufacturer = "acme"
  , ecSerialNumber = "AMR-001"
  , ecHeaderId = 1
  , ecTimestamp = "2026-11-13T12:00:00.000Z"
  , ecVersion = protocolVersion
  , ecMapId = Just "plant-b"
  }

exampleFiles :: [(String, FilePath)]
exampleFiles =
  [ ("palletizing", "examples" </> "palletizing.robot")
  , ("control", "examples" </> "control.robot")
  , ("floor1-zones", "examples" </> "floor1-zones.robot")
  ]

loadSchemaFor :: MessageKind -> IO (Either SchemaError Value)
loadSchemaFor k = loadSchema (schemaDir </> fileName k)
  where
    fileName MkOrder          = "order.schema"
    fileName MkInstantActions = "instantActions.schema"
    fileName MkZoneSet        = "zoneSet.schema"

validateValue :: MessageKind -> Value -> IO [ValidationError]
validateValue k v = do
  r <- loadSchemaFor k
  case r of
    Left err -> assertFailure (show err)
    Right s  -> pure (validate s v)

-- | A zoneSet whose only zone has two vertices, which the schema forbids.
badZone :: Value
badZone = zoneSetWith
  [ object
      [ "zoneId" .= ("s" :: Text)
      , "zoneType" .= ("BLOCKED" :: Text)
      , "vertices" .= [ object ["x" .= (0 :: Double), "y" .= (0 :: Double)]
                      , object ["x" .= (1 :: Double), "y" .= (0 :: Double)] ]
      ]
  ]
