module Kenshou.Suite.Keiro.Fixture.Bonus where

import Data.Aeson (parseJSON, toJSON)
import Data.Aeson.Types (parseEither)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as Text
import Effectful (Eff, (:>))
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx
import Keiki.Builder qualified as B
import Keiki.Core (HsPred, RegFile (..), SymTransducer, (.>))
import Keiki.Core qualified as K
import Keiki.Generics.TH (deriveAggregate)
import Keiro.Codec (Codec (..))
import Keiro.EventStream (EventStream (..), SnapshotPolicy (..))
import Keiro.EventStream.Validate (ValidatedEventStream, mkEventStreamOrThrow)
import Keiro.ProcessManager (PMCommand (..))
import Keiro.Router (DeclarativeRouter (..), Router (..))
import Keiro.Router.Selection
  ( EmptySelectionPolicy,
    PartialDispatchPolicy (..),
    RedeliveryPolicy (..),
    RouterSelectionContract (..),
    RouterSelectionFailure,
    SelectionDedupe (..),
    SelectionFailurePolicy,
    SelectionFingerprint (..),
    SelectionIdentity (..),
    SelectionOrder (..),
    mkRecipientLimit,
    mkSelectionVersion,
  )
import Keiro.Stream (Stream)
import Keiro.Stream qualified as Stream
import Kenshou.Suite.Keiro.Fixture.Account
import Kenshou.Suite.Keiro.Fixture.Domain
import Kenshou.Suite.Keiro.Fixture.Projection (accountBalanceProjection)
import Kiroku.Store (Store, runTransaction)
import Kiroku.Store.Types (EventType (..), RecordedEvent (..))
import Numeric.Natural (Natural)

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

type BonusRouter es = Router BonusDeclaredData AccountPhi AccountRegs AccountState AccountCommand AccountEvent es

type DeclarativeBonusRouter es = DeclarativeRouter BonusDeclaredData AccountPhi AccountRegs AccountState AccountCommand AccountEvent es

bonusRouterName :: Text.Text
bonusRouterName = "bonusRouter"

bonusCommands :: BonusDeclaredData -> [AccountId] -> [PMCommand AccountCommand]
bonusCommands bonus recipients =
  [PMCommand (accountCommandStream account) (CreditBonus (CreditBonusData account bonus.bonusId bonus.amount)) | account <- recipients]

bonusRouterWith :: Text.Text -> ValidatedAccountEventStream -> (BonusDeclaredData -> Eff es [AccountId]) -> BonusRouter es
bonusRouterWith routerName accountEvents recipients =
  Router
    { name = routerName,
      key = \bonus -> let BonusId bonusId = bonus.bonusId in bonusId,
      resolve = \bonus -> bonusCommands bonus <$> recipients bonus,
      targetEventStream = accountEvents,
      targetProjections = const [accountBalanceProjection]
    }

bonusSelectionContract :: EmptySelectionPolicy -> SelectionFailurePolicy -> Natural -> Either RouterSelectionFailure RouterSelectionContract
bonusSelectionContract empty failure maxRecipients = do
  recipientLimit <- mkRecipientLimit maxRecipients
  selectionVersion <- mkSelectionVersion 1
  pure
    RouterSelectionContract
      { identity = SelectionIdentity "kenshou-bonus-selection",
        version = selectionVersion,
        fingerprint = SelectionFingerprint "kenshou-bonus-selection-v1",
        limit = recipientLimit,
        order = OrderByTargetStream,
        dedupe = DedupeByTargetStream,
        emptyPolicy = empty,
        failurePolicy = failure,
        redeliveryPolicy = StableUnion,
        partialPolicy = RetainSuccesses
      }

declarativeBonusRouterWith :: ValidatedAccountEventStream -> RouterSelectionContract -> (BonusDeclaredData -> Eff es (Either RouterSelectionFailure [PMCommand AccountCommand])) -> DeclarativeBonusRouter es
declarativeBonusRouterWith accountEvents contract selector =
  DeclarativeRouter
    { name = bonusRouterName <> "Declarative",
      key = \bonus -> let BonusId bonusId = bonus.bonusId in bonusId,
      selectionContract = contract,
      select = selector,
      targetEventStream = accountEvents,
      targetProjections = const [accountBalanceProjection]
    }

directoryRecipients :: (Store :> es) => BonusDeclaredData -> Eff es [AccountId]
directoryRecipients bonus = do
  rows <- runTransaction (Tx.statement bonus.segment directoryStatement)
  pure (map AccountId rows)

directoryStatement :: Statement.Statement Text.Text [Text.Text]
directoryStatement =
  Statement.preparable
    "SELECT account_id FROM kenshou_keiro.account_directory WHERE segment = $1 ORDER BY account_id"
    (Encoders.param (Encoders.nonNullable Encoders.text))
    (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.text)))

decodeBonusDeclared :: RecordedEvent -> Maybe (RecordedEvent, BonusDeclaredData)
decodeBonusDeclared recorded =
  case bonusCodec.decode recorded.eventType recorded.payload of
    Right (BonusDeclared bonus) -> Just (recorded, bonus)
    _ -> Nothing
