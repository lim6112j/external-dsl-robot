{-# LANGUAGE OverloadedStrings #-}
-- | The abstract syntax tree of the robotdsl language.
--
-- The AST is deliberately close to the surface syntax: optional fields are
-- 'Maybe', nothing is defaulted, and the standard's mandatory bookkeeping
-- (@sequenceId@ numbering, @actionId@ uniqueness, @headerId@, @timestamp@) is
-- left for "RobotDSL.Emit" to fill in. That keeps parsing and lowering
-- separable and makes both easier to test.
--
-- Types here map onto VDA 5050 v3.0.0 object definitions. Where the standard
-- has a fixed vocabulary the corresponding constructor set is closed, so an
-- invalid value cannot be represented.
module RobotDSL.AST
  ( Program(..)
  , Header(..)
  , Decl(..)
  , ZoneSet(..)
  , Zone(..)
  , ZoneKind(..)
  , Vertex(..)
  , Limitation(..)
  , SoftLimitation(..)
  , Order(..)
  , Segment(..)
  , Step(..)
  , Node(..)
  , NodePosition(..)
  , DeviationXY(..)
  , Edge(..)
  , Trajectory(..)
  , ControlPoint(..)
  , Corridor(..)
  , CorridorRefPoint(..)
  , ReleaseLossBehavior(..)
  , OrientationType(..)
  , Action(..)
  , ActionValue(..)
  , BlockingType(..)
  , InstantActions(..)
  , emptyProgram
  ) where

import Data.Text (Text)
import Data.Scientific (Scientific)

import RobotDSL.Version (ProtocolVersion)

-- | A whole @.robot@ source file.
data Program = Program
  { progHeader   :: !Header
  -- ^ @header@, @timestamp@ and @version@ overrides. Any field left unset is
  -- filled by the CLI.
  , progRobot    :: !(Maybe (Text, Text))
  -- ^ @(manufacturer, serialNumber)@ from the @robot@ declaration. The CLI may
  -- override it; without either, a message has no addressee.
  , progMapId    :: !(Maybe Text)
  -- ^ Default @mapId@ for node positions, from the top-level @map@ declaration.
  , progDecls    :: ![Decl]
  -- ^ Top-level declarations in source order. Order is preserved so that
  -- emitted files and @headerId@ allocation follow the file as written.
  } deriving (Eq, Show)

-- | A top-level message declaration.
data Decl
  = DeclZoneSet !ZoneSet
  | DeclOrder    !Order
  | DeclInstant  !InstantActions
  deriving (Eq, Show)

-- | Message header overrides.
data Header = Header
  { hdrHeaderId  :: !(Maybe Int)
  , hdrTimestamp :: !(Maybe Text)
  , hdrVersion   :: !(Maybe ProtocolVersion)
  } deriving (Eq, Show)

emptyProgram :: Program
emptyProgram = Program emptyHeader Nothing Nothing []
emptyHeader :: Header
emptyHeader = Header Nothing Nothing Nothing

-- | A @zoneSet@ message: a named set of zones over one map.
data ZoneSet = ZoneSet
  { zsId         :: !Text
  , zsMapId      :: !(Maybe Text)
  -- ^ 'Nothing' means the set inherits the file-level @map@ declaration.
  , zsDescriptor :: !(Maybe Text)
  , zsZones      :: ![Zone]
  } deriving (Eq, Show)

-- | One zone. 'zoneKind' carries the payload that is only valid for a given
-- @zoneType@, so the type system rules out, for example, a BLOCKED zone that
-- claims a @maximumSpeed@.
data Zone = Zone
  { zoneId         :: !Text
  , zoneDescriptor :: !(Maybe Text)
  , zoneKind       :: !ZoneKind
  , zoneVertices   :: ![Vertex]
  } deriving (Eq, Show)

data ZoneKind
  = ZkBlocked
  | ZkLineGuided
  | ZkRelease
  | ZkCoordinatedReplanning
  -- ^ Requires @maximumSpeed@.
  | ZkSpeedLimit { zkMaximumSpeed :: !Double }
  -- ^ Requires @entryActions@, @duringActions@ and @exitActions@.
  | ZkAction { zkEntry :: ![Action], zkDuring :: ![Action], zkExit :: ![Action] }
  -- ^ Requires @priorityFactor@ in @[0, 1]@.
  | ZkPriority { zkPriorityFactor :: !Double }
  -- ^ Requires @penaltyFactor@ in @[0, 1]@.
  | ZkPenalty { zkPenaltyFactor :: !Double }
  -- ^ Requires @direction@ and @limitation@.
  | ZkDirected { zkDirection :: !Double, zkLimitation :: !Limitation }
  -- ^ Requires @direction@ and @limitation@.
  | ZkBidirected { zkDirection :: !Double, zkSoftLimitation :: !SoftLimitation }
  deriving (Eq, Show)

-- | @limitation@ for a DIRECTED zone.
data Limitation = LmSoft | LmRestricted | LmStrict
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | @limitation@ for a BIDIRECTED zone (no STRICT variant).
data SoftLimitation = SlSoft | SlRestricted
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | A polygon vertex in map coordinates.
data Vertex = Vertex { vxX :: !Double, vxY :: !Double }
  deriving (Eq, Show)

-- | An @order@ message.
data Order = Order
  { ordId         :: !Text
  , ordUpdateId   :: !Int
  , ordDescriptor :: !(Maybe Text)
  , ordSegments   :: ![Segment]
  } deriving (Eq, Show)

-- | A run of steps sharing one @released@ value. The standard calls a
-- released run the /base/ and an unreleased run the /horizon/.
data Segment = Segment
  { segReleased :: !Bool
  , segSteps    :: ![Step]
  } deriving (Eq, Show)

data Step
  = StepNode !Node
  | StepEdge !Edge
  deriving (Eq, Show)

data Node = Node
  { nodeId         :: !Text
  , nodeDescriptor :: !(Maybe Text)
  , nodePosition   :: !(Maybe NodePosition)
  , nodeActions    :: ![Action]
  } deriving (Eq, Show)

data NodePosition = NodePosition
  { npX                      :: !Double
  , npY                      :: !Double
  , npTheta                  :: !(Maybe Double)
  , npAllowedDeviationXY     :: !(Maybe DeviationXY)
  , npAllowedDeviationTheta  :: !(Maybe Double)
  , npMapId                  :: !(Maybe Text)
  -- ^ 'Nothing' means the node inherits the file's top-level @map@
  -- declaration. "RobotDSL.Validate" rejects a position that still cannot be
  -- resolved; "RobotDSL.Emit" applies the fallback.
  } deriving (Eq, Show)

-- | @allowedDeviationXY@: the tolerance ellipse.
data DeviationXY = DeviationXY
  { dvA     :: !Double
  , dvB     :: !Double
  , dvTheta :: !Double
  } deriving (Eq, Show)

data Edge = Edge
  { edgeId                           :: !(Maybe Text)
  -- ^ 'Nothing' lets the emitter synthesise an id.
  , edgeDescriptor                   :: !(Maybe Text)
  , edgeMaxSpeed                     :: !(Maybe Double)
  , edgeMaxMobileRobotHeight         :: !(Maybe Double)
  , edgeMinLoadHandlingDeviceHeight  :: !(Maybe Double)
  , edgeOrientation                  :: !(Maybe Double)
  , edgeOrientationType              :: !(Maybe OrientationType)
  , edgeDirection                    :: !(Maybe Text)
  , edgeReachOrientationBeforeEntering :: !(Maybe Bool)
  , edgeMaxRotationSpeed             :: !(Maybe Double)
  , edgeTrajectory                   :: !(Maybe Trajectory)
  , edgeLength                       :: !(Maybe Double)
  , edgeCorridor                     :: !(Maybe Corridor)
  , edgeActions                      :: ![Action]
  } deriving (Eq, Show)

data OrientationType = OtGlobal | OtTangential
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | A NURBS trajectory for an edge.
data Trajectory = Trajectory
  { trajDegree        :: !(Maybe Int)
  , trajKnotVector    :: !(Maybe [Double])
  , trajControlPoints :: ![ControlPoint]
  } deriving (Eq, Show)

data ControlPoint = ControlPoint
  { cpX      :: !Double
  , cpY      :: !Double
  , cpWeight :: !(Maybe Double)
  } deriving (Eq, Show)

-- | @corridor@: how far the robot may stray from the trajectory.
data Corridor = Corridor
  { corrLeftWidth            :: !Double
  , corrRightWidth           :: !Double
  , corrReferencePoint       :: !(Maybe CorridorRefPoint)
  , corrReleaseRequired      :: !(Maybe Bool)
  , corrReleaseLossBehavior  :: !(Maybe ReleaseLossBehavior)
  } deriving (Eq, Show)

data CorridorRefPoint = CrKinematicCenter | CrContour
  deriving (Eq, Ord, Show, Enum, Bounded)

data ReleaseLossBehavior = RlStop | RlReturn
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | An action. 'actType' is the @actionType@ the standard names in its
-- \"Actions and Parameters\" table (e.g. @pick@, @drop@, @charge@).
data Action = Action
  { actType        :: !Text
  , actBlocking    :: !BlockingType
  , actDescriptor  :: !(Maybe Text)
  , actParameters  :: ![(Text, ActionValue)]
  , actRetriable   :: !(Maybe Bool)
  } deriving (Eq, Show)

data ActionValue
  = AVString !Text
  | AVNumber !Scientific
  | AVBool   !Bool
  | AVArray  ![ActionValue]
  deriving (Eq, Show)

data BlockingType = BtNone | BtSoft | BtSingle | BtHard
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | An @instantActions@ message: a bundle of actions executed on arrival.
data InstantActions = InstantActions
  { iaId      :: !(Maybe Text)
  -- ^ A label used for output file naming only; it is not part of the message.
  , iaActions :: ![Action]
  } deriving (Eq, Show)