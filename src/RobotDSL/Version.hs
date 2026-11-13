{-# LANGUAGE OverloadedStrings #-}
-- | The VDA 5050 protocol version this compiler targets, and the MQTT topic
-- layout that goes with it.
--
-- The version is pinned here rather than sprinkled through the emitter so
-- there is exactly one place to change when moving to a new release of the
-- standard. Everything downstream reads 'protocolVersion'.
module RobotDSL.Version
  ( ProtocolVersion(..)
  , protocolVersion
  , protocolVersionText
  , Topic(..)
  , subtopic
  , topicPath
  ) where

import Data.Text (Text)
import qualified Data.Text as T

-- | A @[Major].[Minor].[Patch]@ protocol version.
data ProtocolVersion = ProtocolVersion
  { pvMajor :: !Int
  , pvMinor :: !Int
  , pvPatch :: !Int
  } deriving (Eq, Ord, Show)

-- | The version of VDA 5050 this compiler emits.
--
-- v3.0.0 is pinned deliberately: it is the first release that carries the
-- zoneSet message and the zoneType vocabulary (BLOCKED, SPEED_LIMIT, ACTION,
-- PRIORITY, PENALTY, DIRECTED, BIDIRECTED, ...), which this DSL exposes.
protocolVersion :: ProtocolVersion
protocolVersion = ProtocolVersion 3 0 0

-- | Render as the wire format the standard expects in the @version@ field.
protocolVersionText :: ProtocolVersion -> Text
protocolVersionText (ProtocolVersion a b c) =
  T.pack (show a) <> "." <> T.pack (show b) <> "." <> T.pack (show c)

-- | The MQTT subtopics a fleet manager and a robot exchange.
data Topic
  = OrderT
  | InstantActionsT
  | ZoneSetT
  | StateT
  | VisualizationT
  | ConnectionT
  | FactsheetT
  | ResponsesT
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The subtopic segment, e.g. @\/order@.
subtopic :: Topic -> Text
subtopic t = case t of
  OrderT           -> "order"
  InstantActionsT  -> "instantActions"
  ZoneSetT         -> "zoneSet"
  StateT           -> "state"
  VisualizationT   -> "visualization"
  ConnectionT      -> "connection"
  FactsheetT       -> "factsheet"
  ResponsesT       -> "responses"

-- | Full topic path for a robot, e.g.
-- @vda5050\/v3\/acme\/AMR-001\/order@.
topicPath :: Topic -> ProtocolVersion -> Text -> Text -> Text
topicPath t v manufacturer serialNumber =
  "vda5050/v" <> T.pack (show (pvMajor v))
  <> "/" <> manufacturer
  <> "/" <> serialNumber
  <> "/" <> subtopic t