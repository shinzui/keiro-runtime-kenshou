module Kenshou.Suite.Runtime.System.Ledger
  ( AccountId (..),
    AccountCommand (..),
    AccountEvent (..),
    AccountEventStream,
    ValidatedLedgerStream,
    LedgerPhi,
    LedgerRegs,
    LedgerState,
    AccountSnapshotPolicy (..),
    TransferRef (..),
    LedgerAmountError (..),
    accountEventStream,
    accountStream,
    accountCommandStream,
    accountBalanceProjection,
    ledgerEventStream,
    ledgerProjections,
    ensureLedgerReadModels,
    commandAccount,
    transferRef,
    openAccount,
    debitTransfer,
    creditTransfer,
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Int (Int64)
import Data.Text (Text)
import Data.UUID qualified as UUID
import Effectful (Eff, (:>))
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx
import Keiki.Core (HsPred)
import Keiro.Projection (InlineProjection (..))
import Keiro.Stream (Stream)
import Kenshou.Suite.Keiro.Fixture.Account (AccountEventStream, AccountSnapshotPolicy (..), ValidatedAccountEventStream, accountCommandStream, accountEventStream, accountStream)
import Kenshou.Suite.Keiro.Fixture.Domain (AccountCommand (..), AccountEvent (..), AccountId (..), AccountRegs, AccountState, CreditTransferData (..), DebitTransferData (..), OpenAccountData (..), TransferCreditedData (..), TransferDebitedData (..), TransferId (..), commandAccountId)
import Kenshou.Suite.Keiro.Fixture.Projection (accountBalanceProjection, ensureFixtureReadModels)
import Kenshou.Suite.Runtime.System.Contracts (OrderId (..))
import Kiroku.Store (Store, runTransaction)
import Kiroku.Store.Types (EventId (..), GlobalPosition (..), RecordedEvent (..))

-- This module is the only import seam for the Keiro account fixture. A
-- fixture rename is therefore a one-file change for the assembled runtime.

type ValidatedLedgerStream = ValidatedAccountEventStream

type LedgerRegs = AccountRegs

type LedgerState = AccountState

type LedgerPhi = HsPred AccountRegs AccountCommand

newtype TransferRef = TransferRef Text
  deriving stock (Eq, Ord, Show)

data LedgerAmountError = NegativeOpeningBalance | NonPositiveTransfer | AmountExceedsFixtureRange
  deriving stock (Eq, Show)

ledgerEventStream :: ValidatedLedgerStream
ledgerEventStream = accountEventStream SnapNever

-- | Balances come from the fixture's own projection; the entries table keeps
-- the transfer reference of every movement so later oracles can count
-- effects per order without reading every stream.
ledgerProjections :: Stream AccountCommand -> [InlineProjection AccountEvent]
ledgerProjections _ = [accountBalanceProjection, entriesProjection]

ensureLedgerReadModels :: (Store :> es) => Eff es ()
ensureLedgerReadModels = do
  ensureFixtureReadModels
  runTransaction do
    Tx.sql "CREATE SCHEMA IF NOT EXISTS ledger"
    Tx.sql "CREATE TABLE IF NOT EXISTS ledger.entries (event_id uuid PRIMARY KEY, account_id text NOT NULL, transfer_ref text NOT NULL, direction text NOT NULL, counterparty text NOT NULL, amount bigint NOT NULL, global_position bigint NOT NULL)"
    Tx.sql "CREATE INDEX IF NOT EXISTS entries_transfer_ref ON ledger.entries (transfer_ref)"

entriesProjection :: InlineProjection AccountEvent
entriesProjection =
  InlineProjection
    { name = "kenshou-runtime-ledger-entries",
      apply = \event recorded -> case event of
        TransferDebited d -> insert recorded d.accountId d.transferId "debit" d.destination d.amount
        TransferCredited d -> insert recorded d.accountId d.transferId "credit" d.source d.amount
        _ -> pure ()
    }
  where
    insert recorded (AccountId account) (TransferId reference) direction (AccountId counterparty) amount =
      Tx.statement
        ( object
            [ "eventId" .= (let EventId value = recorded.eventId in UUID.toText value),
              "account" .= account,
              "reference" .= reference,
              "direction" .= (direction :: Text),
              "counterparty" .= counterparty,
              "amount" .= amount,
              "position" .= (let GlobalPosition value = recorded.globalPosition in value)
            ]
        )
        entryStatement

entryStatement :: Statement.Statement Value ()
entryStatement =
  Statement.preparable
    "INSERT INTO ledger.entries (event_id, account_id, transfer_ref, direction, counterparty, amount, global_position) SELECT (x->>'eventId')::uuid, x->>'account', x->>'reference', x->>'direction', x->>'counterparty', (x->>'amount')::bigint, (x->>'position')::bigint FROM (SELECT $1::jsonb AS x) input ON CONFLICT (event_id) DO NOTHING"
    (Encoders.param (Encoders.nonNullable Encoders.jsonb))
    Decoders.noResult

commandAccount :: AccountCommand -> AccountId
commandAccount = commandAccountId

transferRef :: OrderId -> Text -> TransferRef
transferRef (OrderId identifier) purpose = TransferRef (identifier <> ":" <> purpose)

openAccount :: AccountId -> Int64 -> Either LedgerAmountError AccountCommand
openAccount account amount
  | amount < 0 = Left NegativeOpeningBalance
  | otherwise = OpenAccount . OpenAccountData account <$> asFixtureInt amount

debitTransfer :: AccountId -> TransferRef -> AccountId -> Int64 -> Int -> Either LedgerAmountError AccountCommand
debitTransfer source reference destination amount deadline
  | amount <= 0 = Left NonPositiveTransfer
  | otherwise =
      DebitTransfer . (\units -> DebitTransferData source (transferId reference) destination units deadline)
        <$> asFixtureInt amount

creditTransfer :: AccountId -> TransferRef -> AccountId -> Int64 -> Either LedgerAmountError AccountCommand
creditTransfer destination reference source amount
  | amount <= 0 = Left NonPositiveTransfer
  | otherwise =
      CreditTransfer . (\units -> CreditTransferData destination (transferId reference) source units)
        <$> asFixtureInt amount

transferId :: TransferRef -> TransferId
transferId (TransferRef identifier) = TransferId identifier

asFixtureInt :: Int64 -> Either LedgerAmountError Int
asFixtureInt amount
  | toInteger amount > toInteger (maxBound :: Int) = Left AmountExceedsFixtureRange
  | toInteger amount < toInteger (minBound :: Int) = Left AmountExceedsFixtureRange
  | otherwise = Right (fromIntegral amount)
