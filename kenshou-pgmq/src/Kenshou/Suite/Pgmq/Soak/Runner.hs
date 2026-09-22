module Kenshou.Suite.Pgmq.Soak.Runner (runSoak) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Data.Aeson (object, (.=))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Data.Word (Word64)
import Effectful qualified
import Effectful.Error.Static qualified
import Kenshou.Core.Context (RunContext (..), SummarySection (Diagnosis, Verdicts), putSummary)
import Kenshou.Core.Knob (knobDouble)
import Kenshou.Core.Outcome (Outcome (Failed, Inconclusive))
import Kenshou.Core.Scenario (ScenarioReport (..), failedWith, passed)
import Kenshou.Diagnose.Leak (LeakReport (..), LeakSpec (..), LeakVerdict (..), defaultLeakSpec, judgeLeaks)
import Kenshou.Measure.Knobs (loadModelFromKnobs)
import Kenshou.Measure.Load (LoadReport (..), Operation (..), runLoad)
import Kenshou.Measure.Recorder (ErrorCause (..), OpName (..), OpResult (..))
import Kenshou.Measure.Sampler.Postgres (PgSamplerConfig (..))
import Kenshou.Measure.Session (MeasureConfig (..), MeasurementReport (..), measureConfigFromKnobs, measuredOutcome, phasePlanFromCore, withMeasurement)
import Kenshou.Suite.Pgmq.Harness
import Kenshou.Suite.Pgmq.Knobs (PgmqKnobs (..), knobName)
import Kenshou.Suite.Pgmq.Oracle (archiveKeys)
import Pgmq.Effectful qualified as Pgmq
import Pgmq.Hasql.Statements.Types qualified as Types

runSoak :: Text -> RunContext -> Maybe (IO ScenarioReport)
runSoak identifier context
  | identifier `elem` ["pgmq/queue/soak/steady-state", "pgmq/queue/soak/steady-state-reduced"] = Just (steadyState identifier context)
  | otherwise = Nothing

steadyState :: Text -> RunContext -> IO ScenarioReport
steadyState identifier context = case (loadModelFromKnobs context.knobs, measureConfigFromKnobs context (phasePlanFromCore context.phases)) of
  (Left message, _) -> pure (failedWith ["invalid-load-config"] message)
  (_, Left message) -> pure (failedWith ["invalid-measure-config"] message)
  (Right loadModel, Right baseConfig) ->
    withPgmqRun context \runtime ->
      withScenarioQueue runtime.pool context runtime.knobs "steady_state" \queue -> do
        let config = watchRelations queue baseConfig
            operation = Operation (OpName "queue-cycle") (soakCycle runtime queue)
        (_, measurement) <- withMeasurement context config (\session -> runLoad session loadModel operation)
        threadDelay 1100000
        drainQueue runtime queue
        metrics <- effect runtime (Pgmq.queueMetrics queue)
        archived <- Set.size <$> archiveKeys runtime.pool queue
        let operationFailures = sum [load.failed | load <- measurement.loads]
            queueBound = metrics.queueLength <= fromIntegral (max 100 (runtime.knobs.poolSize * 20))
            workloadReport = if operationFailures == 0 && queueBound then passed else failedWith ["soak-workload"] ("operation failures=" <> Text.pack (show operationFailures) <> ", queue length=" <> Text.pack (show metrics.queueLength))
        putSummary context Verdicts "pgmq-soak-workload" (object ["operationFailures" .= operationFailures, "queueLength" .= metrics.queueLength, "visibleLength" .= metrics.queueVisibleLength])
        putSummary context Diagnosis "pgmq-bloat" (object ["verdict" .= if queueBound then ("bounded" :: Text) else "growth", "queueRows" .= metrics.queueLength, "archiveRows" .= archived])
        leak <- judgeLeaks context (leakPolicy identifier)
        let measured = workloadReport {outcome = measuredOutcome measurement workloadReport.outcome}
        pure case leak.verdict of
          LeakSuspected -> measured {outcome = Failed, reason = Just "resource leak suspected", failures = "leak-suspected" : measured.failures}
          InsufficientData | measured.outcome == passed.outcome -> measured {outcome = Inconclusive, reason = Just "leak verdict has insufficient data"}
          _ -> measured

soakCycle :: PgmqRun -> Pgmq.QueueName -> Int -> Word64 -> IO OpResult
soakCycle runtime queue _ sequenceNumber = do
  outcome <- try @SomeException do
    _ <- effect runtime (Pgmq.sendMessage (Types.SendMessage queue (Pgmq.MessageBody (object ["k" .= sequenceNumber])) Nothing))
    messages <- effect runtime (Pgmq.readMessage (Types.ReadMessage queue 1 (Just 1) Nothing))
    case Vector.toList messages of
      [] -> pure (OpFailed (ErrorCause "empty-read-after-send"))
      message : _
        | deliberateNack sequenceNumber -> pure (OpOk 2)
        | sequenceNumber `mod` 10 == 0 -> do
            archived <- effect runtime (Pgmq.archiveMessage (Types.MessageQuery queue message.messageId))
            pure (if archived then OpOk 3 else OpFailed (ErrorCause "archive-returned-false"))
        | otherwise -> do
            deleted <- effect runtime (Pgmq.deleteMessage (Types.MessageQuery queue message.messageId))
            pure (if deleted then OpOk 3 else OpFailed (ErrorCause "delete-returned-false"))
  pure (either (OpFailed . ErrorCause . Text.pack . show) id outcome)
  where
    fraction = knobDouble runtime.ctx.knobs (knobName "pgmq.soak.nack-fraction")
    deliberateNack number = fraction > 0 && fromIntegral (number `mod` 10000) / 10000 < fraction

watchRelations :: Pgmq.QueueName -> MeasureConfig -> MeasureConfig
watchRelations queue config = config {postgres = fmap addRelations config.postgres}
  where
    suffix = Pgmq.queueNameToText queue
    addRelations postgres = postgres {relations = ["pgmq.q_" <> suffix, "pgmq.a_" <> suffix]}

leakPolicy :: Text -> LeakSpec
leakPolicy identifier
  | "reduced" `Text.isInfixOf` identifier = defaultLeakSpec {warmupCutSeconds = 60, minPoints = 10, minDurationSeconds = 900, envelopeWindowSeconds = 30}
  | otherwise = defaultLeakSpec

effect :: PgmqRun -> Effectful.Eff '[Pgmq.Pgmq, Effectful.Error.Static.Error Pgmq.PgmqRuntimeError, Effectful.IOE] value -> IO value
effect runtime action = either (ioError . userError . show) pure =<< runOps runtime.tracer runtime.pool action

drainQueue :: PgmqRun -> Pgmq.QueueName -> IO ()
drainQueue runtime queue = do
  messages <- effect runtime (Pgmq.readMessage (Types.ReadMessage queue 30 (Just 1000) Nothing))
  if Vector.null messages
    then pure ()
    else do
      _ <- effect runtime (Pgmq.batchDeleteMessages (Types.BatchMessageQuery queue (fmap (.messageId) (Vector.toList messages))))
      drainQueue runtime queue
