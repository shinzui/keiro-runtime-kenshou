module Kenshou.Suite.Keiro.Fixture.Account where

import Data.Aeson (parseJSON, toJSON)
import Data.Aeson.Types (parseEither)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Proxy (Proxy (..))
import Data.Text qualified as Text
import Keiki.Builder ((=:))
import Keiki.Builder qualified as B
import Keiki.Core (HsPred, RegFile (..), SymTransducer, (.&&), (.+), (.-), (.==), (.>), (.>=))
import Keiki.Core qualified as K
import Keiki.Generics.TH (deriveAggregate)
import Keiro.Codec (Codec (..))
import Keiro.EventStream (EventStream (..), SnapshotPolicy (..), StateCodec)
import Keiro.EventStream.Validate (ValidatedEventStream, mkEventStreamOrThrow)
import Keiro.Snapshot (FoldVersion (..), defaultStateCodecWithFold)
import Keiro.Stream (Stream)
import Keiro.Stream qualified as Stream
import Kenshou.Suite.Keiro.Fixture.Domain
import Kiroku.Store.Types (EventType (..), StreamName)

type AccountPhi = HsPred AccountRegs AccountCommand

type AccountEventStream = EventStream AccountPhi AccountRegs AccountState AccountCommand AccountEvent

type ValidatedAccountEventStream = ValidatedEventStream AccountPhi AccountRegs AccountState AccountCommand AccountEvent

data AccountSnapshotPolicy = SnapNever | SnapEvery !Int | SnapOnTerminal
  deriving stock (Eq, Show)

$(deriveAggregate ''AccountCommand ''AccountRegs ''AccountEvent)

accountTransducer :: SymTransducer AccountPhi AccountRegs AccountState AccountCommand AccountEvent
accountTransducer =
  B.buildTransducer AcctUnopened initialRegs (== AcctClosed) do
    B.from AcctUnopened do
      B.onCmd inCtorOpenAccount $ \d -> B.do
        B.requireGuard (d.openingBalance .>= K.lit (0 :: Int))
        B.slot @"balance" =: d.openingBalance
        B.slot @"entries" =: K.lit (1 :: Int)
        B.emit wireAccountOpened AccountOpenedTermFields {accountId = d.accountId, openingBalance = d.openingBalance}
        B.goto AcctOpen
    B.from AcctOpen do
      B.onCmd inCtorDeposit $ \d -> B.do
        B.requireGuard (d.amount .> K.lit (0 :: Int))
        B.slot @"balance" =: (B.reg @"balance" .+ d.amount)
        B.slot @"entries" =: (B.reg @"entries" .+ K.lit (1 :: Int))
        B.emit wireDeposited DepositedTermFields {accountId = d.accountId, amount = d.amount, memo = d.memo}
        B.goto AcctOpen
      B.onCmd inCtorWithdraw $ \d -> B.do
        B.requireGuard (d.amount .> K.lit (0 :: Int) .&& B.reg @"balance" .>= d.amount)
        B.slot @"balance" =: (B.reg @"balance" .- d.amount)
        B.slot @"entries" =: (B.reg @"entries" .+ K.lit (1 :: Int))
        B.emit wireWithdrawn WithdrawnTermFields {accountId = d.accountId, amount = d.amount}
        B.goto AcctOpen
      B.onCmd inCtorDebitTransfer $ \d -> B.do
        B.requireGuard (d.amount .> K.lit (0 :: Int) .&& B.reg @"balance" .>= d.amount)
        B.slot @"balance" =: (B.reg @"balance" .- d.amount)
        B.slot @"entries" =: (B.reg @"entries" .+ K.lit (1 :: Int))
        B.emit wireTransferDebited TransferDebitedTermFields {accountId = d.accountId, transferId = d.transferId, destination = d.destination, amount = d.amount, deadlineEpochSeconds = d.deadlineEpochSeconds}
        B.goto AcctOpen
      B.onCmd inCtorAnnounceTransfer $ \d -> B.do
        B.slot @"entries" =: (B.reg @"entries" .+ K.lit (1 :: Int))
        B.emit wireTransferAnnounced TransferAnnouncedTermFields {accountId = d.accountId, transferId = d.transferId}
        B.goto AcctOpen
      B.onCmd inCtorCreditTransfer $ \d -> B.do
        B.requireGuard (d.amount .> K.lit (0 :: Int))
        B.slot @"balance" =: (B.reg @"balance" .+ d.amount)
        B.slot @"entries" =: (B.reg @"entries" .+ K.lit (1 :: Int))
        B.emit wireTransferCredited TransferCreditedTermFields {accountId = d.accountId, transferId = d.transferId, source = d.source, amount = d.amount}
        B.goto AcctOpen
      B.onCmd inCtorConfirmTransfer $ \d -> B.do
        B.slot @"entries" =: (B.reg @"entries" .+ K.lit (1 :: Int))
        B.emit wireTransferConfirmed TransferConfirmedTermFields {accountId = d.accountId, transferId = d.transferId}
        B.goto AcctOpen
      B.onCmd inCtorCreditBonus $ \d -> B.do
        B.requireGuard (d.amount .> K.lit (0 :: Int))
        B.slot @"balance" =: (B.reg @"balance" .+ d.amount)
        B.slot @"entries" =: (B.reg @"entries" .+ K.lit (1 :: Int))
        B.emit wireBonusCredited BonusCreditedTermFields {accountId = d.accountId, bonusId = d.bonusId, amount = d.amount}
        B.goto AcctOpen
      B.onCmd inCtorCloseAccount $ \d -> B.do
        B.requireGuard (B.reg @"balance" .== K.lit (0 :: Int))
        B.slot @"entries" =: (B.reg @"entries" .+ K.lit (1 :: Int))
        B.emit wireAccountClosed AccountClosedTermFields {accountId = d.accountId}
        B.goto AcctClosed
    B.from AcctClosed do
      B.onCmd inCtorCloseAccount $ \_ -> B.do
        B.noEmit
        B.goto AcctClosed
  where
    initialRegs = RCons (Proxy @"balance") (0 :: Int) $ RCons (Proxy @"entries") (0 :: Int) RNil

accountStateCodec :: StateCodec (AccountState, RegFile AccountRegs)
accountStateCodec = defaultStateCodecWithFold @AccountRegs @AccountState (FoldVersion "kenshou-account-fold-v1") 1

accountEventStream :: AccountSnapshotPolicy -> ValidatedAccountEventStream
accountEventStream policy = mkEventStreamOrThrow "kenshou-account" def
  where
    def =
      EventStream
        { transducer = accountTransducer,
          initialState = AcctUnopened,
          initialRegisters = RCons (Proxy @"balance") (0 :: Int) $ RCons (Proxy @"entries") (0 :: Int) RNil,
          eventCodec = accountCodec,
          resolveStreamName = Stream.streamName,
          snapshotPolicy = case policy of SnapNever -> Never; SnapEvery n -> Every n; SnapOnTerminal -> OnTerminal,
          stateCodec = case policy of SnapNever -> Nothing; _ -> Just accountStateCodec
        }

accountStream :: AccountId -> Stream AccountEventStream
accountStream (AccountId accountId) = Stream.entityStream (Stream.categoryUnsafe "account") accountId

accountCommandStream :: AccountId -> Stream AccountCommand
accountCommandStream (AccountId accountId) = Stream.entityStream (Stream.categoryUnsafe "account") accountId

accountStreamName :: AccountId -> StreamName
accountStreamName = Stream.streamName . accountStream

accountCodec :: Codec AccountEvent
accountCodec =
  Codec
    { eventTypes = EventType "AccountOpened" :| [EventType "Deposited", EventType "Withdrawn", EventType "TransferDebited", EventType "TransferAnnounced", EventType "TransferCredited", EventType "TransferConfirmed", EventType "BonusCredited", EventType "AccountClosed"],
      eventType = \case
        AccountOpened {} -> EventType "AccountOpened"
        Deposited {} -> EventType "Deposited"
        Withdrawn {} -> EventType "Withdrawn"
        TransferDebited {} -> EventType "TransferDebited"
        TransferAnnounced {} -> EventType "TransferAnnounced"
        TransferCredited {} -> EventType "TransferCredited"
        TransferConfirmed {} -> EventType "TransferConfirmed"
        BonusCredited {} -> EventType "BonusCredited"
        AccountClosed {} -> EventType "AccountClosed",
      schemaVersion = 1,
      encode = \case
        AccountOpened d -> toJSON d
        Deposited d -> toJSON d
        Withdrawn d -> toJSON d
        TransferDebited d -> toJSON d
        TransferAnnounced d -> toJSON d
        TransferCredited d -> toJSON d
        TransferConfirmed d -> toJSON d
        BonusCredited d -> toJSON d
        AccountClosed d -> toJSON d,
      decode = \(EventType tag) value ->
        let parseRecord v = either (Left . Text.pack) Right (parseEither parseJSON v)
         in case tag of
              "AccountOpened" -> AccountOpened <$> parseRecord value
              "Deposited" -> Deposited <$> parseRecord value
              "Withdrawn" -> Withdrawn <$> parseRecord value
              "TransferDebited" -> TransferDebited <$> parseRecord value
              "TransferAnnounced" -> TransferAnnounced <$> parseRecord value
              "TransferCredited" -> TransferCredited <$> parseRecord value
              "TransferConfirmed" -> TransferConfirmed <$> parseRecord value
              "BonusCredited" -> BonusCredited <$> parseRecord value
              "AccountClosed" -> AccountClosed <$> parseRecord value
              _ -> Left ("unknown account event type: " <> tag),
      upcasters = []
    }
