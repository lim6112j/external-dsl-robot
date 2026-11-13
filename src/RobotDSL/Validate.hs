{-# LANGUAGE OverloadedStrings #-}
-- | Semantic checks that run after parsing and before lowering.
--
-- The parser guarantees the program is well-formed robotdsl; this module
-- guarantees it is a well-formed /VDA 5050 v3.0.0/ message set. The rules here
-- are the ones that are easy to get wrong from the standard's prose and that
-- a broker will silently reject, so they are checked once, centrally, with an
-- actionable message rather than surfacing as a schema failure later.
module RobotDSL.Validate
  ( Issue(..)
  , validate
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import RobotDSL.AST

-- | A semantic problem with the program.
data Issue = Issue
  { issueSubject :: !Text
  -- ^ What the problem is about, e.g. @zone 'aisle-slow'@.
  , issueMessage :: !Text
  -- ^ What is wrong and, where useful, what to write instead.
  } deriving (Eq, Show)

instance Semigroup Issue where
  a <> _ = a

instance Monoid Issue where
  mempty = Issue "" ""

-- | Collect every semantic issue. An empty list means the program is safe to
-- lower.
validate :: Program -> [Issue]
validate prog = concat
  [ [ Issue "program" "no messages declared; expected at least one order, instantActions or zoneset"
    | null (progDecls prog) ]
  , [ Issue "program"
        ("no robot declared; add `robot <manufacturer> <serialNumber>` or pass "
          <> "--manufacturer and --serial-number")
    | Nothing <- [progRobot prog] ]
  , concatMap (checkDecl (progMapId prog)) (progDecls prog)
  ]

checkDecl :: Maybe Text -> Decl -> [Issue]
checkDecl defMap d = case d of
  DeclZoneSet zs -> checkZoneSet defMap zs
  DeclOrder o    -> checkOrder defMap o
  DeclInstant ia -> checkInstant ia

-- ---------------------------------------------------------------------------
-- Zones
-- ---------------------------------------------------------------------------

checkZoneSet :: Maybe Text -> ZoneSet -> [Issue]
checkZoneSet defMap zs = mapIssue ++ zoneIssues
  where
    subject = "zoneSet '" <> zsId zs <> "'"

    mapIssue = case zsMapId zs of
      Just _  -> []
      Nothing -> case defMap of
        Just _  -> []
        Nothing ->
          [ Issue subject
              ("this zoneSet has no mapId; add `map <id>` at the top of the file "
              <> "or `on map <id>` on the zoneset")
          ]

    zoneIssues =
      [ Issue (subject <> " zone '" <> zoneId z <> "'") msg
      | z <- zsZones zs
      , msg <- checkZone z
      ]

checkZone :: Zone -> [Text]
checkZone z =
  vertexIssues ++ kindIssues
  where
    vertexIssues
      | length (zoneVertices z) < 3 =
          ["a zone polygon needs at least 3 vertices, got "
            <> T.pack (show (length (zoneVertices z)))]
      | otherwise = []

    kindIssues = case zoneKind z of
      ZkSpeedLimit s
        | s <= 0    -> ["SPEED_LIMIT requires a positive maximumSpeed, got " <> showT s]
        | otherwise -> []
      ZkPriority f
        | f < 0 || f > 1 -> ["priorityFactor must be within [0.0, 1.0], got " <> showT f]
        | otherwise      -> []
      ZkPenalty f
        | f < 0 || f > 1 -> ["penaltyFactor must be within [0.0, 1.0], got " <> showT f]
        | otherwise      -> []
      ZkDirected dir _
        | abs dir > pi -> ["direction must be within [-PI, PI] radians, got " <> showT dir]
        | otherwise    -> []
      ZkBidirected dir _
        | abs dir > pi -> ["direction must be within [-PI, PI] radians, got " <> showT dir]
        | otherwise    -> []
      _ -> []

-- ---------------------------------------------------------------------------
-- Orders
-- ---------------------------------------------------------------------------

checkOrder :: Maybe Text -> Order -> [Issue]
checkOrder defMap o = sequenceIssues ++ positionIssues ++ updateIssues
  where
    subject = "order '" <> ordId o <> "'"
    steps   = orderSteps o

    updateIssues
      | ordUpdateId o < 0 =
          [ Issue subject
              ("orderUpdateId must be a non-negative integer, got "
                <> showT (fromIntegral (ordUpdateId o)))
          ]
      | otherwise = []

    sequenceIssues = case steps of
      [] -> [Issue subject "an order needs at least one node"]
      (s0 : rest)
        | not (isNode s0) ->
            [ Issue (subject <> " step 0")
                ("an order must start with a node, not an edge; the first step is "
                  <> stepName s0)
            ]
        | otherwise ->
            [ Issue (subject <> " step " <> T.pack (show i)) msg
            | (i, msg) <- zip [1 :: Int ..] alternation
            ]
        where
          alternation =
            [ "steps must alternate node, edge, node, ...; this " <> stepName st
                <> " follows another " <> stepName prev
            | (prev, st) <- zip steps rest
            , sameKind prev st
            ]

    positionIssues =
      [ Issue (subject <> " node '" <> nodeId n <> "'") msg
      | StepNode n <- steps
      , msg <- nodeIssues n
      ]

    nodeIssues n = case nodePosition n of
      Nothing -> []
      Just p  -> mapIssue p ++ thetaIssue p
      where
        mapIssue p = case npMapId p of
          Just _  -> []
          Nothing -> case defMap of
            Just _  -> []
            Nothing ->
              ["this node has a position but no mapId; add `map <id>` at the top "
                <> "of the file or `on map <id>` on the node"]
        thetaIssue p = case npTheta p of
          Nothing -> []
          Just t
            | abs t > pi -> ["theta must be within [-PI, PI] radians, got " <> showT t]
            | otherwise  -> []

-- | Flatten an order's segments into traversal order.
orderSteps :: Order -> [Step]
orderSteps o = concatMap segSteps (ordSegments o)

stepName :: Step -> Text
stepName (StepNode n) = "node '" <> nodeId n <> "'"
stepName (StepEdge e) = "edge '" <> maybe "<auto>" id (edgeId e) <> "'"

isNode :: Step -> Bool
isNode (StepNode{}) = True
isNode (StepEdge{}) = False

sameKind :: Step -> Step -> Bool
sameKind a b = isNode a == isNode b

-- ---------------------------------------------------------------------------
-- Instant actions
-- ---------------------------------------------------------------------------

checkInstant :: InstantActions -> [Issue]
checkInstant ia =
  [ Issue ("instant action '" <> actType a <> "'") msg
  | a <- iaActions ia, msg <- blockingIssue a ]
  where
    blockingIssue a = case actBlocking a of
      BtNone -> []
      other ->
        [ "blockingType must be NONE in VDA 5050 v3.0.0: instant actions always "
          <> "run in parallel with movement, so the schema's enum is only "
          <> "\"NONE\". Write the action without a blocking clause (or use "
          <> "`blocking NONE`). Got " <> blockingName other <> ", which is only "
          <> "valid on order actions."
        ]

blockingName :: BlockingType -> Text
blockingName BtNone   = "NONE"
blockingName BtSoft   = "SOFT"
blockingName BtSingle = "SINGLE"
blockingName BtHard   = "HARD"

showT :: Double -> Text
showT = T.pack . show