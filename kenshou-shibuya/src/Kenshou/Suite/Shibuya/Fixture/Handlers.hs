module Kenshou.Suite.Shibuya.Fixture.Handlers
  ( HandlerScript (..),
    defaultHandlerScript,
    HandlerProbe,
    HandlerStats (..),
    HandlerEvent (..),
    newHandlerProbe,
    scriptedHandler,
    handlerStats,
    handlerEvents,
  )
where

import Control.Concurrent (ThreadId, myThreadId, threadDelay)
import Control.Concurrent.STM (TVar, atomically, check, modifyTVar', newTVarIO, readTVar)
import Control.Exception (SomeException)
import Control.Exception qualified as Exception
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (UTCTime, getCurrentTime)
import Effectful (IOE, liftIO, (:>))
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Types (Attempt (..), Envelope (..), MessageId)
import Shibuya.Handler (Handler)

data HandlerScript = HandlerScript
  { decisionFor :: !(MessageId -> Int -> Either Text AckDecision),
    delayFor :: !(MessageId -> Int -> Int),
    gate :: !(Maybe (TVar Bool))
  }

defaultHandlerScript :: HandlerScript
defaultHandlerScript = HandlerScript (\_ _ -> Right AckOk) (\_ _ -> 0) Nothing

data HandlerStats = HandlerStats
  { active :: !Int,
    highWater :: !Int,
    started :: !Int,
    ended :: !Int
  }
  deriving stock (Eq, Show)

data HandlerEvent
  = HandlerStarted !MessageId !Int !UTCTime !ThreadId
  | HandlerEnded !MessageId !Int !UTCTime !ThreadId !(Either Text AckDecision)
  deriving stock (Eq, Show)

data HandlerProbe = HandlerProbe
  { script :: !HandlerScript,
    state :: !(TVar (HandlerStats, [HandlerEvent]))
  }

newHandlerProbe :: HandlerScript -> IO HandlerProbe
newHandlerProbe script = HandlerProbe script <$> newTVarIO (HandlerStats 0 0 0 0, [])

handlerStats :: HandlerProbe -> IO HandlerStats
handlerStats probe = fst <$> atomically (readTVar probe.state)

handlerEvents :: HandlerProbe -> IO [HandlerEvent]
handlerEvents probe = reverse . snd <$> atomically (readTVar probe.state)

scriptedHandler :: (IOE :> es) => HandlerProbe -> Handler es msg
scriptedHandler probe message = do
  let identifier = message.envelope.messageId
      attempt = maybe 0 (\(Attempt number) -> fromIntegral number) message.envelope.attempt
  liftIO $ Exception.mask $ \restore -> do
    startedAt <- getCurrentTime
    thread <- myThreadId
    atomically $ modifyTVar' probe.state $ \(stats, events) ->
      let active = stats.active + 1
       in (stats {active, highWater = max stats.highWater active, started = stats.started + 1}, HandlerStarted identifier attempt startedAt thread : events)
    result <- Exception.try @SomeException $ restore $ do
      case probe.script.gate of
        Nothing -> pure ()
        Just open -> atomically $ readTVar open >>= check
      threadDelay (max 0 (probe.script.delayFor identifier attempt))
      pure (probe.script.decisionFor identifier attempt)
    let outcome = either (Left . Text.pack . show) id result
    endedAt <- getCurrentTime
    atomically $ modifyTVar' probe.state $ \(stats, events) ->
      (stats {active = stats.active - 1, ended = stats.ended + 1}, HandlerEnded identifier attempt endedAt thread outcome : events)
    case result of
      Left err -> Exception.throwIO err
      Right decision -> either (ioError . userError . Text.unpack) pure decision
