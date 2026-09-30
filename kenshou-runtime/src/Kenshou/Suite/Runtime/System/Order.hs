module Kenshou.Suite.Runtime.System.Order
  ( OrderCommand (..),
    OrderEvent (..),
    OrderState (..),
    PlaceOrderData (..),
    CompleteOrderData (..),
    RejectOrderData (..),
    ExpireOrderData (..),
    OrderPlacedData (..),
    OrderCompletedData (..),
    OrderRejectedData (..),
    OrderExpiredData (..),
    OrderEventStream,
    orderEventStream,
    orderStream,
    orderCommandStream,
    orderCodec,
  )
where

import Data.Aeson (FromJSON, ToJSON, parseJSON, toJSON)
import Data.Aeson.Types (parseEither)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Keiki.Builder qualified as B
import Keiki.Core (HsPred, RegFile (..), SymTransducer, (.>))
import Keiki.Core qualified as K
import Keiki.Generics.TH (deriveAggregate)
import Keiki.Shape (CanonicalStateShape)
import Keiro.Codec (Codec (..))
import Keiro.EventStream (EventStream (..), SnapshotPolicy (..))
import Keiro.EventStream.Validate (ValidatedEventStream, mkEventStreamOrThrow)
import Keiro.Stream (Stream)
import Keiro.Stream qualified as Stream
import Kenshou.Suite.Runtime.System.Contracts (CustomerId, OrderId (..), Sku)
import Kiroku.Store.Types (EventType (..))

type OrderRegs = '[]

data OrderState = NotPlaced | Placed | Completed | Rejected | Expired
  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)
  deriving anyclass (FromJSON, ToJSON)

instance CanonicalStateShape OrderState

data OrderCommand
  = PlaceOrder !PlaceOrderData
  | CompleteOrder !CompleteOrderData
  | RejectOrder !RejectOrderData
  | ExpireOrder !ExpireOrderData
  deriving stock (Generic, Eq, Show)

data OrderEvent
  = OrderPlaced !OrderPlacedData
  | OrderCompleted !OrderCompletedData
  | OrderRejected !OrderRejectedData
  | OrderExpired !OrderExpiredData
  deriving stock (Generic, Eq, Show)

data PlaceOrderData = PlaceOrderData
  { orderId :: !OrderId,
    customer :: !CustomerId,
    sku :: !Sku,
    quantity :: !Int,
    amountCents :: !Int64,
    slowPick :: !Bool
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

newtype CompleteOrderData = CompleteOrderData {orderId :: OrderId}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data RejectOrderData = RejectOrderData {orderId :: !OrderId, reason :: !Text}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

newtype ExpireOrderData = ExpireOrderData {orderId :: OrderId}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data OrderPlacedData = OrderPlacedData
  { orderId :: !OrderId,
    customer :: !CustomerId,
    sku :: !Sku,
    quantity :: !Int,
    amountCents :: !Int64,
    slowPick :: !Bool
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

newtype OrderCompletedData = OrderCompletedData {orderId :: OrderId}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data OrderRejectedData = OrderRejectedData {orderId :: !OrderId, reason :: !Text}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

newtype OrderExpiredData = OrderExpiredData {orderId :: OrderId}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

type OrderEventStream = EventStream (HsPred OrderRegs OrderCommand) OrderRegs OrderState OrderCommand OrderEvent

type ValidatedOrderEventStream = ValidatedEventStream (HsPred OrderRegs OrderCommand) OrderRegs OrderState OrderCommand OrderEvent

$(deriveAggregate ''OrderCommand ''OrderRegs ''OrderEvent)

orderTransducer :: SymTransducer (HsPred OrderRegs OrderCommand) OrderRegs OrderState OrderCommand OrderEvent
orderTransducer =
  B.buildTransducer NotPlaced RNil isTerminal do
    B.from NotPlaced do
      B.onCmd inCtorPlaceOrder $ \d -> B.do
        B.requireGuard (d.quantity .> K.lit (0 :: Int))
        B.requireGuard (d.amountCents .> K.lit (0 :: Int64))
        B.emit wireOrderPlaced OrderPlacedTermFields {orderId = d.orderId, customer = d.customer, sku = d.sku, quantity = d.quantity, amountCents = d.amountCents, slowPick = d.slowPick}
        B.goto Placed
    B.from Placed do
      B.onCmd inCtorCompleteOrder $ \d -> B.do
        B.emit wireOrderCompleted OrderCompletedTermFields {orderId = d.orderId}
        B.goto Completed
      B.onCmd inCtorRejectOrder $ \d -> B.do
        B.emit wireOrderRejected OrderRejectedTermFields {orderId = d.orderId, reason = d.reason}
        B.goto Rejected
      B.onCmd inCtorExpireOrder $ \d -> B.do
        B.emit wireOrderExpired OrderExpiredTermFields {orderId = d.orderId}
        B.goto Expired
  where
    isTerminal = \case
      Completed -> True
      Rejected -> True
      Expired -> True
      _ -> False

orderEventStream :: ValidatedOrderEventStream
orderEventStream = mkEventStreamOrThrow "kenshou-runtime-order" def
  where
    def =
      EventStream
        { transducer = orderTransducer,
          initialState = NotPlaced,
          initialRegisters = RNil,
          eventCodec = orderCodec,
          resolveStreamName = Stream.streamName,
          snapshotPolicy = Never,
          stateCodec = Nothing
        }

orderStream :: OrderId -> Stream OrderEventStream
orderStream (OrderId identifier) = Stream.entityStream (Stream.categoryUnsafe "order") identifier

orderCommandStream :: OrderId -> Stream OrderCommand
orderCommandStream (OrderId identifier) = Stream.entityStream (Stream.categoryUnsafe "order") identifier

orderCodec :: Codec OrderEvent
orderCodec =
  Codec
    { eventTypes = EventType "OrderPlaced" :| [EventType "OrderCompleted", EventType "OrderRejected", EventType "OrderExpired"],
      eventType = \case
        OrderPlaced {} -> EventType "OrderPlaced"
        OrderCompleted {} -> EventType "OrderCompleted"
        OrderRejected {} -> EventType "OrderRejected"
        OrderExpired {} -> EventType "OrderExpired",
      schemaVersion = 1,
      encode = \case
        OrderPlaced value -> toJSON value
        OrderCompleted value -> toJSON value
        OrderRejected value -> toJSON value
        OrderExpired value -> toJSON value,
      decode = \(EventType tag) value ->
        let parseRecord record = either (Left . Text.pack) Right (parseEither parseJSON record)
         in case tag of
              "OrderPlaced" -> OrderPlaced <$> parseRecord value
              "OrderCompleted" -> OrderCompleted <$> parseRecord value
              "OrderRejected" -> OrderRejected <$> parseRecord value
              "OrderExpired" -> OrderExpired <$> parseRecord value
              _ -> Left ("unknown order event type: " <> tag),
      upcasters = []
    }
