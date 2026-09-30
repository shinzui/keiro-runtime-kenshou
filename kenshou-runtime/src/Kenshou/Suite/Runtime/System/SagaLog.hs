module Kenshou.Suite.Runtime.System.SagaLog
  ( SagaCommand (..),
    SagaEvent (..),
    SagaState (..),
    ObserveSagaData (..),
    SagaObservedData (..),
    SagaEventStream,
    sagaEventStream,
    sagaStream,
    sagaCommandStream,
    sagaCodec,
  )
where

import Data.Aeson (FromJSON, ToJSON, parseJSON, toJSON)
import Data.Aeson.Types (parseEither)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Keiki.Builder qualified as B
import Keiki.Core (HsPred, RegFile (..), SymTransducer)
import Keiki.Generics.TH (deriveAggregate)
import Keiki.Shape (CanonicalStateShape)
import Keiro.Codec (Codec (..))
import Keiro.EventStream (EventStream (..), SnapshotPolicy (..))
import Keiro.EventStream.Validate (ValidatedEventStream, mkEventStreamOrThrow)
import Keiro.Stream (Stream)
import Keiro.Stream qualified as Stream
import Kenshou.Suite.Runtime.System.Contracts (OrderId (..))
import Kiroku.Store.Types (EventType (..))

type SagaRegs = '[]

data SagaState = SagaIdle
  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)

instance CanonicalStateShape SagaState

data SagaCommand = ObserveSaga !ObserveSagaData
  deriving stock (Generic, Eq, Show)

data SagaEvent = SagaObserved !SagaObservedData
  deriving stock (Generic, Eq, Show)

data ObserveSagaData = ObserveSagaData
  { orderId :: !OrderId,
    stage :: !Text,
    sourceEventId :: !Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data SagaObservedData = SagaObservedData
  { orderId :: !OrderId,
    stage :: !Text,
    sourceEventId :: !Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

type SagaEventStream = EventStream (HsPred SagaRegs SagaCommand) SagaRegs SagaState SagaCommand SagaEvent

type ValidatedSagaEventStream = ValidatedEventStream (HsPred SagaRegs SagaCommand) SagaRegs SagaState SagaCommand SagaEvent

$(deriveAggregate ''SagaCommand ''SagaRegs ''SagaEvent)

sagaTransducer :: SymTransducer (HsPred SagaRegs SagaCommand) SagaRegs SagaState SagaCommand SagaEvent
sagaTransducer =
  B.buildTransducer SagaIdle RNil (const False) do
    B.from SagaIdle do
      B.onCmd inCtorObserveSaga $ \d -> B.do
        B.emit wireSagaObserved SagaObservedTermFields {orderId = d.orderId, stage = d.stage, sourceEventId = d.sourceEventId}
        B.goto SagaIdle

sagaEventStream :: ValidatedSagaEventStream
sagaEventStream = mkEventStreamOrThrow "kenshou-runtime-saga-log" def
  where
    def =
      EventStream
        { transducer = sagaTransducer,
          initialState = SagaIdle,
          initialRegisters = RNil,
          eventCodec = sagaCodec,
          resolveStreamName = Stream.streamName,
          snapshotPolicy = Never,
          stateCodec = Nothing
        }

sagaStream :: Text -> OrderId -> Stream SagaEventStream
sagaStream category (OrderId identifier) = Stream.entityStream (Stream.categoryUnsafe category) identifier

sagaCommandStream :: Text -> OrderId -> Stream SagaCommand
sagaCommandStream category (OrderId identifier) = Stream.entityStream (Stream.categoryUnsafe category) identifier

sagaCodec :: Codec SagaEvent
sagaCodec =
  Codec
    { eventTypes = EventType "SagaObserved" :| [],
      eventType = \case
        SagaObserved {} -> EventType "SagaObserved",
      schemaVersion = 1,
      encode = \case
        SagaObserved value -> toJSON value,
      decode = \(EventType tag) value ->
        if tag == "SagaObserved"
          then SagaObserved <$> either (Left . Text.pack) Right (parseEither parseJSON value)
          else Left ("unknown saga event type: " <> tag),
      upcasters = []
    }
