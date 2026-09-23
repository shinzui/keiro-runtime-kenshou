module Kenshou.Suite.Kiroku.Soak.DeadLetter (scenarios) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Exception (bracket, mask_)
import Data.Aeson (object, (.=))
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Int (Int64)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Kenshou.Check.Process (awaitReady, killChild, restartChild, roleProcess, spawn, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Knob (knobInt, mkKnobName)
import Kenshou.Core.Outcome (Outcome (..))
import Kenshou.Core.Scenario (Scenario, ScenarioReport (..), failedWith, passed)
import Kenshou.Diagnose.Leak (LeakReport (..), judgeLeaks)
import Kenshou.Measure.Knobs (loadModelFromKnobs)
import Kenshou.Measure.Load (LoadReport (..), Operation (..), runLoad)
import Kenshou.Measure.Recorder (ErrorCause (..), OpName (..), OpResult (..))
import Kenshou.Measure.Sampler.Postgres (PgSamplerConfig (..))
import Kenshou.Measure.Session (MeasureConfig (..), MeasurementReport (..), measureConfigFromKnobs, measuredOutcome, phasePlanFromCore, withMeasurement)
import Kenshou.Measure.Summary (MeasurementSummary (..), SummaryWindow (..))
import Kenshou.Suite.Kiroku.Fixture.Oracle qualified as Oracle
import Kenshou.Suite.Kiroku.Fixture.Store (withKirokuStore)
import Kenshou.Suite.Kiroku.Soak.Common (SoakDefinition (..), SoakProfile, applyLeakVerdict, effectivePhases, soakLeakSpec, soakPair)
import Kenshou.Suite.Kiroku.Soak.Growth (Growth (..), relationGrowth)
import Kiroku.Store hiding (id, withKirokuStore)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = soakPair (SoakDefinition "dead-letter" "dead-letter-growth" "Retries one percent of appended events to exhaustion through subscriber process kills." runDeadLetterGrowth)

runDeadLetterGrowth :: SoakProfile -> RunContext -> IO ScenarioReport
runDeadLetterGrowth profile context = case (loadModelFromKnobs context.knobs, measureConfigFromKnobs context (phasePlanFromCore (effectivePhases profile context))) of
  (Left reason, _) -> pure (failedWith ["invalid-load-config"] reason)
  (_, Left reason) -> pure (failedWith ["invalid-measure-config"] reason)
  (Right loadModel, Right baseConfig) -> withKirokuStore context \store -> withCheck context \check -> withSupervisor check \supervisor -> do
    let name = either (error . show) id . mkKnobName
        killMinutes = fromIntegral (knobInt context.knobs (name "soak.kill-interval-minutes")) :: Int
        config = baseConfig {postgres = fmap (\pg -> pg {relations = ["kiroku.dead_letters"]}) baseConfig.postgres}
        operation worker sequenceNumber = do
          let poison = sequenceNumber `mod` 100 == 0
              event = EventData Nothing (if poison then EventType "SoakPoison" else EventType "SoakOrdinary") (object ["sequence" .= sequenceNumber]) Nothing Nothing Nothing
              stream = StreamName ("dead-soak-" <> Text.pack (show (worker `mod` 8)))
          result <- runStoreIO store (appendToStream stream AnyVersion [event])
          pure case result of Right _ -> OpOk 1; Left err -> OpFailed (ErrorCause (Text.pack (show err)))
    spec <- roleProcess check "kiroku/poison-subscriber" 0 (object [])
    first <- spawn supervisor spec
    awaitReady first 10000
    active <- newIORef first
    kills <- newIORef (0 :: Int)
    let killLoop = do
          threadDelay (killMinutes * 60 * 1000000)
          mask_ do
            old <- readIORef active
            killChild supervisor old
            replacement <- restartChild supervisor old
            writeIORef active replacement
            atomicModifyIORef' kills (\count -> (count + 1, ()))
          killLoop
        withKills action
          | killMinutes == 0 = action
          | otherwise = bracket (forkIO killLoop) killThread (const action)
    (_, measurement) <- withKills (withMeasurement context config \session -> runLoad session loadModel (Operation (OpName "append") operation))
    durable@(eventCount, _, _) <- Oracle.threeCounts store.pool
    caughtUp <- timeout 120000000 (waitForCheckpoint store eventCount)
    poisonPositions <- Pool.use store.pool (Session.statement () poisonPositionsStatement)
    letters <- Oracle.deadLetters store.pool "soak-dead-letter"
    growth <- relationGrowth context "kiroku.dead_letters"
    killCount <- readIORef kills
    let actualPoison = either (const []) id poisonPositions
        letterPositions = fmap (.position) letters
        completed = sum [load.completed | load <- measurement.loads]
        failed = sum [load.failed | load <- measurement.loads]
        exact = Set.fromList actualPoison == Set.fromList letterPositions && length actualPoison == length letterPositions
        base = if eventCount > 0 && durable == (eventCount, eventCount, eventCount) && failed == 0 && caughtUp == Just True && exact then passed else failedWith ["dead-letter-soak-contract"] ("durable=" <> Text.pack (show durable) <> ", poison=" <> Text.pack (show (length actualPoison)) <> ", letters=" <> Text.pack (show (length letters)) <> ", failures=" <> Text.pack (show failed))
        measured = if base.outcome == Passed then base {outcome = measuredOutcome measurement base.outcome} else base
        growthMeasured = if measured.outcome == Passed && maybe False (not . (.linear)) growth then measured {outcome = Failed, reason = Just "dead-letter relation size did not grow linearly", failures = "dead-letter-relation-growth" : measured.failures} else measured
        growthComplete = if growthMeasured.outcome == Passed && measurement.summary.window.steadySeconds >= 900 && growth == Nothing then growthMeasured {outcome = Inconclusive, reason = Just "dead-letter growth lacked enough samples"} else growthMeasured
    putSummary context Verdicts "dead-letter-growth" (object ["completed" .= completed, "failed" .= failed, "durableCounts" .= durable, "poisonEvents" .= length actualPoison, "deadLetters" .= length letters, "exactlyOnePerPoison" .= exact, "kills" .= killCount, "checkpointAtHead" .= (caughtUp == Just True), "growth" .= fmap (\item -> object ["firstBytesPerRow" .= item.firstBytesPerRow, "lastBytesPerRow" .= item.lastBytesPerRow, "insertedRows" .= item.insertedRows, "linear" .= item.linear]) growth])
    leak <- judgeLeaks context (soakLeakSpec profile)
    pure (applyLeakVerdict leak.verdict growthComplete)

waitForCheckpoint :: KirokuStore -> Int64 -> IO Bool
waitForCheckpoint store target = do
  inventory <- runStoreIO store subscriptionCheckpointInventory
  case inventory of
    Right snapshot | [position | row <- Vector.toList snapshot.checkpoints, row.subscriptionName == SubscriptionName "soak-dead-letter", let { GlobalPosition position = row.checkpointPosition }] == [target] -> pure True
    _ -> threadDelay 100000 >> waitForCheckpoint store target

poisonPositionsStatement :: Statement.Statement () [Int64]
poisonPositionsStatement = Statement.preparable "select se.stream_version from kiroku.events e join kiroku.stream_events se on se.event_id=e.event_id where se.stream_id=0 and e.event_type='SoakPoison' order by se.stream_version" Encoders.noParams (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.int8)))
