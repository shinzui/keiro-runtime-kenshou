module Kenshou.Suite.Kafka.Roles (roles, adapterConsumerRole) where

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
roles = [WorkerRole adapterConsumerRole "Consumes Kafka records through the adapter under a declared handler policy." runAdapterConsumer]

adapterConsumerRole :: RoleName
adapterConsumerRole = either (error . Text.unpack) id (mkRoleName "kafka/adapter-consumer")

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
