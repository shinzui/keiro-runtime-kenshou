module Kenshou.Suite.Shibuya.Correctness.PgmqAckMapping (scenario) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, displayException, try)
import Control.Monad (unless, when)
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Effectful (Eff, IOE, liftIO, (:>))
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension (PgDurability (..), PgVersion (..), noDimensions, postgresDimensions)
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Suite.Shibuya.Fixture.Pgmq (PgmqFixture (..), archiveRows, queuePayloads, queueReadState, queueRows, runPgmqStack, withPgmqFixture)
import Pgmq.Effectful (MessageBody (..), MessageHeaders (..), MessageId (..), SendMessage (..), SendMessageWithHeaders (..), sendMessage, sendMessageWithHeaders)
import Shibuya.Adapter.Pgmq (PgmqAdapterConfig (..), PgmqConfigError (..), PollingConfig (..), bindQueueTopics, defaultConfig, directDeadLetter, mkPgmqAdapterEnv, parseRoutingKey, parseTopicPattern, pgmqAdapter, topicDeadLetter)
import Shibuya.App (defaultAppConfig, defaultShutdownConfig, mkProcessor, runApp, stopAppGracefully, waitApp)
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..), HaltReason (..), RetryDelay (..))
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Core.Types (Attempt (..), Envelope (..))
import System.Timeout (timeout)

scenario :: Scenario
scenario =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/pgmq-adapter/correctness/ack-decision-mapping"),
      revision = 1,
      summary = "Checks queue, lease, archive, dead-letter and halt state for every PGMQ acknowledgement decision.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions = postgresDimensions (PgDurable :| []) (Pg18 :| [Pg17]) noDimensions,
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaPgmq] [] False)},
      knownDefect = Nothing,
      run = runMapping
    }

type Observation = (Maybe Attempt, UTCTime)

runMapping :: RunContext -> IO ScenarioReport
runMapping context = do
  outcome <- try @SomeException $
    timeout 30000000 $
      withPgmqFixture context "ack_source" 10 $ \source ->
        withPgmqFixture context "ack_direct" 2 $ \direct ->
          withPgmqFixture context "ack_topic" 2 $ \topic -> runArms source direct topic
  case outcome of
    Left err -> pure (failedWith ["ack-mapping-exception"] (Text.pack (displayException err)))
    Right Nothing -> pure (failedWith ["ack-mapping-timed-out"] "PGMQ acknowledgement mapping did not finish within 30 seconds")
    Right (Just evidence) -> do
      putSummary context Verdicts "pgmq-ack-decision-mapping" evidence
      pure passed

runArms :: PgmqFixture -> PgmqFixture -> PgmqFixture -> IO Value
runArms source direct topic = do
  let quick = (defaultConfig source.queue) {polling = StandardPolling 0.05, maxRetries = 6}
  _ <- sendText source "ack-ok"
  (okObservations, okDrained) <- runUntil source quick "ok" (const AckOk) ((== 0) <$> queueRows source)
  expect "AckOk did not remove exactly one delivery" (attempts okObservations == [Just 0] && okDrained)

  _ <- sendText source "retry-zero"
  (zeroObservations, zeroDrained) <- runUntil source quick "retry-zero" (\index -> if index == 0 then AckRetry (RetryDelay 0) else AckOk) ((== 0) <$> queueRows source)
  expect "RetryDelay 0 did not redeliver promptly with the next attempt" $
    attempts zeroObservations == [Just 0, Just 1]
      && zeroDrained
      && case zeroObservations of
        [(_, first), (_, second)] -> diffUTCTime second first < 2
        _ -> False

  _ <- sendText source "retry-rounded"
  (delayedObservations, delayedDrained) <- runUntil source quick "retry-rounded" (const (AckRetry (RetryDelay 1.2))) $ do
    state <- queueReadState source
    now <- getCurrentTime
    pure $ case state of [(1, vt)] -> diffUTCTime vt now > 1 && diffUTCTime vt now < 3; _ -> False
  delayedState <- queueReadState source
  let delayedVt = case delayedState of [(1, vt)] -> vt; _ -> error "retry left other than one leased row"
  expect "RetryDelay 1.2 did not round up to two seconds" $
    delayedDrained
      && attempts delayedObservations == [Just 0]
      && case delayedObservations of
        [(_, first)] -> abs (realToFrac (diffUTCTime delayedVt first) - (2 :: Double)) < 1
        _ -> False
  waitUntilVisible delayedVt
  (redeliveryObservations, redeliveryDrained) <- runUntil source quick "retry-final" (const AckOk) ((== 0) <$> queueRows source)
  expect "delayed retry did not redeliver at read count two" (attempts redeliveryObservations == [Just 1] && redeliveryDrained)

  _ <- sendText source "archive"
  (archiveObservations, archiveDrained) <- runUntil source quick "archive" (const (AckDeadLetter (InvalidPayload "invalid"))) ((== 1) <$> archiveRows source)
  archived <- archiveRows source
  remainingAfterArchive <- queueRows source
  expect "AckDeadLetter archive did not move the source row" (attempts archiveObservations == [Just 0] && archiveDrained && archived == 1 && remainingAfterArchive == 0)

  directId <- sendWithHeaders source "direct"
  let directConfig = quick {deadLetterConfig = Just (directDeadLetter direct.queue True)}
  (directObservations, directDrained) <- runUntil source directConfig "direct" (const (AckDeadLetter (PoisonPill "poison"))) ((== 1) <$> queueRows direct)
  directPayload <- onePayload direct
  directRemaining <- queueRows source
  expect "direct DLQ mapping was incomplete" $
    attempts directObservations == [Just 0]
      && directDrained
      && directRemaining == 0
      && validDlqPayload "direct" directId "poison_pill" (Just "poison") directPayload

  let patternValue = either (error . show) id (parseTopicPattern "kenshou.#")
      routingKey = either (error . show) id (parseRoutingKey "kenshou.dlq")
  bound <- runPgmqStack topic.pool (bindQueueTopics topic.queue [patternValue])
  either (ioError . userError . show) pure bound
  topicId <- sendWithHeaders source "topic"
  let topicConfig = quick {deadLetterConfig = Just (topicDeadLetter routingKey True)}
  (topicObservations, topicDrained) <- runUntil source topicConfig "topic" (const (AckDeadLetter (InvalidPayload "invalid"))) ((== 1) <$> queueRows topic)
  topicPayload <- onePayload topic
  topicRemaining <- queueRows source
  expect "topic-routed DLQ mapping was incomplete" $
    attempts topicObservations == [Just 0]
      && topicDrained
      && topicRemaining == 0
      && validDlqPayload "topic" topicId "invalid_payload" (Just "invalid") topicPayload

  _ <- sendText source "halt"
  haltObservations <- runHalt source (quick {haltVisibilityTimeout = Just 3})
  haltState <- queueReadState source
  expect "AckHalt did not park the row and finish the processor" $
    attempts haltObservations == [Just 0]
      && case (haltObservations, haltState) of
        ([(_, first)], [(1, vt)]) -> abs (realToFrac (diffUTCTime vt first) - (3 :: Double)) < 1
        _ -> False

  invalid <- runPgmqStack source.pool (pgmqAdapter (mkPgmqAdapterEnv source.pool) (quick {batchSize = 0}))
  case invalid of
    Right (Left (InvalidBatchSize 0)) -> pure ()
    _ -> ioError (userError "invalid batch size did not return InvalidBatchSize 0")

  pure $
    object
      [ "ackOkAttempts" .= attemptNumbers okObservations,
        "retryZeroAttempts" .= attemptNumbers zeroObservations,
        "retryRoundedAttempts" .= (attemptNumbers delayedObservations <> attemptNumbers redeliveryObservations),
        "retryRoundedVisibilitySeconds" .= (case delayedObservations of [(_, first)] -> realToFrac (diffUTCTime delayedVt first) :: Double; _ -> 0),
        "archiveRows" .= archived,
        "directPayload" .= directPayload,
        "topicPayload" .= topicPayload,
        "haltAttempts" .= attemptNumbers haltObservations,
        "invalidBatchSize" .= ("InvalidBatchSize 0" :: Text)
      ]

runUntil :: PgmqFixture -> PgmqAdapterConfig -> Text -> (Int -> AckDecision) -> IO Bool -> IO ([Observation], Bool)
runUntil fixture config label decision completed = do
  observed <- newIORef ([] :: [Observation])
  result <- runPgmqStack fixture.pool $ do
    adapterResult <- pgmqAdapter (mkPgmqAdapterEnv fixture.pool) config
    case adapterResult of
      Left err -> error (show err)
      Right adapter -> do
        started <- runApp defaultAppConfig [(ProcessorId ("pgmq-ack-" <> label), mkProcessor adapter (recordDecision observed decision))]
        case started of
          Left err -> error (show err)
          Right handle -> do
            sawResult <- liftIO $ timeout 8000000 (waitUntil completed)
            drained <- stopAppGracefully defaultShutdownConfig handle
            waitApp handle
            case sawResult of
              Nothing -> error ("ack arm timed out: " <> Text.unpack label)
              Just () -> pure drained
  drained <- either (ioError . userError . show) pure result
  observations <- reverse <$> readIORef observed
  pure (observations, drained)

runHalt :: PgmqFixture -> PgmqAdapterConfig -> IO [Observation]
runHalt fixture config = do
  observed <- newIORef ([] :: [Observation])
  result <- runPgmqStack fixture.pool $ do
    adapterResult <- pgmqAdapter (mkPgmqAdapterEnv fixture.pool) config
    case adapterResult of
      Left err -> error (show err)
      Right adapter -> do
        started <- runApp defaultAppConfig [(ProcessorId "pgmq-ack-halt", mkProcessor adapter (recordDecision observed (const (AckHalt (HaltOrderedStream "halt")))))]
        case started of
          Left err -> error (show err)
          Right handle -> waitApp handle
  either (ioError . userError . show) pure result
  reverse <$> readIORef observed

recordDecision :: (IOE :> es) => IORef [Observation] -> (Int -> AckDecision) -> Message es Value -> Eff es AckDecision
recordDecision observed decision message = do
  now <- liftIO getCurrentTime
  index <- liftIO $ atomicModifyIORef' observed (\values -> ((message.envelope.attempt, now) : values, length values))
  pure (decision index)

sendText :: PgmqFixture -> Text -> IO MessageId
sendText fixture value = do
  result <- runPgmqStack fixture.pool (sendMessage (SendMessage fixture.queue (MessageBody (String value)) Nothing))
  either (ioError . userError . show) pure result

sendWithHeaders :: PgmqFixture -> Text -> IO MessageId
sendWithHeaders fixture value = do
  let query = SendMessageWithHeaders fixture.queue (MessageBody (object ["token" .= value])) (MessageHeaders (object ["x-pgmq-group" .= ("ack-mapping" :: Text)])) Nothing
  result <- runPgmqStack fixture.pool (sendMessageWithHeaders query)
  either (ioError . userError . show) pure result

onePayload :: PgmqFixture -> IO Value
onePayload fixture = do
  payloads <- queuePayloads fixture
  case payloads of
    [payload] -> pure payload
    _ -> ioError (userError "dead-letter destination did not contain exactly one payload")

validDlqPayload :: Text -> MessageId -> Text -> Maybe Text -> Value -> Bool
validDlqPayload token messageId code detail (Object payload) =
  KeyMap.lookup "original_message" payload == Just (object ["token" .= token])
    && KeyMap.lookup "dead_letter_reason_code" payload == Just (String code)
    && KeyMap.lookup "dead_letter_reason_detail" payload == Just (maybe Null String detail)
    && KeyMap.lookup "dead_letter_reason" payload == Just (String (code <> maybe "" (": " <>) detail))
    && KeyMap.lookup "original_message_id" payload == Just (toJSON (unMessageId messageId))
    && KeyMap.lookup "read_count" payload == Just (toJSON (1 :: Int))
    && KeyMap.member "original_enqueued_at" payload
    && KeyMap.member "last_read_at" payload
    && KeyMap.lookup "original_headers" payload == Just (object ["x-pgmq-group" .= ("ack-mapping" :: Text)])
validDlqPayload _ _ _ _ _ = False

attempts :: [Observation] -> [Maybe Attempt]
attempts = map fst

attemptNumbers :: [Observation] -> [Maybe Word]
attemptNumbers = map (fmap (\(Attempt value) -> value) . fst)

waitUntil :: IO Bool -> IO ()
waitUntil condition = do
  ready <- condition
  unless ready $ threadDelay 10000 >> waitUntil condition

waitUntilVisible :: UTCTime -> IO ()
waitUntilVisible visibleAt = do
  now <- getCurrentTime
  when (now < visibleAt) $ threadDelay 10000 >> waitUntilVisible visibleAt

expect :: String -> Bool -> IO ()
expect message predicate = unless predicate (ioError (userError message))
