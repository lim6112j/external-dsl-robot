{-# LANGUAGE OverloadedStrings #-}
-- | The vocabulary the agent is allowed to draw on.
--
-- Without a node list the model invents plausible-looking ids and the operator
-- only discovers the problem when a robot rejects the order. Supplying the real
-- map is the single biggest quality lever in the whole feature, so this module
-- exists to turn a VDA 5050 map file into exactly that.
module RobotDSL.Agent.Context
  ( Vocabulary(..)
  , emptyVocabulary
  , loadVocabulary
  , standardActions
  ) where

import Control.Exception (SomeException, try)
import Data.Aeson (Value(..))
import qualified Data.Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Vector as V
import qualified Data.Text.IO as TIO

-- | Names the generator may legitimately use.
data Vocabulary = Vocabulary
  { vocMapId :: !(Maybe Text)
  -- ^ The map the vocabulary belongs to.
  , vocNodes :: ![Text]
  -- ^ Node ids, in the order the map lists them.
  , vocEdges :: ![Text]
  -- ^ Edge ids where the map names them.
  } deriving (Eq, Show)

emptyVocabulary :: Vocabulary
emptyVocabulary = Vocabulary Nothing [] []

-- | Load a VDA 5050 map file.
--
-- Accepts the shape used by the fleet-control project:
-- @{"mapId": "...", "nodes": {"RK-AM": {"x":..,"y":..}}, "edges": ...}@.
-- Returns an empty vocabulary when no path is given, and a descriptive error
-- when the file cannot be read or does not parse.
loadVocabulary :: Maybe FilePath -> IO (Either String Vocabulary)
loadVocabulary Nothing = pure (Right emptyVocabulary)
loadVocabulary (Just path) = do
  r <- try (BS.readFile path) :: IO (Either SomeException BS.ByteString)
  case r of
    Left e   -> pure (Left ("cannot read map " ++ path ++ ": " ++ show e))
    Right bs -> case Data.Aeson.eitherDecodeStrict bs of
      Left err -> pure (Left ("cannot parse map " ++ path ++ ": " ++ err))
      Right v  -> pure (Right (vocabularyFrom v))

vocabularyFrom :: Value -> Vocabulary
vocabularyFrom (Object top) = Vocabulary
  { vocMapId = textField "mapId" top
  , vocNodes = objectKeys (KM.lookup "nodes" top)
  , vocEdges = edgeNames (KM.lookup "edges" top)
  }
vocabularyFrom _ = emptyVocabulary

textField :: Text -> KM.KeyMap Value -> Maybe Text
textField k o = case KM.lookup (Key.fromText k) o of
  Just (String s) -> Just s
  _               -> Nothing

-- | Nodes are keyed by id in the map format.
objectKeys :: Maybe Value -> [Text]
objectKeys (Just (Object o)) = map Key.toText (KM.keys o)
objectKeys _                 = []

-- | Edges appear either keyed by id or as an array carrying @edgeId@, so both
-- shapes are accepted.
edgeNames :: Maybe Value -> [Text]
edgeNames (Just (Object o)) = map Key.toText (KM.keys o)
edgeNames (Just (Array a))  = mapMaybe edgeIdOf (V.toList a)
edgeNames _                 = []

edgeIdOf :: Value -> Maybe Text
edgeIdOf (Object o) = case KM.lookup "edgeId" o of
  Just (String s) -> Just s
  _               -> Nothing
edgeIdOf _ = Nothing

-- | The action types the standard names, for the prompt.
--
-- v3.0.0 makes @actionType@ an open enum, so this is a starting vocabulary
-- rather than a closed set: a robot may support types beyond it.
standardActions :: [Text]
standardActions =
  [ "pick"
  , "drop"
  , "move"
  , "charge"
  , "initPosition"
  , "finePositioning"
  , "stateRequest"
  , "factsheetRequest"
  , "cancelOrder"
  , "startPause"
  , "stopPause"
  ]

_unusedTIO :: IO ()
_unusedTIO = TIO.putStr ""
