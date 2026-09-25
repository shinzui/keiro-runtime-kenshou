module Kenshou.Suite.Pgmq.Soak.Runner (runSoak) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Data.Aeson (object, (.=))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Data.Vector qualified as Vector
import Data.Word (Word64)
import Effectful qualified
import Effectful.Error.Static qualified
import Hasql.Pool qualified as Pool
import Kenshou.Core.Context (ArtifactDir (SeriesDir), RunContext (..), SummarySection (Diagnosis, Verdicts), artifactPath, declareMediaType, putSummary)
import Kenshou.Core.Knob (knobDouble, knobInt)
import Kenshou.Core.Outcome (Outcome (Failed, Inconclusive))
import Kenshou.Core.Scenario (ScenarioReport (..), failedWith, passed)
import Kenshou.Diagnose.Leak (Aggregation (WindowMedian), Expectation (Bounded), LeakReport (..), LeakSpec (..), LeakVerdict (..), ProbeSpec (..), defaultLeakSpec, judgeLeaks)
import Kenshou.Diagnose.Leak.MajorGcProbe (withMajorGcProbe)
import Kenshou.Diagnose.Series (SeriesBinding (..))
import Kenshou.Measure.Knobs (loadModelFromKnobs)
import Kenshou.Measure.Load (LoadReport (..), Operation (..), runLoad)
import Kenshou.Measure.Recorder (ErrorCause (..), OpName (..), OpResult (..))
import Kenshou.Measure.Sampler (Sampler (..))
import Kenshou.Measure.Sampler.Postgres (PgSamplerConfig (..))
import Kenshou.Measure.Session (MeasureConfig (..), MeasurementReport (..), measureConfigFromKnobs, measuredOutcome, phasePlanFromCore, withMeasurement)
import Kenshou.Suite.Pgmq.Harness
import Kenshou.Suite.Pgmq.Knobs (PgmqKnobs (..), knobName)
import Kenshou.Suite.Pgmq.Oracle (archiveKeys)
import Pgmq.Effectful qualified as Pgmq
import Pgmq.Hasql.Sessions qualified as Sessions
import Pgmq.Hasql.Statements.Types qualified as Types
import Pgmq.Types qualified as PgmqTypes
import System.IO (BufferMode (LineBuffering), IOMode (WriteMode), hSetBuffering, withFile)

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
        let operation = Operation (OpName "queue-cycle") (soakCycle runtime queue)
            majorGcMs = fromIntegral (knobInt context.knobs (knobName "pgmq.soak.major-gc-interval-ms")) :: Double
        (_, measurement) <- withMajorGcProbe context majorGcMs $ withQueueDepthSeries context runtime queue baseConfig \config -> withMeasurement context config (\session -> runLoad session loadModel operation)
        threadDelay 1100000
        drainQueue runtime queue
        metrics <- effect runtime (Pgmq.queueMetrics queue)
        archived <- Set.size <$> archiveKeys runtime.pool queue
        let operationFailures = sum [load.failed | load <- measurement.loads]
            queueBound = metrics.queueLength <= fromIntegral (max 100 (runtime.knobs.poolSize * 20))
            workloadReport = if operationFailures == 0 && queueBound then passed else failedWith ["soak-workload"] ("operation failures=" <> Text.pack (show operationFailures) <> ", queue length=" <> Text.pack (show metrics.queueLength))
        putSummary context Verdicts "pgmq-soak-workload" (object ["operationFailures" .= operationFailures, "queueLength" .= metrics.queueLength, "visibleLength" .= metrics.queueVisibleLength])
        putSummary context Diagnosis "pgmq-bloat" (object ["verdict" .= if queueBound then ("bounded" :: Text) else "growth", "queueRows" .= metrics.queueLength, "archiveRows" .= archived])
        leak <- judgeLeaks context (leakPolicy identifier majorGcMs)
        let measured = workloadReport {outcome = measuredOutcome measurement workloadReport.outcome}
        pure case leak.verdict of
          LeakSuspected -> measured {outcome = Failed, reason = Just "resource leak suspected", failures = "leak-suspected" : measured.failures}
          InsufficientData | measured.outcome == passed.outcome -> measured {outcome = Inconclusive, reason = Just "leak verdict has insufficient data"}
          _ -> measured

soakCycle :: PgmqRun -> Pgmq.QueueName -> Int -> Word64 -> IO OpResult
soakCycle runtime queue _ sequenceNumber = do
  outcome <- try @SomeException do
    _ <- effect runtime (Pgmq.sendMessage (Types.SendMessage queue (Pgmq.MessageBody (object ["k" .= sequenceNumber])) Nothing))
    messages <- effect runtime (Pgmq.readMessage (Types.ReadMessage queue 1 (Just (max 2 runtime.knobs.batchSize)) Nothing))
    acknowledgements <- traverse acknowledge (Vector.toList messages)
    let failures = [cause | Left cause <- acknowledgements]
        acknowledged = length [() | Right True <- acknowledgements]
    pure case failures of
      cause : _ -> OpFailed cause
      [] -> OpOk (1 + acknowledged)
  pure (either (OpFailed . ErrorCause . Text.pack . show) id outcome)
  where
    fraction = knobDouble runtime.ctx.knobs (knobName "pgmq.soak.nack-fraction")
    messageNumber :: PgmqTypes.Message -> Integer
    messageNumber = fromIntegral . PgmqTypes.unMessageId . (.messageId)
    deliberateNack message = message.readCount == 1 && fraction > 0 && fromIntegral (messageNumber message `mod` 10000) / 10000 < fraction
    acknowledge message
      | deliberateNack message = pure (Right False)
      | messageNumber message `mod` 10 == 0 = do
          archived <- effect runtime (Pgmq.archiveMessage (Types.MessageQuery queue message.messageId))
          pure (if archived then Right True else Left (ErrorCause "archive-returned-false"))
      | otherwise = do
          deleted <- effect runtime (Pgmq.deleteMessage (Types.MessageQuery queue message.messageId))
          pure (if deleted then Right True else Left (ErrorCause "delete-returned-false"))

watchRelations :: Pgmq.QueueName -> MeasureConfig -> MeasureConfig
watchRelations queue config = config {postgres = fmap addRelations config.postgres}
  where
    suffix = Pgmq.queueNameToText queue
    addRelations postgres = postgres {relations = ["pgmq.q_" <> suffix, "pgmq.a_" <> suffix]}

withQueueDepthSeries :: RunContext -> PgmqRun -> Pgmq.QueueName -> MeasureConfig -> (MeasureConfig -> IO value) -> IO value
withQueueDepthSeries context runtime queue baseConfig action = do
  path <- artifactPath context SeriesDir "pgmq-queue-depth.csv"
  declareMediaType context "series/pgmq-queue-depth.csv" "text/csv"
  withFile path WriteMode \handle -> do
    hSetBuffering handle LineBuffering
    Text.IO.hPutStrLn handle "t_mono_ns,t_wall_ms,phase,queue_length,visible_length,total_messages,oldest_age_seconds,default_partition_length"
    let sampler =
          Sampler
            "pgmq-queue-depth"
            ( \prefix -> do
                sampled <- Pool.use runtime.pool (Sessions.queueMetrics queue)
                case sampled of
                  Left err -> Text.IO.hPutStrLn handle (Text.intercalate "," (prefix <> ["error:" <> Text.pack (show err), "", "", "", ""]))
                  Right metrics ->
                    Text.IO.hPutStrLn
                      handle
                      ( Text.intercalate
                          ","
                          ( prefix
                              <> [ Text.pack (show metrics.queueLength),
                                   Text.pack (show metrics.queueVisibleLength),
                                   Text.pack (show metrics.totalMessages),
                                   maybe "" (Text.pack . show) metrics.oldestMsgAgeSec,
                                   maybe "" (Text.pack . show) metrics.defaultPartitionLength
                                 ]
                          )
                      )
            )
        config = watchRelations queue baseConfig {extraSamplers = sampler : baseConfig.extraSamplers}
    action config

leakPolicy :: Text -> Double -> LeakSpec
leakPolicy identifier majorGcMs =
  LeakSpec
    (fmap heapBinding base.probes <> [queueDepthProbe])
    base.warmupCutSeconds
    base.minPoints
    base.minDurationSeconds
    base.envelopeWindowSeconds
    base.resamples
    base.confidence
  where
    heapBinding probe
      | probe.name == "heap.live-bytes" && majorGcMs > 0 = probe {binding = SeriesBinding "rts-major.csv" "t_mono_ns" "live_bytes" Map.empty}
      | otherwise = probe
    base
      | "reduced" `Text.isInfixOf` identifier = defaultLeakSpec {warmupCutSeconds = 60, minPoints = 10, minDurationSeconds = 900, envelopeWindowSeconds = 30}
      | otherwise = defaultLeakSpec
    queueDepthProbe =
      ProbeSpec
        "pgmq.queue-depth"
        "count"
        (SeriesBinding "pgmq-queue-depth.csv" "t_mono_ns" "queue_length" (Map.singleton "phase" "steady"))
        WindowMedian
        Bounded
        1
        20
        0.1
        Nothing

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
