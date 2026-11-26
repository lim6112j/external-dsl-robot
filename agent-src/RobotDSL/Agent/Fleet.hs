{-# LANGUAGE OverloadedStrings #-}
-- | Read-only access to the fleet-control gateway.
--
-- The gateway already exposes everything the agent needs to ground a mission:
-- the map it serves and the robots currently connected to it. This module only
-- reads. Nothing here publishes, so Phase 1 cannot move a robot by accident —
-- issuing a mission is Phase 2 and does not exist yet.
module RobotDSL.Agent.Fleet
  ( FleetConfig(..)
  , RobotRef(..)
  , fetchMap
  , fetchRobots
  , postJson
  ) where

import Control.Exception (SomeException, try)
import Data.Aeson (Value(..))
import qualified Data.Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Vector as V

import Network.HTTP.Client (Manager, httpLbs, parseRequest, responseBody,
                            responseStatus)
import Network.HTTP.Simple (setRequestBodyLBS, setRequestHeader,
                            setRequestMethod)
import Network.HTTP.Types (hAuthorization, hContentType, statusCode)

-- | Where the gateway lives and how to authenticate against it.
data FleetConfig = FleetConfig
  { fcBaseUrl :: !Text
  -- ^ e.g. @http://127.0.0.1:8080@. A trailing slash is ignored.
  , fcToken :: !(Maybe Text)
  -- ^ Bearer token, when the gateway was started with @--api-token@.
  } deriving (Eq, Show)

-- | One robot as the gateway reports it.
data RobotRef = RobotRef
  { rrRobotId :: !Text
  -- ^ @manufacturer:serialNumber@, the form the gateway itself uses.
  , rrManufacturer :: !Text
  , rrSerialNumber :: !Text
  , rrMapId :: !(Maybe Text)
  -- ^ The map the robot last reported, when it has reported one.
  , rrOnline :: !Bool
  , rrDriving :: !Bool
  -- ^ Whether it is executing an order right now.
  , rrOrderId :: !Text
  -- ^ The order it is running; empty when idle.
  } deriving (Eq, Show)

-- | @GET /api/map@ — the map the gateway serves, verbatim.
--
-- The caller turns it into a 'RobotDSL.Agent.Context.Vocabulary'; returning the
-- raw value keeps this module free of vocabulary policy.
fetchMap :: Manager -> FleetConfig -> IO (Either String Value)
fetchMap mgr cfg = getJson mgr cfg "/api/map"

-- | @GET /api/robots@ — the connected fleet.
--
-- A robot with no @robotId@, @manufacturer@ or @serialNumber@ is dropped rather
-- than reported: those three are what address a robot, so a record missing one
-- cannot be used and would only confuse the picker.
fetchRobots :: Manager -> FleetConfig -> IO (Either String [RobotRef])
fetchRobots mgr cfg = do
  r <- getJson mgr cfg "/api/robots"
  pure $ case r of
    Left e -> Left e
    Right v -> case objField "robots" v of
      Just (Array a) -> Right (mapMaybe robotOf (V.toList a))
      Just other -> Left ("unexpected robots shape: " ++ show other)
      Nothing -> Left ("response had no robots array: " ++ show v)

-- | @POST@ a JSON value to a gateway path and decode its answer.
--
-- The same bearer token and the same readable failures as the reads: a
-- gateway that refuses a mission must say why, not throw an exception at the
-- operator.
postJson :: Manager -> FleetConfig -> Text -> Value -> IO (Either String Value)
postJson mgr cfg path body =
  guarded (issueWith "POST" (Just body) mgr cfg path)

getJson :: Manager -> FleetConfig -> Text -> IO (Either String Value)
getJson mgr cfg path = guarded (issueWith "GET" Nothing mgr cfg path)

guarded :: IO (Either String Value) -> IO (Either String Value)
guarded action = do
  r <- try action :: IO (Either SomeException (Either String Value))
  pure $ case r of
    Left e -> Left ("could not reach the fleet gateway: " ++ show e)
    Right ok -> ok

issueWith :: Text -> Maybe Value -> Manager -> FleetConfig -> Text
          -> IO (Either String Value)
issueWith method body mgr cfg path = do
  req0 <- parseRequest (T.unpack (base cfg) ++ T.unpack path)
  let authed = case fcToken cfg of
                Nothing -> req0
                Just t -> setRequestHeader hAuthorization
                            [TE.encodeUtf8 ("Bearer " <> t)] req0
      withMethod = setRequestMethod (TE.encodeUtf8 method) authed
      req = case body of
              Nothing -> withMethod
              Just v -> setRequestHeader hContentType ["application/json"]
                      $ setRequestBodyLBS (Data.Aeson.encode v) withMethod
  resp <- httpLbs req mgr
  let code = statusCode (responseStatus resp)
  if code /= 200
    then pure (Left ("fleet gateway returned HTTP " ++ show code ++ ": "
                       ++ clip 400 (show (responseBody resp))))
    else case Data.Aeson.eitherDecode (responseBody resp) of
      Left err -> pure (Left ("could not parse the gateway response: " ++ err))
      Right v -> pure (Right v)
  where
    base c = T.dropWhileEnd (== '/') (fcBaseUrl c)

robotOf :: Value -> Maybe RobotRef
robotOf (Object o) = do
  rid <- textField "robotId" o
  man <- textField "manufacturer" o
  ser <- textField "serialNumber" o
  pure RobotRef
    { rrRobotId = rid
    , rrManufacturer = man
    , rrSerialNumber = ser
    , rrMapId = textField "mapId" o
    , rrOnline = textField "connection" o == Just "ONLINE"
    , rrDriving = boolField "driving" o
    , rrOrderId = fromMaybe "" (textField "orderId" o)
    }
robotOf _ = Nothing

textField :: Text -> KM.KeyMap Value -> Maybe Text
textField k o = case KM.lookup (Key.fromText k) o of
  Just (String s) -> Just s
  _ -> Nothing

boolField :: Text -> KM.KeyMap Value -> Bool
boolField k o = case KM.lookup (Key.fromText k) o of
  Just (Bool b) -> b
  _ -> False

objField :: Text -> Value -> Maybe Value
objField k (Object o) = KM.lookup (Key.fromText k) o
objField _ _ = Nothing

-- | Clip a value for an error message, so a huge error body cannot flood the
-- response. Named apart from Prelude.truncate to avoid the ambiguity.
clip :: Int -> String -> String
clip n s
  | length s <= n = s
  | otherwise = take n s ++ "..."
