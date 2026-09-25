module Kenshou.Suite.Kafka.Correctness.Retry (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync)
import Control.Exception (IOException, try)
import Data.ByteString.Char8 qualified as ByteString
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (nub, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (liftIO, runEff)
import Effectful.Error.Static (runError)
import GHC.Stack (CallStack)
import Kafka.Consumer.Types (Offset (..))
import Kafka.Effectful.Consumer qualified as C
import Kafka.Types (BatchSize (..), KafkaError, Timeout (..), TopicName)
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Dimension (allTelemetryArms, noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobBool, knobInt, knobText, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (CohortScope (..), KnownDefect (..), PackageCondition (..), Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Env.Kafka
import Kenshou.Suite.Kafka.Fixture (firstBrokers, intKnob, produceValues)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Kafka (KafkaAdapterConfig (..), defaultConfig, kafkaAdapter)
import Shibuya.App (ProcessorId (..), defaultAppConfig, mkProcessor, runApp, stopApp, waitApp)
import Shibuya.Core.Ack (AckDecision (..), RetryDelay (..))
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Types (Envelope (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import Streamly.Data.Stream qualified as Stream
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios =
  [ Scenario
      { id = either (error . Text.unpack) id (parseScenarioId "kafka/adapter/correctness/retry-redelivers-and-never-commits-past"),
        revision = 1,
        summary = "Retries offset 20, samples its committed boundary, and checks resume or completion.",
        tier = TierSmoke,
        placement = PlaceEither,
        knobs =
          [ batchKnob,
            textKnob "kafka.failure-mode" "Failure decision" "retry" ["retry", "throw"],
            intKnob "kafka.retry-delay-ms" "AckRetry delay in milliseconds" 0 0 5000,
            boolKnob "kafka.exit-before-success" "Close after the first failed delivery" False
          ],
        dimensions = allTelemetryArms noDimensions,
        phases = zeroPhases,
        requires = noEnvironment,
        knownDefect =
          Just
            KnownDefect
              { reference = "mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-1",
                summary = "A buffered retry can leave successful successors uncommitted until restart.",
                expectedFailures = ["retry-final-offset-at-log-end"],
                appliesTo = OnlyWhen (ResolvedFromHackage "shibuya-kafka-adapter" :| [])
              },
        run = runRetry
      }
  ]

textKnob :: Text -> Text -> Text -> [Text] -> KnobSpec
textKnob name summary def allowed =
  KnobSpec (key name) summary KnobText (VText def) (OneOf (case allowed of first : rest -> VText first :| fmap VText rest; [] -> error "empty allowed values")) []

boolKnob :: Text -> Text -> Bool -> KnobSpec
boolKnob name summary def = KnobSpec (key name) summary KnobBool (VBool def) AnyValue []

batchKnob :: KnobSpec
batchKnob = KnobSpec (key "kafka.batch-size") "Adapter poll batch size" KnobInt (VInt 100) (OneOf (VInt 1 :| [VInt 10, VInt 100, VInt 1000])) []

key :: Text -> KnobName
key = either (error . Text.unpack) id . mkKnobName

runRetry :: RunContext -> IO ScenarioReport
runRetry context = do
  spec <- either (ioError . userError . Text.unpack) pure (kafkaEnvSpecFromRunSpec context)
  withKafkaEnv context spec \env -> do
    [topic] <- createTopics env [TopicSpec "retry" 1 mempty]
    _ <- produceValues env topic [0 .. 49]
    deliveries <- newIORef ([] :: [Int])
    succeeded <- newIORef ([] :: [Int])
    pending <- newIORef False
    finished <- newIORef False
    samples <- newIORef []
    let exitEarly = knobBool context.knobs (key "kafka.exit-before-success")
        failureMode = knobText context.knobs (key "kafka.failure-mode")
        batchSize = fromIntegral (knobInt context.knobs (key "kafka.batch-size"))
        retryDelay = fromIntegral (knobInt context.knobs (key "kafka.retry-delay-ms")) / 1000
    result <- withAsync (sampleCommitted env pending finished samples) \_ ->
      timeout 30000000 (consumeRetry env topic exitEarly batchSize failureMode retryDelay deliveries succeeded pending)
    writeIORef finished True
    seen <- readIORef deliveries
    oks <- readIORef succeeded
    observed <- readIORef samples
    snapshot <- describeGroup env (groupName env "retry")
    firstResumed <- if exitEarly then firstAfterResume env topic else pure Nothing
    _ <- deleteRunGroups env
    _ <- deleteRunTopics env
    let completed = case result of Just (Right ()) -> True; _ -> False
        bounded = not (null observed) && all (maybe True (<= 20)) observed
        redelivered = length (filter (== 20) seen) >= 2
        allSucceeded = sort (nub oks) == [0 .. 49]
        lagZero = length snapshot.offsets == 1 && all ((== Just 0) . (.lag)) snapshot.offsets
        failures =
          ["retry-run-completed" | not completed]
            <> ["retry-pending-commit-boundary" | not bounded]
            <> if exitEarly
              then ["retry-exit-replays-failed-offset" | maybe True (> 20) firstResumed]
              else
                ["retry-redelivered" | not redelivered]
                  <> ["retry-all-handlers-succeeded" | not allSucceeded]
                  <> ["retry-final-offset-at-log-end" | not lagZero]
    pure $
      if null failures
        then passed
        else failedWith failures ("completed=" <> Text.pack (show completed) <> " deliveries=" <> Text.pack (show (reverse seen)) <> " oks=" <> Text.pack (show (reverse oks)) <> " allSucceeded=" <> Text.pack (show allSucceeded) <> " samples=" <> Text.pack (show observed) <> " resumed=" <> Text.pack (show firstResumed) <> " snapshot=" <> Text.pack (show snapshot))

consumeRetry :: KafkaEnv -> TopicName -> Bool -> Int -> Text -> Rational -> IORef [Int] -> IORef [Int] -> IORef Bool -> IO (Either (CallStack, KafkaError) ())
consumeRetry env topic exitEarly batchSize failureMode retryDelay deliveries succeeded pending =
  runEff . runError @KafkaError . runTracingNoop $
    C.runKafkaConsumer props subscription $ do
      adapter <- kafkaAdapter ((defaultConfig [topic]) {batchSize = BatchSize batchSize})
      let selectedAdapter = if exitEarly then adapter {source = Stream.take 21 adapter.source} else adapter
          handler Message {envelope = Envelope {payload}} = do
            let number = payload >>= readInt
            case number of
              Nothing -> pure AckOk
              Just value -> do
                count <- liftIO $ atomicModifyIORef' deliveries (\old -> (value : old, length (filter (== value) old)))
                if value == 20 && count == 0
                  then do
                    liftIO $ writeIORef pending True
                    liftIO $ threadDelay 1000000
                    if failureMode == "throw"
                      then liftIO $ ioError (userError "first offset-20 delivery failed")
                      else pure (AckRetry (RetryDelay (fromRational retryDelay)))
                  else do
                    liftIO $ modifyIORef' succeeded (value :)
                    liftIO $ if value == 20 then writeIORef pending False else pure ()
                    pure AckOk
      appResult <- runApp defaultAppConfig [(ProcessorId "retry", mkProcessor selectedAdapter handler)]
      case appResult of
        Left problem -> liftIO $ ioError (userError (show problem))
        Right handle -> do
          if exitEarly
            then waitApp handle >> stopApp handle
            else do
              liftIO $ waitForAll succeeded
              -- Let librdkafka's auto-commit interval pass before closing the group.
              liftIO $ threadDelay 6000000
              stopApp handle
              waitApp handle
  where
    props = C.brokersList (firstBrokers env) <> C.groupId (groupName env "retry") <> C.noAutoOffsetStore
    subscription = C.topics [topic] <> C.offsetReset C.Earliest

waitForAll :: IORef [Int] -> IO ()
waitForAll succeeded = do
  values <- readIORef succeeded
  if sort (nub values) == [0 .. 49]
    then pure ()
    else threadDelay 100000 >> waitForAll succeeded

sampleCommitted :: KafkaEnv -> IORef Bool -> IORef Bool -> IORef [Maybe Int] -> IO ()
sampleCommitted env pending finished samples = loop
  where
    loop = do
      done <- readIORef finished
      if done
        then pure ()
        else do
          active <- readIORef pending
          if active
            then do
              outcome <- try @IOException (describeGroup env (groupName env "retry"))
              case outcome of
                Right snapshot -> do
                  stillPending <- readIORef pending
                  if stillPending
                    then modifyIORef' samples (fmap (fmap fromIntegral . (.committed)) snapshot.offsets <>)
                    else pure ()
                Left _ -> pure ()
            else pure ()
          threadDelay 200000
          loop

firstAfterResume :: KafkaEnv -> TopicName -> IO (Maybe Int)
firstAfterResume env topic = do
  let props = C.brokersList (firstBrokers env) <> C.groupId (groupName env "retry") <> C.noAutoOffsetStore
      subscription = C.topics [topic] <> C.offsetReset C.Earliest
  result <- runEff . runError @KafkaError $ C.runKafkaConsumer props subscription $ do
    record <- C.pollMessage (Timeout 5000)
    pure (fmap (fromIntegral . unOffset . C.crOffset) record)
  either (ioError . userError . show) pure result

readInt :: ByteString.ByteString -> Maybe Int
readInt bytes = case reads (ByteString.unpack bytes) of
  [(value, "")] -> Just value
  _ -> Nothing
