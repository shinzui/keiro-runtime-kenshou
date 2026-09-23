module Kenshou.Suite.Keiro.Command.Projection (scenarios) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Time (addUTCTime)
import Data.Vector qualified as Vector
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Keiro.Command (CommandResult (..), defaultRunCommandOptions, runCommand)
import Keiro.Projection (AsyncApplyOutcome (..), applyAsyncProjection, pruneAsyncProjectionDedupBefore)
import Keiro.ReadModel.Schema (markLive, markRebuilding)
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Command.Correctness (recordCells)
import Kenshou.Suite.Keiro.Fixture.Account
import Kenshou.Suite.Keiro.Fixture.Domain
import Kenshou.Suite.Keiro.Fixture.Oracle qualified as Oracle
import Kenshou.Suite.Keiro.Fixture.Projection
import Kenshou.Suite.Keiro.Fixture.Runtime
import Kiroku.Store (defaultConnectionSettings, runTransaction)
import Kiroku.Store.Read (readCategory)
import Kiroku.Store.Types (CategoryName (..), GlobalPosition (..), RecordedEvent (..))

scenarios :: [Scenario]
scenarios = [asyncDedupAndFence]

asyncDedupAndFence :: Scenario
asyncDedupAndFence =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/projection/correctness/async-dedup-and-fence"),
      revision = 1,
      summary = "Checks async deduplication, rebuild fencing, and the effect of pruning.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
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
      run = runAsyncDedup
    }

runAsyncDedup :: RunContext -> IO ScenarioReport
runAsyncDedup context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let KeiroRunner runFixture = fixture.runner
        account = AccountId "async-dedup"
        stream = accountEventStream SnapNever
        target = accountStream account
        submit command = runFixture (runCommand defaultRunCommandOptions stream target command)
        apply recorded = runFixture (runTransaction (applyAsyncProjection accountActivityProjection recorded))
    _ <- runFixture ensureFixtureReadModels >>= either (fail . show) pure
    opened <- submit (OpenAccount (OpenAccountData account 5))
    deposited <- submit (Deposit (DepositData account 1 "fenced"))
    sourceBatch <- runFixture (readCategory (CategoryName "account") (GlobalPosition 0) 10) >>= either (fail . show) pure
    (first, second) <- case Vector.toList sourceBatch of
      [first, second] -> pure (first, second)
      other -> fail ("expected two account events, observed " <> show (length other))
    firstApply <- apply first
    duplicate <- apply first
    _ <- runFixture (markRebuilding accountActivityReadModelName 1 "v1") >>= either (fail . show) pure
    fenced <- apply second
    acquiredBefore <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-async-before")
    beforeConnection <- either (fail . show) pure acquiredBefore
    before <- Oracle.readActivityTable beforeConnection
    Connection.release beforeConnection
    _ <- runFixture (markLive accountActivityReadModelName 1 "v1") >>= either (fail . show) pure
    pruned <- runFixture (pruneAsyncProjectionDedupBefore (addUTCTime 1 first.createdAt))
    afterPrune <- apply first
    acquiredAfter <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-async-after")
    afterConnection <- either (fail . show) pure acquiredAfter
    after <- Oracle.readActivityTable afterConnection
    Connection.release afterConnection
    let accepted = \case Right (Right result) -> result.eventsAppended == 1; _ -> False
        cells =
          [ ("source-events", accepted opened && accepted deposited),
            ("first-applied", firstApply == Right AsyncApplied),
            ("duplicate-skipped", duplicate == Right AsyncDuplicate),
            ("rebuild-fenced", fenced == Right AsyncFenced && Map.lookup account before == Just (1, 5)),
            ("dedup-pruned", case pruned of Right count -> count >= 1; _ -> False),
            ("pruned-event-reapplied", afterPrune == Right AsyncApplied && Map.lookup account after == Just (2, 10))
          ]
    recordCells context cells
