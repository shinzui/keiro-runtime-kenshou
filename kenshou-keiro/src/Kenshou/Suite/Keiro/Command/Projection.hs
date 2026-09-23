module Kenshou.Suite.Keiro.Command.Projection (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically)
import Data.Aeson (object, (.=))
import Data.Int (Int32)
import Data.List (findIndex)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Time (addUTCTime)
import Data.Vector qualified as Vector
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Keiro.Command (CommandResult (..), RunCommandOptions (..), defaultRunCommandOptions, runCommand)
import Keiro.Projection (AsyncApplyOutcome (..), applyAsyncProjection, pruneAsyncProjectionDedupBefore, runCommandWithProjections)
import Keiro.ReadModel.Schema (markLive, markRebuilding)
import Kenshou.Check.Process (ProgressSnapshot (..), awaitMark, awaitReady, childPid, killChild, progress, roleProcess, sendCommand, spawn, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId, unSeed)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobInt, knobText, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Core.Scenario (CohortScope (..), KnownDefect (..), Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Command.Correctness (recordCells)
import Kenshou.Suite.Keiro.Fixture.Account
import Kenshou.Suite.Keiro.Fixture.Domain
import Kenshou.Suite.Keiro.Fixture.Model qualified as Model
import Kenshou.Suite.Keiro.Fixture.Oracle qualified as Oracle
import Kenshou.Suite.Keiro.Fixture.Projection
import Kenshou.Suite.Keiro.Fixture.Runtime
import Kenshou.Suite.Keiro.Fixture.Workload qualified as Workload
import Kiroku.Store (defaultConnectionSettings, runTransaction)
import Kiroku.Store.Read (readCategory)
import Kiroku.Store.Types (CategoryName (..), GlobalPosition (..), RecordedEvent (..))
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [asyncDedupAndFence, asyncAtLeastOnceUnderKill, asyncApplyCheckpointAtomic, inlineAtomicityUnderKill]

inlineAtomicityUnderKill :: Scenario
inlineAtomicityUnderKill =
  asyncAtLeastOnceUnderKill
    { id = either (error . show) id (parseScenarioId "keiro/projection/concurrency/inline-atomicity-under-kill"),
      summary = "Interrupts an inline projection transaction and compares its read model with the durable log.",
      knobs =
        [ KnobSpec (either (error . show) id (mkKnobName "fault.kind")) "Writer or database interruption" KnobText (VText "sigkill") (OneOf (VText "sigkill" :| [VText "backend-terminate", VText "projection-error"])) [],
          KnobSpec (either (error . show) id (mkKnobName "command.duration-seconds")) "Sleep-window timeout" KnobInt (VInt 60) (IntRange 5 120) []
        ],
      run = runInlineAtomicity
    }

runInlineAtomicity :: RunContext -> IO ScenarioReport
runInlineAtomicity context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture ->
    withCheck context \check -> withSupervisor check \supervisor -> do
      let KeiroRunner runFixture = fixture.runner
          account = AccountId "0"
          accountEvents = accountEventStream (SnapEvery 100)
          seed = unSeed context.seed
          workload = take 100 (Workload.workerOps seed Workload.defaultWorkloadSpec {Workload.accounts = 1} 0 1)
          isDepositOp operation = case operation.action of Workload.ActDeposit {} -> True; _ -> False
          faultKind = knobText context.knobs (either (error . show) id (mkKnobName "fault.kind"))
          duration = fromIntegral (knobInt context.knobs (either (error . show) id (mkKnobName "command.duration-seconds"))) :: Int
      startIndex <- maybe (fail "no deposit in first 100 seeded operations") pure (findIndex isDepositOp workload)
      let operation = workload !! startIndex
          amount = case operation.action of Workload.ActDeposit _ value -> value; _ -> 0
          eventId = Workload.opEventId seed operation 0
          writerArgs = object ["worker" .= (0 :: Int), "workers" .= (1 :: Int), "startIndex" .= startIndex, "count" .= (1 :: Int), "accounts" .= (1 :: Int), "inlineProjectionSleep" .= True]
      _ <- runFixture ensureFixtureReadModels >>= either (fail . show) pure
      opened <- runFixture (runCommandWithProjections defaultRunCommandOptions accountEvents (accountStream account) (OpenAccount (OpenAccountData account 10000)) [accountBalanceProjection])
      acquired <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-inline-oracle")
      connection <- either (fail . show) pure acquired
      interrupted <- case faultKind of
        "projection-error" -> do
          result <- runFixture (runCommandWithProjections defaultRunCommandOptions {eventIds = [eventId]} accountEvents (accountStream account) (Deposit (DepositData account amount "kenshou:park")) [accountBalanceProjection, failingProjection])
          pure (case result of Right (Left _) -> True; Left _ -> True; _ -> False)
        _ -> do
          spec <- roleProcess check "keiro/command-writer" 0 writerArgs
          writer <- spawn supervisor spec
          awaitReady writer 10000
          sendCommand writer CtlStart
          sleeper <- timeout (duration * 1000000) (awaitSleeper connection)
          case sleeper of
            Nothing -> pure False
            Just pid -> do
              beforeRows <- Oracle.readCategoryLog connection "account"
              beforeBalances <- Oracle.readBalanceTable connection
              let consistentBefore = matching account beforeRows beforeBalances
              disturbed <-
                if faultKind == "sigkill"
                  then killChild supervisor writer >> pure True
                  else Connection.use connection (Session.statement pid terminateBackend) >>= either (fail . show) pure
              _ <- timeout 10000000 (awaitSleeperGone connection pid)
              pure (consistentBefore && disturbed)
      afterRows <- Oracle.readCategoryLog connection "account"
      afterBalances <- Oracle.readBalanceTable connection
      Connection.release connection
      let accepted = case opened of Right (Right result) -> result.eventsAppended == 1; _ -> False
          depositCount = length [() | row <- afterRows, row.eventId == eventId]
          cells =
            [ ("source-setup", accepted),
              ("fault-observed", interrupted),
              ("inline-read-model-equals-log", matching account afterRows afterBalances),
              ("parked-operation-atomic", depositCount == 0 && Map.lookup account afterBalances == Just (10000, 1, 1))
            ]
      recordCells context cells
  where
    matching account rows balances =
      case Oracle.modelFromLog rows of
        Right model -> case Map.lookup account balances of
          Just (balance, entries, _) ->
            let expected = Model.lookupAccount account model
             in fromIntegral expected.balance == balance && fromIntegral expected.entries == entries
          Nothing -> False
        Left _ -> False
    sleeperStatement =
      Statement.unpreparable
        "SELECT pid FROM pg_stat_activity WHERE state = 'active' AND query LIKE '%pg_sleep(30)%' AND pid <> pg_backend_pid() ORDER BY pid LIMIT 1"
        Encoders.noParams
        (Decoders.rowMaybe (Decoders.column (Decoders.nonNullable Decoders.int4)))
    terminateBackend =
      Statement.unpreparable
        "SELECT pg_terminate_backend($1::int4)"
        (Encoders.param (Encoders.nonNullable Encoders.int4))
        (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.bool)))
    awaitSleeper connection = do
      result <- Connection.use connection (Session.statement () sleeperStatement) >>= either (fail . show) pure
      maybe (threadDelay 100000 >> awaitSleeper connection) pure result
    awaitSleeperGone connection pid = do
      result <- Connection.use connection (Session.statement () sleeperStatement) >>= either (fail . show) pure
      if result == Just (pid :: Int32) then threadDelay 100000 >> awaitSleeperGone connection pid else pure ()

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
