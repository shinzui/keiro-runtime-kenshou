module Kenshou.Suite.Keiro.Inbox.Soak (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel)
import Control.Exception (finally)
import Control.Monad (forM_, forever)
import Data.Aeson (object, (.=))
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List (partition)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Hasql.Transaction qualified as Tx
import Keiro.Inbox (garbageCollectCompleted, listInbox)
import Keiro.Integration.Event (IntegrationEvent (..))
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env qualified as Env
import Kenshou.Core.Id (Kind (..), parseScenarioId, unSeed)
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
import Kenshou.Suite.Keiro.Fixture.Runtime (FixtureEnv (..), KeiroRunner (..))
import Kenshou.Suite.Keiro.Inbox.Correctness (effectReadStatement, ensureEffectTable)
import Kenshou.Suite.Keiro.Inbox.SoakWorker qualified as SoakWorker
import Kenshou.Suite.Keiro.Messaging.Metrics (withMessagingTelemetry)
import Kenshou.Suite.Keiro.Messaging.RelationGrowth (RelationGrowth (..), deadTuplesBounded, readRelationGrowth, sizeBounded)
import Kenshou.Suite.Keiro.Messaging.SoakDiagnosis (majorGcIntervalMs, majorGcKnob, soakLeakSpec, withSoakMajorGc)
import Kenshou.Suite.Keiro.Outbox.Workload (inlineEvent, sourceName)
import Kenshou.Telemetry (telemetryKnobs, telemetrySpecFromContext)
import Kiroku.Store.Transaction qualified as KirokuTransaction
import System.Timeout (timeout)

data Stage = Early | Late deriving stock (Eq, Show)

data Scheduled = Scheduled
  { due :: !UTCTime,
    stage :: !Stage,
    event :: !IntegrationEvent
  }

scenarios :: [Scenario]
scenarios = [dedupeWindow False, dedupeWindow True]

dedupeWindow :: Bool -> Scenario
dedupeWindow reduced =
  Scenario
    { id = either (error . show) id (parseScenarioId (if reduced then "keiro/inbox/soak/dedupe-window-reduced" else "keiro/inbox/soak/dedupe-window")),
      revision = 3,
      summary = "Redelivers continuously before and after completed-row retention while GC runs, checking classification, handler effects and table growth.",
      tier = if reduced then TierExtended else TierSoak,
      placement = if reduced then PlaceEither else PlaceCell,
      knobs = telemetryKnobs <> measureKnobs Soak <> [intKnob "soak.duration-minutes" (if reduced then 20 else 240) 1 1440, intKnob "inbox.rate-per-second" 2 1 100, intKnob "inbox.retention-seconds" 120 120 120, KnobSpec (name "inbox.worker-isolation") "Consumer process isolation" KnobText (VText "in-process") (OneOf (VText "in-process" :| [VText "process"])) [VText "process"], majorGcKnob],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| [TracingNoop, TracingSdkInMemory, TracingSdkOtlp]) TracingOff),
            metrics = Supported (Support (MetricsOff :| [MetricsCollect, MetricsServe, MetricsServeScraped]) MetricsOff),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      phases = CorePhase.PhasePlan 5 (if reduced then 1200 else 14400) 5,
      requires = noEnvironment {Env.postgres = Just (PostgresRequirement [SchemaKiroku, SchemaKeiro] [("shared_preload_libraries", "'pg_stat_statements'")] False)},
      knownDefect = Nothing,
      run = runDedupeWindow
    }

runDedupeWindow :: RunContext -> IO ScenarioReport
runDedupeWindow context = case (measureConfigFromKnobs context (phasePlanFromCore (CorePhase.PhasePlan 5 (fromIntegral minutes * 60) 5)), telemetrySpecFromContext context) of
  (Left reason, _) -> pure (failedWith ["invalid-measure-config"] reason)
  (_, Left reason) -> pure (failedWith ["invalid-telemetry-config"] reason)
  (Right baseConfig, Right telemetrySpec) -> withMessagingTelemetry context telemetrySpec \fixture telemetry _ -> do
    ensureEffectTable fixture
    let KeiroRunner runFixture = fixture.runner
        source = sourceName context "dedupe-soak"
        isolated = knobText context.knobs (name "inbox.worker-isolation") == "process"
        rateInt = fromIntegral (knobInt context.knobs (name "inbox.rate-per-second")) :: Int
        rate = fromIntegral rateInt :: Double
        retention = fromIntegral (knobInt context.knobs (name "inbox.retention-seconds"))
        load = OpenLoop (OpenConfig (ConstantRate rate) 128 1 (OverloadConfig 1000000000 3 30000000000))
        config = (baseConfig :: MeasureConfig) {Measure.postgres = fmap (\pg -> pg {relations = ["keiro.keiro_inbox"]}) baseConfig.postgres}
        deliverLocal _ = SoakWorker.deliverInbox fixture telemetry
    runFixture (KirokuTransaction.runTransaction (Tx.sql "CREATE TABLE kenshou_fx.inbox_soak_deliveries (worker text NOT NULL, stage text NOT NULL, message_id text NOT NULL, classification text NOT NULL, delivered_at timestamptz NOT NULL DEFAULT clock_timestamp(), PRIMARY KEY(worker,stage,message_id))")) >>= either (fail . show) pure
    scheduled <- newIORef []
    inFlight <- newIORef (0 :: Int)
    earlyDuplicates <- newIORef (0 :: Int)
    lateProcessed <- newIORef (0 :: Int)
    classificationErrors <- newIORef (0 :: Int)
    gcErrors <- newIORef (0 :: Int)
    let enqueue deliver _ sequenceNumber = do
          now <- getCurrentTime
          let event = inlineEvent source (Text.pack (show sequenceNumber)) Nothing (fromIntegral sequenceNumber) now
              offset = fromIntegral ((unSeed context.seed + sequenceNumber) `mod` 20) :: Int
              early = Scheduled (addUTCTime (fromIntegral (50 + offset)) now) Early event
              late = Scheduled (addUTCTime (fromIntegral (170 + offset)) now) Late event
          first <- deliver "fresh" event
          case first of
            "processed" -> do
              atomicModifyIORef' scheduled (\items -> (early : late : items, ()))
              pure (OpOk 1)
            _ -> pure (OpFailed (ErrorCause "fresh-inbox-classification"))
        collect = forever do
          threadDelay 30000000
          now <- getCurrentTime
          result <- runFixture (garbageCollectCompleted retention now)
          case result of
            Left _ -> atomicModifyIORef' gcErrors (\count -> (count + 1, ()))
            Right _ -> pure ()
        redeliver deliver = forever do
          threadDelay 1000000
          now <- getCurrentTime
          due <- atomicModifyIORef' scheduled \items ->
            let (ready, pending) = partition (\item -> item.due <= now) items
             in (pending, ready)
          atomicModifyIORef' inFlight (\count -> (count + length due, ()))
          forM_ due \item -> do
            outcome <- deliver (if item.stage == Early then "early" else "late") item.event
            case (item.stage, outcome) of
              (Early, "duplicate") -> atomicModifyIORef' earlyDuplicates (\count -> (count + 1, ()))
              (Late, "processed") -> atomicModifyIORef' lateProcessed (\count -> (count + 1, ()))
              _ -> atomicModifyIORef' classificationErrors (\count -> (count + 1, ()))
            atomicModifyIORef' inFlight (\count -> (count - 1, ()))
        awaitSchedule expected = do
          pending <- readIORef scheduled
          active <- readIORef inFlight
          earlyCount <- readIORef earlyDuplicates
          lateCount <- readIORef lateProcessed
          errors <- readIORef classificationErrors
          if null pending && active == 0 && earlyCount + lateCount + errors == 2 * expected
            then pure True
            else threadDelay 1000000 >> awaitSchedule expected
    let runConsumers deliver = do
          gcWorker <- async collect
          deliveryWorker <- async (redeliver deliver)
          let shutdown = cancel deliveryWorker >> cancel gcWorker
          withSoakMajorGc
            context
            ( do
                result@(loadReport, _) <- withMeasurement context config \session -> runLoad session load (Operation (OpName "inbox.fresh") (enqueue deliver))
                drained <- timeout 240000000 (awaitSchedule (fromIntegral loadReport.completed))
                pure (result, drained)
            )
            `finally` shutdown
    (((loadReport, measurement), drained), processReport) <-
      if isolated
        then do
          (value, report) <- SoakWorker.withProcessConsumers context source runConsumers
          pure (value, Just report)
        else (,Nothing) <$> runConsumers deliverLocal
    rows <- runFixture (listInbox source) >>= either (fail . show) pure
    effects <- runFixture (KirokuTransaction.runTransaction (Tx.statement () effectReadStatement)) >>= either (fail . show) pure
    earlyCount <- readIORef earlyDuplicates
    lateCount <- readIORef lateProcessed
    classifyFailures <- readIORef classificationErrors
    gcFailures <- readIORef gcErrors
    pending <- readIORef scheduled
    growth <- readRelationGrowth context "keiro.keiro_inbox"
    let completed = fromIntegral loadReport.completed :: Int
        growthBounded = maybe False (sizeBounded (8 * 1024 * 1024)) growth
        deadBounded = maybe False (deadTuplesBounded (fromIntegral (max 1000 (rateInt * 240)))) growth
        processOutcomes = maybe [] (map leakOutcome . (.childLeaks)) processReport
        processCells = maybe [] (\report -> [("consumer-processes-stopped", report.stopped && report.errors == 0)]) processReport
        cells =
          [ ("fresh-processed", completed > 0 && loadReport.failed == 0 && not loadReport.abortedEarly),
            ("inside-window-duplicate", drained == Just True && earlyCount == completed),
            ("outside-window-reprocessed", drained == Just True && lateCount == completed),
            ("effect-count", length effects == completed + lateCount),
            ("no-delivery-or-gc-errors", classifyFailures == 0 && gcFailures == 0 && null pending),
            ("inbox-retention", length rows <= max 1000 (rateInt * 240)),
            ("table-growth", minutes < 10 || growthBounded),
            ("dead-tuple-growth", minutes < 10 || deadBounded)
          ]
            <> processCells
        duration = fromIntegral minutes * 60 :: Double
        leakSpec = soakLeakSpec context duration
    putSummary context Measurements "inbox-dedupe-window" (object ["workerIsolation" .= (if isolated then "process" :: Text else "in-process"), "workerReports" .= fmap (.workers) processReport, "fresh" .= completed, "earlyDuplicates" .= earlyCount, "lateProcessed" .= lateCount, "effects" .= length effects, "rowsRetained" .= length rows, "pending" .= length pending, "classificationErrors" .= classifyFailures, "gcErrors" .= gcFailures, "majorGcIntervalMs" .= majorGcIntervalMs context, "growth" .= fmap (\sample -> object ["earlyBytes" .= sample.earlyBytes, "lateBytes" .= sample.lateBytes, "earlyDeadTuples" .= sample.earlyDeadTuples, "lateDeadTuples" .= sample.lateDeadTuples, "sizeBounded" .= growthBounded, "deadTuplesBounded" .= deadBounded]) growth])
    base <- recordCells context cells
    leak <- judgeLeaksWithWindow context (Just (5, 5 + duration)) leakSpec
    pure (base {outcome = worstOutcome (base.outcome :| ([measuredOutcome measurement base.outcome, leakOutcome leak, if minutes >= 10 && growth == Nothing then Inconclusive else Passed] <> processOutcomes))})
  where
    minutes = fromIntegral (knobInt context.knobs (name "soak.duration-minutes")) :: Int

intKnob :: Text -> Int -> Int -> Int -> KnobSpec
intKnob key def low high = KnobSpec (name key) key KnobInt (VInt (fromIntegral def)) (IntRange (fromIntegral low) (fromIntegral high)) []

name :: Text -> KnobName
name = either (error . show) id . mkKnobName
