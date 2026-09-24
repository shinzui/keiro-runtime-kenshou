module Kenshou.Suite.Kafka.Correctness.MultiTopic (scenarios) where

import Data.ByteString.Char8 qualified as ByteString
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (liftIO, runEff)
import Effectful.Error.Static (runError)
import Kafka.Effectful.Consumer qualified as C
import Kafka.Types (KafkaError, TopicName)
import Kenshou.Core.Context (RunContext)
import Kenshou.Core.Dimension (allTelemetryArms, noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (CohortScope (..), KnownDefect (..), Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Env.Kafka
import Kenshou.Suite.Kafka.Fixture (firstBrokers, produceValues)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Kafka (defaultConfig, kafkaAdapter)
import Shibuya.App (ProcessorId (..), defaultAppConfig, mkProcessor, runApp, stopApp, waitApp)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Types (Envelope (..), MessageId (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import Streamly.Data.Stream qualified as Stream

scenarios :: [Scenario]
scenarios =
  [ Scenario
      { id = either (error . Text.unpack) id (parseScenarioId "kafka/adapter/correctness/multi-topic-partition-key"),
        revision = 1,
        summary = "Checks message IDs and partition keys across two topics with partition zero.",
        tier = TierSmoke,
        placement = PlaceEither,
        knobs = [],
        dimensions = allTelemetryArms noDimensions,
        phases = zeroPhases,
        requires = noEnvironment,
        knownDefect =
          Just
            KnownDefect
              { reference = "mori://shinzui/shibuya-kafka-adapter/okf/capabilities/concepts/CAP-3",
                summary = "Envelope.partition contains only the numeric partition, so two topics collide.",
                expectedFailures = ["partition-key-distinguishes-topics"],
                appliesTo = AllCohorts
              },
        run = runMultiTopic
      }
  ]

runMultiTopic :: RunContext -> IO ScenarioReport
runMultiTopic context = do
  spec <- either (ioError . userError . Text.unpack) pure (kafkaEnvSpecFromRunSpec context)
  withKafkaEnv context spec \env -> do
    [firstTopic, secondTopic] <- createTopics env [TopicSpec "topic-a" 1 mempty, TopicSpec "topic-b" 1 mempty]
    _ <- produceValues env firstTopic [0 .. 9]
    _ <- produceValues env secondTopic [10 .. 19]
    facts <- consumeBoth env [firstTopic, secondTopic]
    _ <- deleteRunGroups env
    _ <- deleteRunTopics env
    let firstKeys = [key | (value, _, key) <- facts, value < 10]
        secondKeys = [key | (value, _, key) <- facts, value >= 10]
        ids = [identifier | (_, identifier, _) <- facts]
        uniqueIds = length facts == 20 && length (nub ids) == 20
        distinctKeys = not (null firstKeys || null secondKeys) && all (`notElem` secondKeys) firstKeys
    pure $
      if not uniqueIds
        then failedWith ["message-id-unique"] ("message IDs collided or records were missing: " <> Text.pack (show facts))
        else
          if distinctKeys
            then passed
            else failedWith ["partition-key-distinguishes-topics"] ("topic-a keys=" <> Text.pack (show (nub firstKeys)) <> " topic-b keys=" <> Text.pack (show (nub secondKeys)))

consumeBoth :: KafkaEnv -> [TopicName] -> IO [(Int, Text, Text)]
consumeBoth env topics = do
  facts <- newIORef []
  let props = C.brokersList (firstBrokers env) <> C.groupId (groupName env "multi-topic") <> C.noAutoOffsetStore
      subscription = C.topics topics <> C.offsetReset C.Earliest
  result <- runEff . runError @KafkaError . runTracingNoop $
    C.runKafkaConsumer props subscription $ do
      adapter <- kafkaAdapter (defaultConfig topics)
      let finiteAdapter = adapter {source = Stream.take 20 adapter.source}
          handler Message {envelope = Envelope {payload, messageId = MessageId identifier, partition}} = do
            case (payload >>= readInt, partition) of
              (Just value, Just key) -> liftIO $ modifyIORef' facts ((value, identifier, key) :)
              _ -> pure ()
            pure AckOk
      appResult <- runApp defaultAppConfig [(ProcessorId "multi-topic", mkProcessor finiteAdapter handler)]
      case appResult of
        Left problem -> liftIO $ ioError (userError (show problem))
        Right handle -> waitApp handle >> stopApp handle
  either (ioError . userError . show) pure result
  reverse <$> readIORef facts

readInt :: ByteString.ByteString -> Maybe Int
readInt bytes = case reads (ByteString.unpack bytes) of
  [(value, "")] -> Just value
  _ -> Nothing
