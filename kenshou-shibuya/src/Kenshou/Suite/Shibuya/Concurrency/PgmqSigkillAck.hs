module Kenshou.Suite.Shibuya.Concurrency.PgmqSigkillAck (scenario) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (forConcurrently)
import Control.Concurrent.STM (atomically)
import Control.Exception (SomeException, displayException, try)
import Control.Monad (forM, unless)
import Data.Aeson (Value (..), object, withObject, (.:), (.=))
import Data.Aeson.Types (parseEither)
import Data.Int (Int64)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (UTCTime, diffUTCTime)
import Kenshou.Check.Process (Child, ProgressSnapshot (..), awaitMark, awaitReady, killChild, progress, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (deriveSeed, withCheck)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension (PgDurability (..), PgVersion (..), noDimensions, postgresDimensions)
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId, unSeed)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobInt, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Suite.Shibuya.Fixture.Pgmq (PgmqFixture (..), dlqRowsWithReason, effectDeliveries, ensureEffectsTable, queueRows, runPgmqStack, withPgmqFixture)
import Pgmq.Effectful (MessageBody (..), SendMessage (..), sendMessage)
import Pgmq.Effectful qualified as Pgmq
import Shibuya.Adapter.Pgmq (queueNameToText)
import System.Exit (ExitCode (..))
import System.Timeout (timeout)

scenario :: Scenario
scenario =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/pgmq-adapter/concurrency/sigkill-between-handler-success-and-ack"),
      revision = 1,
      summary = "SIGKILL at the durable-effect gate proves bounded PGMQ redelivery and crash-local duplicates.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs =
        [ KnobSpec (name "crash.kills") "Distinct consumer processes killed per arm" KnobInt (VInt 20) (IntRange 1 20) [],
          KnobSpec (name "pgmq-adapter.visibility-timeout-seconds") "Visibility timeout of killed deliveries" KnobInt (VInt 5) (IntRange 5 30) []
        ],
      dimensions = postgresDimensions (PgDurable :| []) (Pg18 :| [Pg17]) noDimensions,
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaPgmq] [] False)},
      knownDefect = Nothing,
      run = runCrashes
    }
  where
    name raw = either (error . Text.unpack) id (mkKnobName raw)

data KillEvidence = KillEvidence
  { identifier :: !Text,
    startedAt :: !UTCTime,
    effectMarkSeen :: !Bool
  }

data ArmEvidence = ArmEvidence
  { sentIds :: ![Text],
    killTarget :: !Int,
    visibilitySeconds :: !Int,
    killed :: ![KillEvidence],
    killEffects :: ![(Text, Int64, UTCTime, UTCTime)],
    recoveryEffects :: ![(Text, Int64, UTCTime, UTCTime)],
    remainingRows :: !Int64,
    recoveryExit :: !ExitCode
  }

data BudgetEvidence = BudgetEvidence
  { attempts :: ![Int64],
    sourceRows :: !Int64,
    deadLetterRows :: !Int64,
    reasonRows :: !Int64,
    finalExit :: !ExitCode
  }

runCrashes :: RunContext -> IO ScenarioReport
runCrashes context = do
  let kills = fromIntegral (knobInt context.knobs (name "crash.kills"))
      visibility = fromIntegral (knobInt context.knobs (name "pgmq-adapter.visibility-timeout-seconds"))
  result <- try @SomeException $ timeout 210000000 $ do
    gated <- runArm context "gated" False kills visibility
    random <- runArm context "random" True kills visibility
    budget <- runBudget context
    pure (gated, random, budget)
  case result of
    Left err -> pure (failedWith ["sigkill-ack-exception"] (Text.pack (displayException err)))
    Right Nothing -> pure (failedWith ["sigkill-ack-timeout"] "The PGMQ SIGKILL arms exceeded 210 seconds")
    Right (Just (gated, random, budget)) -> do
      let failures = checkArm "gated" gated <> checkArm "random" random <> checkBudget budget
      putSummary context Verdicts "pgmq-sigkill-ack" (object ["gated" .= armValue gated, "random" .= armValue random, "budgetBurnedByCrashes" .= budgetValue budget])
      pure $ if null failures then passed else failedWith failures (Text.intercalate "; " failures)
  where
    name raw = either (error . Text.unpack) id (mkKnobName raw)

runBudget :: RunContext -> IO BudgetEvidence
runBudget context = withPgmqFixture context "kill_budget_source" 4 $ \source ->
  withPgmqFixture context "kill_budget_dlq" 4 $ \dlq -> do
    ensureEffectsTable source.pool
    sent <- runPgmqStack source.pool (sendMessage (SendMessage source.queue (MessageBody (String "budget")) Nothing))
    identifier <- either (fail . show) (pure . Text.pack . show . Pgmq.unMessageId) sent
    finalExit <- withCheck context $ \check -> withSupervisor check $ \supervisor -> do
      mapM_
        ( \index -> do
            let args = budgetArgs source dlq ("budget_kill_" <> Text.pack (show index)) True
            spec <- roleProcess check "shibuya/pgmq-consumer" (41 + index) args
            child <- spawn supervisor spec
            awaitReady child 5000
            sendCommand child CtlStart
            awaitMark child "effect-done" 9000
            killChild supervisor child
        )
        [0 .. (2 :: Int)]
      spec <- roleProcess check "shibuya/pgmq-consumer" 44 (budgetArgs source dlq "budget_final" False)
      final <- spawn supervisor spec
      awaitReady final 5000
      sendCommand final CtlStart
      awaitMark final "running" 5000
      moved <- timeout 10000000 $ waitForBudgetMove source dlq
      unless (moved == Just ()) (fail "PGMQ crash-exhausted message did not reach the dead-letter queue")
      stopGracefully supervisor final 5000
    rows <- concat <$> traverse (\index -> effectDeliveries source.pool ("budget_kill_" <> Text.pack (show index))) [0 .. (2 :: Int)]
    let attempts = sort [attempt | (messageId, attempt, _, _) <- rows, messageId == identifier]
    sourceRows <- queueRows source
    deadLetterRows <- queueRows dlq
    reasonRows <- dlqRowsWithReason dlq "max_retries_exceeded"
    pure BudgetEvidence {attempts, sourceRows, deadLetterRows, reasonRows, finalExit}

budgetArgs :: PgmqFixture -> PgmqFixture -> Text -> Bool -> Value
budgetArgs source dlq arm gated =
  object
    [ "queue" .= queueNameToText source.queue,
      "arm" .= arm,
      "visibilitySeconds" .= (2 :: Int),
      "extendLease" .= False,
      "handlerMicros" .= (0 :: Int),
      "gateAfterEffect" .= gated,
      "retryBudget" .= (3 :: Int),
      "deadLetterQueue" .= queueNameToText dlq.queue
    ]

waitForBudgetMove :: PgmqFixture -> PgmqFixture -> IO ()
waitForBudgetMove source dlq = do
  sourceCount <- queueRows source
  deadLetterCount <- queueRows dlq
  unless (sourceCount == 0 && deadLetterCount == 1) $ threadDelay 50000 >> waitForBudgetMove source dlq

checkBudget :: BudgetEvidence -> [Text]
checkBudget evidence =
  ["budget-effect-attempts" | evidence.attempts /= [0, 1, 2]]
    <> ["budget-source-not-drained" | evidence.sourceRows /= 0]
    <> ["budget-dead-letter-count" | evidence.deadLetterRows /= 1]
    <> ["budget-reason" | evidence.reasonRows /= 1]
    <> ["budget-final-exit" | evidence.finalExit /= ExitSuccess]

budgetValue :: BudgetEvidence -> Value
budgetValue evidence =
  object
    [ "attempts" .= evidence.attempts,
      "sourceRows" .= evidence.sourceRows,
      "deadLetterRows" .= evidence.deadLetterRows,
      "reasonRows" .= evidence.reasonRows,
      "finalExit" .= show evidence.finalExit
    ]

runArm :: RunContext -> Text -> Bool -> Int -> Int -> IO ArmEvidence
runArm context arm randomTiming kills visibility = withPgmqFixture context ("kill_" <> arm) 4 $ \fixture -> do
  ensureEffectsTable fixture.pool
  sent <- runPgmqStack fixture.pool $ traverse (\index -> sendMessage (SendMessage fixture.queue (MessageBody (Number (fromIntegral index))) Nothing)) [1 .. 5 * kills]
  sentIds <- either (fail . show) (pure . fmap (Text.pack . show . Pgmq.unMessageId)) sent
  (killed, recoveryExit) <- withCheck context $ \check -> withSupervisor check $ \supervisor -> do
    workers <- forM [0 .. kills - 1] $ \index -> do
      let label = arm <> "_kill_" <> Text.pack (show index)
          args = workerArgs fixture label True (if randomTiming then 100000 else 0) visibility
      spec <- roleProcess check "shibuya/pgmq-consumer" (if randomTiming then index + 20 else index) args
      child <- spawn supervisor spec
      awaitReady child 5000
      pure child
    mapM_ (`sendCommand` CtlStart) workers
    killed <- forConcurrently (zip [0 .. kills - 1] workers) $ \(index, child) -> do
      awaitMark child "delivery-start" 5000
      start <- mark child "delivery-start"
      (identifier, startedAt) <- either fail pure (parseEither (withObject "delivery-start" $ \value -> (,) <$> value .: "messageId" <*> value .: "at") start)
      if randomTiming
        then do
          let delay = fromIntegral (deriveSeed (unSeed context.seed) ("pgmq-kill-" <> Text.pack (show index)) `mod` 160000)
          threadDelay delay
        else awaitMark child "effect-done" 5000
      snapshot <- atomically (progress child)
      killChild supervisor child
      pure (KillEvidence identifier startedAt (Map.member "effect-done" snapshot.marks))
    let recoveryLabel = arm <> "_recovery"
        recoveryArgs = workerArgs fixture recoveryLabel False 20000 visibility
    spec <- roleProcess check "shibuya/pgmq-consumer" (if randomTiming then 40 else 20) recoveryArgs
    child <- spawn supervisor spec
    awaitReady child 5000
    sendCommand child CtlStart
    awaitMark child "running" 5000
    completed <- timeout ((visibility + 20) * 1000000) (waitForRecovery fixture recoveryLabel sentIds)
    unless (completed == Just ()) (fail "PGMQ crash recovery did not process every ID")
    recoveryExit <- stopGracefully supervisor child 5000
    pure (killed, recoveryExit)
  killEffects <- concat <$> traverse (\index -> effectDeliveries fixture.pool (arm <> "_kill_" <> Text.pack (show index))) [0 .. kills - 1]
  recoveryEffects <- effectDeliveries fixture.pool (arm <> "_recovery")
  remainingRows <- queueRows fixture
  pure ArmEvidence {sentIds, killTarget = kills, visibilitySeconds = visibility, killed, killEffects, recoveryEffects, remainingRows, recoveryExit}

workerArgs :: PgmqFixture -> Text -> Bool -> Int -> Int -> Value
workerArgs fixture arm gated micros visibility =
  object
    [ "queue" .= queueNameToText fixture.queue,
      "arm" .= arm,
      "visibilitySeconds" .= visibility,
      "extendLease" .= False,
      "handlerMicros" .= micros,
      "gateAfterEffect" .= gated,
      "retryBudget" .= (25 :: Int)
    ]

mark :: Child -> Text -> IO Value
mark child name = do
  snapshot <- atomically (progress child)
  maybe (fail ("worker mark missing: " <> Text.unpack name)) pure (Map.lookup name snapshot.marks)

waitForRecovery :: PgmqFixture -> Text -> [Text] -> IO ()
waitForRecovery fixture arm identifiers = do
  effects <- effectDeliveries fixture.pool arm
  unless (Set.fromList identifiers `Set.isSubsetOf` Set.fromList [identifier | (identifier, _, _, _) <- effects]) $ do
    threadDelay 50000
    waitForRecovery fixture arm identifiers

checkArm :: Text -> ArmEvidence -> [Text]
checkArm arm evidence =
  let expected = Set.fromList evidence.sentIds
      killedIds = Set.fromList [item.identifier | item <- evidence.killed]
      effects = evidence.killEffects <> evidence.recoveryEffects
      counts = Map.fromListWith (+) [(identifier, 1 :: Int) | (identifier, _, _, _) <- effects]
      recovered = Map.fromList [(identifier, (attempt, startedAt)) | (identifier, attempt, startedAt, _) <- evidence.recoveryEffects]
      firstEffects = Map.fromList [(identifier, (attempt, startedAt)) | (identifier, attempt, startedAt, _) <- evidence.killEffects]
      unallowed = [identifier | (identifier, count) <- Map.toList counts, count > 1, identifier `Set.notMember` killedIds]
      late = [item.identifier | item <- evidence.killed, Just (_, recoveredAt) <- [Map.lookup item.identifier recovered], diffUTCTime recoveredAt item.startedAt > fromIntegral evidence.visibilitySeconds + 2.05]
      wrongAttempts = [item.identifier | item <- evidence.killed, Just (attempt, _) <- [Map.lookup item.identifier recovered], attempt /= 1]
      falseMarks = [item.identifier | item <- evidence.killed, item.effectMarkSeen, Map.notMember item.identifier firstEffects]
      prefix = arm <> ": "
   in [prefix <> "sent-count" | length evidence.sentIds /= 5 * evidence.killTarget]
        <> [prefix <> "kill-count" | length evidence.killed /= evidence.killTarget || Set.size killedIds /= evidence.killTarget]
        <> [prefix <> "message-loss" | expected /= Map.keysSet counts]
        <> [prefix <> "recovery-missing" | Set.fromList [identifier | (identifier, _, _, _) <- evidence.recoveryEffects] /= expected]
        <> [prefix <> "duplicate-outside-kill" | not (null unallowed)]
        <> [prefix <> "duplicate-budget" | any (> 2) (Map.elems counts)]
        <> [prefix <> "redelivery-late" | not (null late)]
        <> [prefix <> "read-count-not-incremented" | not (null wrongAttempts)]
        <> [prefix <> "effect-mark-not-durable" | not (null falseMarks)]
        <> [prefix <> "gated-effect-count" | arm == "gated" && length evidence.killEffects /= evidence.killTarget]
        <> [prefix <> "queue-not-drained" | evidence.remainingRows /= 0]
        <> [prefix <> "recovery-exit" | evidence.recoveryExit /= ExitSuccess]

armValue :: ArmEvidence -> Value
armValue evidence =
  object
    [ "sent" .= length evidence.sentIds,
      "killTarget" .= evidence.killTarget,
      "visibilitySeconds" .= evidence.visibilitySeconds,
      "killed" .= length evidence.killed,
      "killedDistinct" .= Set.size (Set.fromList [item.identifier | item <- evidence.killed]),
      "effectMarks" .= length [() | item <- evidence.killed, item.effectMarkSeen],
      "effectsBeforeKill" .= length evidence.killEffects,
      "recoveryEffects" .= length evidence.recoveryEffects,
      "duplicates" .= (length (evidence.killEffects <> evidence.recoveryEffects) - length evidence.sentIds),
      "maximumRedeliverySeconds" .= maximum (0 : [realToFrac (diffUTCTime recoveredAt item.startedAt) :: Double | item <- evidence.killed, Just (_, recoveredAt) <- [Map.lookup item.identifier recovered]]),
      "remainingRows" .= evidence.remainingRows,
      "recoveryExit" .= show evidence.recoveryExit
    ]
  where
    recovered = Map.fromList [(identifier, (attempt, startedAt)) | (identifier, attempt, startedAt, _) <- evidence.recoveryEffects]
