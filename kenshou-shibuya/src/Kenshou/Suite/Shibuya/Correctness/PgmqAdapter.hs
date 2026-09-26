module Kenshou.Suite.Shibuya.Correctness.PgmqAdapter (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, displayException, try)
import Control.Monad (forM, when)
import Data.Aeson (Value (..), object, (.=))
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as Text
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Data.Vector qualified as Vector
import Effectful (liftIO)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension (PgDurability (..), PgVersion (..), noDimensions, postgresDimensions)
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobInt, knobText, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Suite.Shibuya.Concurrency.PgmqLeaseSizing qualified as PgmqLeaseSizing
import Kenshou.Suite.Shibuya.Concurrency.PgmqPoolStarvation qualified as PgmqPoolStarvation
import Kenshou.Suite.Shibuya.Concurrency.PgmqPrefetchShutdown qualified as PgmqPrefetchShutdown
import Kenshou.Suite.Shibuya.Concurrency.PgmqShutdownRelease qualified as PgmqShutdownRelease
import Kenshou.Suite.Shibuya.Correctness.PgmqAckMapping qualified as PgmqAckMapping
import Kenshou.Suite.Shibuya.Fixture.Pgmq (PgmqFixture (..), dlqRowsWithReason, queueRows, runPgmqStack, withPgmqFixture)
import Pgmq.Effectful (Message (..), MessageBody (..), ReadMessage (..), SendMessage (..), readMessage, sendMessage)
import Shibuya.Adapter.Pgmq (PgmqAdapterConfig (..), PgmqAdapterEnv (..), PollingConfig (..), defaultConfig, directDeadLetter, mkPgmqAdapterEnv, pgmqAdapter)
import Shibuya.App (defaultAppConfig, defaultShutdownConfig, mkProcessor, runApp, stopAppGracefully, waitApp)
import Shibuya.Core.Ack (AckDecision (..), RetryDelay (..))
import Shibuya.Core.Metrics (ProcessorId (..))
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [PgmqAckMapping.scenario, shutdownLatency, autoDeadLetterCountsDeliveries, PgmqPoolStarvation.scenario, PgmqPrefetchShutdown.scenario, PgmqShutdownRelease.scenario, PgmqLeaseSizing.scenario]

autoDeadLetterCountsDeliveries :: Scenario
autoDeadLetterCountsDeliveries =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/pgmq-adapter/correctness/auto-dead-letter-counts-deliveries"),
      revision = 1,
      summary = "Retry exhaustion and raw reads spend the same delivery budget before the handler runs.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs =
        [ KnobSpec (name "pgmq-adapter.max-retries") "Maximum deliveries before automatic dead lettering" KnobInt (VInt 3) (IntRange 0 10) [],
          KnobSpec (name "pgmq-adapter.pool-size") "PostgreSQL connection pool size" KnobInt (VInt 10) (IntRange 2 64) []
        ],
      dimensions = postgresDimensions (PgDurable :| []) (Pg18 :| [Pg17]) noDimensions,
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaPgmq] [] False)},
      knownDefect = Nothing,
      run = runAutoDeadLetter
    }
  where
    name raw = either (error . Text.unpack) id (mkKnobName raw)

data AutoEvidence = AutoEvidence
  { handlerCalls :: !Int,
    autoReadCounts :: ![Int64],
    rawReadCounts :: ![Int64],
    sourceRows :: !Int64,
    dlqRows :: !Int64,
    reasonRows :: !Int64,
    drained :: !Bool
  }

runAutoDeadLetter :: RunContext -> IO ScenarioReport
runAutoDeadLetter context = do
  let retries = fromIntegral (knobInt context.knobs (name "pgmq-adapter.max-retries")) :: Int64
      poolSize = fromIntegral (knobInt context.knobs (name "pgmq-adapter.pool-size"))
  outcome <- try @SomeException $
    timeout 45000000 $
      withPgmqFixture context "auto_source" poolSize $ \source ->
        withPgmqFixture context "auto_dlq" 2 $ \dlq -> do
          retryArm <- runAutoArm source dlq retries 0 "retry"
          rawArm <- runAutoArm source dlq retries (fromIntegral retries + 1) "raw"
          pure (retryArm, rawArm)
  case outcome of
    Left err -> pure (failedWith ["adapter-exception"] (Text.pack (displayException err)))
    Right Nothing -> pure (failedWith ["auto-dead-letter-timed-out"] "Automatic dead lettering did not complete within 45 seconds")
    Right (Just (retryArm, rawArm)) -> do
      let failures =
            checkArm "retry" retries 0 1 retryArm
              <> checkArm "raw" retries (fromIntegral retries + 1) 2 rawArm
              <> ["retry-handler-count" | retryArm.handlerCalls /= fromIntegral retries]
              <> ["raw-handler-was-invoked" | rawArm.handlerCalls /= 0]
              <> ["retry-callback-read-count" | retryArm.autoReadCounts /= [retries + 1]]
              <> ["raw-callback-read-count" | rawArm.autoReadCounts /= [retries + 2]]
      putSummary context Verdicts "pgmq-auto-dead-letter" $
        object
          [ "maxRetries" .= retries,
            "retryHandlerCalls" .= retryArm.handlerCalls,
            "retryCallbackReadCounts" .= retryArm.autoReadCounts,
            "rawHandlerCalls" .= rawArm.handlerCalls,
            "rawPreReadCounts" .= rawArm.rawReadCounts,
            "rawCallbackReadCounts" .= rawArm.autoReadCounts,
            "sourceRows" .= rawArm.sourceRows,
            "dlqRows" .= rawArm.dlqRows,
            "reasonRows" .= rawArm.reasonRows
          ]
      pure $ if null failures then passed else failedWith failures (Text.intercalate "; " failures)
  where
    name raw = either (error . Text.unpack) id (mkKnobName raw)

checkArm :: Text.Text -> Int64 -> Int -> Int64 -> AutoEvidence -> [Text.Text]
checkArm label retries prereads expectedRows evidence =
  [label <> "-source-row-remains" | evidence.sourceRows /= 0]
    <> [label <> "-dlq-copy-count" | evidence.dlqRows /= expectedRows]
    <> [label <> "-dlq-reason-code" | evidence.reasonRows /= expectedRows]
    <> [label <> "-raw-read-counts" | evidence.rawReadCounts /= [1 .. fromIntegral prereads]]
    <> [label <> "-stop-did-not-drain" | not evidence.drained]
    <> [label <> "-handler-exceeded-budget" | fromIntegral evidence.handlerCalls > retries]
    <> [label <> "-callback-count" | length evidence.autoReadCounts /= 1]

runAutoArm :: PgmqFixture -> PgmqFixture -> Int64 -> Int -> Text.Text -> IO AutoEvidence
runAutoArm source dlq retries prereads arm = do
  sent <- runPgmqStack source.pool (sendMessage (SendMessage source.queue (MessageBody (String arm)) Nothing))
  either (ioError . userError . show) (const (pure ())) sent
  rawCounts <- forM [1 .. prereads] $ \_ -> do
    result <- runPgmqStack source.pool (readMessage (ReadMessage source.queue 1 (Just 1) Nothing))
    messages <- either (ioError . userError . show) pure result
    case Vector.toList messages of
      [message] -> do
        threadDelay 1100000
        pure message.readCount
      _ -> ioError (userError "raw pre-read returned other than one message")
  calls <- newIORef (0 :: Int)
  auto <- newIORef ([] :: [Int64])
  let environment =
        (mkPgmqAdapterEnv source.pool)
          { onAutoDeadLetter = \message -> atomicModifyIORef' auto (\counts -> (message.readCount : counts, ()))
          }
      config =
        (defaultConfig source.queue)
          { maxRetries = retries,
            deadLetterConfig = Just (directDeadLetter dlq.queue True)
          }
  result <- runPgmqStack source.pool $ do
    adapterResult <- pgmqAdapter environment config
    case adapterResult of
      Left err -> error (show err)
      Right adapter -> do
        started <- runApp defaultAppConfig [(ProcessorId ("pgmq-auto-" <> arm), mkProcessor adapter (\_ -> liftIO (atomicModifyIORef' calls (\n -> (n + 1, ()))) >> pure (AckRetry (RetryDelay 0))))]
        case started of
          Left err -> error (show err)
          Right handle -> do
            autoSeen <- liftIO $ timeout 20000000 (waitForAuto auto)
            stopped <- stopAppGracefully defaultShutdownConfig handle
            waitApp handle
            case autoSeen of
              Nothing -> error "automatic dead lettering did not occur within 20 seconds"
              Just () -> pure stopped
  stopped <- either (ioError . userError . show) pure result
  AutoEvidence
    <$> readIORef calls
    <*> (reverse <$> readIORef auto)
    <*> pure rawCounts
    <*> queueRows source
    <*> queueRows dlq
    <*> dlqRowsWithReason dlq "max_retries_exceeded"
    <*> pure stopped

waitForAuto :: IORef [Int64] -> IO ()
waitForAuto auto = do
  counts <- readIORef auto
  when (null counts) $ threadDelay 10000 >> waitForAuto auto

shutdownLatency :: Scenario
shutdownLatency =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/pgmq-adapter/correctness/shutdown-latency-is-bounded-by-polling"),
      revision = 1,
      summary = "An idle PostgreSQL-backed adapter drains within its configured poll interval and can be stopped twice.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs =
        [ KnobSpec pollingKnob "Adapter polling strategy" KnobText (VText "standard:1") (OneOf (VText "standard:1" :| [VText "long:5:100"])) [],
          KnobSpec poolSizeKnob "PostgreSQL connection pool size" KnobInt (VInt 10) (IntRange 2 64) []
        ],
      dimensions = postgresDimensions (PgDurable :| []) (Pg18 :| [Pg17]) noDimensions,
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaPgmq] [] False)},
      knownDefect = Nothing,
      run = runShutdownLatency
    }
  where
    pollingKnob = either (error . Text.unpack) id (mkKnobName "pgmq-adapter.polling")
    poolSizeKnob = either (error . Text.unpack) id (mkKnobName "pgmq-adapter.pool-size")

runShutdownLatency :: RunContext -> IO ScenarioReport
runShutdownLatency context = do
  let pollMode = knobText context.knobs (name "pgmq-adapter.polling")
      poolSize = fromIntegral (knobInt context.knobs (name "pgmq-adapter.pool-size"))
      (polling, boundSeconds) = if pollMode == "long:5:100" then (LongPolling 5 100, 6 :: Double) else (StandardPolling 1, 2)
  withPgmqFixture context "shutdown" poolSize $ \fixture -> do
    probe <- runPgmqStack fixture.pool (sendMessage (SendMessage fixture.queue (MessageBody (String "shutdown-probe")) Nothing))
    case probe of
      Left err -> pure (failedWith ["pgmq-send-failed"] (Text.pack (show err)))
      Right _ -> do
        handled <- newIORef (0 :: Int)
        result <- try @SomeException $ timeout 10000000 $ runPgmqStack fixture.pool $ do
          adapterResult <- pgmqAdapter (mkPgmqAdapterEnv fixture.pool) ((defaultConfig fixture.queue) {polling})
          case adapterResult of
            Left err -> error (show err)
            Right adapter -> do
              started <- runApp defaultAppConfig [(ProcessorId "pgmq-idle-shutdown", mkProcessor adapter (\_ -> liftIO (atomicModifyIORef' handled (\n -> (n + 1, ()))) >> pure AckOk))]
              case started of
                Left err -> error (show err)
                Right handle -> do
                  liftIO $ waitForHandled handled
                  -- A completed delivery proves the source ran before the idle poll.
                  liftIO $ threadDelay 100000
                  before <- liftIO getCurrentTime
                  drained <- stopAppGracefully defaultShutdownConfig handle
                  after <- liftIO getCurrentTime
                  again <- stopAppGracefully defaultShutdownConfig handle
                  waitApp handle
                  pure (drained, again, realToFrac (diffUTCTime after before) :: Double)
        count <- readIORef handled
        remaining <- queueRows fixture
        let (failures, duration) = case result of
              Left err -> (["adapter-exception: " <> Text.pack (displayException err)], 0)
              Right Nothing -> (["adapter-shutdown-timed-out"], 0)
              Right (Just (Left err)) -> (["pgmq-runtime-error: " <> Text.pack (show err)], 0)
              Right (Just (Right (drained, again, seconds))) ->
                ( ["adapter-did-not-drain" | not drained]
                    <> ["repeated-stop-changed-result" | again /= drained]
                    <> ["shutdown-exceeded-poll-bound" | seconds > boundSeconds],
                  seconds
                )
            allFailures = failures <> ["probe-was-not-handled" | count /= 1] <> ["queue-did-not-drain" | remaining /= 0]
        putSummary context Verdicts "pgmq-shutdown-latency" $
          object ["polling" .= pollMode, "elapsedSeconds" .= duration, "boundSeconds" .= boundSeconds, "handled" .= count, "remainingRows" .= remaining]
        pure $ if null allFailures then passed else failedWith allFailures (Text.intercalate "; " allFailures)
  where
    name raw = either (error . Text.unpack) id (mkKnobName raw)

waitForHandled :: IORef Int -> IO ()
waitForHandled handled = do
  count <- readIORef handled
  if count >= 1 then pure () else threadDelay 10000 >> waitForHandled handled
