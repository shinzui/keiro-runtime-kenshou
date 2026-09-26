module Kenshou.Suite.Shibuya.Concurrency.PgmqOutageRestart (scenario, backendScenario) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (race, wait, waitCatch, withAsync)
import Control.Concurrent.MVar (MVar, isEmptyMVar, newEmptyMVar, readMVar, tryPutMVar)
import Control.Exception (SomeException, displayException, finally, try)
import Control.Monad (unless, void, when)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (getCurrentTime)
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, Limit (..), Persistence (..), UnliftStrategy (..), liftIO, withEffToIO)
import Effectful.Error.Static (Error)
import Hasql.Pool (Pool)
import Kenshou.Check.Fault (Fault (..), FaultHandle (..))
import Kenshou.Check.Fault.Postgres (Backend (..), BackendSelector (..), listBackends, terminateBackends)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension (PgDurability (..), PgVersion (..), noDimensions, postgresDimensions)
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..), ServerControl (..), StopMode (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobInt, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (CohortScope (..), KnownDefect (..), PackageCondition (..), Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Suite.Shibuya.Fixture.Pgmq (PgmqFixture (..), effectRows, ensureEffectsTable, insertEffect, queueRows, runPgmqStack, withPgmqConnectionPool, withPgmqFixture, withPgmqNamedConnectionPool)
import Pgmq.Effectful (BatchSendMessage (..), MessageBody (..), Pgmq, PgmqRuntimeError, batchSendMessage)
import Pgmq.Effectful qualified as Pgmq
import Shibuya.Adapter.Pgmq (PgmqAdapterConfig (..), PgmqAdapterEnv (..), PollRetryConfig (..), PollingConfig (..), defaultConfig, mkPgmqAdapterEnv, pgmqAdapter)
import Shibuya.App (AppConfig (..), QueueProcessor (..), SupervisionStrategy (..), defaultAppConfig, defaultShutdownConfig, mkProcessor, runApp, stopApp, stopAppGracefully, waitApp)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Core.Types (Attempt (..), Envelope (..), MessageId (..))
import Shibuya.Policy (Concurrency (..))
import Shibuya.Telemetry.Effect (Tracing)
import System.Timeout (timeout)

scenario :: Scenario
scenario = outageScenario "postgres-outage-and-the-restart-loop" "postmaster-restart"

backendScenario :: Scenario
backendScenario = outageScenario "backend-termination-and-the-restart-loop" "terminate-backends"

outageScenario :: Text -> Text -> Scenario
outageScenario scenarioName fault =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId ("shibuya/pgmq-adapter/concurrency/" <> scenarioName)),
      revision = 1,
      summary = "Exercises polling and acknowledgement faults with a producer, a durable effect ledger and an application restart loop.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs =
        [KnobSpec (name "workload.messages") "Messages sent by the concurrent producer per arm" KnobInt (VInt 100) (IntRange 20 200) []]
          <> [KnobSpec (name "outage.seconds") "Postmaster downtime" KnobInt (VInt 10) (IntRange 1 15) [] | fault == "postmaster-restart"],
      dimensions = postgresDimensions (PgDurable :| []) (Pg18 :| [Pg17]) noDimensions,
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaPgmq] [] (fault == "postmaster-restart"))},
      knownDefect =
        Just $
          if fault == "postmaster-restart"
            then
              KnownDefect
                { reference = "mori://shinzui/shibuya-pgmq-adapter/docs/changelog",
                  summary = "The released adapter does not call onAckFailure after an exhausted acknowledgement error",
                  expectedFailures = ["acknowledgement: ack-failure-hook-not-fired"],
                  appliesTo = OnlyWhen (VersionBelow "shibuya-pgmq-adapter" "0.16.1.0" :| [])
                }
            else
              KnownDefect
                { reference = "mori://shinzui/pgmq-hs/okf/bug-reports/concepts/BUG-1",
                  summary = "The PGMQ transient-error classifier treats a backend disconnect as permanent",
                  expectedFailures = ["polling: unexpected-app-exit", "acknowledgement: unexpected-app-exit"],
                  appliesTo = OnlyWhen (VersionBelow "pgmq-effectful" "0.6.1.2" :| [])
                },
      run = runOutage fault
    }
  where
    name raw = either (error . Text.unpack) id (mkKnobName raw)

data Stage = Polling | Acknowledgement deriving stock (Eq, Show)

data AppEnd = AppStopped | AppReturned | AppWaitException Text | AppRunException Text deriving stock (Eq, Show)

data ArmEvidence = ArmEvidence
  { sent :: !Int,
    effects :: !Int,
    missingIds :: !Int,
    unexpectedIds :: !Int,
    duplicateIds :: !Int,
    unrelatedDuplicates :: !Int,
    remainingRows :: !Int,
    faultVictims :: !Int,
    producerAttempts :: !Int,
    applicationExits :: !Int,
    waitExceptions :: ![Text],
    ackFailureHooks :: !Int,
    drained :: !Bool,
    stopped :: !Bool
  }

runOutage :: Text -> RunContext -> IO ScenarioReport
runOutage fault context = do
  let seconds = if fault == "postmaster-restart" then fromIntegral (knobInt context.knobs (name "outage.seconds")) else 0
      messages = fromIntegral (knobInt context.knobs (name "workload.messages"))
  result <- try @SomeException $ timeout 240000000 $ do
    polling <- runArm context fault seconds messages Polling
    acknowledgement <- runArm context fault seconds messages Acknowledgement
    pure (polling, acknowledgement)
  case result of
    Left err -> pure (failedWith ["outage-exception"] (Text.pack (displayException err)))
    Right Nothing -> pure (failedWith ["outage-timeout"] "Outage arms exceeded four minutes")
    Right (Just (polling, acknowledgement)) -> do
      let failures = checkArm "polling" fault polling <> checkArm "acknowledgement" fault acknowledgement
      putSummary context Verdicts "pgmq-outage-restart" (object ["fault" .= fault, "outageSeconds" .= seconds, "polling" .= armValue polling, "acknowledgement" .= armValue acknowledgement])
      pure $ if null failures then passed else failedWith failures (Text.intercalate "; " failures)
  where
    name raw = either (error . Text.unpack) id (mkKnobName raw)

runArm :: RunContext -> Text -> Int -> Int -> Stage -> IO ArmEvidence
runArm context fault outageSeconds messages stage =
  withPgmqFixture context (if stage == Polling then "outage_poll" else "outage_ack") 4 $ \source ->
    withPgmqConnectionPool (requirePostgres context).connectionString 4 $ \oraclePool -> do
      ensureEffectsTable oraclePool
      let arm = if stage == Polling then "outage-polling" else "outage-acknowledgement"
      seeded <- if stage == Acknowledgement then sendMessages source 1 0 else pure []
      stopRequested <- newEmptyMVar
      handlerStarted <- newEmptyMVar
      releaseHandler <- newEmptyMVar
      producerStart <- newEmptyMVar
      appEnds <- newIORef []
      ackFailures <- newIORef 0
      producerAttempts <- newIORef 0
      let special = case seeded of identifier : _ -> Just identifier; [] -> Nothing
          handler message = do
            let MessageId identifier = message.envelope.messageId
                attempt = maybe (-1) (\(Attempt number) -> fromIntegral number) message.envelope.attempt
            now <- liftIO getCurrentTime
            liftIO $ withPgmqConnectionPool (requirePostgres context).connectionString 2 $ \effectPool ->
              insertEffect effectPool arm identifier attempt now now Nothing
            when (Just identifier == special) $ liftIO $ do
              void (tryPutMVar handlerStarted ())
              readMVar releaseHandler
            pure AckOk
      withAsync (consumerLoop (requirePostgres context).connectionString source stage handler stopRequested appEnds ackFailures) $ \consumer ->
        withAsync (readMVar producerStart >> produceUntilSent (requirePostgres context).connectionString source messages producerAttempts) $ \producer -> do
          case stage of
            Polling -> awaitActivePoll (requirePostgres context)
            Acknowledgement -> requireSignal "ack-handler-not-started" handlerStarted >> threadDelay 500000
          victims <- injectOutage (requirePostgres context) fault outageSeconds releaseHandler producerStart
          sentByProducer <- wait producer
          let identifiers = seeded <> sentByProducer
          withPgmqConnectionPool (requirePostgres context).connectionString 4 $ \finalPool -> do
            let finalSource = PgmqFixture finalPool source.queue
            drained <- maybe False (const True) <$> timeout 120000000 (waitForAll finalPool finalSource arm identifiers)
            void (tryPutMVar stopRequested ())
            stopped <- maybe False (either (const False) (const True)) <$> timeout 5000000 (waitCatch consumer)
            rows <- effectRows finalPool arm
            remaining <- fromIntegral <$> queueRows finalSource
            ends <- reverse <$> readIORef appEnds
            hooks <- readIORef ackFailures
            attempts <- readIORef producerAttempts
            let expected = Set.fromList identifiers
                observed = Map.fromListWith (+) [(identifier, 1 :: Int) | (identifier, _, _) <- rows]
                missing = Set.size (expected `Set.difference` Map.keysSet observed)
                unexpected = Set.size (Map.keysSet observed `Set.difference` expected)
                duplicates = length [() | (identifier, count) <- Map.toList observed, identifier `Set.member` expected, count > 1]
                unrelated = length [() | (identifier, count) <- Map.toList observed, count > 1, Just identifier /= special]
                waitErrors = [message | AppWaitException message <- ends]
            pure $ ArmEvidence (length identifiers) (length rows) missing unexpected duplicates unrelated remaining victims attempts (length ends) waitErrors hooks drained stopped

sendMessages :: PgmqFixture -> Int -> Int -> IO [Text]
sendMessages source messages offset = do
  result <- runPgmqStack source.pool $ batchSendMessage (BatchSendMessage source.queue [MessageBody (object ["number" .= number]) | number <- [offset + 1 .. offset + messages]] Nothing)
  either (ioError . userError . show) (pure . fmap (Text.pack . show . Pgmq.unMessageId)) result

produceUntilSent :: Text -> PgmqFixture -> Int -> IORef Int -> IO [Text]
produceUntilSent connection source messages attempts = go (0 :: Int)
  where
    go failures
      | failures >= 200 = fail "producer could not send after PostgreSQL outage"
      | otherwise = do
          atomicModifyIORef' attempts (\count -> (count + 1, ()))
          sent <- try @SomeException $ withPgmqConnectionPool connection 2 $ \pool ->
            sendMessages (PgmqFixture pool source.queue) messages 1000
          case sent of
            Right identifiers -> pure identifiers
            Left _ -> threadDelay 200000 >> go (failures + 1)

consumerLoop :: Text -> PgmqFixture -> Stage -> (Message '[Pgmq, Tracing, Error PgmqRuntimeError, IOE] Value -> Eff '[Pgmq, Tracing, Error PgmqRuntimeError, IOE] AckDecision) -> MVar () -> IORef [AppEnd] -> IORef Int -> IO ()
consumerLoop connection source stage handler stopRequested ends ackFailures = go
  where
    go = do
      stopped <- not <$> isEmptyMVar stopRequested
      unless stopped $ do
        ended <- try @SomeException $ withPgmqNamedConnectionPool connection 10 "kenshou-shibuya-outage-consumer" $ \pool ->
          runPgmqStack pool (runInstance pool source stage handler stopRequested ackFailures)
        let end = case ended of
              Left err -> AppRunException (Text.pack (displayException err))
              Right (Left err) -> AppRunException (Text.pack (show err))
              Right (Right value) -> value
        stoppedAfter <- not <$> isEmptyMVar stopRequested
        unless stoppedAfter $ do
          atomicModifyIORef' ends (\observed -> (end : observed, ()))
          threadDelay 200000
          go

runInstance :: Pool -> PgmqFixture -> Stage -> (Message '[Pgmq, Tracing, Error PgmqRuntimeError, IOE] Value -> Eff '[Pgmq, Tracing, Error PgmqRuntimeError, IOE] AckDecision) -> MVar () -> IORef Int -> Eff '[Pgmq, Tracing, Error PgmqRuntimeError, IOE] AppEnd
runInstance pool source stage handler stopRequested ackFailures = do
  let defaults = defaultConfig source.queue
      pollBudget = if stage == Acknowledgement then defaults.pollRetry {maxAttempts = 100, initialBackoff = 1, maxBackoff = 1} else defaults.pollRetry
      pollingMode = if stage == Acknowledgement then StandardPolling 4 else LongPolling 2 100
      config = defaults {polling = pollingMode, visibilityTimeout = 5, maxRetries = 100, pollRetry = pollBudget}
      environment = (mkPgmqAdapterEnv pool) {onAckFailure = \_ _ -> atomicModifyIORef' ackFailures (\count -> (count + 1, ()))}
  adapterResult <- pgmqAdapter environment config
  case adapterResult of
    Left err -> error (show err)
    Right adapter -> do
      let workerConcurrency = if stage == Acknowledgement then Serial else Async 4
      started <- runApp defaultAppConfig {strategy = StopAllOnFailure} [(ProcessorId "pgmq-outage", (mkProcessor adapter handler) {concurrency = workerConcurrency})]
      case started of
        Left err -> error (show err)
        Right handle -> withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO -> liftIO $ do
          outcome <- try @SomeException (race (runInIO (waitApp handle)) (readMVar stopRequested))
          graceful <- timeout 2000000 (try @SomeException (runInIO (stopAppGracefully defaultShutdownConfig handle)))
          case graceful of
            Nothing -> void $ timeout 2000000 (try @SomeException (runInIO (stopApp handle)))
            Just _ -> pure ()
          pure $ case outcome of
            Left err -> AppWaitException (Text.pack (displayException err))
            Right (Left ()) -> AppReturned
            Right (Right ()) -> AppStopped

awaitActivePoll :: PostgresEnv -> IO ()
awaitActivePoll postgres = do
  reached <- timeout 10000000 loop
  unless (reached == Just ()) $ fail "consumer did not reach a PGMQ long poll"
  where
    loop = do
      backends <- listBackends postgres
      let active = any (\backend -> backend.applicationName == "kenshou-shibuya-outage-consumer" && backend.state == "active" && "read_with_poll" `Text.isInfixOf` backend.query) backends
      unless active $ threadDelay 20000 >> loop

requireSignal :: String -> MVar () -> IO ()
requireSignal label signal = do
  observed <- timeout 10000000 (readMVar signal)
  unless (observed == Just ()) $ fail label

injectOutage :: PostgresEnv -> Text -> Int -> MVar () -> MVar () -> IO Int
injectOutage postgres fault seconds releaseHandler producerStart =
  if fault == "postmaster-restart"
    then case postgres.control of
      Nothing -> fail "postmaster control unavailable"
      Just control -> do
        (control.stopServer StopImmediate >> releaseAndProduce >> threadDelay (seconds * 1000000)) `finally` control.startServer
        pure 1
    else do
      handle <- (terminateBackends postgres (ByApplicationName "kenshou-shibuya-outage-consumer")).inject
      releaseAndProduce
      pure $ case handle.details of
        Object details -> case KeyMap.lookup "victims" details of
          Just (Array victims) -> Vector.length victims
          _ -> 0
        _ -> 0
  where
    releaseAndProduce = do
      void (tryPutMVar releaseHandler ())
      void (tryPutMVar producerStart ())

waitForAll :: Pool -> PgmqFixture -> Text -> [Text] -> IO ()
waitForAll oraclePool source arm identifiers = do
  rows <- effectRows oraclePool arm
  remaining <- queueRows source
  let observed = Set.fromList [identifier | (identifier, _, _) <- rows]
  unless (Set.fromList identifiers `Set.isSubsetOf` observed && remaining == 0) $ threadDelay 100000 >> waitForAll oraclePool source arm identifiers

checkArm :: Text -> Text -> ArmEvidence -> [Text]
checkArm label fault evidence =
  let prefix = label <> ": "
   in [prefix <> "fault-not-triggered" | evidence.faultVictims < 1]
        <> [prefix <> "producer-not-retried" | fault == "postmaster-restart" && evidence.producerAttempts < 2]
        <> [prefix <> "message-loss" | evidence.missingIds > 0 || evidence.unexpectedIds > 0 || evidence.remainingRows > 0 || not evidence.drained]
        <> [prefix <> "unrelated-duplicate-effect" | evidence.unrelatedDuplicates > 0]
        <> [prefix <> "polling-duplicate-effect" | label == "polling" && evidence.duplicateIds > 0]
        <> [prefix <> "restart-loop-stuck" | not evidence.stopped]
        <> [prefix <> "unexpected-app-exit" | fault == "terminate-backends" && evidence.applicationExits > 0]
        <> [prefix <> "poll-exit-not-observed" | fault == "postmaster-restart" && label == "polling" && evidence.applicationExits == 0]
        <> [prefix <> "ack-failure-hook-not-fired" | fault == "postmaster-restart" && label == "acknowledgement" && evidence.ackFailureHooks == 0]
        <> [prefix <> "ack-failure-not-visible" | fault == "postmaster-restart" && label == "acknowledgement" && null evidence.waitExceptions]

armValue :: ArmEvidence -> Value
armValue evidence =
  object
    [ "sent" .= evidence.sent,
      "effects" .= evidence.effects,
      "missingIds" .= evidence.missingIds,
      "unexpectedIds" .= evidence.unexpectedIds,
      "duplicateIds" .= evidence.duplicateIds,
      "unrelatedDuplicates" .= evidence.unrelatedDuplicates,
      "remainingRows" .= evidence.remainingRows,
      "faultVictims" .= evidence.faultVictims,
      "producerAttempts" .= evidence.producerAttempts,
      "applicationExits" .= evidence.applicationExits,
      "waitExceptions" .= evidence.waitExceptions,
      "ackFailureHooks" .= evidence.ackFailureHooks,
      "drained" .= evidence.drained,
      "stopped" .= evidence.stopped
    ]
