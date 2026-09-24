module Kenshou.Suite.Keiro.Command.Bench (scenarios) where

import Data.Aeson (object, toJSON, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Keiro.Command (CommandError (..), CommandResult (..), RunCommandOptions (..), defaultRunCommandOptions, runCommand, runCommandWithSql)
import Keiro.Projection (runCommandWithProjections)
import Keiro.Telemetry (newKeiroMetrics)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (Kind (..), parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobBool, knobInt, knobText, mkKnobName)
import Kenshou.Core.Phase (PhasePlan (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport (..), Tier (..), failedWith)
import Kenshou.Measure.Knobs (LoadDefaults (..), defaultLoadDefaults, loadKnobs, loadModelFromKnobs, measureKnobs)
import Kenshou.Measure.Load (ClosedConfig (..), LoadModel (..), LoadReport (..), Operation (..), runLoad)
import Kenshou.Measure.Recorder (ErrorCause (..), OpName (..), OpResult (..))
import Kenshou.Measure.Session (MeasurementReport (..), measureConfigFromKnobs, measuredOutcome, phasePlanFromCore, withMeasurement)
import Kenshou.Suite.Keiro.Command.Correctness (recordCells)
import Kenshou.Suite.Keiro.Fixture.Account
import Kenshou.Suite.Keiro.Fixture.Domain
import Kenshou.Suite.Keiro.Fixture.Model qualified as Model
import Kenshou.Suite.Keiro.Fixture.Oracle qualified as Oracle
import Kenshou.Suite.Keiro.Fixture.Projection (accountBalanceProjection, ensureFixtureReadModels)
import Kenshou.Suite.Keiro.Fixture.Runtime
import Kenshou.Telemetry (TelemetryHandles (..), telemetryKnobs, telemetrySpecFromContext, withTelemetry)
import Kiroku.Store (appendToStream, defaultConnectionSettings)
import Kiroku.Store.Connection (ConnectionSettingsM (..))
import Kiroku.Store.Types (EventType (..), ExpectedVersion (..))
import Kiroku.Store.Types qualified as StoreTypes

scenarios :: [Scenario]
scenarios = [throughputLatency, hydrationCost, allStreamAppendCeiling]

allStreamAppendCeiling :: Scenario
allStreamAppendCeiling =
  throughputLatency
    { id = either (error . show) id (parseScenarioId "keiro/command/benchmark/all-stream-append-ceiling"),
      summary = "Measures independent account writers contending only on the global append position.",
      knobs =
        telemetryKnobs
          <> loadKnobs (defaultLoadDefaults {workers = 8})
          <> measureKnobs Benchmark
          <> [ intKnob "command.writers" 8 1 64,
               intKnob "kiroku.pool-size" 13 1 64,
               intKnob "command.duration-seconds" 120 1 3600
             ],
      run = runCommandBenchmark True
    }

hydrationCost :: Scenario
hydrationCost =
  throughputLatency
    { id = either (error . show) id (parseScenarioId "keiro/command/benchmark/hydration-cost"),
      summary = "Measures command hydration against a selected stream length, snapshot policy, and read page size.",
      knobs =
        telemetryKnobs
          <> loadKnobs (defaultLoadDefaults {workers = 1})
          <> measureKnobs Benchmark
          <> [ intKnob "command.stream-length" 1000 0 10000,
               KnobSpec (knobName "snapshot.policy") "Snapshot policy" KnobText (VText "never") (OneOf (VText "never" :| [VText "every-100"])) [],
               intKnob "command.page-size" 256 1 1024,
               intKnob "command.duration-seconds" 120 1 3600
             ],
      run = runHydrationCost
    }

runHydrationCost :: RunContext -> IO ScenarioReport
runHydrationCost context =
  case (loadModelFromKnobs context.knobs, measureConfigFromKnobs context (phasePlanFromCore (PhasePlan 5 (fromIntegral (knobInt context.knobs (knobName "command.duration-seconds"))) 5))) of
    (Left reason, _) -> pure (failedWith ["invalid-load-config"] reason)
    (_, Left reason) -> pure (failedWith ["invalid-measure-config"] reason)
    (Right configuredLoad, Right config) -> case telemetrySpecFromContext context of
      Left reason -> pure (failedWith ["invalid-telemetry-config"] reason)
      Right telemetrySpec -> withTelemetry telemetrySpec \telemetry ->
        withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
          let KeiroRunner runFixture = fixture.runner
              account = AccountId "hydration-bench"
              streamLength = fromIntegral (knobInt context.knobs (knobName "command.stream-length")) :: Int
              page = fromIntegral (knobInt context.knobs (knobName "command.page-size"))
              policyName = knobText context.knobs (knobName "snapshot.policy")
              eventStream = accountEventStream (if policyName == "never" then SnapNever else SnapEvery 100)
          keiroMetrics <- traverse newKeiroMetrics telemetry.meter
          let options = defaultRunCommandOptions {pageSize = page, verifyReplayOnAppend = False, tracer = telemetry.tracer, metrics = keiroMetrics}
              target = accountStream account
          opened <- runFixture (runCommand options eventStream target (OpenAccount (OpenAccountData account 1)))
          let seedEvent = StoreTypes.EventData {StoreTypes.eventId = Nothing, StoreTypes.eventType = EventType "Deposited", StoreTypes.payload = toJSON (DepositData account 1 "seed"), StoreTypes.metadata = Nothing, StoreTypes.causationId = Nothing, StoreTypes.correlationId = Nothing}
              appendBatch count =
                if count == 0
                  then pure True
                  else do
                    result <- runFixture (appendToStream (accountStreamName account) AnyVersion (replicate count seedEvent))
                    pure (either (const False) (const True) result)
              seedHistory version remaining
                | remaining == 0 = pure True
                | policyName == "never" = do
                    let batch = min 1000 remaining
                    accepted <- appendBatch batch
                    if accepted then seedHistory (version + batch) (remaining - batch) else pure False
                | otherwise = do
                    let distance = 100 - version `mod` 100
                        direct = min remaining (distance - 1)
                    accepted <- appendBatch direct
                    if not accepted
                      then pure False
                      else
                        if direct == remaining
                          then pure True
                          else do
                            snapshotCommand <- runFixture (runCommand options eventStream target (Deposit (DepositData account 1 "seed")))
                            case snapshotCommand of
                              Right (Right result) | result.eventsAppended == 1 -> seedHistory (version + direct + 1) (remaining - direct - 1)
                              _ -> pure False
          historySeeded <- seedHistory 1 streamLength
          let operation _ _ = do
                result <- runFixture (runCommand options eventStream target (CloseAccount (CloseAccountData account)))
                pure case result of
                  Right (Left CommandRejected) -> OpOk 1
                  other -> OpFailed (ErrorCause (Text.pack (show other)))
              oneWriter = case configuredLoad of
                ClosedLoop closed -> ClosedLoop (closed {workers = 1})
                other -> other
          (_, report) <- withMeasurement context config (\measurement -> runLoad measurement oneWriter (Operation (OpName "hydrate-command") operation))
          acquired <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-hydration-bench-oracle")
          connection <- either (fail . show) pure acquired
          rows <- Oracle.readCategoryLog connection "account"
          snapshots <- Oracle.readSnapshots connection
          Connection.release connection
          let completions = sum [batch.completed | batch <- report.loads]
              failures = sum [batch.failed | batch <- report.loads]
              seededOk = case opened of Right (Right response) -> response.eventsAppended == 1 && historySeeded; _ -> False
              modelOk = case Oracle.modelFromLog rows of Right model -> Model.totalMoney model == 1 + streamLength && length rows == streamLength + 1; Left _ -> False
              snapshotOk =
                let expectedVersion = ((streamLength + 1) `div` 100) * 100
                 in if policyName == "never" || expectedVersion == 0
                      then Map.notMember (accountStreamName account) snapshots
                      else case Map.lookup (accountStreamName account) snapshots of Just (version, _) -> version == fromIntegral expectedVersion; Nothing -> False
          putSummary context Measurements "hydration-cost" (object ["streamLength" .= streamLength, "snapshotPolicy" .= policyName, "pageSize" .= page, "completed" .= completions, "failed" .= failures])
          base <- recordCells context [("stream-prepared", seededOk), ("snapshot-policy-prepared", snapshotOk), ("commands-completed", completions > 0 && failures == 0), ("durable-ledger", Oracle.logWellFormed rows && modelOk)]
          pure (base {outcome = measuredOutcome report base.outcome})

throughputLatency :: Scenario
throughputLatency =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/command/benchmark/throughput-latency"),
      revision = 1,
      summary = "Measures concurrent command throughput and latency, then checks the durable ledger.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs =
        telemetryKnobs
          <> loadKnobs (defaultLoadDefaults {workers = 8})
          <> measureKnobs Benchmark
          <> [ intKnob "command.writers" 8 1 128,
               intKnob "command.accounts" 1000 1 10000,
               intKnob "kiroku.pool-size" 10 1 128,
               KnobSpec (knobName "command.runner") "Command execution path" KnobText (VText "plain") (OneOf (VText "plain" :| [VText "with-sql", VText "with-inline-projection"])) [],
               KnobSpec (knobName "snapshot.policy") "Snapshot policy" KnobText (VText "every-100") (OneOf (VText "never" :| [VText "every-100"])) [],
               intKnob "command.memo-bytes" 64 0 65536,
               KnobSpec (knobName "command.verify-replay-on-append") "Verify replay on append" KnobBool (VBool True) AnyValue [],
               intKnob "command.duration-seconds" 120 1 3600
             ],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| [TracingNoop, TracingSdkInMemory, TracingSdkOtlp]) TracingOff),
            metrics = Supported (Support (MetricsOff :| [MetricsCollect, MetricsServe, MetricsServeScraped]) MetricsOff),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      phases = PhasePlan 5 120 5,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku, SchemaKeiro] [("shared_preload_libraries", "'pg_stat_statements'")] False)},
      knownDefect = Nothing,
      run = runCommandBenchmark False
    }

runCommandBenchmark :: Bool -> RunContext -> IO ScenarioReport
runCommandBenchmark isCeiling context =
  case (loadModelFromKnobs context.knobs, measureConfigFromKnobs context (phasePlanFromCore (PhasePlan 5 (fromIntegral (knobInt context.knobs (knobName "command.duration-seconds"))) 5))) of
    (Left reason, _) -> pure (failedWith ["invalid-load-config"] reason)
    (_, Left reason) -> pure (failedWith ["invalid-measure-config"] reason)
    (Right configuredLoad, Right config) -> case telemetrySpecFromContext context of
      Left reason -> pure (failedWith ["invalid-telemetry-config"] reason)
      Right telemetrySpec -> withTelemetry telemetrySpec \telemetry ->
        withFixtureEnv ((defaultConnectionSettings (requirePostgres context).connectionString) {poolSize = fromIntegral (knobInt context.knobs (knobName "kiroku.pool-size"))}) \fixture -> do
          let KeiroRunner runFixture = fixture.runner
              writers = fromIntegral (knobInt context.knobs (knobName "command.writers")) :: Int
              accounts = if isCeiling then writers else fromIntegral (knobInt context.knobs (knobName "command.accounts")) :: Int
              account index = AccountId ("bench-" <> Text.pack (show index))
              policyName = if isCeiling then "every-100" else knobText context.knobs (knobName "snapshot.policy")
              runnerName = if isCeiling then "plain" else knobText context.knobs (knobName "command.runner")
              memoBytes = if isCeiling then 5 else fromIntegral (knobInt context.knobs (knobName "command.memo-bytes")) :: Int
              eventStream = accountEventStream (if policyName == "never" then SnapNever else SnapEvery 100)
              load = case configuredLoad of
                ClosedLoop closed -> ClosedLoop (closed {workers = writers})
                other -> other
          keiroMetrics <- traverse newKeiroMetrics telemetry.meter
          let options = defaultRunCommandOptions {tracer = telemetry.tracer, metrics = keiroMetrics, verifyReplayOnAppend = isCeiling || knobBool context.knobs (knobName "command.verify-replay-on-append")}
              submit target command = case runnerName of
                "with-sql" -> runFixture (fmap (fmap fst) (runCommandWithSql options eventStream (accountStream target) command (\_ -> pure ())))
                "with-inline-projection" -> runFixture (runCommandWithProjections options eventStream (accountStream target) command [accountBalanceProjection])
                _ -> runFixture (runCommand options eventStream (accountStream target) command)
          if runnerName == "with-inline-projection" then runFixture ensureFixtureReadModels >>= either (fail . show) pure else pure ()
          seeded <- traverse (\index -> submit (account index) (OpenAccount (OpenAccountData (account index) 0))) [0 .. accounts - 1]
          let operation worker index = do
                let target = account ((worker + fromIntegral index * writers) `mod` accounts)
                result <- submit target (Deposit (DepositData target 1 (Text.replicate memoBytes "x")))
                pure case result of
                  Right (Right response) | response.eventsAppended == 1 -> OpOk 1
                  other -> OpFailed (ErrorCause (Text.pack (show other)))
          (_, report) <- withMeasurement context config (\measurement -> runLoad measurement load (Operation (OpName "command") operation))
          acquired <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-command-bench-oracle")
          connection <- either (fail . show) pure acquired
          rows <- Oracle.readCategoryLog connection "account"
          balances <- if runnerName == "with-inline-projection" then Oracle.readBalanceTable connection else pure mempty
          Connection.release connection
          let completions = sum [batch.completed | batch <- report.loads]
              failures = sum [batch.failed | batch <- report.loads]
              seedOk = all (\case Right (Right response) -> response.eventsAppended == 1; _ -> False) seeded
              ledgerOk = case Oracle.modelFromLog rows of
                Right model -> Model.totalMoney model == length rows - accounts
                Left _ -> False
              inlineOk =
                runnerName /= "with-inline-projection" || case Oracle.modelFromLog rows of
                  Left _ -> False
                  Right model -> all (\index -> let current = account index; expected = Model.lookupAccount current model in case Map.lookup current balances of Just (balance, entries, _) -> fromIntegral expected.balance == balance && fromIntegral expected.entries == entries; Nothing -> False) [0 .. accounts - 1]
              checks = [("seeded-writers", seedOk), ("commands-completed", failures == 0 && completions > 0), ("durable-ledger", Oracle.logWellFormed rows && ledgerOk), ("inline-balances", inlineOk)]
          putSummary context Measurements "command-throughput" (object ["writers" .= writers, "accounts" .= accounts, "runner" .= runnerName, "snapshotPolicy" .= policyName, "memoBytes" .= memoBytes, "poolSize" .= (fromIntegral (knobInt context.knobs (knobName "kiroku.pool-size")) :: Int), "completed" .= completions, "failed" .= failures, "durableEvents" .= length rows])
          base <- recordCells context checks
          pure (base {outcome = measuredOutcome report base.outcome})

intKnob :: Text -> Int -> Int -> Int -> KnobSpec
intKnob key def low high = KnobSpec (knobName key) key KnobInt (VInt (fromIntegral def)) (IntRange (fromIntegral low) (fromIntegral high)) []

knobName :: Text -> KnobName
knobName = either (error . show) id . mkKnobName
