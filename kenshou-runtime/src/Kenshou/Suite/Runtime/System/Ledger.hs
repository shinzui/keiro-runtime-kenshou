module Kenshou.Suite.Runtime.System.Ledger
  ( AccountId (..),
    AccountCommand (..),
    AccountEvent (..),
    AccountEventStream,
    AccountSnapshotPolicy (..),
    TransferRef (..),
    LedgerAmountError (..),
    accountEventStream,
    accountStream,
    accountCommandStream,
    accountBalanceProjection,
    transferRef,
    openAccount,
    debitTransfer,
    creditTransfer,
  )
where

import Data.Int (Int64)
import Data.Text (Text)
import Kenshou.Suite.Keiro.Fixture.Account (AccountEventStream, AccountSnapshotPolicy (..), accountCommandStream, accountEventStream, accountStream)
import Kenshou.Suite.Keiro.Fixture.Domain (AccountCommand (..), AccountEvent (..), AccountId (..), CreditTransferData (..), DebitTransferData (..), OpenAccountData (..), TransferId (..))
import Kenshou.Suite.Keiro.Fixture.Projection (accountBalanceProjection)
import Kenshou.Suite.Runtime.System.Contracts (OrderId (..))

newtype TransferRef = TransferRef Text
  deriving stock (Eq, Ord, Show)

data LedgerAmountError = NegativeOpeningBalance | NonPositiveTransfer | AmountExceedsFixtureRange
  deriving stock (Eq, Show)

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
