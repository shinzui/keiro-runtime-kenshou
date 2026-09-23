module Kenshou.Suite.Keiro.Command.Concurrency (scenarios) where

import Control.Concurrent.Async (async, wait)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Monad (replicateM)
import Data.List (nub)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Time (addUTCTime, getCurrentTime)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Keiro.Command (CommandError (..), CommandResult (..), RunCommandOptions (..), defaultRunCommandOptions, runCommand)
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId, unSeed)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobInt, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Command.Correctness (recordCells)
import Kenshou.Suite.Keiro.Fixture.Account
import Kenshou.Suite.Keiro.Fixture.Domain
import Kenshou.Suite.Keiro.Fixture.Model qualified as Model
import Kenshou.Suite.Keiro.Fixture.Oracle qualified as Oracle
import Kenshou.Suite.Keiro.Fixture.Runtime
import Kenshou.Suite.Keiro.Fixture.Workload qualified as Workload
import Kiroku.Store (defaultConnectionSettings)
import Kiroku.Store.Error (StoreError (..))

scenarios :: [Scenario]
scenarios = [identicalCommandsOneBatch, hotStreamContention]

hotStreamContention :: Scenario
hotStreamContention =
  identicalCommandsOneBatch
    { id = either (error . show) id (parseScenarioId "keiro/command/concurrency/hot-stream-contention"),
      summary = "Checks accepted writes on a contended stream have distinct versions and the right balance.",
      knobs =
        [ KnobSpec (knobName "command.writers") "Concurrent writers" KnobInt (VInt 8) (IntRange 2 128) [],
          KnobSpec (knobName "command.retry-limit") "Optimistic conflict retry limit" KnobInt (VInt 3) (IntRange 0 16) [],
          KnobSpec (knobName "command.duration-seconds") "Contention duration" KnobInt (VInt 30) (IntRange 1 600) []
        ],
      run = runHotStream
    }

knobName :: Text -> KnobName
knobName = either (error . show) id . mkKnobName

runHotStream :: RunContext -> IO ScenarioReport
runHotStream context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let account = AccountId "hot-stream"
        target = accountStream account
        eventStream = accountEventStream SnapNever
        KeiroRunner runFixture = fixture.runner
        writerCount = fromIntegral (knobInt context.knobs (knobName "command.writers"))
        retryBudget = fromIntegral (knobInt context.knobs (knobName "command.retry-limit"))
        duration = fromIntegral (knobInt context.knobs (knobName "command.duration-seconds"))
    opened <- runFixture (runCommand defaultRunCommandOptions eventStream target (OpenAccount (OpenAccountData account 0)))
    gate <- newEmptyMVar
    let work writer = do
          deadline <- readMVar gate
          loop deadline writer 0 [] (0 :: Int)
        loop deadline writer index accepted unexpected = do
          now <- getCurrentTime
          if now >= deadline
            then pure (accepted, unexpected)
            else do
              let identifier = Workload.opEventId (unSeed context.seed) (Workload.Op writer index (Workload.ActDeposit account 1)) 0
                  options = defaultRunCommandOptions {eventIds = [identifier], retryLimit = retryBudget}
              outcome <- runFixture (runCommand options eventStream target (Deposit (DepositData account 1 "contention")))
              case outcome of
                Right (Right result) | result.eventsAppended == 1 -> loop deadline writer (index + 1) (result.streamVersion : accepted) unexpected
                Right (Left (RetryExhausted {})) -> loop deadline writer (index + 1) accepted unexpected
                _ -> loop deadline writer (index + 1) accepted (unexpected + 1)
    workers <- traverse (async . work) [0 .. writerCount - 1]
    start <- getCurrentTime
    putMVar gate (addUTCTime duration start)
    results <- traverse wait workers
    acquired <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-contention-oracle")
    connection <- either (fail . show) pure acquired
    rows <- Oracle.readCategoryLog connection "account"
    Connection.release connection
    let versions = concatMap fst results
        acceptedCount = length versions
        unexpectedCount = sum (map snd results)
        cells =
          [ ("initial-open", case opened of Right (Right result) -> result.eventsAppended == 1; _ -> False),
            ("accepted-versions-unique", length (nub versions) == acceptedCount),
            ("accepted-equals-log", length rows == acceptedCount + 1 && Oracle.logWellFormed rows),
            ("final-balance", case Oracle.modelFromLog rows of Right model -> Model.totalMoney model == acceptedCount; _ -> False),
            ("no-unexpected-results", unexpectedCount == 0)
          ]
    recordCells context cells

identicalCommandsOneBatch :: Scenario
identicalCommandsOneBatch =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/command/concurrency/identical-commands-one-batch"),
      revision = 1,
      summary = "Checks concurrent submissions of one event identifier append exactly once.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = [KnobSpec (either (error . show) id (mkKnobName "command.concurrency")) "Simultaneous clients" KnobInt (VInt 16) (IntRange 2 256) []],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgFsyncOff :| [PgDurable]) PgFsyncOff),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku, SchemaKeiro] [] False)},
      knownDefect = Nothing,
      run = runIdentical
    }

runIdentical :: RunContext -> IO ScenarioReport
runIdentical context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let account = AccountId "concurrent-identical"
        target = accountStream account
        eventStream = accountEventStream SnapNever
        command = Deposit (DepositData account 7 "identical")
        identifier = Workload.opEventId (unSeed context.seed) (Workload.Op 0 0 (Workload.ActDeposit account 7)) 0
        options = defaultRunCommandOptions {eventIds = [identifier]}
        KeiroRunner runFixture = fixture.runner
        concurrency = fromIntegral (knobInt context.knobs (either (error . show) id (mkKnobName "command.concurrency")))
    opened <- runFixture (runCommand defaultRunCommandOptions eventStream target (OpenAccount (OpenAccountData account 0)))
    gate <- newEmptyMVar
    workers <- replicateM concurrency (async (readMVar gate >> runFixture (runCommand options eventStream target command)))
    putMVar gate ()
    results <- traverse wait workers
    acquired <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-identical-oracle")
    connection <- either (fail . show) pure acquired
    rows <- Oracle.readCategoryLog connection "account"
    Connection.release connection
    let accepted = [result.streamVersion | Right (Right result) <- results, result.eventsAppended == 1]
        duplicate = length [() | Right (Left (StoreFailed (DuplicateEvent _))) <- results]
        exhausted = length [() | Right (Left (RetryExhausted {})) <- results]
        cells =
          [ ("initial-open", case opened of Right (Right result) -> result.eventsAppended == 1; _ -> False),
            ("one-accepted", length accepted == 1 && length (nub accepted) == 1),
            ("others-duplicate-or-exhausted", length accepted + duplicate + exhausted == concurrency),
            ("no-retry-exhaustion", exhausted == 0),
            ("event-id-once", length [() | row <- rows, row.eventId == identifier] == 1),
            ("stream-version-once", length rows == 2),
            ("balance-once", case Oracle.modelFromLog rows of Right model -> Model.totalMoney model == 7; _ -> False)
          ]
    recordCells context cells
