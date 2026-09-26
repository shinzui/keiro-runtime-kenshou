module Kenshou.Suite.Shibuya.Correctness.KirokuReplay (scenario) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, displayException, try)
import Control.Monad (when)
import Data.Aeson (object, (.=))
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as Text
import Effectful (liftIO, runEff)
import Kenshou.Core.Context (RunContext, SummarySection (..), putSummary)
import Kenshou.Core.Dimension (PgDurability (..), PgVersion (..), noDimensions, postgresDimensions)
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Suite.Shibuya.Fixture.Kiroku (KirokuFixture (..), appendEvents, checkpointOf, eventPositions, subscriptionFor, withKirokuFixture)
import Kiroku.Store (GlobalPosition (..), RecordedEvent (..))
import Shibuya.Adapter.Kiroku (SubscriptionName, SubscriptionTarget (..), defaultKirokuAdapterConfig, kirokuAdapter)
import Shibuya.App (ShutdownConfig (..), defaultAppConfig, defaultShutdownConfig, mkProcessor, runApp, stopAppGracefully, waitApp)
import Shibuya.Core.Ack (AckDecision (..), HaltReason (..))
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Core.Types (Envelope (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import System.Timeout (timeout)

scenario :: Scenario
scenario =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/kiroku-adapter/correctness/halt-and-shutdown-replay"),
      revision = 1,
      summary = "Restarts after handler halt and forced mid-batch stop without skipping an uncheckpointed Kiroku event.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions = postgresDimensions (PgDurable :| []) (Pg18 :| [Pg17]) noDimensions,
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku] [] False)},
      knownDefect = Nothing,
      run = runReplay
    }

data ReplayEvidence = ReplayEvidence
  { positions :: ![Int64],
    halted :: ![Int64],
    stopped :: ![Int64],
    recovered :: ![Int64],
    checkpointAfterHalt :: !(Maybe Int64),
    checkpointAfterStop :: !(Maybe Int64),
    finalCheckpoint :: !(Maybe Int64),
    forced :: !Bool,
    drained :: !Bool
  }

runReplay :: RunContext -> IO ScenarioReport
runReplay context = do
  outcome <- try @SomeException $ timeout 30000000 $ withKirokuFixture context runFixture
  case outcome of
    Left err -> pure (failedWith ["kiroku-replay-exception"] (Text.pack (displayException err)))
    Right Nothing -> pure (failedWith ["kiroku-replay-timeout"] "Kiroku replay did not finish within 30 seconds")
    Right (Just evidence) -> do
      let positions = evidence.positions
          third = positions !! 2
          fifth = positions !! 4
          lastPosition = last positions
          afterHalt = maybe 0 id evidence.checkpointAfterHalt
          afterStop = maybe 0 id evidence.checkpointAfterStop
          expectedStopped = takeWhile (<= fifth) (dropWhile (<= afterHalt) positions)
          expectedRecovered = dropWhile (<= afterStop) positions
          failures =
            ["halt-did-not-reach-event" | evidence.halted /= take 3 positions]
              <> ["halt-advanced-past-event" | afterHalt >= third]
              <> ["halt-restart-skipped-event" | evidence.stopped /= expectedStopped]
              <> ["stop-advanced-past-in-flight-event" | afterStop >= fifth]
              <> ["shutdown-restart-skipped-event" | evidence.recovered /= expectedRecovered]
              <> ["checkpoint-decreased" | afterStop < afterHalt || evidence.finalCheckpoint /= Just lastPosition]
              <> ["replay-exceeded-batch" | length evidence.stopped > 8 || length evidence.recovered > 8]
              <> ["stop-was-not-forced" | not evidence.forced]
              <> ["final-run-did-not-drain" | not evidence.drained]
      putSummary context Verdicts "kiroku-halt-shutdown-replay" $
        object
          [ "positions" .= positions,
            "haltDeliveries" .= evidence.halted,
            "stopDeliveries" .= evidence.stopped,
            "recoveryDeliveries" .= evidence.recovered,
            "checkpoints" .= [evidence.checkpointAfterHalt, evidence.checkpointAfterStop, evidence.finalCheckpoint],
            "forcedStop" .= evidence.forced,
            "finalDrained" .= evidence.drained
          ]
      pure $ if null failures then passed else failedWith failures (Text.intercalate "; " failures)

runFixture :: KirokuFixture -> IO ReplayEvidence
runFixture fixture = do
  appendEvents fixture 8
  positions <- eventPositions fixture
  when (length positions /= 8) $ ioError (userError "fixture did not append eight events")
  let subscription = subscriptionFor fixture "replay"
      third = positions !! 2
      fifth = positions !! 4
      lastPosition = last positions
  halted <- newIORef ([] :: [Int64])
  runEff $ runTracingNoop $ do
    adapter <- kirokuAdapter fixture.store (defaultKirokuAdapterConfig subscription (Category fixture.category))
    let handler message = do
          let position = positionOf message
          liftIO $ atomicModifyIORef' halted (\values -> (position : values, ()))
          pure $ if position == third then AckHalt (HaltOrderedStream "replay") else AckOk
    started <- runApp defaultAppConfig [(ProcessorId "kiroku-replay-halt", mkProcessor adapter handler)]
    case started of
      Left err -> error (show err)
      Right handle -> waitApp handle
  haltDeliveries <- reverse <$> readIORef halted
  afterHalt <- checkpointOf fixture subscription 0

  stopped <- newIORef ([] :: [Int64])
  reached <- newEmptyMVar
  release <- newEmptyMVar
  wasForced <- runEff $ runTracingNoop $ do
    adapter <- kirokuAdapter fixture.store (defaultKirokuAdapterConfig subscription (Category fixture.category))
    let handler message = do
          let position = positionOf message
          liftIO $ atomicModifyIORef' stopped (\values -> (position : values, ()))
          when (position == fifth) $ liftIO (putMVar reached () >> takeMVar release)
          pure AckOk
    started <- runApp defaultAppConfig [(ProcessorId "kiroku-replay-stop", mkProcessor adapter handler)]
    case started of
      Left err -> error (show err)
      Right handle -> do
        liftIO $ takeMVar reached
        drained <- stopAppGracefully (defaultShutdownConfig {drainTimeout = 0.1}) handle
        waitApp handle
        pure (not drained)
  stopDeliveries <- reverse <$> readIORef stopped
  afterStop <- checkpointOf fixture subscription 0

  recovered <- newIORef ([] :: [Int64])
  finalDrained <- runEff $ runTracingNoop $ do
    adapter <- kirokuAdapter fixture.store (defaultKirokuAdapterConfig subscription (Category fixture.category))
    let handler message = do
          liftIO $ atomicModifyIORef' recovered (\values -> (positionOf message : values, ()))
          pure AckOk
    started <- runApp defaultAppConfig [(ProcessorId "kiroku-replay-recover", mkProcessor adapter handler)]
    case started of
      Left err -> error (show err)
      Right handle -> do
        liftIO $ waitForCheckpoint fixture subscription lastPosition
        drained <- stopAppGracefully defaultShutdownConfig handle
        waitApp handle
        pure drained
  recoveryDeliveries <- reverse <$> readIORef recovered
  finalCheckpoint <- checkpointOf fixture subscription 0
  pure (ReplayEvidence positions haltDeliveries stopDeliveries recoveryDeliveries afterHalt afterStop finalCheckpoint wasForced finalDrained)

positionOf :: Message es RecordedEvent -> Int64
positionOf message = case message.envelope.payload.globalPosition of GlobalPosition position -> position

waitForCheckpoint :: KirokuFixture -> SubscriptionName -> Int64 -> IO ()
waitForCheckpoint fixture subscription position = do
  checkpoint <- checkpointOf fixture subscription 0
  when (checkpoint /= Just position) $ threadDelay 10000 >> waitForCheckpoint fixture subscription position
