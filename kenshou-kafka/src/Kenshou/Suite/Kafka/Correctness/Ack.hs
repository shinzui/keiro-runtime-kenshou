module Kenshou.Suite.Kafka.Correctness.Ack (scenarios) where

import Data.ByteString.Char8 qualified as ByteString
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (liftIO, runEff)
import Effectful.Error.Static (runError)
import Kafka.Effectful.Consumer qualified as C
import Kafka.Types (KafkaError, Timeout (..), TopicName)
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Dimension (allTelemetryArms, noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (knobInt, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Env.Kafka
import Kenshou.Suite.Kafka.Fixture (firstBrokers, intKnob, produceValues)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Kafka (defaultConfig, kafkaAdapter)
import Shibuya.App (ProcessorId (..), defaultAppConfig, mkProcessor, runApp, stopApp, waitApp)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import Streamly.Data.Stream qualified as Stream

scenarios :: [Scenario]
scenarios =
  [ Scenario
      { id = either (error . Text.unpack) id (parseScenarioId "kafka/adapter/correctness/ack-ok-commits-and-resumes"),
        revision = 1,
        summary = "Checks serial AckOk handling, committed offsets, and a quiet resumed session.",
        tier = TierSmoke,
        placement = PlaceEither,
        knobs = [intKnob "kafka.partitions" "Topic partitions" 4 1 64, intKnob "kafka.messages" "Acknowledged records" 500 1 50000],
        dimensions = allTelemetryArms noDimensions,
        phases = zeroPhases,
        requires = noEnvironment,
        knownDefect = Nothing,
        run = runAckOk
      }
  ]

runAckOk :: RunContext -> IO ScenarioReport
runAckOk context = do
  spec <- either (ioError . userError . Text.unpack) pure (kafkaEnvSpecFromRunSpec context)
  withKafkaEnv context spec \env -> do
    let partitions = fromIntegral (knobInt context.knobs (either (error . Text.unpack) id (mkKnobName "kafka.partitions")))
        messages = fromIntegral (knobInt context.knobs (either (error . Text.unpack) id (mkKnobName "kafka.messages")))
    [topic] <- createTopics env [TopicSpec "ack-ok" partitions mempty]
    sent <- produceValues env topic [0 .. messages - 1]
    facts <- consumeWithAdapter env topic messages
    snapshot <- describeGroup env (groupName env "ack-ok")
    resumed <- countOnResume env topic
    _ <- deleteRunGroups env
    _ <- deleteRunTopics env
    let received = [value | (value, _, _) <- facts]
        perPartition = Map.fromListWith (flip (<>)) [(partition, [offset]) | (_, partition, offset) <- facts]
        ordered = all strictlyIncreasing (Map.elems perPartition)
        lagZero = length snapshot.offsets == partitions && all ((== Just 0) . (.lag)) snapshot.offsets
    pure $
      if length sent == messages && sort received == [0 .. messages - 1] && ordered && lagZero && resumed == 0
        then passed
        else failedWith ["ack-ok-commits-and-resumes"] ("received=" <> Text.pack (show (length facts)) <> " ordered=" <> Text.pack (show ordered) <> " lagZero=" <> Text.pack (show lagZero) <> " resumed=" <> Text.pack (show resumed))

consumeWithAdapter :: KafkaEnv -> TopicName -> Int -> IO [(Int, Text, Int)]
consumeWithAdapter env topic count = do
  facts <- newIORef []
  let props = C.brokersList (firstBrokers env) <> C.groupId (groupName env "ack-ok") <> C.noAutoOffsetStore
      subscription = C.topics [topic] <> C.offsetReset C.Earliest
  result <- runEff . runError @KafkaError . runTracingNoop $
    C.runKafkaConsumer props subscription $ do
      adapter <- kafkaAdapter (defaultConfig [topic])
      let finiteAdapter = adapter {source = Stream.take count adapter.source}
          handler Message {envelope = Envelope {payload, partition, cursor}} = do
            let value = payload >>= readInt
            case (value, partition, cursor) of
              (Just number, Just partitionValue, Just (CursorInt offset)) ->
                liftIO $ modifyIORef' facts ((number, partitionValue, offset) :)
              _ -> pure ()
            pure AckOk
      appResult <- runApp defaultAppConfig [(ProcessorId "ack-ok", mkProcessor finiteAdapter handler)]
      case appResult of
        Left problem -> liftIO $ ioError (userError (show problem))
        Right handle -> waitApp handle >> stopApp handle
  either (ioError . userError . show) pure result
  reverse <$> readIORef facts

countOnResume :: KafkaEnv -> TopicName -> IO Int
countOnResume env topic = do
  let props = C.brokersList (firstBrokers env) <> C.groupId (groupName env "ack-ok") <> C.noAutoOffsetStore
      subscription = C.topics [topic] <> C.offsetReset C.Earliest
  result <- runEff . runError @KafkaError $ C.runKafkaConsumer props subscription $ do
    values <- C.pollMessage (Timeout 5000)
    pure (maybe 0 (const 1) values)
  either (ioError . userError . show) pure result

readInt :: ByteString.ByteString -> Maybe Int
readInt bytes = case reads (ByteString.unpack bytes) of
  [(value, "")] -> Just value
  _ -> Nothing

strictlyIncreasing :: [Int] -> Bool
strictlyIncreasing values = and (zipWith (<) values (drop 1 values))
