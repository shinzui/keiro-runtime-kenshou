module Kenshou.Suite.Keiro.Command.Projection (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically)
import Data.Aeson (object, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Time (addUTCTime)
import Data.Vector qualified as Vector
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Keiro.Command (CommandResult (..), defaultRunCommandOptions, runCommand)
import Keiro.Projection (AsyncApplyOutcome (..), applyAsyncProjection, pruneAsyncProjectionDedupBefore)
import Keiro.ReadModel.Schema (markLive, markRebuilding)
import Kenshou.Check.Process (ProgressSnapshot (..), awaitMark, awaitReady, childPid, killChild, progress, roleProcess, sendCommand, spawn, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobText, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Core.Scenario (CohortScope (..), KnownDefect (..), Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Command.Correctness (recordCells)
import Kenshou.Suite.Keiro.Fixture.Account
import Kenshou.Suite.Keiro.Fixture.Domain
import Kenshou.Suite.Keiro.Fixture.Oracle qualified as Oracle
import Kenshou.Suite.Keiro.Fixture.Projection
import Kenshou.Suite.Keiro.Fixture.Runtime
import Kiroku.Store (defaultConnectionSettings, runTransaction)
import Kiroku.Store.Read (readCategory)
import Kiroku.Store.Types (CategoryName (..), GlobalPosition (..), RecordedEvent (..))
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [asyncDedupAndFence, asyncAtLeastOnceUnderKill, asyncApplyCheckpointAtomic]

asyncAtLeastOnceUnderKill :: Scenario
asyncAtLeastOnceUnderKill =
  asyncDedupAndFence
    { id = either (error . show) id (parseScenarioId "keiro/projection/concurrency/async-at-least-once-under-kill"),
      summary = "Kills a projection worker after apply and checks deduplication on restart.",
      tier = TierStandard,
      knobs = [KnobSpec (either (error . show) id (mkKnobName "projection.sabotage")) "Disable deduplication on restart" KnobText (VText "none") (OneOf (VText "none" :| [VText "skip-dedup"])) []],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      run = runAsyncCrash False
    }

asyncApplyCheckpointAtomic :: Scenario
asyncApplyCheckpointAtomic =
  asyncAtLeastOnceUnderKill
    { id = either (error . show) id (parseScenarioId "keiro/projection/concurrency/async-apply-checkpoint-atomic"),
      summary = "Checks the stronger atomic apply and checkpoint property.",
      knobs = [],
      knownDefect = Just (KnownDefect "mori://shinzui/keiro/okf/improvement-requests/concepts/IR-10" "Async apply and subscription checkpoint are separate" ["no-redelivery-after-apply"] AllCohorts),
      run = runAsyncCrash True
    }

runAsyncCrash :: Bool -> RunContext -> IO ScenarioReport
runAsyncCrash atomicContract context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture ->
    withCheck context \check -> withSupervisor check \supervisor -> do
      let KeiroRunner runFixture = fixture.runner
          account = AccountId "projection-crash"
          accountEvents = accountEventStream SnapNever
          sabotage = if atomicContract then False else knobText context.knobs (either (error . show) id (mkKnobName "projection.sabotage")) == "skip-dedup"
          accepted = \case Right (Right result) -> result.eventsAppended == 1; _ -> False
      _ <- runFixture ensureFixtureReadModels >>= either (fail . show) pure
      opened <- runFixture (runCommand defaultRunCommandOptions accountEvents (accountStream account) (OpenAccount (OpenAccountData account 5)))
      deposited <- runFixture (runCommand defaultRunCommandOptions accountEvents (accountStream account) (Deposit (DepositData account 1 "after-crash")))
      armedSpec <- roleProcess check "keiro/projection-worker" 0 (object ["batchSize" .= (100 :: Int), "parkAfterApply" .= True])
      armed <- spawn supervisor armedSpec
      awaitReady armed 10000
      sendCommand armed CtlStart
      awaitMark armed "parked" 30000
      acquired <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-projection-crash-oracle")
      connection <- either (fail . show) pure acquired
      before <- Oracle.readActivityTable connection
      killChild supervisor armed
      resumedSpec <- roleProcess check "keiro/projection-worker" 1 (object ["batchSize" .= (100 :: Int), "skipDedup" .= sabotage])
      resumed <- spawn supervisor resumedSpec
      awaitReady resumed 10000
      sendCommand resumed CtlStart
      completed <- timeout 90000000 (awaitActivity connection account (if sabotage then 3 else 2))
      after <- Oracle.readActivityTable connection
      observed <- atomically (progress resumed)
      Connection.release connection
      killChild supervisor resumed
      let redelivered = Map.member "projection-duplicate" observed.marks
          baseCells =
            [ ("source-setup", accepted opened && accepted deposited),
              ("applied-before-kill", Map.lookup account before == Just (1, 5)),
              ("killed-and-restarted", childPid armed /= childPid resumed && completed == Just True),
              ("activity-equals-log", Map.lookup account after == Just (2, 6)),
              ("redelivery-deduplicated", redelivered)
            ]
          cells = if atomicContract then baseCells <> [("no-redelivery-after-apply", not redelivered)] else baseCells
      recordCells context cells
  where
    awaitActivity connection account expected = do
      rows <- Oracle.readActivityTable connection
      if maybe False ((>= expected) . fst) (Map.lookup account rows)
        then pure True
        else threadDelay 100000 >> awaitActivity connection account expected

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
