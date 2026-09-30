module Kenshou.Suite.Runtime.System.KafkaBridge
  ( publishToKafka,
    producerRecord,
    liveTraceHeaders,
    ConsumerDecodeError (..),
    decodeConsumerRecord,
  )
where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time (UTCTime)
import Effectful (runEff)
import Effectful.Error.Static (runError)
import Kafka.Consumer.Types (ConsumerRecord (..), Offset (..))
import Kafka.Effectful.Producer qualified as Producer
import Kafka.Types (KafkaError, PartitionId (..), Timeout (..), TopicName (..), headersFromList, headersToList)
import Keiro.Inbox.Kafka (KafkaDecodeError, KafkaInboundRecord (..), integrationEventFromKafka)
import Keiro.Inbox.Types (KafkaDeliveryRef)
import Keiro.Integration.Event (IntegrationEvent (..))
import Keiro.Outbox (OrderingPolicy (..), OutboxId, OutboxRow (..), PublishOutcome (..))
import Keiro.Outbox.Kafka (KafkaProducerRecord (..), outboxRowToKafkaRecord)
import Keiro.Telemetry (injectTraceContext)
import Kenshou.Env.Kafka (BrokerLane (..), KafkaEnv (..))

-- | Publish one record at a time with broker acknowledgement. A failed
-- ordering group is blocked for the rest of the batch, while independent
-- groups continue so their rows do not consume attempts without a publish.
publishToKafka :: KafkaEnv -> OrderingPolicy -> [OutboxRow] -> IO [(OutboxId, PublishOutcome)]
publishToKafka environment policy = go Set.empty
  where
    brokers = (NonEmpty.head environment.lanes).laneBrokers

    go _ [] = pure []
    go failedGroups (row : rest) = do
      let group = orderingGroup policy row
      if maybe False (`Set.member` failedGroups) group
        then ((row.outboxId, PublishFailed "earlier record in ordering group failed") :) <$> go failedGroups rest
        else do
          let wire = outboxRowToKafkaRecord row
          headers <- liveTraceHeaders wire.headers
          result <-
            runEff . runError @KafkaError $
              Producer.runKafkaProducer
                (Producer.brokersList brokers <> Producer.sendTimeout (Timeout 10000) <> Producer.extraProp "acks" "all")
                (Producer.produceMessageSync (producerRecord wire headers))
          case result of
            Left problem ->
              ((row.outboxId, PublishFailed (Text.pack (show problem))) :)
                <$> go (maybe failedGroups (`Set.insert` failedGroups) group) rest
            Right _ -> ((row.outboxId, PublishSucceeded) :) <$> go failedGroups rest

orderingGroup :: OrderingPolicy -> OutboxRow -> Maybe (Text, Maybe Text)
orderingGroup policy row = case policy of
  PerSourceStream -> Just (row.event.source, Nothing)
  PerKeyHeadOfLine -> (\key -> (row.event.source, Just key)) <$> row.event.key
  StopTheLine -> Just ("", Nothing)
  BestEffort -> Nothing

producerRecord :: KafkaProducerRecord -> [(ByteString, ByteString)] -> Producer.ProducerRecord
producerRecord record headers =
  Producer.ProducerRecord
    { Producer.prTopic = TopicName record.topic,
      Producer.prPartition = Producer.UnassignedPartition,
      Producer.prKey = record.key,
      Producer.prValue = Just record.payload,
      Producer.prHeaders = headersFromList headers
    }

liveTraceHeaders :: [(ByteString, ByteString)] -> IO [(ByteString, ByteString)]
liveTraceHeaders stored = do
  let decoded = [(TextEncoding.decodeUtf8 name, TextEncoding.decodeUtf8 value) | (name, value) <- stored]
      withoutTrace = filter (not . isTraceHeader . fst) decoded
  currentTrace <- injectTraceContext []
  let selected = if null currentTrace then decoded else withoutTrace <> currentTrace
  pure [(TextEncoding.encodeUtf8 name, TextEncoding.encodeUtf8 value) | (name, value) <- selected]
  where
    isTraceHeader name = name == "traceparent" || name == "tracestate"

data ConsumerDecodeError
  = MissingKafkaPayload
  | InvalidKafkaKeyUtf8 !ByteString
  | InvalidKafkaHeaderUtf8 !ByteString
  | InvalidKeiroEnvelope !KafkaDecodeError
  deriving stock (Eq, Show)

-- | Preserve broker coordinates and reject malformed wire bytes before the
-- Keiro inbox records a receipt. Callers acknowledge the Kafka offset only
-- after the downstream transaction commits.
decodeConsumerRecord :: ConsumerRecord (Maybe ByteString) (Maybe ByteString) -> UTCTime -> Either ConsumerDecodeError (IntegrationEvent, KafkaDeliveryRef)
decodeConsumerRecord record receivedAt = do
  payload <- maybe (Left MissingKafkaPayload) Right record.crValue
  key <- traverse (\raw -> first (const (InvalidKafkaKeyUtf8 raw)) (TextEncoding.decodeUtf8' raw)) record.crKey
  headers <- traverse decodeHeader (headersToList record.crHeaders)
  first InvalidKeiroEnvelope $
    integrationEventFromKafka
      KafkaInboundRecord
        { topic = unTopicName record.crTopic,
          partition = fromIntegral (unPartitionId record.crPartition),
          offset = unOffset record.crOffset,
          key,
          payload,
          headers,
          receivedAt
        }
  where
    decodeHeader (name, value) = do
      decodedName <- first (const (InvalidKafkaHeaderUtf8 name)) (TextEncoding.decodeUtf8' name)
      decodedValue <- first (const (InvalidKafkaHeaderUtf8 value)) (TextEncoding.decodeUtf8' value)
      pure (decodedName, decodedValue)
