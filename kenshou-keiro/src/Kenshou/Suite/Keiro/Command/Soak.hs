module Kenshou.Suite.Keiro.Command.Soak (scenarios) where

import Data.Aeson (object, toJSON, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Keiro.Command (CommandResult (..), RunCommandOptions (..), defaultRunCommandOptions, runCommand)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (Kind (..), parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobInt, mkKnobName)
import Kenshou.Core.Outcome (Outcome (..), worstOutcome)
import Kenshou.Core.Phase (PhasePlan (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport (..), Tier (..), failedWith)
import Kenshou.Diagnose.Leak (LeakReport (..), LeakSpec (..), ProbeSpec (..), defaultLeakSpec, judgeLeaks, leakOutcome)
import Kenshou.Diagnose.Leak.MajorGcProbe (withMajorGcProbe)
import Kenshou.Diagnose.Series (SeriesBinding (..))
import Kenshou.Measure.Knobs (LoadDefaults (..), defaultLoadDefaults, loadKnobs, loadModelFromKnobs, measureKnobs)
import Kenshou.Measure.Load (LoadReport (..), Operation (..), runLoad)
import Kenshou.Measure.Recorder (ErrorCause (..), OpName (..), OpResult (..))
import Kenshou.Measure.Session (MeasurementReport (..), measureConfigFromKnobs, measuredOutcome, phasePlanFromCore, withMeasurement)
import Kenshou.Suite.Keiro.Command.Correctness (recordCells)
import Kenshou.Suite.Keiro.Fixture.Account
import Kenshou.Suite.Keiro.Fixture.Domain
import Kenshou.Suite.Keiro.Fixture.Model qualified as Model
import Kenshou.Suite.Keiro.Fixture.Oracle qualified as Oracle
import Kenshou.Suite.Keiro.Fixture.Runtime
import Kenshou.Telemetry (telemetryKnobs, telemetrySpecFromContext, withTelemetry)
import Kiroku.Store (appendToStream, defaultConnectionSettings)
import Kiroku.Store.Connection (ConnectionSettingsM (..))
import Kiroku.Store.Types (EventType (..), ExpectedVersion (..))
import Kiroku.Store.Types qualified as StoreTypes

scenarios :: [Scenario]
scenarios = [seedBacklog False, seedBacklog True]

seedBacklog :: Bool -> Scenario
seedBacklog reduced =
  Scenario
    { id = either (error . show) id (parseScenarioId (if reduced then "keiro/snapshot/soak/seed-verification-backlog-reduced" else "keiro/snapshot/soak/seed-verification-backlog")),
      revision = 1,
      summary = "Sustains commands against a long snapshotted stream and judges thread and connection growth.",
      tier = if reduced then TierExtended else TierSoak,
      placement = if reduced then PlaceEither else PlaceCell,
      knobs =
        telemetryKnobs
          <> loadKnobs (defaultLoadDefaults {workers = 1, thinkTimeUs = 5_000})
          <> measureKnobs Soak
          <> [ intKnob "snapshot.seed-verify-sample-rate" 1 0 1000,
               intKnob "command.stream-length" 10000 100 10000,
               intKnob "soak.duration-minutes" (if reduced then 20 else 240) 1 1440,
               intKnob "diagnose.major-gc-interval-ms" 0 0 60000
             ],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| [TracingNoop, TracingSdkInMemory, TracingSdkOtlp]) TracingOff),
            metrics = Supported (Support (MetricsOff :| [MetricsCollect, MetricsServe, MetricsServeScraped]) MetricsOff),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      phases = PhasePlan 5 (if reduced then 1200 else 14400) 5,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku, SchemaKeiro] [("shared_preload_libraries", "'pg_stat_statements'")] False)},
      knownDefect = Nothing,
      run = runSeedBacklog
    }

runSeedBacklog :: RunContext -> IO ScenarioReport
runSeedBacklog context =
  case (loadModelFromKnobs context.knobs, measureConfigFromKnobs context (phasePlanFromCore (PhasePlan 5 (fromIntegral (knobInt context.knobs (knobName "soak.duration-minutes")) * 60) 5))) of
    (Left reason, _) -> pure (failedWith ["invalid-load-config"] reason)
    (_, Left reason) -> pure (failedWith ["invalid-measure-config"] reason)
    (Right load, Right config) -> case telemetrySpecFromContext context of
      Left reason -> pure (failedWith ["invalid-telemetry-config"] reason)
      Right spec -> withTelemetry spec (runMeasured load config)
  where
    runMeasured load config telemetry = do
      runtimeTelemetry <- keiroTelemetry telemetry
      withFixtureTelemetryEnv ((defaultConnectionSettings (requirePostgres context).connectionString) {poolSize = 13}) runtimeTelemetry \fixture -> do
        let KeiroRunner runFixture = fixture.runner
            account = AccountId "seed-backlog"
            stream = accountEventStream (SnapEvery 100)
            target = accountStream account
            lengthBefore = fromIntegral (knobInt context.knobs (knobName "command.stream-length")) :: Int
            rate = fromIntegral (knobInt context.knobs (knobName "snapshot.seed-verify-sample-rate")) :: Int
            majorGcMs = fromIntegral (knobInt context.knobs (knobName "diagnose.major-gc-interval-ms")) :: Double
        let options = (keiroCommandOptions runtimeTelemetry) {seedVerifySampleRate = rate}
            seedOptions = defaultRunCommandOptions {seedVerifySampleRate = 0, verifyReplayOnAppend = False}
            accepted = \case Right (Right result) -> result.eventsAppended == 1; _ -> False
        opened <- runFixture (runCommand seedOptions stream target (OpenAccount (OpenAccountData account 0)))
        let seedEvent = StoreTypes.EventData {StoreTypes.eventId = Nothing, StoreTypes.eventType = EventType "Deposited", StoreTypes.payload = toJSON (DepositData account 1 "seed"), StoreTypes.metadata = Nothing, StoreTypes.causationId = Nothing, StoreTypes.correlationId = Nothing}
            appendBatch count =
              if count == 0
                then pure True
                else do
                  result <- runFixture (appendToStream (accountStreamName account) AnyVersion (replicate count seedEvent))
                  pure (either (const False) (const True) result)
            seedHistory version remaining
              | remaining == 0 = pure True
              | otherwise = do
                  let distance = 100 - version `mod` 100
                      direct = min remaining (distance - 1)
                  appended <- appendBatch direct
                  if not appended
                    then pure False
                    else
                      if direct == remaining
                        then pure True
                        else do
                          result <- runFixture (runCommand seedOptions stream target (Deposit (DepositData account 1 "seed")))
                          if accepted result then seedHistory (version + direct + 1) (remaining - direct - 1) else pure False
        seeded <- seedHistory 1 lengthBefore
        let operation _ _ = do
              outcome <- runFixture (runCommand options stream target (Deposit (DepositData account 1 "soak")))
              pure $ if accepted outcome then OpOk 1 else OpFailed (ErrorCause (Text.pack (show outcome)))
        -- This opt-in probe establishes post-major heap evidence; its run is diagnostic latency evidence only.
        (_, report) <- withMajorGcProbe context majorGcMs $ withMeasurement context config (\measurement -> runLoad measurement load (Operation (OpName "seed-backlog-command") operation))
        acquired <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-seed-backlog-oracle")
        connection <- either (fail . show) pure acquired
        rows <- Oracle.readCategoryLog connection "account"
        snapshots <- Oracle.readSnapshots connection
        Connection.release connection
        let completed = fromIntegral (sum [batch.completed | batch <- report.loads]) :: Int
            failures = sum [batch.failed | batch <- report.loads]
            ledgerOkay = case Oracle.modelFromLog rows of Right model -> Model.totalMoney model == lengthBefore + completed && length rows == lengthBefore + completed + 1; Left _ -> False
            latestSnapshotVersion = ((lengthBefore + completed + 1) `div` 100) * 100
            snapshotOkay = case Map.lookup (accountStreamName account) snapshots of Just (version, _) -> version == fromIntegral latestSnapshotVersion; Nothing -> False
            duration = fromIntegral (knobInt context.knobs (knobName "soak.duration-minutes")) * 60 :: Double
            leakSpec =
              defaultLeakSpec
                { probes = [if probe.name == "heap.live-bytes" && majorGcMs > 0 then probe {binding = SeriesBinding "rts-major.csv" "t_mono_ns" "live_bytes" Map.empty} else probe | probe <- defaultLeakSpec.probes],
                  warmupCutSeconds = 0,
                  minDurationSeconds = max 30 (duration * 0.7),
                  minPoints = 10,
                  envelopeWindowSeconds = max 2 (min 30 (duration / 40))
                }
        leak <- judgeLeaks context leakSpec
        putSummary context Measurements "seed-backlog" (object ["streamLength" .= lengthBefore, "sampleRate" .= rate, "completed" .= completed, "failed" .= failures, "majorGcIntervalMs" .= majorGcMs, "leakVerdict" .= show leak.verdict])
        base <- recordCells context [("stream-prepared", accepted opened && seeded), ("commands-completed", completed > 0 && failures == 0), ("snapshot-boundary", snapshotOkay), ("durable-ledger", ledgerOkay && Oracle.logWellFormed rows)]
        let healthResult = measuredOutcome report base.outcome
            finalOutcome = if healthResult == InfrastructureFailure then healthResult else worstOutcome (base.outcome :| [healthResult, leakOutcome leak])
        pure (base {outcome = finalOutcome})

intKnob :: Text.Text -> Int -> Int -> Int -> KnobSpec
intKnob key def low high = KnobSpec (knobName key) key KnobInt (VInt (fromIntegral def)) (IntRange (fromIntegral low) (fromIntegral high)) []

knobName :: Text.Text -> KnobName
knobName = either (error . show) id . mkKnobName
