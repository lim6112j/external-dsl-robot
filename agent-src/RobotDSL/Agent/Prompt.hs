{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
-- | Prompt construction and output cleaning.
--
-- The prompt is the only place the model is told what the language is, so it is
-- written as a reference rather than a hint: every keyword below is one the
-- parser actually accepts, and every semantic trap the standard has is stated
-- explicitly. When the two drift apart the parser wins, because its errors are
-- fed back to the model on retry.
module RobotDSL.Agent.Prompt
  ( Role(..)
  , ChatMessage(..)
  , systemPrompt
  , userMessage
  , cleanOutput
  , headerKeywords
  , robotSection
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import RobotDSL.Agent.Context (Vocabulary(..), standardActions)
import RobotDSL.Agent.Fleet (RobotRef(..))

-- | A conversation turn.
data Role = RoleSystem | RoleUser | RoleAssistant
  deriving (Eq, Ord, Show, Enum, Bounded)

data ChatMessage = ChatMessage
  { cmRole    :: !Role
  , cmContent :: !Text
  } deriving (Eq, Show)

-- | The system prompt: role, output rule, grammar, vocabulary, few-shot.
--
-- The order matters. The output rule comes first because the single most common
-- failure is a model that wraps its answer in a markdown fence or prefixes it
-- with a sentence, and the parser rejects both.
systemPrompt :: Maybe RobotRef -> Vocabulary -> Text
systemPrompt robot voc = T.intercalate "\n\n"
  [ "You translate an operator request into a robotdsl source file. robotdsl is a "
   <> "small brace-delimited language that compiles to VDA 5050 v3.0.0 JSON for "
   <> "autonomous mobile robots."
  , "OUTPUT RULE — read this first. Reply with the robotdsl source and NOTHING "
   <> "else. No markdown code fences. No explanation, no introduction, no "
   <> "trailing commentary, no questions back. Your entire reply is parsed by a "
   <> "strict parser, so any extra text is a hard failure. Start your reply with "
   <> "the first line of the source."
  , grammar
  , robotSection robot
  , vocabularySection voc
  , "RULES THAT ARE EASY TO GET WRONG:\n"
   <> "1. Every name is a double-quoted string: node \"RK-AM\", zone \"no-go\".\n"
   <> "2. An order must START with a node, then alternate node, edge, node, edge...\n"
   <> "3. Never write sequenceId, actionId, headerId or timestamp. The compiler "
   <> "generates them. Writing them is an error.\n"
   <> "4. Order actions default to blocking HARD. Instant actions must be NONE. "
   <> "Zone actions must be NONE. So omit the blocking clause entirely unless the "
   <> "operator explicitly asks otherwise on an order action.\n"
   <> "5. A node with a position needs a map. Put map \"<mapId>\" at the top of the "
   <> "file, or on map \"<mapId>\" on the node.\n"
   <> "6. A zone polygon needs at least 3 vertices, and an action zone also needs "
   <> "all three of entry, during and exit even when empty.\n"
   <> "7. theta and facing are radians in [-PI, PI].\n"
   <> "8. priority and penalty factors are in [0.0, 1.0].\n"
   <> "9. Prefer `go to \"<node>\" at (x, y)` over an explicit edge. Use an explicit "
   <> "edge only when a speed, corridor or trajectory is needed.\n"
   <> "10. actionType values come from the standard list. A robot may support "
   <> "others, but do not invent one unless the operator names it.\n"
   <> "11. Only travel between nodes that appear in the traversable hops list. "
   <> "A hop the map does not have cannot be driven."
  , fewShot
  ]

-- | The grammar, as the parser accepts it.
grammar :: Text
grammar = T.intercalate "\n"
  [ "GRAMMAR"
  , "  file     := { headerDecl | message }"
  , "  headerDecl := robot \"<mfr>\" \"<serial>\""
  , "              | map \"<mapId>\""
  , "              | version 3.0.0"
  , "              | header <int>"
  , "              | timestamp \"<ISO8601>\""
  , ""
  , "  message := order | instant | zoneset"
  , ""
  , "  order \"<id>\" [update <int>] [describe \"<text>\"] { body }"
  , "  body   := { segment | step }"
  , "  segment:= (route | base) { { step } }      -- released: true"
  , "          | horizon { { step } }            -- released: false"
  , ""
  , "  step   := node \"<id>\" { nodeMod } [ { { action } } ]"
  , "          | edge [\"<id>\"] { edgeMod } [ { { action } } ]"
  , "          | go to \"<id>\" { nodeMod | edgeMod | via \"<edgeId>\" } [ { { action } } ]"
  , ""
  , "  nodeMod:= describe \"<text>\" | at (x, y) | at (x, y, theta) | facing <rad>"
  , "          | on map \"<mapId>\" | deviation (a, b, theta) | deviation_theta <rad>"
  , ""
  , "  edgeMod:= describe \"<text>\" | speed <m/s> | length <m> | maxheight <m>"
  , "          | minloadheight <m> | orientation <rad>"
  , "          | orientation_type global | tangential"
  , "          | direction \"<text>\" | reachbefore true | false"
  , "          | maxrotation <rad/s>"
  , "          | trajectory degree <int> knots [n, ...] controlpoints [(x, y), ...]"
  , "          | corridor <left> <right> [ref kinematic_center | contour]"
  , "              [release_required true | false] [release_loss stop | return]"
  , ""
  , "  action := action \"<type>\" { actionMod }"
  , "  actionMod:= blocking none | soft | single | hard"
  , "            | describe \"<text>\" | retriable"
  , "            | with { key = value, ... }     -- value is string, number,"
  , "                                          --  boolean, or [array]"
  , ""
  , "  instant [\"<label>\"] { { action } }"
  , ""
  , "  zoneset \"<id>\" [on map \"<mapId>\"] [describe \"<text>\"] { { zone } }"
  , "  zone   := zone \"<id>\" [describe \"<text>\"] <zoneType> { polygon | groups }"
  , "  polygon:= polygon (x, y) (x, y) ...      -- at least 3 vertices"
  , "  groups := (entry | during | exit) { { action } }"
  , ""
  , "  zoneType:= blocked                       -- BLOCKED"
  , "           | line_guided                  -- LINE_GUIDED"
  , "           | release                      -- RELEASE"
  , "           | coordinated_replanning       -- COORDINATED_REPLANNING"
  , "           | speed_limit <m/s>            -- SPEED_LIMIT"
  , "           | action                       -- ACTION"
  , "           | priority factor <0.0-1.0>    -- PRIORITY"
  , "           | penalty factor <0.0-1.0>     -- PENALTY"
  , "           | directed heading <rad> strictness soft | restricted | strict"
  , "                                            -- DIRECTED"
  , "           | bidirected heading <rad> strictness soft | restricted"
  , "                                            -- BIDIRECTED"
  , ""
  , "  The keyword on the left is what you write; the name on the right is the"
  , "  VDA 5050 zoneType it compiles to."
  ]

-- | What the generator may legitimately name.
vocabularySection :: Vocabulary -> Text
vocabularySection voc = T.intercalate "\n" (mapSection ++ actionSection)
  where
    -- The action catalogue does not depend on the map: a generator with no map
    -- still needs to know which action types exist.
    actionSection =
      [ "action types: " <> T.intercalate ", " standardActions ]

    -- The hops are the ground truth for what can actually be driven. Without
    -- them the model invents a traversal the map does not have, and the
    -- operator only finds out when a robot refuses the order.
    hopsLine = case vocEdgePairs voc of
      [] -> "traversable hops: none are known, so keep the mission to one node plus one destination."
      ps -> "traversable hops (from -> to); only these exist: "
              <> T.intercalate ", " (map fmt ps)

    fmt (a, b) = a <> " -> " <> b

    scopeLine = case vocScope voc of
      Nothing -> []
      Just picked ->
        [ "scope: the operator restricted this mission to "
            <> T.intercalate ", " picked
            <> ". Do not leave it." ]

    mapSection = case (vocMapId voc, vocNodes voc) of
      (Nothing, []) ->
        [ "VOCABULARY"
        , "No map was supplied, so no real node ids are known. Use the node ids"
        , "exactly as the operator words them, and prefer a single node plus one"
        , "destination."
        ]
      (m, ns) ->
        [ "VOCABULARY — use ONLY these names."
        , "mapId: " <> fromMaybeText m
        , "node ids: " <> T.intercalate ", " ns
        , case vocEdges voc of
            [] -> "edge ids: (unnamed; let the compiler generate them)"
            es -> "edge ids: " <> T.intercalate ", " es
        , hopsLine
        ] ++ scopeLine

    fromMaybeText Nothing = "(none given)"
    fromMaybeText (Just x) = x

-- | Which robot the mission is for, when one is known.
--
-- The model needs the identity to write the @robot@ header declaration. The
-- state is context: it stops the model proposing a pickup on a robot that is
-- already driving something else, and it tells the operator what the generator
-- believes it is talking to.
robotSection :: Maybe RobotRef -> Text
robotSection Nothing =
  "ROBOT\nNo robot is selected. Write robot \"<manufacturer>\" \"<serialNumber>\" using the identity the operator names."
robotSection (Just r) = T.intercalate "\n"
  [ "ROBOT — this mission is for:"
  , "robotId: " <> rrRobotId r
  , "manufacturer: " <> rrManufacturer r
  , "serialNumber: " <> rrSerialNumber r
  , "state: " <> stateText
  ]
  where
    stateText
      | not (rrOnline r) = "offline"
      | rrDriving r      = "online, driving order " <> rrOrderId r
      | otherwise        = "online, idle"

-- | Two worked examples, chosen to cover the two shapes operators ask for most.
fewShot :: Text
fewShot = T.intercalate "\n"
  [ "EXAMPLE 1"
  , "Request: 랙에서 팔레트를 집어 컨베이어 A로 가져다줘"
  , "Answer:"
  , "robot \"acme\" \"AMR-001\""
  , "map \"plant-b\""
  , "order \"order-pallet-1\" {"
  , "  base {"
  , "    node \"RK-AM\" at (12.5, 3.0) facing 0.0 {"
  , "      action \"pick\" describe \"grab pallet\" with { loadId = \"KLT-42\" }"
  , "    }"
  , "    go to \"CHG-01\" at (0.0, 0.0) facing 1.5708 {"
  , "      action \"drop\" with { loadId = \"KLT-42\" }"
  , "    }"
  , "  }"
  , "}"
  , ""
  , "EXAMPLE 2"
  , "Request: 로봇 멈춰"
  , "Answer:"
  , "instant \"pause\" {"
  , "  action \"startPause\""
  , "}"
  ]

-- | The operator request, wrapped as the user turn.
userMessage :: Text -> Text
userMessage req =
  "Operator request (Korean): " <> req
  <> "\nReply with the robotdsl source only, per the output rule."

-- | Keywords that may legally begin a source file, used to find where the
-- actual source starts when the model prefixes prose.
headerKeywords :: [Text]
headerKeywords =
  [ "robot", "map", "version", "header", "timestamp"
  , "order", "instant", "zoneset"
  ]

-- | Strip the wrappings models add before handing text to the parser.
--
-- Three failure shapes are handled, in order: a markdown fence (optionally with
-- a language tag), a trailing fence, and prose before the first real line. The
-- parser is the authority on validity; this only removes packaging.
cleanOutput :: Text -> Text
cleanOutput raw0 =
  case stripFences (T.strip raw0) of
    ""   -> ""
    body -> dropLeadingProse body

-- | Remove a leading and trailing markdown fence.
stripFences :: Text -> Text
stripFences t =
  let ls = T.lines t
      body = case ls of
        (l : rest)
          | isFenceLine l -> rest
        _ -> ls
      trimmed = reverse (dropWhile isFenceLine (reverse body))
  in T.unlines trimmed
  where
    isFenceLine l = "```" `T.isPrefixOf` T.strip l

-- | Drop everything before the first line that starts a real declaration.
dropLeadingProse :: Text -> Text
dropLeadingProse t =
  let ls = T.lines t
      idx = firstIndex ls
  in T.unlines (drop idx ls)
  where
    firstIndex ls0 = go 0 ls0
      where
        go _ [] = 0
        go !n (l : rest)
          | startsDecl (T.strip l) = n
          | otherwise             = go (n + 1) rest

startsDecl :: Text -> Bool
startsDecl l = any (`T.isPrefixOf` l) headerKeywords
