module Kenshou.Suite.Keiro.Fixture.Bonus where

import Data.Aeson (parseJSON, toJSON)
import Data.Aeson.Types (parseEither)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as Text
import Keiki.Builder qualified as B
import Keiki.Core (HsPred, RegFile (..), SymTransducer, (.>))
import Keiki.Core qualified as K
import Keiki.Generics.TH (deriveAggregate)
import Keiro.Codec (Codec (..))
import Keiro.EventStream (EventStream (..), SnapshotPolicy (..))
import Keiro.EventStream.Validate (ValidatedEventStream, mkEventStreamOrThrow)
import Keiro.Stream (Stream)
import Keiro.Stream qualified as Stream
import Kenshou.Suite.Keiro.Fixture.Domain
import Kiroku.Store.Types (EventType (..))

type BonusPhi = HsPred BonusRegs BonusCommand

type BonusEventStream = EventStream BonusPhi BonusRegs BonusState BonusCommand BonusEvent

type ValidatedBonusEventStream = ValidatedEventStream BonusPhi BonusRegs BonusState BonusCommand BonusEvent

$(deriveAggregate ''BonusCommand ''BonusRegs ''BonusEvent)

bonusTransducer :: SymTransducer BonusPhi BonusRegs BonusState BonusCommand BonusEvent
bonusTransducer =
  B.buildTransducer BonusUndeclared RNil (== BonusDeclaredState) do
    B.from BonusUndeclared do
      B.onCmd inCtorDeclareBonus $ \d -> B.do
        B.requireGuard (d.amount .> K.lit (0 :: Int))
        B.emit wireBonusDeclared BonusDeclaredTermFields {bonusId = d.bonusId, segment = d.segment, amount = d.amount}
        B.goto BonusDeclaredState

bonusCodec :: Codec BonusEvent
bonusCodec =
  Codec
    { eventTypes = EventType "BonusDeclared" :| [],
      eventType = \_ -> EventType "BonusDeclared",
      schemaVersion = 1,
      encode = \(BonusDeclared d) -> toJSON d,
      decode = \(EventType tag) value ->
        if tag == "BonusDeclared"
          then BonusDeclared <$> either (Left . Text.pack) Right (parseEither parseJSON value)
          else Left ("unknown bonus event type: " <> tag),
      upcasters = []
    }

bonusEventStream :: ValidatedBonusEventStream
bonusEventStream =
  mkEventStreamOrThrow
    "kenshou-bonus"
    EventStream
      { transducer = bonusTransducer,
        initialState = BonusUndeclared,
        initialRegisters = RNil,
        eventCodec = bonusCodec,
        resolveStreamName = Stream.streamName,
        snapshotPolicy = Never,
        stateCodec = Nothing
      }

bonusStream :: BonusId -> Stream BonusEventStream
bonusStream (BonusId bonusId) = Stream.entityStream (Stream.categoryUnsafe "bonus") bonusId
