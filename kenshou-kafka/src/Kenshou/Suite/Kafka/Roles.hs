module Kenshou.Suite.Kafka.Roles (roles, adapterConsumerRole, batchProducerRole) where

import Data.Aeson (FromJSON (..), Value, object, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Char8 qualified as ByteString
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (liftIO, runEff)
import Effectful.Error.Static (runError)
import Kafka.Consumer.Types (ConsumerGroupId (..))
import Kafka.Effectful.Consumer qualified as C
import Kafka.Effectful.Producer qualified as P
import Kafka.Types (BrokerAddress (..), KafkaError, TopicName (..))
import Kenshou.Core.Role (ControlMessage (..), RoleContext (..), RoleName, WorkerInit (..), WorkerMessage (..), WorkerRole (..), mkRoleName)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Kafka (defaultConfig, kafkaAdapter)
import Shibuya.App (ProcessorId (..), defaultAppConfig, mkProcessor, runApp, stopApp, waitApp)
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..), HaltReason (..))
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Types (Envelope (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import Streamly.Data.Stream qualified as Stream

roles :: [WorkerRole]
roles =
  [ WorkerRole adapterConsumerRole "Consumes Kafka records through the adapter under a declared handler policy." runAdapterConsumer,
    WorkerRole batchProducerRole "Enqueues a batch and attempts a bounded flush during a broker outage." runBatchProducer
  ]

adapterConsumerRole :: RoleName
adapterConsumerRole = either (error . Text.unpack) id (mkRoleName "kafka/adapter-consumer")

batchProducerRole :: RoleName
batchProducerRole = either (error . Text.unpack) id (mkRoleName "kafka/batch-producer")

data ConsumerArgs = ConsumerArgs
  { brokers :: [Text],
    topic :: Text,
    group :: Text,
    messages :: Int,
    poisonCount :: Int
  }

instance FromJSON ConsumerArgs where
  parseJSON = withObject "Kafka consumer args" \value ->
    ConsumerArgs <$> value .: "brokers" <*> value .: "topic" <*> value .: "group" <*> value .: "messages" <*> value .: "poisonCount"

runAdapterConsumer :: RoleContext -> IO ()
runAdapterConsumer context = do
  args <- case fromJson context.init.args of
    Left problem -> ioError (userError problem)
    Right value -> pure value
  context.send WrkReady
  command <- context.receive
  case command of
    Just CtlStart -> do
      (oks, drops) <- consumeDeadLetters args
      context.send (WrkCustom "summary" (object ["ok" .= oks, "dropped" .= drops]))
      _ <- context.receive
      pure ()
    _ -> ioError (userError "adapter-consumer expected start")

fromJson :: (FromJSON a) => Value -> Either String a
fromJson value = case Aeson.fromJSON value of Aeson.Error problem -> Left problem; Aeson.Success parsed -> Right parsed

consumeDeadLetters :: ConsumerArgs -> IO ([Int], [Int])
consumeDeadLetters args = do
  oks <- newIORef []
  drops <- newIORef []
  let topic = TopicName args.topic
      props = C.brokersList (fmap BrokerAddress args.brokers) <> C.groupId (ConsumerGroupId args.group) <> C.noAutoOffsetStore
      subscription = C.topics [topic] <> C.offsetReset C.Earliest
  outcome <- runEff . runError @KafkaError . runTracingNoop $
    C.runKafkaConsumer props subscription $ do
      adapter <- kafkaAdapter (defaultConfig [topic])
      let finiteAdapter = adapter {source = Stream.take args.messages adapter.source}
          handler Message {envelope = Envelope {payload}} = case payload >>= readInt of
            Nothing -> pure (AckHalt (HaltFatal "invalid payload"))
            Just value
              | value < args.poisonCount -> do
                  liftIO $ modifyIORef' drops (value :)
                  pure (AckDeadLetter (PoisonPill "kenshou"))
              | otherwise -> do
                  liftIO $ modifyIORef' oks (value :)
                  pure AckOk
      appResult <- runApp defaultAppConfig [(ProcessorId "adapter-consumer", mkProcessor finiteAdapter handler)]
      case appResult of
        Left problem -> liftIO $ ioError (userError (show problem))
        Right handle -> waitApp handle >> stopApp handle
  either (ioError . userError . show) pure outcome
  (,) <$> (reverse <$> readIORef oks) <*> (reverse <$> readIORef drops)

readInt :: ByteString.ByteString -> Maybe Int
readInt bytes = case reads (ByteString.unpack bytes) of [(value, "")] -> Just value; _ -> Nothing

data ProducerArgs = ProducerArgs {brokers :: [Text], topic :: Text, messages :: Int, messageTimeoutMillis :: Int}

instance FromJSON ProducerArgs where
  parseJSON = withObject "Kafka producer args" \value ->
    ProducerArgs <$> value .: "brokers" <*> value .: "topic" <*> value .: "messages" <*> value .: "messageTimeoutMillis"

runBatchProducer :: RoleContext -> IO ()
runBatchProducer context = do
  args <- either (ioError . userError) pure (fromJson context.init.args :: Either String ProducerArgs)
  context.send WrkReady
  command <- context.receive
  case command of
    Just CtlStart -> do
      let props = P.brokersList (fmap BrokerAddress args.brokers) <> P.extraProp "message.timeout.ms" (Text.pack (show args.messageTimeoutMillis))
          topic = TopicName args.topic
          records =
            [ P.ProducerRecord
                { P.prTopic = topic,
                  P.prPartition = P.UnassignedPartition,
                  P.prKey = Just (ByteString.pack (show number)),
                  P.prValue = Just (ByteString.pack (show number)),
                  P.prHeaders = mempty
                }
            | number <- [0 .. args.messages - 1]
            ]
      outcome <- runEff . runError @KafkaError $
        P.runKafkaProducer props $ do
          failures <- P.produceMessageBatch records
          liftIO $ context.send (WrkCustom "enqueue" (object ["failures" .= length failures, "submitted" .= args.messages]))
          P.flushProducer
          liftIO $ context.send (WrkCustom "flushed" (object []))
      case outcome of
        Left problem -> context.send (WrkError (Text.pack (show problem)))
        Right () -> pure ()
      _ <- context.receive
      pure ()
    _ -> ioError (userError "batch-producer expected start")
