module Kenshou.Suite.Keiro.Timer.Concurrency (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically)
import Control.Monad (forM, forM_)
import Data.Aeson (Value (Null), object, (.=))
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
import Keiro.Timer (TimerId (..), TimerRequest (..), TimerRow (..), TimerStatus (..), lookupTimer, scheduleTimerTx)
import Kenshou.Check.Fact (Fact (..), FactKind (..))
import Kenshou.Check.Ledger (sealLedger)
import Kenshou.Check.Ledger.Read (discoverLedgers, foldFacts)
import Kenshou.Check.Process (ProgressSnapshot (..), awaitMark, awaitReady, progress, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (CheckEnv (..), withCheck)
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (knobInt)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Timer.Knobs (timerKnobName, timerKnobs)
import Kenshou.Suite.Keiro.Timer.Oracle (recordTimerCells)
import Kenshou.Suite.Keiro.Timer.Roles (businessEventId)
import Kenshou.Suite.Keiro.Workflow.Fixture (durableKirokuStore, withDurableStore)
import Kiroku.Store (defaultConnectionSettings, readStreamForward, runStoreIO, runTransaction)
import Kiroku.Store.Types (RecordedEvent (..), StreamName (..), StreamVersion (..))

scenarios :: [Scenario]
scenarios = [skipLocked, sigkillBetweenFireAndMark, slowFireDoubleFires]

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
    recordTimerCells check cells

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

fixtureTimerId :: Int -> TimerId
fixtureTimerId number = TimerId $ UUID.V5.generateNamed UUID.V5.namespaceURL (ByteString.unpack (TextEncoding.encodeUtf8 ("kenshou:timer:process-claim:" <> Text.pack (show number))))

timerText :: TimerId -> Text.Text
timerText (TimerId value) = UUID.toText value
