module Kenshou.Suite.Runtime.System.KafkaBridge
  ( publishToKafka,
    producerRecord,
    liveTraceHeaders,
  )
where

import Data.ByteString (ByteString)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Effectful (runEff)
import Effectful.Error.Static (runError)
import Kafka.Effectful.Producer qualified as Producer
import Kafka.Types (KafkaError, Timeout (..), TopicName (..), headersFromList)
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
