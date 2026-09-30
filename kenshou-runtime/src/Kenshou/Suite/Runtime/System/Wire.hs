module Kenshou.Suite.Runtime.System.Wire
  ( WireError (..),
    shopEventDraft,
    warehouseEventDraft,
    decodeShopEvent,
    decodeWarehouseEvent,
  )
where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import Data.Text (Text)
import Data.Time (UTCTime)
import Keiro.Integration.Event (IntegrationContentType (..), IntegrationEvent (..), IntegrationEventError, decodeJsonIntegrationEvent)
import Keiro.Outbox (IntegrationEventDraft (..))
import Kenshou.Suite.Runtime.System.Contracts (OrderId (..), ShopMessage (..), TopicPrefix, WarehouseMessage (..), shopTopic, warehouseTopic)

data WireError
  = UnexpectedDestination !Text
  | UnexpectedKey !(Maybe Text)
  | UnsupportedEventType !Text
  | UnsupportedSchemaVersion !Int
  | PayloadEventTypeMismatch !Text
  | InvalidBusinessPayload !IntegrationEventError
  deriving stock (Eq, Show)

-- | The outbox owns message identity and source-event provenance. These
-- drafts provide only the versioned public business contract and routing.
shopEventDraft :: TopicPrefix -> UTCTime -> ShopMessage -> IntegrationEventDraft
shopEventDraft prefix occurredAt message =
  draft (shopTopic prefix) (orderKey message.orderId) "order.placed.v1" occurredAt message

warehouseEventDraft :: TopicPrefix -> UTCTime -> WarehouseMessage -> IntegrationEventDraft
warehouseEventDraft prefix occurredAt message =
  draft (warehouseTopic prefix) (orderKey message.orderId) (warehouseEventType message) occurredAt message

orderKey :: OrderId -> Maybe Text
orderKey (OrderId identifier) = Just identifier

draft :: (Aeson.ToJSON a) => Text -> Maybe Text -> Text -> UTCTime -> a -> IntegrationEventDraft
draft destination key eventType occurredAt message =
  IntegrationEventDraft
    { destination,
      key,
      eventType,
      schemaVersion = 1,
      contentType = ApplicationJson,
      schemaReference = Nothing,
      sourceEventId = Nothing,
      sourceGlobalPosition = Nothing,
      payloadBytes = Lazy.toStrict (Aeson.encode message),
      occurredAt,
      causationId = Nothing,
      correlationId = Nothing,
      traceContext = Nothing,
      attributes = Nothing
    }

decodeShopEvent :: TopicPrefix -> IntegrationEvent -> Either WireError ShopMessage
decodeShopEvent prefix event = do
  checkEnvelope (shopTopic prefix) "order.placed.v1" event
  message <- either (Left . InvalidBusinessPayload) Right (decodeJsonIntegrationEvent event)
  checkKey (orderKey message.orderId) event
  pure message

decodeWarehouseEvent :: TopicPrefix -> IntegrationEvent -> Either WireError WarehouseMessage
decodeWarehouseEvent prefix event = do
  checkDestination (warehouseTopic prefix) event
  checkVersion event
  if event.eventType `elem` ["fulfilment.shipped.v1", "fulfilment.refused.v1", "fulfilment.expired.v1"]
    then pure ()
    else Left (UnsupportedEventType event.eventType)
  message <- either (Left . InvalidBusinessPayload) Right (decodeJsonIntegrationEvent event)
  if warehouseEventType message == event.eventType
    then checkKey (orderKey message.orderId) event >> Right message
    else Left (PayloadEventTypeMismatch event.eventType)

checkKey :: Maybe Text -> IntegrationEvent -> Either WireError ()
checkKey expected event
  | event.key == expected = Right ()
  | otherwise = Left (UnexpectedKey event.key)

checkEnvelope :: Text -> Text -> IntegrationEvent -> Either WireError ()
checkEnvelope destination eventType event = do
  checkDestination destination event
  checkVersion event
  if event.eventType == eventType then Right () else Left (UnsupportedEventType event.eventType)

checkDestination :: Text -> IntegrationEvent -> Either WireError ()
checkDestination expected event
  | event.destination == expected = Right ()
  | otherwise = Left (UnexpectedDestination event.destination)

checkVersion :: IntegrationEvent -> Either WireError ()
checkVersion event
  | event.schemaVersion == 1 = Right ()
  | otherwise = Left (UnsupportedSchemaVersion event.schemaVersion)

warehouseEventType :: WarehouseMessage -> Text
warehouseEventType = \case
  FulfilmentShippedV1 {} -> "fulfilment.shipped.v1"
  FulfilmentRefusedV1 {} -> "fulfilment.refused.v1"
  FulfilmentExpiredV1 {} -> "fulfilment.expired.v1"
