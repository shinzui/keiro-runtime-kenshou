module Kenshou.Suite.Runtime.System.Fulfilment
  ( FulfilmentCommand (..),
    FulfilmentEvent (..),
    FulfilmentState (..),
    RequestFulfilmentData (..),
    RefuseFulfilmentData (..),
    ShipFulfilmentData (..),
    ExpireFulfilmentData (..),
    FulfilmentRequestedData (..),
    FulfilmentRefusedData (..),
    FulfilmentShippedData (..),
    FulfilmentExpiredData (..),
    FulfilmentEventStream,
    fulfilmentEventStream,
    fulfilmentStream,
    fulfilmentCommandStream,
    fulfilmentCodec,
  )
where

import Data.Aeson (FromJSON, ToJSON, parseJSON, toJSON)
import Data.Aeson.Types (parseEither)
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
import Kenshou.Suite.Runtime.System.Contracts (OrderId (..), Sku)
import Kiroku.Store.Types (EventType (..))

type FulfilmentRegs = '[]

data FulfilmentState = NotRequested | Requested | Refused | Shipped | Expired
  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)
  deriving anyclass (FromJSON, ToJSON)

instance CanonicalStateShape FulfilmentState

data FulfilmentCommand
  = RequestFulfilment !RequestFulfilmentData
  | RefuseFulfilment !RefuseFulfilmentData
  | ShipFulfilment !ShipFulfilmentData
  | ExpireFulfilment !ExpireFulfilmentData
  deriving stock (Generic, Eq, Show)

data FulfilmentEvent
  = FulfilmentRequested !FulfilmentRequestedData
  | FulfilmentRefused !FulfilmentRefusedData
  | FulfilmentShipped !FulfilmentShippedData
  | FulfilmentExpired !FulfilmentExpiredData
  deriving stock (Generic, Eq, Show)

data RequestFulfilmentData = RequestFulfilmentData
  { orderId :: !OrderId,
    sku :: !Sku,
    quantity :: !Int
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data RefuseFulfilmentData = RefuseFulfilmentData {orderId :: !OrderId, reason :: !Text}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

newtype ShipFulfilmentData = ShipFulfilmentData {orderId :: OrderId}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

newtype ExpireFulfilmentData = ExpireFulfilmentData {orderId :: OrderId}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data FulfilmentRequestedData = FulfilmentRequestedData
  { orderId :: !OrderId,
    sku :: !Sku,
    quantity :: !Int
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data FulfilmentRefusedData = FulfilmentRefusedData {orderId :: !OrderId, reason :: !Text}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

newtype FulfilmentShippedData = FulfilmentShippedData {orderId :: OrderId}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

newtype FulfilmentExpiredData = FulfilmentExpiredData {orderId :: OrderId}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

type FulfilmentEventStream = EventStream (HsPred FulfilmentRegs FulfilmentCommand) FulfilmentRegs FulfilmentState FulfilmentCommand FulfilmentEvent

type ValidatedFulfilmentEventStream = ValidatedEventStream (HsPred FulfilmentRegs FulfilmentCommand) FulfilmentRegs FulfilmentState FulfilmentCommand FulfilmentEvent

$(deriveAggregate ''FulfilmentCommand ''FulfilmentRegs ''FulfilmentEvent)

fulfilmentTransducer :: SymTransducer (HsPred FulfilmentRegs FulfilmentCommand) FulfilmentRegs FulfilmentState FulfilmentCommand FulfilmentEvent
fulfilmentTransducer =
  B.buildTransducer NotRequested RNil isTerminal do
    B.from NotRequested do
      B.onCmd inCtorRequestFulfilment $ \d -> B.do
        B.requireGuard (d.quantity .> K.lit (0 :: Int))
        B.emit wireFulfilmentRequested FulfilmentRequestedTermFields {orderId = d.orderId, sku = d.sku, quantity = d.quantity}
        B.goto Requested
      B.onCmd inCtorRefuseFulfilment $ \d -> B.do
        B.emit wireFulfilmentRefused FulfilmentRefusedTermFields {orderId = d.orderId, reason = d.reason}
        B.goto Refused
    B.from Requested do
      B.onCmd inCtorShipFulfilment $ \d -> B.do
        B.emit wireFulfilmentShipped FulfilmentShippedTermFields {orderId = d.orderId}
        B.goto Shipped
      B.onCmd inCtorExpireFulfilment $ \d -> B.do
        B.emit wireFulfilmentExpired FulfilmentExpiredTermFields {orderId = d.orderId}
        B.goto Expired
  where
    isTerminal = \case
      Refused -> True
      Shipped -> True
      Expired -> True
      _ -> False

fulfilmentEventStream :: ValidatedFulfilmentEventStream
fulfilmentEventStream = mkEventStreamOrThrow "kenshou-runtime-fulfilment" def
  where
    def =
      EventStream
        { transducer = fulfilmentTransducer,
          initialState = NotRequested,
          initialRegisters = RNil,
          eventCodec = fulfilmentCodec,
          resolveStreamName = Stream.streamName,
          snapshotPolicy = Never,
          stateCodec = Nothing
        }

fulfilmentStream :: OrderId -> Stream FulfilmentEventStream
fulfilmentStream (OrderId identifier) = Stream.entityStream (Stream.categoryUnsafe "fulfilment") identifier

fulfilmentCommandStream :: OrderId -> Stream FulfilmentCommand
fulfilmentCommandStream (OrderId identifier) = Stream.entityStream (Stream.categoryUnsafe "fulfilment") identifier

fulfilmentCodec :: Codec FulfilmentEvent
fulfilmentCodec =
  Codec
    { eventTypes = EventType "FulfilmentRequested" :| [EventType "FulfilmentRefused", EventType "FulfilmentShipped", EventType "FulfilmentExpired"],
      eventType = \case
        FulfilmentRequested {} -> EventType "FulfilmentRequested"
        FulfilmentRefused {} -> EventType "FulfilmentRefused"
        FulfilmentShipped {} -> EventType "FulfilmentShipped"
        FulfilmentExpired {} -> EventType "FulfilmentExpired",
      schemaVersion = 1,
      encode = \case
        FulfilmentRequested value -> toJSON value
        FulfilmentRefused value -> toJSON value
        FulfilmentShipped value -> toJSON value
        FulfilmentExpired value -> toJSON value,
      decode = \(EventType tag) value ->
        let parseRecord record = either (Left . Text.pack) Right (parseEither parseJSON record)
         in case tag of
              "FulfilmentRequested" -> FulfilmentRequested <$> parseRecord value
              "FulfilmentRefused" -> FulfilmentRefused <$> parseRecord value
              "FulfilmentShipped" -> FulfilmentShipped <$> parseRecord value
              "FulfilmentExpired" -> FulfilmentExpired <$> parseRecord value
              _ -> Left ("unknown fulfilment event type: " <> tag),
      upcasters = []
    }
