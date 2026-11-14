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
  , vocabularyFrom
  , applyScope
  , standardActions
  ) where

import Control.Exception (SomeException, try)
import Data.Aeson (Value(..))
import qualified Data.Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import Data.Maybe (mapMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Vector as V

-- | Names the generator may legitimately use.
data Vocabulary = Vocabulary
  { vocMapId :: !(Maybe Text)
  -- ^ The map the vocabulary belongs to.
  , vocNodes :: ![Text]
  -- ^ Node ids, in the order the map lists them.
  , vocEdges :: ![Text]
  -- ^ Edge ids where the map names them.
  , vocEdgePairs :: ![(Text, Text)]
  -- ^ Traversable hops (from, to). The maps in use name no edge ids, so this
  -- is what constrains @go to "<A>" ... "<B>"@.
  , vocScope :: !(Maybe [Text])
  -- ^ The operator's node subset. 'Nothing' means the whole map.
  , vocPositions :: ![(Text, (Double, Double))]
  -- ^ Node coordinates, so a route can be drawn without re-reading the map.
  -- A pair, not a triple: 'Data.List.lookup' splits the key off, and what is
  -- left has to be the coordinate pair the preview wants. A 3-tuple would be a
  -- different type constructor and not match at all.
  } deriving (Eq, Show)

emptyVocabulary :: Vocabulary
emptyVocabulary = Vocabulary Nothing [] [] [] Nothing []

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
  , vocEdgePairs = edgePairs (KM.lookup "edges" top)
  , vocScope = Nothing
  , vocPositions = nodePositions (KM.lookup "nodes" top)
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

-- | Traversable hops from the map's edge array.
--
-- The shape is @[{"from": "A", "to": "B", "length": ..}, ...]@. An object keyed
-- by edge id is not supported: no map in use has that shape, and guessing the
-- endpoints would be worse than reporting none.
edgePairs :: Maybe Value -> [(Text, Text)]
edgePairs (Just (Array a)) = mapMaybe hopOf (V.toList a)
edgePairs _                = []

hopOf :: Value -> Maybe (Text, Text)
hopOf (Object o) = (,) <$> textField "from" o <*> textField "to" o
hopOf _          = Nothing

-- | Narrow a vocabulary to the nodes the operator picked.
--
-- Edges keep only the hops whose both endpoints fall inside the subset, which
-- is what "this mission stays in the rack area" means. Passing 'Nothing'
-- returns the vocabulary unchanged. Node ids the map does not know are simply
-- dropped, so a stale selection degrades to a smaller scope rather than an
-- error the operator cannot act on.
applyScope :: Maybe [Text] -> Vocabulary -> Vocabulary
applyScope Nothing voc = voc
applyScope (Just picked) voc = voc
  { vocNodes = filter (`Set.member` keep) (vocNodes voc)
  , vocEdgePairs = filter inside (vocEdgePairs voc)
  , vocScope = Just picked
  }
  where
    keep = Set.fromList picked
    inside (a, b) = a `Set.member` keep && b `Set.member` keep

-- | Node coordinates from the map.
--
-- The shape is @{"RK-AM": {"x": 1.0, "y": 2.0, "theta": 0.0}}@. A node whose
-- x or y is missing or not a number is dropped rather than reported at (0, 0),
-- which would silently draw it into a corner of the map.
nodePositions :: Maybe Value -> [(Text, (Double, Double))]
nodePositions (Just (Object o)) =
  [ (Key.toText k, (x, y))
  | (k, Object v) <- KM.toList o
  , Just x <- [numberField "x" v]
  , Just y <- [numberField "y" v]
  ]
nodePositions _ = []

numberField :: Text -> KM.KeyMap Value -> Maybe Double
numberField k o = case KM.lookup (Key.fromText k) o of
  Just (Number n) -> Just (realToFrac n)
  _               -> Nothing

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
