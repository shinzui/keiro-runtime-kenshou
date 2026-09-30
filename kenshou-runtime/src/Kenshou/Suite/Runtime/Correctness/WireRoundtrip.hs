module Kenshou.Suite.Runtime.Correctness.WireRoundtrip (scenarios) where

import Control.Monad (forM)
import Data.Aeson (object, (.=))
import Data.ByteString (ByteString)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Effectful (runEff)
import Effectful.Error.Static (runError)
import Kafka.Consumer (ConsumerGroupId)
import Kafka.Consumer.Types (ConsumerRecord)
import Kafka.Effectful.Consumer qualified as Consumer
import Kafka.Effectful.Producer qualified as Producer
import Kafka.Types (KafkaError, Timeout (..), TopicName (..))
import Keiro.Inbox.Types (KafkaDeliveryRef (..))
import Keiro.Integration.Event (IntegrationEvent (..))
import Keiro.Outbox (IntegrationEventDraft (..))
import Keiro.Outbox.Kafka (KafkaProducerRecord (..), integrationEventToKafkaRecord)
import Kenshou.Core.Context (RunContext, SummarySection (..), putSummary)
import Kenshou.Core.Dimension (allTelemetryArms, noDimensions)
import Kenshou.Core.Env (kafkaEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Env.Kafka (BrokerLane (..), KafkaEnv (..))
import Kenshou.Suite.Runtime.System.Broker (RuntimeBroker (..), withRuntimeBroker)
import Kenshou.Suite.Runtime.System.Contracts (CustomerId (..), OrderId (..), ShopMessage (..), Sku (..), TopicPrefix (..), WarehouseMessage (..))
import Kenshou.Suite.Runtime.System.KafkaBridge (decodeConsumerRecord, producerRecord)
import Kenshou.Suite.Runtime.System.Wire (decodeShopEvent, decodeWarehouseEvent, shopEventDraft, warehouseEventDraft)

scenarios :: [Scenario]
scenarios =
  [ Scenario
      { id = either (error . Text.unpack) id (parseScenarioId "runtime/broker/correctness/public-wire-roundtrip"),
        revision = 1,
        summary = "Round-trips one versioned shop order and warehouse outcome through both run-scoped Kafka topics.",
        tier = TierSmoke,
        placement = PlaceEither,
        knobs = [],
        dimensions = allTelemetryArms noDimensions,
        phases = zeroPhases,
        requires = kafkaEnvironment,
        knownDefect = Nothing,
        run = runRoundtrip
      }
  ]

runRoundtrip :: RunContext -> IO ScenarioReport
runRoundtrip context = withRuntimeBroker context 1 \broker -> do
  let environment = broker.environment
      prefix = TopicPrefix environment.prefix
      orderId = OrderId "order-1"
      placed = OrderPlacedV1 orderId (CustomerId "customer-1") (Sku "sku-1") 2 900 False
      shipped = FulfilmentShippedV1 orderId (Sku "sku-1") 2
  now <- getCurrentTime
  let shopEvent = fromDraft "shop" "shop-message-1" (shopEventDraft prefix now placed)
      warehouseEvent = fromDraft "warehouse" "warehouse-message-1" (warehouseEventDraft prefix now shipped)
      brokers = (NonEmpty.head environment.lanes).laneBrokers
  produced <-
    runEff . runError @KafkaError $
      Producer.runKafkaProducer (Producer.brokersList brokers <> Producer.sendTimeout (Timeout 10000) <> Producer.extraProp "acks" "all") $
        forM [shopEvent, warehouseEvent] \event -> do
          let wire = integrationEventToKafkaRecord event
          Producer.produceMessageSync (producerRecord wire wire.headers)
  _ <- either (ioError . userError . show) pure produced
  shopRecord <- consumeOne environment broker.shopEvents broker.warehouseConsumerGroup
  warehouseRecord <- consumeOne environment broker.warehouseEvents broker.shopConsumerGroup
  let shopResult = shopRecord >>= (\record -> either (const Nothing) Just (decodeConsumerRecord record now))
      warehouseResult = warehouseRecord >>= (\record -> either (const Nothing) Just (decodeConsumerRecord record now))
      shopGood = case shopResult of
        Just (event, ref) -> event == shopEvent && decodeShopEvent prefix event == Right placed && validRef broker.shopEvents ref
        Nothing -> False
      warehouseGood = case warehouseResult of
        Just (event, ref) -> event == warehouseEvent && decodeWarehouseEvent prefix event == Right shipped && validRef broker.warehouseEvents ref
        Nothing -> False
  putSummary context Verdicts "publicWireRoundtrip" $
    object
      [ "shopReceived" .= maybe False (const True) shopRecord,
        "warehouseReceived" .= maybe False (const True) warehouseRecord,
        "shopExact" .= shopGood,
        "warehouseExact" .= warehouseGood
      ]
  pure $
    if shopGood && warehouseGood
      then passed
      else failedWith ["public-wire-roundtrip"] ("shop=" <> Text.pack (show shopResult) <> " warehouse=" <> Text.pack (show warehouseResult))

validRef :: TopicName -> KafkaDeliveryRef -> Bool
validRef (TopicName expected) ref = ref.topic == expected && ref.partition == 0 && ref.offset >= 0

consumeOne :: KafkaEnv -> TopicName -> ConsumerGroupId -> IO (Maybe (ConsumerRecord (Maybe ByteString) (Maybe ByteString)))
consumeOne environment topic group = do
  let brokers = (NonEmpty.head environment.lanes).laneBrokers
      props = Consumer.brokersList brokers <> Consumer.groupId group <> Consumer.noAutoOffsetStore
      subscription = Consumer.topics [topic] <> Consumer.offsetReset Consumer.Earliest
  result <- runEff . runError @KafkaError $ Consumer.runKafkaConsumer props subscription (poll 0)
  either (ioError . userError . show) pure result
  where
    poll (attempts :: Int)
      | attempts >= 20 = pure Nothing
      | otherwise = do
          candidate <- Consumer.pollMessage (Timeout 500)
          case candidate of
            Nothing -> poll (attempts + 1)
            Just record -> pure (Just record)

fromDraft :: Text -> Text -> IntegrationEventDraft -> IntegrationEvent
fromDraft source messageId draft =
  IntegrationEvent
    { messageId,
      source,
      destination = draft.destination,
      key = draft.key,
      eventType = draft.eventType,
      schemaVersion = draft.schemaVersion,
      contentType = draft.contentType,
      schemaReference = draft.schemaReference,
      sourceEventId = draft.sourceEventId,
      sourceGlobalPosition = draft.sourceGlobalPosition,
      payloadBytes = draft.payloadBytes,
      occurredAt = draft.occurredAt,
      causationId = draft.causationId,
      correlationId = draft.correlationId,
      traceContext = draft.traceContext,
      attributes = draft.attributes
    }
