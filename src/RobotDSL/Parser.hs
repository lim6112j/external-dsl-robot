{-# LANGUAGE OverloadedStrings #-}
-- | The robotdsl parser: source text to "RobotDSL.AST".
--
-- Design notes that shape the grammar:
--
--   * Every name (robot, map, order, zone, node, edge, action) is a quoted
--     string. That keeps real identifiers — @pumpenhaus_1@, @MONTAGE@,
--     @plant-b\/l1@ — legal without reserving a single keyword, and lets them
--     contain spaces, dots and dashes.
--
--   * Modifier lists (@blocking@, @describe@, @at@, @speed@, ...) parse in any
--     order, so the operator is not forced to memorise a clause order.
--
--   * Keywords match case-insensitively and must end at an identifier
--     boundary, so @speed@ and @speed_limit@ never collide.
--
--   * @go@ is sugar for an edge followed by a node and is expanded here, so
--     everything downstream sees only explicit steps.
--
--   * A zone's brace block always holds its @polygon@; ACTION zones
--     additionally hold @entry@\/@during@\/@exit@ groups, which the schema
--     requires alongside the vertices.
module RobotDSL.Parser
  ( parseProgram
  , ParseError(..)
  ) where

import Data.Bifunctor (first)
import Data.Char (isAlphaNum)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Scientific (Scientific, toRealFloat)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Void (Void)
import Text.Megaparsec hiding (ParseError)
import Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer as L

import RobotDSL.AST
import RobotDSL.Version (ProtocolVersion(..))

type Parser = Parsec Void Text

-- | A parse failure, rendered with source position.
newtype ParseError = ParseError Text
  deriving (Eq, Show)

-- | Parse a whole program. @path@ is used only for error messages.
parseProgram :: FilePath -> Text -> Either ParseError Program
parseProgram path src =
  first (ParseError . T.pack . errorBundlePretty) (runParser program path src)

-- ---------------------------------------------------------------------------
-- Lexer
-- ---------------------------------------------------------------------------

-- | Whitespace, plus @#@ and @--@ line comments and @/* *\/@ block comments.
sc :: Parser ()
sc = L.space space1 lineComment blockComment
  where
    lineComment  = L.skipLineComment "#" <|> L.skipLineComment "--"
    blockComment = L.skipBlockComment "/*" "*/"

-- | Consume surrounding whitespace as well as the payload.
lexeme :: Parser a -> Parser a
lexeme p = sc *> p <* sc

symbol :: Text -> Parser Text
symbol = L.symbol sc

-- | A case-insensitive keyword that must end at an identifier boundary.
keyword :: Text -> Parser Text
keyword kw = try (lexeme go)
  where
    go = do
      s <- takeWhile1P (Just "a name or keyword") isIdentChar
      if T.toLower s == T.toLower kw
        then pure s
        else fail ("expected '" ++ T.unpack kw ++ "', found '" ++ T.unpack s ++ "'")

isIdentChar :: Char -> Bool
isIdentChar c = c == '_' || c == '-' || c == '.' || c == '/' || c == ':' || c == '@' || isAlphaNum c

stringLiteral :: Parser Text
stringLiteral = lexeme . fmap T.pack $ do
  _ <- char '"'
  manyTill L.charLiteral (char '"')

identLiteral :: Parser Text
identLiteral = lexeme (takeWhile1P (Just "a parameter name") isParamKeyChar)

isParamKeyChar :: Char -> Bool
isParamKeyChar c = c == '_' || c == '.' || c == '-' || isAlphaNum c

braces :: Parser a -> Parser a
braces = between (symbol "{") (symbol "}")

brackets :: Parser a -> Parser a
brackets = between (symbol "[") (symbol "]")

doubleLiteral :: Parser Double
doubleLiteral = lexeme (toRealFloat <$> L.signed sc L.scientific)

intLiteral :: Parser Integer
intLiteral = lexeme (L.signed sc L.decimal)

scientificLiteral :: Parser Scientific
scientificLiteral = lexeme (L.signed sc L.scientific)

versionTriple :: Parser ProtocolVersion
versionTriple = do
  a <- L.decimal
  _ <- char '.'
  b <- L.decimal
  _ <- char '.'
  c <- lexeme L.decimal
  pure (ProtocolVersion a b c)

-- | @key = value@ with an optional trailing comma, newline separated.
params :: Parser [(Text, ActionValue)]
params = many (param <* optional (try (symbol ",")))
  where
    param = do
      k <- identLiteral
      _ <- symbol "="
      v <- valueLiteral
      pure (k, v)

valueLiteral :: Parser ActionValue
valueLiteral =
      (AVArray <$> arrayLiteral)
  <|> (AVString <$> stringLiteral)
  <|> (AVBool <$> booleanLiteral)
  <|> (AVNumber <$> scientificLiteral)

arrayLiteral :: Parser [ActionValue]
arrayLiteral = brackets (valueLiteral `sepBy` symbol ",")

booleanLiteral :: Parser Bool
booleanLiteral = (True <$ keyword "true") <|> (False <$ keyword "false")

-- ---------------------------------------------------------------------------
-- Program
-- ---------------------------------------------------------------------------

data RawItem
  = RawRobot !Text !Text
  | RawMap !Text
  | RawVersion !ProtocolVersion
  | RawHeaderId !Int
  | RawTimestamp !Text
  | RawDecl !Decl

program :: Parser Program
program = sc *> (buildProgram <$> many rawItem) <* eof

rawItem :: Parser RawItem
rawItem =
      (RawRobot <$> (keyword "robot" *> stringLiteral) <*> stringLiteral)
  <|> (RawMap <$> (keyword "map" *> stringLiteral))
  <|> (RawVersion <$> (keyword "version" *> versionTriple))
  <|> (RawHeaderId . fromIntegral <$> (keyword "header" *> intLiteral))
  <|> (RawTimestamp <$> (keyword "timestamp" *> stringLiteral))
  <|> (RawDecl <$> zoneSetDecl)
  <|> (RawDecl <$> orderDecl)
  <|> (RawDecl <$> instantDecl)

buildProgram :: [RawItem] -> Program
buildProgram items =
  Program
    { progHeader = Header
        { hdrHeaderId  = lastMay [ i | RawHeaderId i <- items ]
        , hdrTimestamp = lastMay [ t | RawTimestamp t <- items ]
        , hdrVersion   = lastMay [ v | RawVersion v <- items ]
        }
    , progRobot    = lastMay [ (m, s) | RawRobot m s <- items ]
    , progMapId    = lastMay [ m | RawMap m <- items ]
    , progDecls    = [ d | RawDecl d <- items ]
    }
  where
    lastMay [] = Nothing
    lastMay xs = Just (last xs)
-- ---------------------------------------------------------------------------
-- Zones
-- ---------------------------------------------------------------------------

zoneSetDecl :: Parser Decl
zoneSetDecl = do
  _ <- keyword "zoneset"
  zsid <- stringLiteral
  mapId <- optional (keyword "on" *> keyword "map" *> stringLiteral)
  descr <- optional (keyword "describe" *> stringLiteral)
  zones <- braces (many zoneDecl)
  pure (DeclZoneSet ZoneSet
    { zsId = zsid
    , zsMapId = mapId
    , zsDescriptor = descr
    , zsZones = zones
    })

zoneDecl :: Parser Zone
zoneDecl = do
  _ <- keyword "zone"
  zid <- stringLiteral
  descr <- optional (keyword "describe" *> stringLiteral)
  kind0 <- zoneSpec
  (groups, verts) <- braces zoneBlockBody
  kind <- resolveKind zid kind0 groups
  pure Zone { zoneId = zid, zoneDescriptor = descr, zoneKind = kind, zoneVertices = verts }

-- | ACTION zones take their actions from the brace block; every other type
-- must not declare any, which is reported here rather than silently dropped.
resolveKind :: Text -> ZoneKind -> [(Text, [Action])] -> Parser ZoneKind
resolveKind zid kind groups = case kind of
  ZkAction{} ->
    pure (ZkAction (look "entry") (look "during") (look "exit"))
  _ | null groups -> pure kind
    | otherwise ->
        fail $ "zone '" ++ T.unpack zid ++ "' (" ++ T.unpack (zoneTypeName kind)
             ++ ") declares entry/during/exit action groups, but only ACTION "
             ++ "zones carry actions"
  where
    look n = fromMaybe [] (lookup n groups)

zoneTypeName :: ZoneKind -> Text
zoneTypeName k = case k of
  ZkBlocked               -> "BLOCKED"
  ZkLineGuided            -> "LINE_GUIDED"
  ZkRelease               -> "RELEASE"
  ZkCoordinatedReplanning -> "COORDINATED_REPLANNING"
  ZkSpeedLimit{}          -> "SPEED_LIMIT"
  ZkAction{}              -> "ACTION"
  ZkPriority{}            -> "PRIORITY"
  ZkPenalty{}             -> "PENALTY"
  ZkDirected{}            -> "DIRECTED"
  ZkBidirected{}          -> "BIDIRECTED"

data ZoneBlockPart = ZoneGroup !Text ![Action] | ZonePolygon ![Vertex]

zoneBlockBody :: Parser ([(Text, [Action])], [Vertex])
zoneBlockBody = do
  parts <- many zoneBlockPart
  pure ([ (n, as) | ZoneGroup n as <- parts ]
       , concat [ vs | ZonePolygon vs <- parts ])

zoneBlockPart :: Parser ZoneBlockPart
zoneBlockPart =
      (ZonePolygon <$> (keyword "polygon" *> many vertex))
  <|> (uncurry ZoneGroup <$> actionGroup)

actionGroup :: Parser (Text, [Action])
actionGroup = do
  name <- choice
    [ "entry"  <$ keyword "entry"
    , "during" <$ keyword "during"
    , "exit"   <$ keyword "exit"
    ]
  acts <- braces (many (actionDecl BtNone))
  pure (name, acts)

-- | The zone's type plus the payload that type requires. Choosing the payload
-- parser by the type is what stops a BLOCKED zone carrying a @maximumSpeed@.
zoneSpec :: Parser ZoneKind
zoneSpec =
      (ZkBlocked <$ keyword "blocked")
  <|> (ZkLineGuided <$ keyword "line_guided")
  <|> (ZkRelease <$ keyword "release")
  <|> (ZkCoordinatedReplanning <$ keyword "coordinated_replanning")
  <|> (ZkSpeedLimit <$> (keyword "speed_limit" *> label "a speed in m/s" doubleLiteral))
  <|> (ZkPriority <$> (keyword "priority" *> keyword "factor"
                    *> label "a factor between 0.0 and 1.0" doubleLiteral))
  <|> (ZkPenalty <$> (keyword "penalty" *> keyword "factor"
                  *> label "a factor between 0.0 and 1.0" doubleLiteral))
  <|> (uncurry ZkDirected <$> directedZone)
  <|> (uncurry ZkBidirected <$> bidirectedZone)
  <|> (ZkAction [] [] [] <$ keyword "action")

directedZone :: Parser (Double, Limitation)
directedZone = do
  _ <- keyword "directed"
  _ <- keyword "heading"
  d <- label "a heading in radians" doubleLiteral
  lim <- optional (keyword "strictness" *> choice
    [ LmSoft       <$ keyword "soft"
    , LmRestricted <$ keyword "restricted"
    , LmStrict     <$ keyword "strict"
    ])
  pure (d, fromMaybe LmSoft lim)

bidirectedZone :: Parser (Double, SoftLimitation)
bidirectedZone = do
  _ <- keyword "bidirected"
  _ <- keyword "heading"
  d <- label "a heading in radians" doubleLiteral
  lim <- optional (keyword "strictness" *> choice
    [ SlSoft       <$ keyword "soft"
    , SlRestricted <$ keyword "restricted"
    ])
  pure (d, fromMaybe SlSoft lim)

vertex :: Parser Vertex
vertex = between (symbol "(") (symbol ")") $ do
  x <- doubleLiteral
  _ <- symbol ","
  Vertex x <$> doubleLiteral

-- ---------------------------------------------------------------------------
-- Orders
-- ---------------------------------------------------------------------------

orderDecl :: Parser Decl
orderDecl = do
  _ <- keyword "order"
  oid <- stringLiteral
  updateId <- fromMaybe 0 <$> optional (keyword "update" *> (fromIntegral <$> intLiteral))
  descr <- optional (keyword "describe" *> stringLiteral)
  segs <- braces orderBody
  pure (DeclOrder Order
    { ordId = oid
    , ordUpdateId = updateId
    , ordDescriptor = descr
    , ordSegments = segs
    })

-- | @route@ and @base@ both mean @released: true@; @horizon@ means false.
orderBody :: Parser [Segment]
orderBody = many (segment <|> bareSteps)
  where
    bareSteps = Segment True . concat <$> some step

segment :: Parser Segment
segment = do
  released <- (True <$ choice [keyword "route", keyword "base"])
                  <|> (False <$ keyword "horizon")
  Segment released <$> braces (concat <$> many step)

step :: Parser [Step]
step = nodeStep <|> edgeStep <|> goStep

-- | A node or edge may carry no actions at all, which is the common case for a
-- plain waypoint or a simple hop.
--
-- The brace is only consumed when one is actually next. Without the lookahead
-- the @try@ would swallow a genuine error inside the block — an unclosed @{@
-- would be reported at the opening brace instead of at the missing @}@.
optionalActions :: Parser [Action]
optionalActions = do
  atBrace <- lookAhead (option False (True <$ symbol "{"))
  if atBrace
    then braces (many (actionDecl BtHard))
    else pure []

nodeStep :: Parser [Step]
nodeStep = do
  _ <- keyword "node"
  nid <- stringLiteral
  mods <- many nodeMod
  acts <- optionalActions
  pure [StepNode (buildNode nid mods acts)]

edgeStep :: Parser [Step]
edgeStep = do
  _ <- keyword "edge"
  eid <- optional stringLiteral
  mods <- many edgeMod
  acts <- optionalActions
  pure [StepEdge (buildEdge eid mods acts)]

-- | @go@ is sugar for an edge followed by a node.
goStep :: Parser [Step]
goStep = do
  _ <- keyword "go"
  _ <- keyword "to"
  nid <- stringLiteral
  mods <- many goMod
  acts <- optionalActions
  let nmods = [ m | GoNode m <- mods ]
      emods = [ m | GoEdge m <- mods ]
  pure [StepEdge (buildEdge Nothing emods []), StepNode (buildNode nid nmods acts)]

data GoMod = GoNode NodeMod | GoEdge EdgeMod

goMod :: Parser GoMod
goMod =
      (GoNode <$> nodeMod)
  <|> (GoEdge <$> edgeMod)
  <|> (GoEdge . EmId <$> (keyword "via" *> stringLiteral))

-- | Node modifiers, accumulated and then assembled by 'buildNode'.
data NodeMod
  = NmDescribe !Text
  | NmAt !(Double, Double, Maybe Double)
  | NmFacing !Double
  | NmOnMap !Text
  | NmDeviationXY !Double !Double !Double
  | NmDeviationTheta !Double

nodeMod :: Parser NodeMod
nodeMod =
      (NmDescribe <$> (keyword "describe" *> stringLiteral))
  <|> (NmAt <$> (keyword "at" *> positionArgs))
  <|> (NmFacing <$> (keyword "facing" *> doubleLiteral))
  <|> (NmOnMap <$> (keyword "on" *> keyword "map" *> stringLiteral))
  <|> ((\(a, b, c) -> NmDeviationXY a b c) <$> (keyword "deviation" *> deviationArgs))
  <|> (NmDeviationTheta <$> (keyword "deviation_theta" *> doubleLiteral))

buildNode :: Text -> [NodeMod] -> [Action] -> Node
buildNode nid mods acts =
  Node
    { nodeId = nid
    , nodeDescriptor = listToMaybe [ d | NmDescribe d <- mods ]
    , nodePosition = case listToMaybe [ p | NmAt p <- mods ] of
        Nothing -> Nothing
        Just (x, y, th) -> Just NodePosition
          { npX = x
          , npY = y
          , npTheta = case th of
              Just t  -> Just t
              Nothing -> listToMaybe [ t | NmFacing t <- mods ]
          , npAllowedDeviationXY = listToMaybe
              [ DeviationXY a b c | NmDeviationXY a b c <- mods ]
          , npAllowedDeviationTheta = listToMaybe [ t | NmDeviationTheta t <- mods ]
          , npMapId = listToMaybe [ m | NmOnMap m <- mods ]
          }
    , nodeActions = acts
    }

positionArgs :: Parser (Double, Double, Maybe Double)
positionArgs = between (symbol "(") (symbol ")") $ do
  x <- doubleLiteral
  _ <- symbol ","
  y <- doubleLiteral
  th <- optional (try (symbol "," *> doubleLiteral))
  pure (x, y, th)

deviationArgs :: Parser (Double, Double, Double)
deviationArgs = between (symbol "(") (symbol ")") $ do
  a <- doubleLiteral
  _ <- symbol ","
  b <- doubleLiteral
  _ <- symbol ","
  c <- doubleLiteral
  pure (a, b, c)

data EdgeMod
  = EmId !Text
  | EmDescribe !Text
  | EmSpeed !Double
  | EmMaxHeight !Double
  | EmMinLoadHeight !Double
  | EmOrientation !Double
  | EmOrientationType !OrientationType
  | EmDirection !Text
  | EmReachBefore !Bool
  | EmMaxRotation !Double
  | EmTrajectory !Trajectory
  | EmLength !Double
  | EmCorridor !Corridor

edgeMod :: Parser EdgeMod
edgeMod =
      (EmDescribe <$> (keyword "describe" *> stringLiteral))
  <|> (EmSpeed <$> (keyword "speed" *> doubleLiteral))
  <|> (EmMaxHeight <$> (keyword "maxheight" *> doubleLiteral))
  <|> (EmMinLoadHeight <$> (keyword "minloadheight" *> doubleLiteral))
  <|> (EmOrientation <$> (keyword "orientation" *> doubleLiteral))
  <|> (EmOrientationType <$> (keyword "orientation_type" *> orientationType))
  <|> (EmDirection <$> (keyword "direction" *> stringLiteral))
  <|> (EmReachBefore <$> (keyword "reachbefore" *> booleanLiteral))
  <|> (EmMaxRotation <$> (keyword "maxrotation" *> doubleLiteral))
  <|> (EmTrajectory <$> (keyword "trajectory" *> trajectoryLiteral))
  <|> (EmLength <$> (keyword "length" *> doubleLiteral))
  <|> (EmCorridor <$> (keyword "corridor" *> corridorLiteral))

buildEdge :: Maybe Text -> [EdgeMod] -> [Action] -> Edge
buildEdge eid mods acts =
  (foldl' apply (emptyEdge eid) mods) { edgeActions = acts }
  where
    apply e m = case m of
      EmId i              -> e { edgeId = Just i }
      EmDescribe d        -> e { edgeDescriptor = Just d }
      EmSpeed v           -> e { edgeMaxSpeed = Just v }
      EmMaxHeight v       -> e { edgeMaxMobileRobotHeight = Just v }
      EmMinLoadHeight v   -> e { edgeMinLoadHandlingDeviceHeight = Just v }
      EmOrientation v     -> e { edgeOrientation = Just v }
      EmOrientationType t -> e { edgeOrientationType = Just t }
      EmDirection d       -> e { edgeDirection = Just d }
      EmReachBefore b     -> e { edgeReachOrientationBeforeEntering = Just b }
      EmMaxRotation v     -> e { edgeMaxRotationSpeed = Just v }
      EmTrajectory t      -> e { edgeTrajectory = Just t }
      EmLength v          -> e { edgeLength = Just v }
      EmCorridor c        -> e { edgeCorridor = Just c }

emptyEdge :: Maybe Text -> Edge
emptyEdge e = Edge
  { edgeId = e
  , edgeDescriptor = Nothing
  , edgeMaxSpeed = Nothing
  , edgeMaxMobileRobotHeight = Nothing
  , edgeMinLoadHandlingDeviceHeight = Nothing
  , edgeOrientation = Nothing
  , edgeOrientationType = Nothing
  , edgeDirection = Nothing
  , edgeReachOrientationBeforeEntering = Nothing
  , edgeMaxRotationSpeed = Nothing
  , edgeTrajectory = Nothing
  , edgeLength = Nothing
  , edgeCorridor = Nothing
  , edgeActions = []
  }

orientationType :: Parser OrientationType
orientationType = (OtGlobal <$ keyword "global") <|> (OtTangential <$ keyword "tangential")

trajectoryLiteral :: Parser Trajectory
trajectoryLiteral = do
  deg <- optional (keyword "degree" *> (fromIntegral <$> intLiteral))
  knots <- optional (keyword "knots" *> brackets (doubleLiteral `sepBy` symbol ","))
  cps <- keyword "controlpoints" *> brackets (controlPoint `sepBy` symbol ",")
  pure Trajectory { trajDegree = deg, trajKnotVector = knots, trajControlPoints = cps }

controlPoint :: Parser ControlPoint
controlPoint = between (symbol "(") (symbol ")") $ do
  x <- doubleLiteral
  _ <- symbol ","
  y <- doubleLiteral
  w <- optional (try (symbol "," *> doubleLiteral))
  pure (ControlPoint x y w)

corridorLiteral :: Parser Corridor
corridorLiteral = do
  l <- doubleLiteral
  r <- doubleLiteral
  ref <- optional (keyword "ref" *> choice
    [ CrKinematicCenter <$ keyword "kinematic_center"
    , CrContour <$ keyword "contour"
    ])
  rel <- optional (keyword "release_required" *> booleanLiteral)
  loss <- optional (keyword "release_loss" *> choice
    [ RlStop <$ keyword "stop"
    , RlReturn <$ keyword "return"
    ])
  pure Corridor
    { corrLeftWidth = l
    , corrRightWidth = r
    , corrReferencePoint = ref
    , corrReleaseRequired = rel
    , corrReleaseLossBehavior = loss
    }

-- ---------------------------------------------------------------------------
-- Instant actions
-- ---------------------------------------------------------------------------

instantDecl :: Parser Decl
instantDecl = do
  _ <- keyword "instant"
  iid <- optional stringLiteral
  acts <- braces (many (actionDecl BtNone))
  pure (DeclInstant InstantActions { iaId = iid, iaActions = acts })

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

-- | @blockingType@ defaults differ by context, which is the single most
-- surprising part of the standard:
--
--   * order actions default to HARD (the standard's own default: finish the
--     action before moving on);
--   * instant actions default to NONE, because v3.0.0 restricts their enum to
--     NONE alone — they always run in parallel with movement;
--   * zone entry/during/exit actions default to NONE, since they are triggered
--     by crossing the zone rather than sequenced.
actionDecl :: BlockingType -> Parser Action
actionDecl def = do
  _ <- keyword "action"
  atype <- stringLiteral
  buildAction def atype <$> many actionMod

data ActionMod
  = AmBlocking !BlockingType
  | AmDescribe !Text
  | AmRetriable
  | AmWith ![(Text, ActionValue)]

actionMod :: Parser ActionMod
actionMod =
      (AmBlocking <$> (keyword "blocking" *> blockingTypeLiteral))
  <|> (AmDescribe <$> (keyword "describe" *> stringLiteral))
  <|> (AmRetriable <$ keyword "retriable")
  <|> (AmWith <$> (keyword "with" *> braces params))

-- | Order actions default to HARD, matching the standard's default: the robot
-- finishes the action before it moves on. Instant actions are the opposite and
-- are checked separately in "RobotDSL.Validate".
buildAction :: BlockingType -> Text -> [ActionMod] -> Action
buildAction def atype = foldl' apply base
  where
    base = Action
      { actType = atype
      , actBlocking = def
      , actDescriptor = Nothing
      , actParameters = []
      , actRetriable = Nothing
      }
    apply a m = case m of
      AmBlocking b -> a { actBlocking = b }
      AmDescribe d -> a { actDescriptor = Just d }
      AmRetriable  -> a { actRetriable = Just True }
      AmWith ps    -> a { actParameters = ps }

blockingTypeLiteral :: Parser BlockingType
blockingTypeLiteral = choice
  [ BtNone   <$ keyword "none"
  , BtSoft   <$ keyword "soft"
  , BtSingle <$ keyword "single"
  , BtHard   <$ keyword "hard"
  ]