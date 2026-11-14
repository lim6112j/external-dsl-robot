{-# LANGUAGE OverloadedStrings #-}
-- | The OpenRouter client.
--
-- OpenRouter speaks the OpenAI chat-completions dialect, so the request is one
-- POST and the response is one JSON object. The caller supplies the 'Manager'
-- rather than the client building its own: production wants a TLS manager with
-- a timeout, tests want a plain one pointed at a stub.
module RobotDSL.Agent.Client
  ( ClientConfig(..)
  , Completion(..)
  , complete
  ) where

import Control.Exception (SomeException, try)
import Data.Aeson (Value(..), object, (.=))
import qualified Data.Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Vector as V

import Network.HTTP.Client (Manager, httpLbs, parseRequest, responseBody,
                            responseStatus)
import Network.HTTP.Simple (setRequestBodyLBS, setRequestHeader,
                            setRequestMethod)
import Network.HTTP.Types (hAuthorization, hContentType, statusCode)

import RobotDSL.Agent.Prompt (ChatMessage(..), Role(..))

-- | Everything needed to reach one model.
data ClientConfig = ClientConfig
  { ccApiKey     :: !Text
  , ccModel      :: !Text
  , ccBaseUrl    :: !Text
  -- ^ e.g. @https://openrouter.ai/api/v1@
  , ccMaxTokens  :: !Int
  } deriving (Eq, Show)

-- | What came back, including the token counts so the caller can show cost.
data Completion = Completion
  { compText             :: !Text
  , compPromptTokens     :: !Int
  , compCompletionTokens :: !Int
  } deriving (Eq, Show)

-- | One chat-completions round trip.
--
-- Returns @Left@ with a human-readable reason on any failure: a transport
-- error, a non-200 status, an unparseable body, or a body that has the right
-- shape but no content.
complete :: Manager -> ClientConfig -> [ChatMessage] -> IO (Either String Completion)
complete mgr cfg msgs = do
  r <- try (issue mgr cfg msgs) :: IO (Either SomeException (Either String Completion))
  pure $ case r of
    Left e   -> Left ("could not reach OpenRouter: " ++ show e)
    Right ok -> ok

issue :: Manager -> ClientConfig -> [ChatMessage] -> IO (Either String Completion)
issue mgr cfg msgs = do
  req0 <- parseRequest (T.unpack (ccBaseUrl cfg) ++ "/chat/completions")
  let req = setRequestMethod "POST"
          $ setRequestHeader hContentType ["application/json"]
          $ setRequestHeader hAuthorization [TE.encodeUtf8 ("Bearer " <> ccApiKey cfg)]
          $ setRequestBodyLBS (Data.Aeson.encode requestBody)
          $ req0
  resp <- httpLbs req mgr
  let code = statusCode (responseStatus resp)
  if code /= 200
    then pure (Left ("OpenRouter returned HTTP " ++ show code ++ ": "
                       ++ clip 400 (show (responseBody resp))))
    else case Data.Aeson.eitherDecode (responseBody resp) of
      Left err -> pure (Left ("could not parse the OpenRouter response: " ++ err))
      Right v  -> pure (extractCompletion v)
  where
    requestBody = object
      [ "model"      .= ccModel cfg
      , "max_tokens" .= ccMaxTokens cfg
      , "messages"   .= map messageValue msgs
      ]

messageValue :: ChatMessage -> Value
messageValue (ChatMessage r c) = object ["role" .= roleText r, "content" .= c]

roleText :: Role -> Text
roleText RoleSystem    = "system"
roleText RoleUser      = "user"
roleText RoleAssistant = "assistant"

extractCompletion :: Value -> Either String Completion
extractCompletion v =
  case objField "choices" v >>= arrIndex 0 >>= objField "message" >>= objField "content" of
    Just (String s) -> Right Completion
      { compText = s
      , compPromptTokens = usageOf "prompt_tokens"
      , compCompletionTokens = usageOf "completion_tokens"
      }
    Just other -> Left ("unexpected content shape in the response: " ++ show other)
    Nothing    -> Left ("response had no choices[0].message.content: " ++ show v)
  where
    usageOf k = case objField "usage" v >>= objField k of
      Just (Number n) -> round n
      _               -> 0

objField :: Text -> Value -> Maybe Value
objField k (Object o) = KM.lookup (Key.fromText k) o
objField _ _          = Nothing

arrIndex :: Int -> Value -> Maybe Value
arrIndex i (Array a) = a V.!? i
arrIndex _ _         = Nothing

-- | Clip a value for an error message, so a huge error body cannot flood the
-- response. Named apart from Prelude.truncate to avoid the ambiguity.
clip :: Int -> String -> String
clip n s
  | length s <= n = s
  | otherwise     = take n s ++ "..."
