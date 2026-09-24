module Kenshou.Suite.Keiro.Timer.Correctness (scenarios) where

import Data.Aeson (Value (Null))
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Time (addUTCTime, getCurrentTime)
import Data.UUID qualified as UUID
import Effectful (Eff, IOE, liftIO)
import Effectful.Error.Static (Error)
import Keiro.Timer (TimerId (..), TimerInspection (..), TimerRequest (..), TimerRow (..), TimerStatus (..), TimerWorkerConfigError (..), TimerWorkerOptions (..), cancelTimer, claimDueTimer, deadLetterTimer, defaultTimerWorkerOptions, lookupTimer, lookupTimerInspection, markTimerFired, mkTimerWorkerOptions, requeueStuckTimers, runTimerWorkerWith, scheduleTimerOnceTx, scheduleTimerTx)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Timer.Oracle (recordTimerCells)
import Kenshou.Suite.Keiro.Workflow.Fixture (durableKirokuStore, withDurableStore)
import Kiroku.Store (Store, defaultConnectionSettings, runStoreIO, runTransaction)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Types (EventId (..))

scenarios :: [Scenario]
scenarios = [lifecycle, maxAttemptsDeadLetters]

maxAttemptsDeadLetters :: Scenario
maxAttemptsDeadLetters =
  lifecycle
    { id = either (error . show) id (parseScenarioId "keiro/timer/correctness/max-attempts-dead-letters-post-claim"),
      summary = "Checks that the post-claim attempt ceiling dead-letters without running the callback and that invalid options are rejected.",
      run = runMaxAttempts
    }

runMaxAttempts :: RunContext -> IO ScenarioReport
runMaxAttempts context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    now <- getCurrentTime
    calls <- newIORef (0 :: Int)
    let store = durableKirokuStore fixture
        due = addUTCTime (-2) now
        request number = TimerRequest (TimerId (uuid number)) "kenshou" "attempt-ceiling" due Null
        timer number = TimerId (uuid number)
        opts = defaultTimerWorkerOptions {maxAttempts = Just 2, requeueStuckAfter = Just 1}
        run :: Eff '[Store, Error StoreError, IOE] a -> IO (Either StoreError a)
        run = runStoreIO store
        failFire _ = liftIO (atomicModifyIORef' calls (\n -> (n + 1, ()))) >> pure Nothing
    _ <- run $ runTransaction (scheduleTimerTx (request 4))
    first <- run $ runTimerWorkerWith Nothing opts now failFire
    second <- run $ runTimerWorkerWith Nothing opts (addUTCTime 2 now) failFire
    third <- run $ runTimerWorkerWith Nothing opts (addUTCTime 4 now) failFire
    dead <- run $ lookupTimerInspection (timer 4)
    count <- readIORef calls
    _ <- run $ runTransaction (scheduleTimerTx (request 5))
    zeroClaim <- run $ runTimerWorkerWith Nothing opts {maxAttempts = Just 0} (addUTCTime 4 now) failFire
    zeroDead <- run $ lookupTimer (timer 5)
    afterZero <- readIORef calls
    let claimed result attempt = case result of Right (Just row) -> row.attempts == attempt; _ -> False
        cells =
          [ ("first-two-fire", claimed first 1 && claimed second 2 && count == 2),
            ("third-claim-dead", claimed third 3 && case dead of Right (Just inspection) -> inspection.timer.status == Dead && inspection.timer.attempts == 3 && inspection.lastError == Just "timer exceeded attempt ceiling of 2"; _ -> False),
            ("zero-ceiling", claimed zeroClaim 1 && afterZero == 2 && case zeroDead of Right (Just row) -> row.status == Dead && row.attempts == 1; _ -> False),
            ("invalid-options", mkTimerWorkerOptions opts {maxAttempts = Just (-1)} == Left (InvalidTimerMaxAttempts (-1)) && mkTimerWorkerOptions opts {requeueStuckAfter = Just 0} == Left (InvalidTimerRequeueStuckAfter 0))
          ]
    recordTimerCells check cells

lifecycle :: Scenario
lifecycle =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/timer/correctness/lifecycle-and-at-least-once"),
      revision = 1,
      summary = "Checks first arm, scheduled rearm, claim order, fire acknowledgement, stuck requeue, and at-least-once callback execution.",
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
      run = runLifecycle
    }

runLifecycle :: RunContext -> IO ScenarioReport
runLifecycle context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    now <- getCurrentTime
    fires <- newIORef (0 :: Int)
    let store = durableKirokuStore fixture
        tid n = TimerId (uuid n)
        eid = EventId (uuid 100)
        due = addUTCTime (-2) now
        later = addUTCTime (-1) now
        request n at = TimerRequest (tid n) "kenshou" "timer-lifecycle" at Null
        run :: Eff '[Store, Error StoreError, IOE] a -> IO (Either StoreError a)
        run = runStoreIO store
    once <- run $ runTransaction (scheduleTimerOnceTx (request 1 due))
    twice <- run $ runTransaction (scheduleTimerOnceTx (request 1 later))
    firstArm <- run $ lookupTimer (tid 1)
    _ <- run $ runTransaction (scheduleTimerTx (request 2 later))
    _ <- run $ runTransaction (scheduleTimerTx (request 2 due))
    rearmed <- run $ lookupTimer (tid 2)
    claimed1 <- run $ claimDueTimer now
    marked1 <- run $ markTimerFired (tid 1) eid
    terminal1 <- run $ lookupTimer (tid 1)
    _ <- run $ runTransaction (scheduleTimerTx (request 1 later))
    afterTerminalRearm <- run $ lookupTimer (tid 1)
    refusedCancel <- run $ cancelTimer (tid 1)
    refusedDead <- run $ deadLetterTimer (tid 1) "late"
    claimed2 <- run $ claimDueTimer now
    marked2 <- run $ markTimerFired (tid 2) eid
    _ <- run $ runTransaction (scheduleTimerTx (request 3 due))
    let options = defaultTimerWorkerOptions {requeueStuckAfter = Just 1}
        fire _ = do
          occurrence <- liftIO $ atomicModifyIORef' fires (\n -> let next = n + 1 in (next, next))
          pure (if occurrence == 1 then Nothing else Just eid)
    firstPass <- run $ runTimerWorkerWith Nothing options now fire
    firingRow <- run $ lookupTimer (tid 3)
    requeued <- run $ requeueStuckTimers 1 (addUTCTime 3 now)
    secondPass <- run $ runTimerWorkerWith Nothing options (addUTCTime 3 now) fire
    finalRow <- run $ lookupTimer (tid 3)
    fireCount <- readIORef fires
    let rowIs result predicate = case result of Right (Just row) -> predicate row; _ -> False
        cells =
          [ ("first-arm-wins", once == Right True && twice == Right False && rowIs firstArm (\row -> row.fireAt == due)),
            ("scheduled-rearm", rowIs rearmed (\row -> row.fireAt == due)),
            ("claim-order", rowIs claimed1 (\row -> row.timerId == tid 1 && row.attempts == 1) && rowIs claimed2 (\row -> row.timerId == tid 2)),
            ("fired-event-id", marked1 == Right True && marked2 == Right True && rowIs terminal1 (\row -> row.status == Fired && row.firedEventId == Just eid)),
            ("terminal-rearm-refused", rowIs afterTerminalRearm (\row -> row.status == Fired && row.fireAt == due && row.firedEventId == Just eid)),
            ("terminal-refusals", refusedCancel == Right False && refusedDead == Right False),
            ("none-leaves-firing", rowIs firstPass (\row -> row.timerId == tid 3) && rowIs firingRow (\row -> row.status == Firing && row.attempts == 1)),
            ("virtual-requeue-and-refire", requeued == Right 1 && rowIs secondPass (\row -> row.timerId == tid 3 && row.attempts == 2) && rowIs finalRow (\row -> row.status == Fired && row.firedEventId == Just eid && row.attempts == 2) && fireCount == 2)
          ]
    recordTimerCells check cells

uuid :: Int -> UUID.UUID
uuid n = maybe (error "invalid fixed timer UUID") id $ UUID.fromString ("00000000-0000-0000-0000-" <> pad n)
  where
    pad value = replicate (12 - length digits) '0' <> digits
      where
        digits = show value
