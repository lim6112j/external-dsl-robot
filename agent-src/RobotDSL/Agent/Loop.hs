{-# LANGUAGE OverloadedStrings #-}
-- | The generate-parse-validate-retry loop.
--
-- This module is where the safety property of the whole feature lives: the
-- model only ever proposes text, and nothing reaches the operator unless
-- 'RobotDSL.Parser' and 'RobotDSL.Validate' both accept it. When they do not,
-- the exact error is fed back to the model and it gets another go, up to
-- 'lrMaxAttempts'.
--
-- Two deliberate choices worth knowing about:
--
--   * A failed intermediate attempt is never recorded in the conversation
--     history. Only the output that actually validated is kept, so the model
--     is not taught to reproduce its own mistakes.
--
--   * When the program omits the @robot@ and @map@ declarations, they are
--     injected from the configured context. Without this, a model that simply
--     forgets them would fail validation for a reason that has nothing to do
--     with what the operator asked for.
module RobotDSL.Agent.Loop
  ( LoopResult(..)
  , LoopConfig(..)
  , runLoop
  , finalize
  , inject
  ) where

import Data.Aeson (Value)
import Data.IORef (IORef, newIORef, readIORef, modifyIORef')
import Data.Text (Text)
import qualified Data.Text as T

import Network.HTTP.Client (Manager)

import RobotDSL.Agent.Client
import RobotDSL.Agent.Context (Vocabulary)
import RobotDSL.Agent.Fleet (RobotRef(..))
import RobotDSL.Agent.Prompt
import RobotDSL.AST
import RobotDSL.Emit
import RobotDSL.Parser
import RobotDSL.Validate

-- | How many attempts the loop may spend before giving up.
lrMaxAttempts :: Int
lrMaxAttempts = 3

-- | Everything the loop needs that is not part of one request.
--
-- 'Manager' has no Eq or Show instance, so the deriving clause is omitted: the
-- record is compared by its contents in tests, never by the manager.
data LoopConfig = LoopConfig
  { lcManager  :: !Manager
  -- ^ Connection manager, shared so the TLS handshake is not repeated per call.
  , lcClient   :: !ClientConfig
  -- ^ Which model to call.
  , lcVocab    :: !Vocabulary
  -- ^ Node and action names the model may use.
  , lcEmit     :: !EmitContext
  -- ^ manufacturer, serialNumber and mapId used both for injection and for
  -- emitting the preview JSON.
  , lcRobot    :: !(Maybe RobotRef)
  -- ^ The robot the mission is for, when the fleet is known. Feeds the prompt
  -- only; injection still uses lcMfr and lcSerial.
  , lcMfr      :: !(Maybe Text)
  , lcSerial   :: !(Maybe Text)
  -- ^ Robot identity to inject when the generated source omits it.
  }

-- | The outcome of one operator request.
data LoopResult = LoopResult
  { lrOk       :: !Bool
  -- ^ True only when a program parsed, validated and emitted.
  , lrDsl      :: !Text
  -- ^ The last generated source, kept even on failure so the operator can fix
  -- it by hand.
  , lrMessages :: ![Value]
  -- ^ The emitted messages, empty on failure.
  , lrAttempts :: !Int
  , lrErrors   :: ![Text]
  -- ^ Every reason the final attempt was rejected, empty on success.
  , lrUsage    :: !(Maybe (Int, Int))
  -- ^ (prompt tokens, completion tokens) accumulated over all attempts.
  } deriving (Eq, Show)

-- | Run the loop over one operator request, on top of an existing
-- conversation.
--
-- @history@ is the conversation so far and is not modified: the caller owns
-- it and decides what to append.
runLoop :: LoopConfig -> [ChatMessage] -> Text -> IO LoopResult
runLoop cfg history request = do
  usageRef <- newIORef (0 :: Int, 0 :: Int)
  go usageRef 1 []
  where
    go :: IORef (Int, Int) -> Int -> [Text] -> IO LoopResult
    go usageRef attempt errs = do
      let feedback = [ChatMessage RoleUser (feedbackText errs) | not (null errs)]
          convo = history
               ++ [ ChatMessage RoleSystem (systemPrompt (lcRobot cfg) (lcVocab cfg))
                  , ChatMessage RoleUser (userMessage request)
                  ]
               ++ feedback
      res <- complete (lcManager cfg) (lcClient cfg) convo
      case res of
        Left transport -> do
          let err = T.pack transport
          if attempt >= lrMaxAttempts
            then finish usageRef attempt [err] "" Nothing
            else go usageRef (attempt + 1) (errs ++ [err])
        Right comp -> do
          modifyIORef' usageRef
            (\(p, c) -> (p + compPromptTokens comp, c + compCompletionTokens comp))
          let dsl = cleanOutput (compText comp)
          case finalize cfg dsl of
            Right msgs -> finish usageRef attempt [] dsl (Just msgs)
            Left problems ->
              if attempt >= lrMaxAttempts
                then finish usageRef attempt problems dsl Nothing
                else go usageRef (attempt + 1) problems

finish :: IORef (Int, Int) -> Int -> [Text] -> Text -> Maybe [Value] -> IO LoopResult
finish usageRef attempt errs dsl msgsM = do
  (p, c) <- readIORef usageRef
  pure LoopResult
    { lrOk = null errs
    , lrDsl = dsl
    , lrMessages = maybe [] id msgsM
    , lrAttempts = attempt
    , lrErrors = errs
    , lrUsage = if p == 0 && c == 0 then Nothing else Just (p, c)
    }

-- | Turn the accumulated errors into the message that asks the model to fix
-- its output. The parser errors are reproduced verbatim because they carry
-- line and column numbers the model can act on.
feedbackText :: [Text] -> Text
feedbackText errs = T.intercalate "\n\n"
  [ "Your previous reply was rejected. Fix it and reply with the corrected"
  , "robotdsl source only, following the output rule exactly."
  , ""
  , T.intercalate "\n" (map (\e -> "- " <> e) errs)
  ]

-- | Parse, validate, inject and emit.
--
-- Injection happens between parsing and validation so that the injected
-- declarations are themselves checked.
finalize :: LoopConfig -> Text -> Either [Text] [Value]
finalize cfg dsl =
  case parseProgram "<agent>" dsl of
    Left (ParseError msg) -> Left [msg]
    Right prog0 -> do
      let prog = inject cfg prog0
      case validate prog of
        [] -> Right (map emValue (emit prog (lcEmit cfg)))
        issues -> Left (map renderIssue issues)

-- | Fill in the declarations the model left out.
inject :: LoopConfig -> Program -> Program
inject cfg prog = prog
  { progRobot = orMaybe (progRobot prog)
                    ((\m s -> (m, s)) <$> lcMfr cfg <*> lcSerial cfg)
  , progMapId = orMaybe (progMapId prog) (ecMapId (lcEmit cfg))
  }
  where
    orMaybe a b = case a of
      Just v  -> Just v
      Nothing -> b

renderIssue :: Issue -> Text
renderIssue i = issueSubject i <> ": " <> issueMessage i
