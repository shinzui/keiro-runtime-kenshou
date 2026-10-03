module Kenshou.Suite.Keiro.Queue.Soak (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, wait)
import Control.Exception (finally)
import Control.Monad (forM, forever, unless)
import Data.Aeson (object, (.=))
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (liftIO)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Keiro.PGMQ.Codec (aesonJobCodec)
import Keiro.PGMQ.Dlq (PurgeDlqResult (..), archiveDlq, purgeDlq)
import Keiro.PGMQ.Job (Job (..), JobOrdering (..), JobOutcome (..), JobPolling (..), JobTuning (..), defaultJobTuning, defaultRetryPolicy, enqueue, enqueueTraced, ensureJobQueue, runJobOnceWithContext)
import Keiro.PGMQ.Runtime (JobRuntime (..), QueueRef (..), queueRef, runJobEff, withJobRuntime)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env qualified as Env
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (Kind (..), parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobInt, knobText, mkKnobName)
import Kenshou.Core.Outcome (Outcome (..), worstOutcome)
import Kenshou.Core.Phase qualified as CorePhase
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport (..), Tier (..), failedWith)
import Kenshou.Diagnose.Leak (judgeLeaksWithWindow, leakOutcome)
import Kenshou.Measure.Knobs (measureKnobs)
import Kenshou.Measure.Load (Arrival (..), LoadModel (..), LoadReport (..), OpenConfig (..), Operation (..), OverloadConfig (..), runLoad)
import Kenshou.Measure.Recorder (ErrorCause (..), OpName (..), OpResult (..))
import Kenshou.Measure.Sampler.Postgres (PgSamplerConfig (..))
import Kenshou.Measure.Session (MeasureConfig (..), measureConfigFromKnobs, measuredOutcome, phasePlanFromCore, withMeasurement)
import Kenshou.Measure.Session qualified as Measure
import Kenshou.Suite.Keiro.Command.Correctness (recordCells)
import Kenshou.Suite.Keiro.Messaging.RelationGrowth (RelationGrowth (..), bytesPerInsertedRow, deadTuplesBounded, readRelationGrowth, sizeBounded)
import Kenshou.Suite.Keiro.Messaging.SoakDiagnosis (majorGcIntervalMs, majorGcKnob, soakLeakSpec, withSoakMajorGc)
import Kenshou.Suite.Keiro.Outbox.Workload (sourceName)
import Kenshou.Suite.Keiro.Queue.SoakWorker qualified as SoakWorker
import Kenshou.Telemetry (TelemetryHandles (..), telemetryKnobs, telemetrySpecFromContext, withTelemetry)
import Pgmq.Types (MessageHeaders (..), queueNameToText)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [queueGrowth False, queueGrowth True]

queueGrowth :: Bool -> Scenario
queueGrowth reduced =
  Scenario
    { id = either (error . show) id (parseScenarioId (if reduced then "keiro/queue/soak/queue-and-dlq-growth-reduced" else "keiro/queue/soak/queue-and-dlq-growth")),
      revision = 3,
      summary = "Continuously processes jobs with terminal poison messages, checking bounded main queue, exact DLQ placement and optional DLQ archiving.",
      tier = if reduced then TierExtended else TierSoak,
      placement = if reduced then PlaceEither else PlaceCell,
      knobs = telemetryKnobs <> measureKnobs Soak <> [intKnob "soak.duration-minutes" (if reduced then 20 else 240) 1 1440, intKnob "queue.rate-per-second" 5 1 100, intKnob "queue.dead-every" 20 2 1000, textKnob "queue.dlq-maintenance" "on" ["off"], textKnob "queue.worker-isolation" "in-process" ["process"], majorGcKnob],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| [TracingNoop, TracingSdkInMemory, TracingSdkOtlp]) TracingOff),
            metrics = Supported (Support (MetricsOff :| [MetricsCollect, MetricsServe, MetricsServeScraped]) MetricsOff),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      phases = CorePhase.PhasePlan 5 (if reduced then 1200 else 14400) 5,
      requires = noEnvironment {Env.postgres = Just (PostgresRequirement [SchemaPgmq] [("shared_preload_libraries", "'pg_stat_statements'")] False)},
      knownDefect = Nothing,
      run = runQueueGrowth
    }

runQueueGrowth :: RunContext -> IO ScenarioReport
runQueueGrowth context = case (measureConfigFromKnobs context (phasePlanFromCore (CorePhase.PhasePlan 5 (fromIntegral minutes * 60) 5)), telemetrySpecFromContext context) of
  (Left reason, _) -> pure (failedWith ["invalid-measure-config"] reason)
  (_, Left reason) -> pure (failedWith ["invalid-telemetry-config"] reason)
  (Right baseConfig, Right telemetrySpec) -> withTelemetry telemetrySpec \telemetry ->
    withJobRuntime (requirePostgres context).connectionString telemetry.tracer \runtime -> do
      let job = Job "queue-growth" (queueRef (sourceName context "queue-growth")) (aesonJobCodec @Text) Unordered defaultRetryPolicy
          mainTable = "pgmq.q_" <> queueNameToText job.jobQueue.physicalName
          dlqTable = "pgmq.q_" <> queueNameToText job.jobQueue.dlqName
          archiveTable = "pgmq.a_" <> queueNameToText job.jobQueue.dlqName
          rateInt = fromIntegral (knobInt context.knobs (name "queue.rate-per-second")) :: Int
          deadEvery = fromIntegral (knobInt context.knobs (name "queue.dead-every")) :: Int
          isolated = knobText context.knobs (name "queue.worker-isolation") == "process"
          maintenance = knobText context.knobs (name "queue.dlq-maintenance") == "on"
          load = OpenLoop (OpenConfig (ConstantRate (fromIntegral rateInt)) 128 1 (OverloadConfig 1000000000 3 30000000000))
          tuning = defaultJobTuning {polling = PollEvery 0.1, visibilityTimeout = 30}
          config = (baseConfig :: MeasureConfig) {Measure.postgres = fmap (\pg -> pg {relations = [mainTable, dlqTable]}) baseConfig.postgres}
          countRows table = do
            let statement = Statement.preparable ("SELECT count(*) FROM " <> table) Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))
            Pool.use runtime.runtimePool (Session.statement () statement) >>= either (fail . show) pure
          effectInsert = Statement.preparable "INSERT INTO kenshou_fx.queue_soak_effects (payload, attempts) VALUES ($1, 1) ON CONFLICT (payload) DO UPDATE SET attempts = kenshou_fx.queue_soak_effects.attempts + 1" (Encoders.param (Encoders.nonNullable Encoders.text)) Decoders.noResult
          effectRows = do
            let statement = Statement.preparable "SELECT payload, attempts FROM kenshou_fx.queue_soak_effects" Encoders.noParams (Decoders.rowList ((,) <$> Decoders.column (Decoders.nonNullable Decoders.text) <*> Decoders.column (Decoders.nonNullable Decoders.int4)))
            Pool.use runtime.runtimePool (Session.statement () statement) >>= either (fail . show) pure
      Pool.use runtime.runtimePool (Session.script "CREATE SCHEMA IF NOT EXISTS kenshou_fx; CREATE TABLE kenshou_fx.queue_soak_effects (payload text PRIMARY KEY, attempts integer NOT NULL, worker text NOT NULL DEFAULT 'in-process')") >>= either (fail . show) pure
      _ <- runJobEff runtime (ensureJobQueue job) >>= either (fail . show) pure
      workerErrors <- newIORef (0 :: Int)
      maintenanceErrors <- newIORef (0 :: Int)
      archivedByMaintenance <- newIORef (0 :: Int)
      peakDepth <- newIORef (0 :: Int64)
      stop <- newIORef False
      let enqueueOne _ sequenceNumber = do
            let poison = fromIntegral sequenceNumber `mod` deadEvery == (0 :: Int)
                payload = (if poison then "dead:" else "done:") <> Text.pack (show sequenceNumber)
            sent <- runJobEff runtime (case telemetry.tracerProvider of Nothing -> enqueue job payload; Just provider -> enqueueTraced provider job (MessageHeaders (object [])) payload)
            case sent of
              Right _ -> pure (OpOk 1)
              Left err -> pure (OpFailed (ErrorCause (Text.pack (show err))))
          handler _ payload = do
            liftIO (Pool.use runtime.runtimePool (Session.statement payload effectInsert) >>= either (fail . show) pure)
            pure (if Text.isPrefixOf "dead:" payload then Dead "soak-poison" else Done)
          worker = do
            halted <- readIORef stop
            unless halted do
              result <- runJobEff runtime (runJobOnceWithContext tuning 10 job handler)
              case result of
                Left _ -> atomicModifyIORef' workerErrors (\count -> (count + 1, ())) >> threadDelay 100000
                Right 0 -> threadDelay 10000
                Right _ -> pure ()
              worker
          collect = do
            halted <- readIORef stop
            unless halted do
              threadDelay 15000000
              haltedAfterWait <- readIORef stop
              unless haltedAfterWait do
                result <- runJobEff runtime (archiveDlq job 100000)
                case result of
                  Left _ -> atomicModifyIORef' maintenanceErrors (\count -> (count + 1, ()))
                  Right count -> atomicModifyIORef' archivedByMaintenance (\total -> (total + count, ()))
                collect
          sampleDepth = forever do
            threadDelay 5000000
            depth <- countRows mainTable
            atomicModifyIORef' peakDepth (\peak -> (max peak depth, ()))
          awaitDrain :: Int -> IO Bool
          awaitDrain expected = do
            seen <- countRows "kenshou_fx.queue_soak_effects"
            depth <- countRows mainTable
            if seen == fromIntegral expected && depth == 0
              then pure True
              else threadDelay 1000000 >> awaitDrain expected
      workers <- if isolated then pure [] else forM [1 .. 2 :: Int] (const (async worker))
      collector <- if maintenance then Just <$> async collect else pure Nothing
      depthSampler <- async sampleDepth
      let shutdown = writeIORef stop True >> mapM_ cancel workers >> maybe (pure ()) wait collector >> cancel depthSampler
      let withWorkers action =
            if isolated
              then do
                (value, report) <- SoakWorker.withProcessWorkers context (sourceName context "queue-growth") action
                pure (value, Just report)
              else (,Nothing) <$> action
      (((loadReport, measurement), drained), processReport) <-
        ( withWorkers $ withSoakMajorGc context do
            result@(loadReport, _) <- withMeasurement context config \session -> runLoad session load (Operation (OpName "queue.enqueue") enqueueOne)
            drained <- timeout 120000000 (awaitDrain (fromIntegral loadReport.completed))
            pure (result, drained)
        )
          `finally` shutdown
      finalArchive <- if maintenance then runJobEff runtime (archiveDlq job 100000) >>= either (fail . show) pure else pure 0
      purged <- if maintenance then Just <$> (runJobEff runtime (purgeDlq job) >>= either (fail . show) pure) else pure Nothing
      effects <- effectRows
      mainDepth <- countRows mainTable
      dlqDepth <- countRows dlqTable
      archiveDepth <- countRows archiveTable
      maxDepth <- readIORef peakDepth
      errors <- readIORef workerErrors
      gcErrors <- readIORef maintenanceErrors
      archivedDuring <- readIORef archivedByMaintenance
      mainGrowth <- readRelationGrowth context mainTable
      dlqGrowth <- readRelationGrowth context dlqTable
      let completed = fromIntegral loadReport.completed :: Int
          expected = Set.fromList [(if index `mod` deadEvery == 0 then "dead:" else "done:") <> Text.pack (show index) | index <- [0 .. completed - 1]]
          deadExpected = length [index | index <- [0 .. completed - 1], index `mod` deadEvery == 0]
          mainBounded = maybe False (sizeBounded (8 * 1024 * 1024)) mainGrowth
          dlqBounded = maybe False (sizeBounded (8 * 1024 * 1024)) dlqGrowth
          deadTuplesBoundedMain = maybe False (deadTuplesBounded (fromIntegral (max 1000 (rateInt * 60)))) mainGrowth
          deadTuplesBoundedDlq = maybe False (deadTuplesBounded (fromIntegral (max 1000 (rateInt * 60)))) dlqGrowth
          processOutcomes = maybe [] (map leakOutcome . (.childLeaks)) processReport
          processCells = maybe [] (\report -> [("worker-processes-stopped", report.stopped && report.errors == 0)]) processReport
          cells =
            [ ("enqueue-load-completed", completed > 0 && loadReport.failed == 0 && not loadReport.abortedEarly),
              ("all-jobs-handled-once", drained == Just True && length effects == completed && Set.fromList (map fst effects) == expected && all ((== 1) . snd) effects),
              ("main-queue-bounded", mainDepth == 0 && maxDepth <= fromIntegral (max 100 (rateInt * 30))),
              ("exact-dead-placement", if maintenance then dlqDepth == 0 && archiveDepth == fromIntegral deadExpected && archivedDuring + finalArchive == deadExpected else dlqDepth == fromIntegral deadExpected && archiveDepth == 0),
              ("no-worker-or-maintenance-errors", errors == 0 && gcErrors == 0 && (purged == Nothing || purged == Just (PurgeDlqPurged 0))),
              ("main-table-growth", minutes < 10 || mainBounded),
              ("main-dead-tuple-growth", minutes < 10 || deadTuplesBoundedMain),
              ("dlq-table-growth", minutes < 10 || not maintenance || dlqBounded),
              ("dlq-dead-tuple-growth", minutes < 10 || not maintenance || deadTuplesBoundedDlq)
            ]
              <> processCells
          duration = fromIntegral minutes * 60 :: Double
          leakSpec = soakLeakSpec context duration
          growthSummary sample = object ["earlyBytes" .= sample.earlyBytes, "lateBytes" .= sample.lateBytes, "earlyDeadTuples" .= sample.earlyDeadTuples, "lateDeadTuples" .= sample.lateDeadTuples, "bytesPerInsertedRow" .= bytesPerInsertedRow sample]
      putSummary context Measurements "queue-and-dlq-growth" (object ["workerIsolation" .= (if isolated then "process" :: Text else "in-process"), "workerReports" .= fmap (.workers) processReport, "enqueued" .= completed, "handled" .= length effects, "deadExpected" .= deadExpected, "mainDepth" .= mainDepth, "peakMainDepth" .= maxDepth, "dlqDepth" .= dlqDepth, "dlqArchiveDepth" .= archiveDepth, "archivedDuringSteady" .= archivedDuring, "archivedAtEnd" .= finalArchive, "maintenance" .= maintenance, "purged" .= show purged, "workerErrors" .= errors, "maintenanceErrors" .= gcErrors, "majorGcIntervalMs" .= majorGcIntervalMs context, "mainGrowth" .= fmap growthSummary mainGrowth, "dlqGrowth" .= fmap growthSummary dlqGrowth])
      base <- recordCells context cells
      leak <- judgeLeaksWithWindow context (Just (5, 5 + duration)) leakSpec
      pure (base {outcome = worstOutcome (base.outcome :| ([measuredOutcome measurement base.outcome, leakOutcome leak, if minutes >= 10 && (mainGrowth == Nothing || (maintenance && dlqGrowth == Nothing)) then Inconclusive else Passed] <> processOutcomes))})
  where
    minutes = fromIntegral (knobInt context.knobs (name "soak.duration-minutes")) :: Int

intKnob :: Text -> Int -> Int -> Int -> KnobSpec
intKnob key def low high = KnobSpec (name key) key KnobInt (VInt (fromIntegral def)) (IntRange (fromIntegral low) (fromIntegral high)) []

textKnob :: Text -> Text -> [Text] -> KnobSpec
textKnob key def alternatives = KnobSpec (name key) key KnobText (VText def) (OneOf (VText def :| map VText alternatives)) (map VText alternatives)

name :: Text -> KnobName
name = either (error . show) id . mkKnobName
