module Kenshou.Suite.Keiro.Command.Bench (scenarios) where

import Data.Aeson (object, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Keiro.Command (CommandError (..), CommandResult (..), RunCommandOptions (..), defaultRunCommandOptions, runCommand)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (Kind (..), parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobInt, knobText, mkKnobName)
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
import Kenshou.Suite.Keiro.Fixture.Runtime
import Kiroku.Store (defaultConnectionSettings)
import Kiroku.Store.Connection (ConnectionSettingsM (..))

scenarios :: [Scenario]
scenarios = [throughputLatency, hydrationCost, allStreamAppendCeiling]

allStreamAppendCeiling :: Scenario
allStreamAppendCeiling =
  throughputLatency
    { id = either (error . show) id (parseScenarioId "keiro/command/benchmark/all-stream-append-ceiling"),
      summary = "Measures independent account writers contending only on the global append position.",
      knobs =
        loadKnobs (defaultLoadDefaults {workers = 8})
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
        loadKnobs (defaultLoadDefaults {workers = 1})
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
    (Right configuredLoad, Right config) ->
      withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
        let KeiroRunner runFixture = fixture.runner
            account = AccountId "hydration-bench"
            streamLength = fromIntegral (knobInt context.knobs (knobName "command.stream-length")) :: Int
            page = fromIntegral (knobInt context.knobs (knobName "command.page-size"))
            policyName = knobText context.knobs (knobName "snapshot.policy")
            eventStream = accountEventStream (if policyName == "never" then SnapNever else SnapEvery 100)
            options = defaultRunCommandOptions {pageSize = page, verifyReplayOnAppend = False}
            target = accountStream account
        seeded <- traverse (\command -> runFixture (runCommand options eventStream target command)) (OpenAccount (OpenAccountData account 1) : replicate streamLength (Deposit (DepositData account 1 "seed")))
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
        Connection.release connection
        let completions = sum [batch.completed | batch <- report.loads]
            failures = sum [batch.failed | batch <- report.loads]
            seededOk = all (\case Right (Right response) -> response.eventsAppended == 1; _ -> False) seeded
            modelOk = case Oracle.modelFromLog rows of Right model -> Model.totalMoney model == 1 + streamLength && length rows == streamLength + 1; Left _ -> False
        putSummary context Measurements "hydration-cost" (object ["streamLength" .= streamLength, "snapshotPolicy" .= policyName, "pageSize" .= page, "completed" .= completions, "failed" .= failures])
        base <- recordCells context [("stream-prepared", seededOk), ("commands-completed", completions > 0 && failures == 0), ("durable-ledger", Oracle.logWellFormed rows && modelOk)]
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
        loadKnobs (defaultLoadDefaults {workers = 8})
          <> measureKnobs Benchmark
          <> [intKnob "command.writers" 8 1 128, intKnob "command.duration-seconds" 120 1 3600],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      phases = PhasePlan 5 120 5,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku, SchemaKeiro] [("shared_preload_libraries", "'pg_stat_statements'")] False)},
      knownDefect = Nothing,
      run = runCommandBenchmark False
    }

runCommandBenchmark :: Bool -> RunContext -> IO ScenarioReport
runCommandBenchmark ceiling context =
  case (loadModelFromKnobs context.knobs, measureConfigFromKnobs context (phasePlanFromCore (PhasePlan 5 (fromIntegral (knobInt context.knobs (knobName "command.duration-seconds"))) 5))) of
    (Left reason, _) -> pure (failedWith ["invalid-load-config"] reason)
    (_, Left reason) -> pure (failedWith ["invalid-measure-config"] reason)
    (Right configuredLoad, Right config) ->
      withFixtureEnv ((defaultConnectionSettings (requirePostgres context).connectionString) {poolSize = if ceiling then fromIntegral (knobInt context.knobs (knobName "kiroku.pool-size")) else 10}) \fixture -> do
        let KeiroRunner runFixture = fixture.runner
            writers = fromIntegral (knobInt context.knobs (knobName "command.writers")) :: Int
            account worker = AccountId ("bench-" <> Text.pack (show worker))
            eventStream = accountEventStream (SnapEvery 100)
            load = case configuredLoad of
              ClosedLoop closed -> ClosedLoop (closed {workers = writers})
              other -> other
        seeded <- traverse (\worker -> runFixture (runCommand defaultRunCommandOptions eventStream (accountStream (account worker)) (OpenAccount (OpenAccountData (account worker) 0)))) [0 .. writers - 1]
        let operation worker _ = do
              let target = account (worker `mod` writers)
              result <- runFixture (runCommand defaultRunCommandOptions eventStream (accountStream target) (Deposit (DepositData target 1 "bench")))
              pure case result of
                Right (Right response) | response.eventsAppended == 1 -> OpOk 1
                other -> OpFailed (ErrorCause (Text.pack (show other)))
        (_, report) <- withMeasurement context config (\measurement -> runLoad measurement load (Operation (OpName "command") operation))
        acquired <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-command-bench-oracle")
        connection <- either (fail . show) pure acquired
        rows <- Oracle.readCategoryLog connection "account"
        Connection.release connection
        let completions = sum [batch.completed | batch <- report.loads]
            failures = sum [batch.failed | batch <- report.loads]
            seedOk = all (\case Right (Right response) -> response.eventsAppended == 1; _ -> False) seeded
            ledgerOk = case Oracle.modelFromLog rows of
              Right model -> Model.totalMoney model == length rows - writers
              Left _ -> False
            checks = [("seeded-writers", seedOk), ("commands-completed", failures == 0 && completions > 0), ("durable-ledger", Oracle.logWellFormed rows && ledgerOk)]
        putSummary context Measurements "command-throughput" (object ["writers" .= writers, "poolSize" .= (if ceiling then fromIntegral (knobInt context.knobs (knobName "kiroku.pool-size")) :: Int else 10), "completed" .= completions, "failed" .= failures, "durableEvents" .= length rows])
        base <- recordCells context checks
        pure (base {outcome = measuredOutcome report base.outcome})

intKnob :: Text -> Int -> Int -> Int -> KnobSpec
intKnob key def low high = KnobSpec (knobName key) key KnobInt (VInt (fromIntegral def)) (IntRange (fromIntegral low) (fromIntegral high)) []

knobName :: Text -> KnobName
knobName = either (error . show) id . mkKnobName
