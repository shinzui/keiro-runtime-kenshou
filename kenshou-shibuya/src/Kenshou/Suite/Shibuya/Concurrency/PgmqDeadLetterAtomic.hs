module Kenshou.Suite.Shibuya.Concurrency.PgmqDeadLetterAtomic (scenario) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (race, withAsync)
import Control.Exception (SomeException, try)
import Control.Monad (forM_, unless, when)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as ByteString
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, Limit (..), Persistence (..), UnliftStrategy (..), liftIO, withEffToIO)
import Effectful.Error.Static (Error)
import Hasql.Pool (Pool)
import Kenshou.Check.Fault (Fault (..), FaultHandle (..))
import Kenshou.Check.Fault.Network (TcpProxy, armResponseBarrier, proxiedConnectionString, queryBarrierReached, releaseResponseBarrier, resetConnections, withTcpProxy)
import Kenshou.Check.Fault.Postgres (BackendSelector (..), terminateBackends)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension (PgDurability (..), PgVersion (..), noDimensions, postgresDimensions)
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobInt, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (CohortScope (..), KnownDefect (..), PackageCondition (..), Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Suite.Shibuya.Fixture.Pgmq (PgmqFixture (..), queueConservationIds, queueConservationSnapshot, queueRows, runPgmqStack, withPgmqFixture, withPgmqNamedConnectionPool)
import Pgmq.Effectful (BatchSendMessage (..), MessageBody (..), Pgmq, PgmqRuntimeError, batchSendMessage)
import Pgmq.Effectful qualified as Pgmq
import Shibuya.Adapter.Pgmq (PgmqAdapterConfig (..), PollingConfig (..), defaultConfig, directDeadLetter, mkPgmqAdapterEnv, pgmqAdapter)
import Shibuya.App (AppConfig (..), QueueProcessor (..), ShutdownConfig (..), defaultAppConfig, defaultShutdownConfig, mkProcessor, runApp, stopAppGracefully, waitApp)
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..))
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Policy (Concurrency (..))
import Shibuya.Telemetry.Effect (Tracing)
import System.Timeout (timeout)

scenario :: Scenario
scenario =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/pgmq-adapter/concurrency/dead-letter-move-is-atomic"),
      revision = 1,
      summary = "Checks source/DLQ conservation while backend termination and lost COMMIT responses disturb direct dead lettering.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = [KnobSpec (name "workload.messages") "Messages in each direct-DLQ fault arm" KnobInt (VInt 10000) (IntRange 100 10000) []],
      dimensions = postgresDimensions (PgDurable :| []) (Pg18 :| [Pg17]) noDimensions,
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaPgmq] [] False)},
      knownDefect =
        Just $
          KnownDefect
            { reference = "mori://shinzui/shibuya/plans/41-verify-pgmq-acknowledgement-and-dead-letter-recovery-under-faults",
              summary = "A retried direct dead-letter move can write another DLQ copy after its source deletion committed",
              expectedFailures = ["backend: sampled-duplicate-copy", "backend: duplicate-copy", "lost-commit: sampled-duplicate-copy", "lost-commit: duplicate-copy"],
              appliesTo = OnlyWhen (VersionBelow "shibuya-pgmq-adapter" "0.16.1.0" :| [])
            },
      run = runAtomic
    }
  where
    name raw = either (error . Text.unpack) id (mkKnobName raw)

data ArmEvidence = ArmEvidence
  { sent :: !Int,
    finalSource :: !Int,
    finalDeadLetter :: !Int,
    missingIds :: !Int,
    duplicateCopies :: !Int,
    samples :: !Int,
    missingSamples :: !Int,
    duplicateSamples :: !Int,
    nullSamples :: !Int,
    handlerCalls :: !Int,
    restarts :: !Int,
    faultTriggers :: !Int
  }

runAtomic :: RunContext -> IO ScenarioReport
runAtomic context = do
  let messages = fromIntegral (knobInt context.knobs (name "workload.messages"))
  result <- try @SomeException $ timeout 900000000 $ do
    backend <- runArm context "backend" messages False
    lostCommit <- runArm context "lost_commit" messages True
    pure (backend, lostCommit)
  case result of
    Left err -> pure (failedWith ["atomic-move-exception"] (Text.pack (show err)))
    Right Nothing -> pure (failedWith ["atomic-move-timeout"] "The direct-DLQ fault arms exceeded fifteen minutes")
    Right (Just (backend, lostCommit)) -> do
      let failures = checkArm "backend" backend <> checkArm "lost-commit" lostCommit
      putSummary context Verdicts "pgmq-dead-letter-atomic" (object ["backend" .= armValue backend, "lostCommit" .= armValue lostCommit])
      pure $ if null failures then passed else failedWith failures (Text.intercalate "; " failures)
  where
    name raw = either (error . Text.unpack) id (mkKnobName raw)

runArm :: RunContext -> Text -> Int -> Bool -> IO ArmEvidence
runArm context arm messages useProxy =
  withPgmqFixture context (arm <> "_source") 4 $ \source ->
    withPgmqFixture context (arm <> "_dlq") 4 $ \deadLetter -> do
      sentIds <- sendAll source messages
      let postgres = requirePostgres context
      if useProxy
        then do
          let endpoint = maybe (error "PostgreSQL TCP endpoint unavailable") (\(host, port) -> pure (Text.unpack host, fromIntegral port)) postgres.tcpEndpoint
          withTcpProxy endpoint $ \proxy -> do
            let connection = proxiedConnectionString postgres proxy
            runObserved source deadLetter sentIds connection (proxyResets proxy messages)
        else runObserved source deadLetter sentIds postgres.connectionString (backendFaults postgres messages)

sendAll :: PgmqFixture -> Int -> IO [Text]
sendAll fixture messages = do
  ids <- fmap concat $ traverse sendChunk (chunksOf 500 [1 .. messages])
  pure (fmap (Text.pack . show . Pgmq.unMessageId) ids)
  where
    sendChunk numbers = do
      result <- runPgmqStack fixture.pool $ batchSendMessage (BatchSendMessage fixture.queue [MessageBody (object ["number" .= number]) | number <- numbers] Nothing)
      either (fail . show) pure result

chunksOf :: Int -> [a] -> [[a]]
chunksOf _ [] = []
chunksOf size values = take size values : chunksOf size (drop size values)

runObserved :: PgmqFixture -> PgmqFixture -> [Text] -> Text -> (IORef Int -> IORef Int -> IO ()) -> IO ArmEvidence
runObserved source deadLetter sentIds connection disturbance = do
  let expected = length sentIds
  observations <- newIORef (0, 0, 0, 0)
  handlerCalls <- newIORef 0
  restartCount <- newIORef 0
  faultTriggers <- newIORef 0
  withAsync (sampleLoop source deadLetter expected observations) $ \_ ->
    withAsync (disturbance handlerCalls faultTriggers) $ \_ -> do
      runConsumerLoop connection source deadLetter expected handlerCalls restartCount 50
      threadDelay 250000
  (samples, missingSamples, duplicateSamples, nullSamples) <- readIORef observations
  finalSource <- fromIntegral <$> queueRows source
  finalDeadLetter <- fromIntegral <$> queueRows deadLetter
  finalIds <- queueConservationIds source deadLetter
  let expectedSet = Set.fromList sentIds
      actualSet = Set.fromList finalIds
      missingIds = Set.size (expectedSet `Set.difference` actualSet)
      duplicateCopies = length finalIds - Set.size actualSet
  ArmEvidence expected finalSource finalDeadLetter missingIds duplicateCopies samples missingSamples duplicateSamples nullSamples <$> readIORef handlerCalls <*> readIORef restartCount <*> readIORef faultTriggers

sampleLoop :: PgmqFixture -> PgmqFixture -> Int -> IORef (Int, Int, Int, Int) -> IO ()
sampleLoop source deadLetter expected observations = do
  (total, distinct, nulls) <- queueConservationSnapshot source deadLetter
  let missing = distinct < fromIntegral expected
      duplicate = total > distinct
      nullOriginal = nulls > 0
  atomicModifyIORef' observations $ \(count, missingCount, duplicateCount, nullCount) ->
    ((count + 1, missingCount + fromEnum missing, duplicateCount + fromEnum duplicate, nullCount + fromEnum nullOriginal), ())
  threadDelay 200000
  sampleLoop source deadLetter expected observations

backendFaults :: PostgresEnv -> Int -> IORef Int -> IORef Int -> IO ()
backendFaults postgres messages handlerCalls hits =
  forM_ [1 .. (min 20 (max 1 (messages `div` 20)))] $ \index -> do
    let threshold = max 1 (messages * index `div` 22)
    awaitHandlerThreshold handlerCalls threshold
    handle <- (terminateBackends postgres (ByApplicationName "kenshou-shibuya-atomic-consumer")).inject
    let victims = case handle.details of
          Object details -> case KeyMap.lookup "victims" details of
            Just (Array entries) -> Vector.length entries
            _ -> 0
          _ -> 0
    atomicModifyIORef' hits (\count -> (count + victims, ()))

awaitHandlerThreshold :: IORef Int -> Int -> IO ()
awaitHandlerThreshold handlerCalls threshold = do
  observed <- readIORef handlerCalls
  unless (observed >= threshold) $ threadDelay 10000 >> awaitHandlerThreshold handlerCalls threshold

proxyResets :: TcpProxy -> Int -> IORef Int -> IORef Int -> IO ()
proxyResets proxy messages _handlerCalls hits =
  forM_ [1 .. min 5 (max 1 (messages `div` 100))] $ \_ -> do
    barrier <- armResponseBarrier proxy (ByteString.pack "COMMIT")
    reached <- timeout 10000000 (queryBarrierReached barrier)
    case reached of
      Nothing -> releaseResponseBarrier proxy barrier
      Just () -> do
        resetCount <- resetConnections proxy
        releaseResponseBarrier proxy barrier
        atomicModifyIORef' hits (\count -> (count + resetCount, ()))

runConsumerLoop :: Text -> PgmqFixture -> PgmqFixture -> Int -> IORef Int -> IORef Int -> Int -> IO ()
runConsumerLoop _ _ _ _ _ _ 0 = fail "PGMQ atomic-move restart budget exhausted"
runConsumerLoop connection source deadLetter expected handlerCalls restarts budget = do
  outcome <- try @SomeException $ withPgmqNamedConnectionPool connection 16 "kenshou-shibuya-atomic-consumer" $ \pool ->
    runPgmqStack pool (consumeOnce pool source deadLetter expected handlerCalls)
  remaining <- queueRows source
  case outcome of
    Right (Right ()) | remaining == 0 -> pure ()
    _ | remaining == 0 -> pure ()
    _ -> do
      when (budget == 1) $ fail ("PGMQ atomic-move restart budget exhausted with " <> show remaining <> " source rows and last outcome " <> show outcome)
      atomicModifyIORef' restarts (\count -> (count + 1, ()))
      threadDelay 100000
      runConsumerLoop connection source deadLetter expected handlerCalls restarts (budget - 1)

consumeOnce :: Pool -> PgmqFixture -> PgmqFixture -> Int -> IORef Int -> Eff '[Pgmq, Tracing, Error PgmqRuntimeError, IOE] ()
consumeOnce pool source deadLetter expected handlerCalls = do
  let config =
        (defaultConfig source.queue)
          { batchSize = 50,
            visibilityTimeout = 5,
            polling = StandardPolling 0.01,
            maxRetries = 100,
            deadLetterConfig = Just (directDeadLetter deadLetter.queue True)
          }
      handler _ = do
        liftIO $ atomicModifyIORef' handlerCalls (\count -> (count + 1, ()))
        pure (AckDeadLetter (PoisonPill "atomic-move"))
  adapterResult <- pgmqAdapter (mkPgmqAdapterEnv pool) config
  case adapterResult of
    Left err -> error (show err)
    Right adapter -> do
      let processor = (mkProcessor adapter handler) {concurrency = Async 8}
      started <- runApp defaultAppConfig {inboxSize = 100} [(ProcessorId "pgmq-atomic", processor)]
      case started of
        Left err -> error (show err)
        Right handle -> withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO -> liftIO $ do
          outcome <- try @SomeException (race (runInIO (waitApp handle)) (waitForDrain source deadLetter expected))
          _ <- try @SomeException (runInIO (stopAppGracefully defaultShutdownConfig {drainTimeout = 5} handle))
          case outcome of
            Right (Right ()) -> pure ()
            Right (Left ()) -> fail "PGMQ adapter exited before direct-DLQ drain"
            Left err -> fail (show err)

waitForDrain :: PgmqFixture -> PgmqFixture -> Int -> IO ()
waitForDrain source deadLetter expected = do
  sourceCount <- queueRows source
  deadLetterCount <- queueRows deadLetter
  unless (sourceCount == 0 && deadLetterCount >= fromIntegral expected) $ threadDelay 50000 >> waitForDrain source deadLetter expected

checkArm :: Text -> ArmEvidence -> [Text]
checkArm arm evidence =
  let prefix = arm <> ": "
   in [prefix <> "observer-insufficient-samples" | evidence.samples < 2]
        <> [prefix <> "sampled-missing-id" | evidence.missingSamples > 0]
        <> [prefix <> "sampled-duplicate-copy" | evidence.duplicateSamples > 0]
        <> [prefix <> "sampled-null-original-id" | evidence.nullSamples > 0]
        <> [prefix <> "source-not-drained" | evidence.finalSource /= 0]
        <> [prefix <> "dead-letter-count" | evidence.finalDeadLetter < evidence.sent || (evidence.finalDeadLetter > evidence.sent && evidence.duplicateCopies == 0)]
        <> [prefix <> "missing-id" | evidence.missingIds > 0]
        <> [prefix <> "duplicate-copy" | evidence.duplicateCopies > 0]
        <> [prefix <> "fault-not-triggered" | evidence.faultTriggers < 1]

armValue :: ArmEvidence -> Value
armValue evidence =
  object
    [ "sent" .= evidence.sent,
      "finalSource" .= evidence.finalSource,
      "finalDeadLetter" .= evidence.finalDeadLetter,
      "missingIds" .= evidence.missingIds,
      "duplicateCopies" .= evidence.duplicateCopies,
      "samples" .= evidence.samples,
      "missingSamples" .= evidence.missingSamples,
      "duplicateSamples" .= evidence.duplicateSamples,
      "nullSamples" .= evidence.nullSamples,
      "handlerCalls" .= evidence.handlerCalls,
      "restarts" .= evidence.restarts,
      "faultTriggers" .= evidence.faultTriggers
    ]
