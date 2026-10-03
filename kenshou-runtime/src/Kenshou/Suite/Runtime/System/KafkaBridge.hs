module Kenshou.Suite.Runtime.System.KafkaBridge
  ( publishToKafka,
    publishToBrokers,
    producerRecord,
    liveTraceHeaders,
    ConsumerDecodeError (..),
    decodeConsumerRecord,
    decodeEnvelope,
    ConsumerSpec (..),
    ConsumerExit (..),
    runKafkaInboxConsumer,
  )
where

import Control.Concurrent.Async (race)
import Control.Concurrent.MVar (MVar, readMVar)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time (UTCTime, getCurrentTime)
import Effectful (Limit (..), Persistence (..), UnliftStrategy (..), liftIO, runEff, withEffToIO)
import Effectful.Error.Static (runError, tryError)
import Kafka.Consumer.Types (ConsumerGroupId (..), ConsumerRecord (..), Offset (..))
import Kafka.Effectful.Consumer qualified as Consumer
import Kafka.Effectful.OpenTelemetry.Producer.Interpreter (runKafkaProducerTraced)
import Kafka.Effectful.Producer qualified as Producer
import Kafka.Types (BrokerAddress (..), KafkaError, PartitionId (..), Timeout (..), TopicName (..), headersFromList, headersToList)
import Keiro.Inbox.Kafka (KafkaDecodeError, KafkaInboundRecord (..), integrationEventFromKafka)
import Keiro.Inbox.Types (KafkaDeliveryRef)
import Keiro.Integration.Event (IntegrationEvent (..))
import Keiro.Outbox (OrderingPolicy (..), OutboxId, OutboxRow (..), PublishOutcome (..))
import Keiro.Outbox.Kafka (KafkaProducerRecord (..), outboxRowToKafkaRecord)
import Keiro.Telemetry (injectTraceContext)
import Kenshou.Env.Kafka (BrokerLane (..), KafkaEnv (..))
import Kenshou.Suite.Runtime.System.Config (PublishMode (..))
import Kenshou.Suite.Runtime.System.Trace (Signals (..), TraceSabotage (..), noSignals, withStoredTrace)
import OpenTelemetry.Trace.Core (Tracer)
import Shibuya.Adapter.Kafka (defaultConfig, kafkaAdapterWith, kafkaRebalanceHandler, newKafkaAdapterState)
import Shibuya.App (ProcessorId (..), defaultAppConfig, mkProcessor, runApp, stopApp, waitApp)
import Shibuya.Core.Ack (AckDecision)
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..))
import Shibuya.Telemetry.Effect (runTracing, runTracingNoop)
import Text.Read (readMaybe)

-- | Publish through the run's first broker lane. See 'publishToBrokers'.
publishToKafka :: KafkaEnv -> OrderingPolicy -> [OutboxRow] -> IO [(OutboxId, PublishOutcome)]
publishToKafka environment = publishToBrokers SyncPerRecord noSignals (NonEmpty.head environment.lanes).laneBrokers

-- | Publish one record at a time with broker acknowledgement, through one
-- producer per claimed batch. A failed ordering group is blocked for the
-- rest of the batch, while independent groups continue so their rows do not
-- consume attempts without a publish.
--
-- With a tracer, each record is sent by the traced producer inside the
-- trace stored on its outbox row: the producer's @send <topic>@ span joins
-- the order's trace and its context replaces the stored trace headers, so
-- the consumer's process span becomes the send span's child. Without one,
-- the stored headers are published as they are.
--
-- 'BatchEnqueue' is the known-defect wiring (keiro plan 120, KFK-3): it hands
-- the whole batch to the producer's queue and reports every enqueued row as
-- published without waiting for a broker acknowledgement.
publishToBrokers :: PublishMode -> Signals -> [BrokerAddress] -> OrderingPolicy -> [OutboxRow] -> IO [(OutboxId, PublishOutcome)]
publishToBrokers _ _ _ _ [] = pure []
publishToBrokers BatchEnqueue _ brokers _ rows = do
  let properties = Producer.brokersList brokers <> Producer.sendTimeout (Timeout 10000) <> Producer.extraProp "acks" "all"
      records = [(row.outboxId, producerRecord wire wire.headers) | row <- rows, let wire = outboxRowToKafkaRecord row]
  result <- runEff . runError @KafkaError $ Producer.runKafkaProducer properties (Producer.produceMessageBatch (fmap snd records))
  pure case result of
    Left (_, problem) -> [(row.outboxId, PublishFailed ("producer unavailable: " <> Text.pack (show problem))) | row <- rows]
    Right failures ->
      [ (identifier, maybe PublishSucceeded (PublishFailed . Text.pack . show) (lookup record [(failed, problem) | (failed, problem) <- failures]))
      | (identifier, record) <- records
      ]
publishToBrokers SyncPerRecord signals brokers policy rows = do
  let properties = Producer.brokersList brokers <> Producer.sendTimeout (Timeout 10000) <> Producer.extraProp "acks" "all"
  result <-
    runEff . runError @KafkaError $
      maybe Producer.runKafkaProducer runKafkaProducerTraced tracer properties (go Set.empty rows)
  pure case result of
    Right outcomes -> outcomes
    Left (_, problem) -> [(row.outboxId, PublishFailed ("producer unavailable: " <> Text.pack (show problem))) | row <- rows]
  where
    tracer = if signals.sabotage == UntracedProducer then Nothing else signals.tracer
    go _ [] = pure []
    go failedGroups (row : rest) = do
      let group = orderingGroup policy row
      if maybe False (`Set.member` failedGroups) group
        then ((row.outboxId, PublishFailed "earlier record in ordering group failed") :) <$> go failedGroups rest
        else do
          let wire = outboxRowToKafkaRecord row
          headers <- case tracer of
            Nothing -> liftIO (liveTraceHeaders wire.headers)
            Just _ -> pure (filter (not . isTraceHeader . fst) wire.headers)
          sent <- withStoredTrace noSignals {tracer} row.event.traceContext (tryError @KafkaError (Producer.produceMessageSync (producerRecord wire headers)))
          case sent of
            Left (_, problem) ->
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
      withoutTrace = filter (not . isTraceName . fst) decoded
  currentTrace <- injectTraceContext []
  let selected = if null currentTrace then decoded else withoutTrace <> currentTrace
  pure [(TextEncoding.encodeUtf8 name, TextEncoding.encodeUtf8 value) | (name, value) <- selected]
  where
    isTraceName name = name == "traceparent" || name == "tracestate"

isTraceHeader :: ByteString -> Bool
isTraceHeader name = name == "traceparent" || name == "tracestate"

data ConsumerDecodeError
  = MissingKafkaPayload
  | InvalidKafkaKeyUtf8 !ByteString
  | InvalidKafkaHeaderUtf8 !ByteString
  | MissingDeliveryCoordinates
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

-- | The shibuya Kafka envelope carries the payload, headers, partition and
-- offset but not the record key, so the decoded event has no key and the
-- caller must not require one.
decodeEnvelope :: TopicName -> Envelope (Maybe ByteString) -> UTCTime -> Either ConsumerDecodeError (IntegrationEvent, KafkaDeliveryRef)
decodeEnvelope topic envelope receivedAt = do
  payload <- maybe (Left MissingKafkaPayload) Right envelope.payload
  partition <- maybe (Left MissingDeliveryCoordinates) Right (envelope.partition >>= readMaybe . Text.unpack)
  offset <- case envelope.cursor of
    Just (CursorInt value) -> Right (fromIntegral value)
    _ -> Left MissingDeliveryCoordinates
  headers <- traverse decodeHeader (maybe [] id envelope.headers)
  first InvalidKeiroEnvelope $
    integrationEventFromKafka
      KafkaInboundRecord
        { topic = unTopicName topic,
          partition,
          offset,
          key = Nothing,
          payload,
          headers,
          receivedAt
        }

decodeHeader :: (ByteString, ByteString) -> Either ConsumerDecodeError (Text, Text)
decodeHeader (name, value) = do
  decodedName <- first (const (InvalidKafkaHeaderUtf8 name)) (TextEncoding.decodeUtf8' name)
  decodedValue <- first (const (InvalidKafkaHeaderUtf8 value)) (TextEncoding.decodeUtf8' value)
  pure (decodedName, decodedValue)

data ConsumerSpec = ConsumerSpec
  { brokers :: ![Text],
    topic :: !Text,
    group :: !Text,
    processor :: !Text,
    properties :: ![(Text, Text)]
  }
  deriving stock (Eq, Show)

-- | Consume one topic through shibuya-kafka-adapter under serial processing,
-- with offsets stored only after the handler's acknowledgement. The loop
-- runs until the stop variable is filled; its value is returned.
--
-- With a tracer, shibuya opens a @<processor> process@ consumer span per
-- record, parented to the trace in the record's headers, and the handler
-- runs inside it.
runKafkaInboxConsumer :: Maybe Tracer -> ConsumerSpec -> MVar result -> (Envelope (Maybe ByteString) -> UTCTime -> IO AckDecision) -> IO (Either Text (ConsumerExit result))
runKafkaInboxConsumer tracer spec stop handle = do
  state <- newKafkaAdapterState
  let topic = TopicName spec.topic
      props =
        Consumer.brokersList (fmap BrokerAddress spec.brokers)
          <> Consumer.groupId (ConsumerGroupId spec.group)
          <> Consumer.noAutoOffsetStore
          <> mconcat [Consumer.extraProp name value | (name, value) <- spec.properties]
          <> Consumer.setCallback (Consumer.rebalanceCallback (kafkaRebalanceHandler state))
      subscription = Consumer.topics [topic] <> Consumer.offsetReset Consumer.Earliest
  outcome <- runEff . runError @KafkaError . maybe runTracingNoop runTracing tracer $
    Consumer.runKafkaConsumer props subscription do
      adapter <- kafkaAdapterWith state (defaultConfig [topic])
      let handler Message {envelope} = liftIO do
            now <- getCurrentTime
            handle envelope now
      started <- runApp defaultAppConfig [(ProcessorId spec.processor, mkProcessor adapter handler)]
      case started of
        Left problem -> pure (Left (Text.pack (show problem)))
        Right app -> do
          ended <- withEffToIO (ConcUnlift Ephemeral (Limited 1)) \unlift -> race (readMVar stop) (unlift (waitApp app))
          case ended of
            Left result -> stopApp app >> pure (Right (StoppedWith result))
            Right () -> pure (Right SessionEnded)
  pure case outcome of
    Left (_, problem) -> Left (Text.pack (show problem))
    Right value -> value

-- | How a consumer session ended. 'SessionEnded' means the adapter's
-- processors finished although no stop was requested: the consumer still
-- holds its group membership but no longer handles its partitions.
data ConsumerExit result = StoppedWith result | SessionEnded
  deriving stock (Eq, Show)
