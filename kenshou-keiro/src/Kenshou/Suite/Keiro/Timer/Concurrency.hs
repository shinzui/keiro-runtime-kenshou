module Kenshou.Suite.Keiro.Timer.Concurrency (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically)
import Control.Monad (forM, forM_)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as ByteString
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time (addUTCTime, getCurrentTime)
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID.V5
import Data.Vector qualified as Vector
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx
import Keiro.Timer (TimerId (..), TimerRequest (..), TimerRow (..), TimerStatus (..), TimerWorkerOptions (..), cancelTimer, claimDueTimer, deadLetterTimer, defaultTimerWorkerOptions, lookupTimer, markTimerFired, requeueStuckTimer, runTimerWorkerWith, scheduleTimerTx)
import Kenshou.Check.Fact (Fact (..), FactKind (..))
import Kenshou.Check.Ledger (sealLedger)
import Kenshou.Check.Ledger.Read (discoverLedgers, foldFacts)
import Kenshou.Check.Process (ProgressSnapshot (..), awaitMark, awaitReady, childPid, killChild, progress, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (CheckEnv (..), withCheck)
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId, unSeed)
import Kenshou.Core.Knob (knobInt)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Timer.Knobs (timerKnobName, timerKnobs)
import Kenshou.Suite.Keiro.Timer.Oracle (recordTimerCells)
import Kenshou.Suite.Keiro.Timer.Roles (businessEventId)
import Kenshou.Suite.Keiro.Workflow.Fixture (DurableStore, durableKirokuStore, withDurableStore)
import Kiroku.Store (defaultConnectionSettings, readStreamForward, runStoreIO, runTransaction)
import Kiroku.Store.Types (RecordedEvent (..), StreamName (..), StreamVersion (..))
import System.Posix.Signals (sigKILL, signalProcessGroup)

scenarios :: [Scenario]
scenarios = [skipLocked, sigkillBetweenFireAndMark, slowFireDoubleFires, foregroundResumeTokens]

foregroundResumeTokens :: Scenario
foregroundResumeTokens =
  skipLocked
    { id = either (error . show) id (parseScenarioId "keiro/timer/concurrency/foreground-resume-tokens"),
      summary = "Races guarded dead-timer resume claims across processes and checks renewal, guarded transitions and expiry recovery.",
      run = runForegroundResumeTokens
    }

runForegroundResumeTokens :: RunContext -> IO ScenarioReport
runForegroundResumeTokens context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    now <- getCurrentTime
    let store = durableKirokuStore fixture
        tid = fixtureTimerId 900002
        lateTid = fixtureTimerId 900003
        reason = "manual-review"
        request = TimerRequest tid "kenshou" "timer-foreground-resume" (addUTCTime (-1) now) Null
        lateRequest = TimerRequest lateTid "kenshou" "timer-late-resume" (addUTCTime (-1) now) Null
        lookupOne = runStoreIO store (lookupTimer tid)
        claimed snapshot = case Map.lookup "resume-claim" snapshot.marks of
          Just (Object fields) -> KeyMap.lookup "claimed" fields == Just (Bool True)
          _ -> False
        recovered = do
          result <- lookupOne
          pure (case result of Right (Just row) -> row.status == Dead && row.attempts == 1; _ -> False)
    seeded <- runStoreIO store (runTransaction (scheduleTimerTx request))
    dead <- runStoreIO store (deadLetterTimer tid reason)
    lateSeeded <- runStoreIO store (runTransaction (scheduleTimerTx lateRequest))
    lateDead <- runStoreIO store (deadLetterTimer lateTid reason)
    (winnerCount, attemptsAfterClaim, renewed, guarded, expiredRecovered, lateComplete) <- withSupervisor check \supervisor -> do
      workers <- forM [0 .. 3 :: Int] \index -> do
        spec <- roleProcess check "keiro/timer-resume-claimer" index (object ["timerId" .= timerText tid, "reason" .= reason, "maxAttempts" .= (4 :: Int), "leaseSeconds" .= (2 :: Int)])
        worker <- spawn supervisor spec
        awaitReady worker 10000
        pure worker
      forM_ workers (\worker -> sendCommand worker CtlStart)
      forM_ workers (\worker -> awaitMark worker "resume-claim" 10000)
      states <- traverse (atomically . progress) workers
      let winners = [worker | (worker, state) <- zip workers states, claimed state]
      attemptsAfterClaim <- lookupOne
      case winners of
        [owner] -> do
          guardedResults <-
            sequence
              [ runStoreIO store (markTimerFired tid (businessEventId tid)),
                runStoreIO store (cancelTimer tid),
                runStoreIO store (deadLetterTimer tid "incorrect"),
                runStoreIO store (requeueStuckTimer tid)
              ]
          sendCommand owner (CtlCustom "renew" Null)
          awaitMark owner "resume-renew" 5000
          renewal <- atomically (progress owner)
          let renewed = Map.lookup "resume-renew" renewal.marks == Just (object ["renewed" .= True])
              guarded = all (== Right False) guardedResults
          killChild supervisor owner
          threadDelay 2500000
          later <- getCurrentTime
          _ <- runStoreIO store (runTimerWorkerWith Nothing defaultTimerWorkerOptions {requeueStuckAfter = Nothing} later (const (pure Nothing)))
          expiredRecovered <- recovered
          lateSpec <- roleProcess check "keiro/timer-resume-claimer" 4 (object ["timerId" .= timerText lateTid, "reason" .= reason, "maxAttempts" .= (4 :: Int), "leaseSeconds" .= (2 :: Int)])
          lateOwner <- spawn supervisor lateSpec
          awaitReady lateOwner 10000
          sendCommand lateOwner CtlStart
          awaitMark lateOwner "resume-claim" 10000
          threadDelay 2500000
          expiryNow <- getCurrentTime
          _ <- runStoreIO store (runTimerWorkerWith Nothing defaultTimerWorkerOptions {requeueStuckAfter = Nothing} expiryNow (const (pure Nothing)))
          sendCommand lateOwner (CtlCustom "complete" Null)
          awaitMark lateOwner "resume-complete" 5000
          lateState <- atomically (progress lateOwner)
          let lateComplete = Map.lookup "resume-complete" lateState.marks == Just (object ["completed" .= False])
          pure (1 :: Int, attemptsAfterClaim, renewed, guarded, expiredRecovered, lateComplete)
        _ -> pure (length winners, attemptsAfterClaim, False, False, False, False)
    finalRow <- lookupOne
    lateRow <- runStoreIO store (lookupTimer lateTid)
    finalGuard <- runStoreIO store (runTransaction (Tx.statement (let TimerId value = tid in value) resumeGuardStatement))
    dueAfterRecovery <- getCurrentTime >>= runStoreIO store . claimDueTimer
    let firstAttempt = case attemptsAfterClaim of Right (Just row) -> row.status == Firing && row.attempts == 1; _ -> False
        retained = case finalRow of Right (Just row) -> row.status == Dead && row.attempts == 1; _ -> False
        lateRetained = case lateRow of Right (Just row) -> row.status == Dead && row.attempts == 1; _ -> False
    recordTimerCells
      check
      [ ("seed-dead-row", seeded == Right () && dead == Right True),
        ("single-foreground-owner", winnerCount == 1 && firstAttempt),
        ("guarded-transitions-refused", guarded),
        ("lease-renewed", renewed),
        ("expired-claim-recovered-without-stuck-timeout", expiredRecovered && retained && finalGuard == Right (Just (Just reason, True, True)) && dueAfterRecovery == Right Nothing),
        ("former-owner-late-completion-refused", lateSeeded == Right () && lateDead == Right True && lateComplete && lateRetained)
      ]

slowFireDoubleFires :: Scenario
slowFireDoubleFires =
  skipLocked
    { id = either (error . show) id (parseScenarioId "keiro/timer/concurrency/slow-fire-double-fires"),
      summary = "Lets one timer fire outlast stale-claim requeue and checks duplicate attempts, one event and a rejected late mark.",
      run = runSlowFireDoubleFires
    }

runSlowFireDoubleFires :: RunContext -> IO ScenarioReport
runSlowFireDoubleFires context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    now <- getCurrentTime
    let store = durableKirokuStore fixture
        tid = fixtureTimerId 900001
        request = TimerRequest tid "kenshou" "timer-slow-fire" (addUTCTime (-1) now) Null
        lookupOne = runStoreIO store (lookupTimer tid)
        fired = do
          result <- lookupOne
          pure (case result of Right (Just row) -> row.status == Fired; _ -> False)
    seeded <- runStoreIO store (runTransaction (scheduleTimerTx request))
    sealLedger check.ledger
    (firstEffect, secondCompleted, lateMarkRejected) <- withSupervisor check \supervisor -> do
      firstSpec <- roleProcess check "keiro/timer-worker" 0 (object ["slowFireMicros" .= (6000000 :: Int)])
      first <- spawn supervisor firstSpec
      awaitReady first 10000
      sendCommand first CtlStart
      firstEffect <- awaitTimerEffect check tid 100
      secondSpec <- roleProcess check "keiro/timer-worker" 1 (object [])
      second <- spawn supervisor secondSpec
      awaitReady second 10000
      sendCommand second CtlStart
      secondCompleted <- waitUntil fired 80
      awaitMark first "slow-mark" 10000
      status <- atomically (progress first)
      _ <- stopGracefully supervisor second 2000
      pure (firstEffect, secondCompleted, Map.lookup "slow-mark" status.marks == Just (object ["marked" .= False]))
    finalRow <- lookupOne
    business <- runStoreIO store (readStreamForward (StreamName ("kenshouTimer-" <> timerText tid)) (StreamVersion 0) 3)
    ledgers <- discoverLedgers check.ledgerDirectory
    effects <- foldFacts ledgers Map.empty \counts fact ->
      pure if fact.kind == Effect then Map.insertWith (+) fact.key (1 :: Int) counts else counts
    recordTimerCells
      check
      [ ("slow-fire-started", seeded == Right () && firstEffect),
        ("second-worker-fired", secondCompleted && case finalRow of Right (Just row) -> row.status == Fired && row.attempts == 2 && row.firedEventId == Just (businessEventId tid); _ -> False),
        ("raw-fire-twice", Map.lookup (timerText tid) effects == Just 2 && Map.size effects == 1),
        ( "one-business-event",
          case business of
            Right events -> case Vector.toList events of
              [event] -> event.eventId == businessEventId tid
              _ -> False
            Left _ -> False
        ),
        ("late-mark-rejected", lateMarkRejected)
      ]

awaitTimerEffect :: CheckEnv -> TimerId -> Int -> IO Bool
awaitTimerEffect _ _ 0 = pure False
awaitTimerEffect check tid remaining = do
  ledgers <- discoverLedgers check.ledgerDirectory
  found <- foldFacts ledgers False \seen fact -> pure (seen || fact.kind == Effect && fact.key == timerText tid)
  if found then pure True else threadDelay 50000 >> awaitTimerEffect check tid (remaining - 1)

sigkillBetweenFireAndMark :: Scenario
sigkillBetweenFireAndMark =
  skipLocked
    { id = either (error . show) id (parseScenarioId "keiro/timer/concurrency/sigkill-between-fire-and-mark"),
      summary = "Kills a timer worker after its business event, then checks requeue, bounded duplicate fire and one event.",
      knobs = timerKnobs,
      run = runSigkillBetweenFireAndMark
    }

runSigkillBetweenFireAndMark :: RunContext -> IO ScenarioReport
runSigkillBetweenFireAndMark context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    now <- getCurrentTime
    let store = durableKirokuStore fixture
        tid = fixtureTimerId 900000
        request = TimerRequest tid "kenshou" "timer-crash-window" (addUTCTime (-1) now) Null
        lookupOne = runStoreIO store (lookupTimer tid)
        fired = do
          result <- lookupOne
          pure (case result of Right (Just row) -> row.status == Fired; _ -> False)
    seeded <- runStoreIO store (runTransaction (scheduleTimerTx request))
    sealLedger check.ledger
    (armed, firingBeforeRestart, completed) <- withSupervisor check \supervisor -> do
      firstSpec <- roleProcess check "keiro/timer-worker" 0 (object ["killAfterFire" .= True])
      first <- spawn supervisor firstSpec
      awaitReady first 10000
      sendCommand first CtlStart
      armed <- awaitCrashArm check 100
      firingBeforeRestart <- lookupOne
      secondSpec <- roleProcess check "keiro/timer-worker" 1 (object [])
      second <- spawn supervisor secondSpec
      awaitReady second 10000
      sendCommand second CtlStart
      completed <- waitUntil fired 160
      _ <- stopGracefully supervisor second 2000
      pure (armed, firingBeforeRestart, completed)
    finalRow <- lookupOne
    business <- runStoreIO store (readStreamForward (StreamName ("kenshouTimer-" <> timerText tid)) (StreamVersion 0) 3)
    ledgers <- discoverLedgers check.ledgerDirectory
    (effects, arms) <- foldFacts ledgers (Map.empty, 0 :: Int) \(counts, marks) fact ->
      pure (if fact.kind == Effect then (Map.insertWith (+) fact.key (1 :: Int) counts, marks) else (counts, marks + if fact.kind == Mark && fact.id == "crash-armed" then 1 else 0))
    let cells =
          [ ("crash-arm-flushed", armed && arms == 1),
            ("first-claim-left-firing", seeded == Right () && case firingBeforeRestart of Right (Just row) -> row.status == Firing && row.attempts == 1; _ -> False),
            ("requeued-and-fired", completed && case finalRow of Right (Just row) -> row.status == Fired && row.attempts == 2 && row.firedEventId == Just (businessEventId tid); _ -> False),
            ("duplicate-effect-bounded", Map.lookup (timerText tid) effects == Just 2 && Map.size effects == 1),
            ( "one-business-event",
              case business of
                Right events -> case Vector.toList events of
                  [event] -> event.eventId == businessEventId tid
                  _ -> False
                Left _ -> False
            )
          ]
    randomCells <- randomKillArm context check fixture
    recordTimerCells check (cells <> randomCells)

randomKillArm :: RunContext -> CheckEnv -> DurableStore -> IO [(Text.Text, Bool)]
randomKillArm context check fixture = do
  now <- getCurrentTime
  let store = durableKirokuStore fixture
      timerIds = map fixtureTimerId [910000 .. 910049]
      request tid = TimerRequest tid "kenshou" "timer-random-kill" (addUTCTime (-1) now) Null
      delay index = 10000 + fromIntegral ((unSeed context.seed + fromIntegral index * 1103515245) `mod` 30000)
      done = do
        remaining <- runStoreIO store (runTransaction (Tx.statement () remainingTimerCount))
        pure (remaining == Right 0)
  seeded <- traverse (\tid -> runStoreIO store (runTransaction (scheduleTimerTx (request tid)))) timerIds
  completed <- withSupervisor check \supervisor -> do
    forM_ [0 .. 2 :: Int] \index -> do
      spec <- roleProcess check "keiro/timer-worker" (index + 2) (object ["fireDelayMicros" .= (50000 :: Int)])
      worker <- spawn supervisor spec
      awaitReady worker 10000
      sendCommand worker CtlStart
      awaitMark worker "timer-pass" 10000
      threadDelay (delay index)
      signalProcessGroup sigKILL (childPid worker)
      threadDelay 50000
    replacementSpec <- roleProcess check "keiro/timer-worker" 5 (object ["fireDelayMicros" .= (50000 :: Int)])
    replacement <- spawn supervisor replacementSpec
    awaitReady replacement 10000
    sendCommand replacement CtlStart
    result <- waitUntil done 160
    _ <- stopGracefully supervisor replacement 2000
    pure result
  rows <- traverse (runStoreIO store . lookupTimer) timerIds
  streams <- traverse (\tid -> runStoreIO store (readStreamForward (StreamName ("kenshouTimer-" <> timerText tid)) (StreamVersion 0) 3)) timerIds
  ledgers <- discoverLedgers check.ledgerDirectory
  effects <- foldFacts ledgers Map.empty \counts fact ->
    pure if fact.kind == Effect then Map.insertWith (+) fact.key (1 :: Int) counts else counts
  let fired tid result = case result of
        Right (Just row) -> row.status == Fired && row.attempts >= 1 && row.firedEventId == Just (businessEventId tid)
        _ -> False
      bounded tid result = case result of
        Right (Just row) -> maybe False (\count -> count >= 1 && count <= row.attempts) (Map.lookup (timerText tid) effects)
        _ -> False
      oneEvent tid result = case result of
        Right events -> case Vector.toList events of
          [event] -> event.eventId == businessEventId tid
          _ -> False
        Left _ -> False
  pure
    [ ("random-kills-recovered-all-timers", length seeded == length timerIds && all (== Right ()) seeded && completed && and (zipWith fired timerIds rows)),
      ("random-kill-effects-bounded-by-attempts", and (zipWith bounded timerIds rows)),
      ("random-kill-business-events-once", and (zipWith oneEvent timerIds streams))
    ]

awaitCrashArm :: CheckEnv -> Int -> IO Bool
awaitCrashArm _ 0 = pure False
awaitCrashArm check remaining = do
  ledgers <- discoverLedgers check.ledgerDirectory
  found <- foldFacts ledgers False \seen fact -> pure (seen || fact.kind == Mark && fact.id == "crash-armed")
  if found then pure True else threadDelay 50000 >> awaitCrashArm check (remaining - 1)

skipLocked :: Scenario
skipLocked =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/timer/concurrency/skip-locked-claims-across-processes"),
      revision = 1,
      summary = "Runs competing timer-worker processes against a due population and checks single claims and effects.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = timerKnobs,
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
      run = runSkipLocked
    }

runSkipLocked :: RunContext -> IO ScenarioReport
runSkipLocked context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    now <- getCurrentTime
    let store = durableKirokuStore fixture
        count = fromIntegral (knobInt context.knobs (timerKnobName "timer.count")) :: Int
        workerCount = fromIntegral (knobInt context.knobs (timerKnobName "timer.worker-processes")) :: Int
        tickMs = fromIntegral (knobInt context.knobs (timerKnobName "timer.tick-interval-ms")) :: Int
        timerIds = map fixtureTimerId [0 .. count - 1]
        request tid = TimerRequest tid "kenshou" "timer-process-claims" (addUTCTime (-1) now) Null
        lookupOne tid = runStoreIO store (lookupTimer tid)
        done = do
          remaining <- runStoreIO store (runTransaction (Tx.statement () remainingTimerCount))
          pure (remaining == Right 0)
    seeded <- forM timerIds \tid -> runStoreIO store (runTransaction (scheduleTimerTx (request tid)))
    sealLedger check.ledger
    completed <- withSupervisor check \supervisor -> do
      workers <- forM [0 .. workerCount - 1] \workerIndex -> do
        spec <- roleProcess check "keiro/timer-worker" workerIndex (object [])
        child <- spawn supervisor spec
        awaitReady child 10000
        pure child
      forM_ workers (\child -> sendCommand child CtlStart)
      result <- waitUntil done (max 600 (3 * count * tickMs `div` (max 1 workerCount * 250)))
      forM_ workers (\child -> stopGracefully supervisor child 2000)
      pure result
    rows <- traverse lookupOne timerIds
    streams <- forM timerIds \tid -> runStoreIO store (readStreamForward (StreamName ("kenshouTimer-" <> timerText tid)) (StreamVersion 0) 3)
    ledgers <- discoverLedgers check.ledgerDirectory
    effects <- foldFacts ledgers Map.empty \counts fact ->
      pure if fact.kind == Effect then Map.insertWith (+) fact.key (1 :: Int) counts else counts
    let validRow tid result = case result of Right (Just row) -> row.timerId == tid && row.status == Fired && row.attempts == 1 && row.firedEventId == Just (businessEventId tid); _ -> False
        validStream tid result = case result of
          Right events -> case Vector.toList events of
            [event] -> event.eventId == businessEventId tid
            _ -> False
          Left _ -> False
        cells =
          [ ("all-timers-fired", length seeded == count && all (either (const False) (const True)) seeded && completed && and (zipWith validRow timerIds rows)),
            ("one-effect-per-timer", Map.size effects == count && all (\tid -> Map.lookup (timerText tid) effects == Just 1) timerIds),
            ("one-business-event-per-timer", and (zipWith validStream timerIds streams))
          ]
    recordTimerCells check cells

waitUntil :: IO Bool -> Int -> IO Bool
waitUntil _ 0 = pure False
waitUntil predicate remaining = do
  complete <- predicate
  if complete then pure True else threadDelay 250000 >> waitUntil predicate (remaining - 1)

remainingTimerCount :: Statement.Statement () Int64
remainingTimerCount =
  Statement.preparable
    "SELECT count(*) FROM keiro.keiro_timers WHERE status <> 'fired'"
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

resumeGuardStatement :: Statement.Statement UUID.UUID (Maybe (Maybe Text.Text, Bool, Bool))
resumeGuardStatement =
  Statement.preparable
    "SELECT last_error, resume_claim_token IS NULL, resume_lease_until IS NULL FROM keiro.keiro_timers WHERE timer_id = $1"
    (Encoders.param (Encoders.nonNullable Encoders.uuid))
    (Decoders.rowMaybe ((,,) <$> Decoders.column (Decoders.nullable Decoders.text) <*> Decoders.column (Decoders.nonNullable Decoders.bool) <*> Decoders.column (Decoders.nonNullable Decoders.bool)))

fixtureTimerId :: Int -> TimerId
fixtureTimerId number = TimerId $ UUID.V5.generateNamed UUID.V5.namespaceURL (ByteString.unpack (TextEncoding.encodeUtf8 ("kenshou:timer:process-claim:" <> Text.pack (show number))))

timerText :: TimerId -> Text.Text
timerText (TimerId value) = UUID.toText value
