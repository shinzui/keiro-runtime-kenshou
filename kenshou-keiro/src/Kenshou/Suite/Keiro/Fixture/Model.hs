module Kenshou.Suite.Keiro.Fixture.Model
  ( ModelAccount (..),
    Model (..),
    ModelVerdict (..),
    emptyModel,
    decide,
    apply,
    totalMoney,
    lookupAccount,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Kenshou.Suite.Keiro.Fixture.Domain

data ModelAccount = ModelAccount
  { state :: !AccountState,
    balance :: !Int,
    entries :: !Int
  }
  deriving stock (Eq, Ord, Show)

newtype Model = Model (Map AccountId ModelAccount)
  deriving stock (Eq, Ord, Show)

data ModelVerdict = ModelAccepts !AccountEvent | ModelNoOp | ModelRejects
  deriving stock (Eq, Show)

emptyModel :: Model
emptyModel = Model Map.empty

lookupAccount :: AccountId -> Model -> ModelAccount
lookupAccount accountId (Model accounts) =
  Map.findWithDefault (ModelAccount AcctUnopened 0 0) accountId accounts

decide :: Model -> AccountCommand -> ModelVerdict
decide model command =
  let account = lookupAccount (commandAccountId command) model
   in case (account.state, command) of
        (AcctUnopened, OpenAccount d)
          | d.openingBalance >= 0 -> ModelAccepts (AccountOpened (AccountOpenedData d.accountId d.openingBalance))
        (AcctOpen, Deposit d)
          | d.amount > 0 -> ModelAccepts (Deposited (DepositedData d.accountId d.amount d.memo))
        (AcctOpen, Withdraw d)
          | d.amount > 0 && account.balance >= d.amount -> ModelAccepts (Withdrawn (WithdrawnData d.accountId d.amount))
        (AcctOpen, DebitTransfer d)
          | d.amount > 0 && account.balance >= d.amount -> ModelAccepts (TransferDebited (TransferDebitedData d.accountId d.transferId d.destination d.amount d.deadlineEpochSeconds))
        (AcctOpen, AnnounceTransfer d) -> ModelAccepts (TransferAnnounced (TransferAnnouncedData d.accountId d.transferId))
        (AcctOpen, CreditTransfer d)
          | d.amount > 0 -> ModelAccepts (TransferCredited (TransferCreditedData d.accountId d.transferId d.source d.amount))
        (AcctOpen, ConfirmTransfer d) -> ModelAccepts (TransferConfirmed (TransferConfirmedData d.accountId d.transferId))
        (AcctOpen, CreditBonus d)
          | d.amount > 0 -> ModelAccepts (BonusCredited (BonusCreditedData d.accountId d.bonusId d.amount))
        (AcctOpen, CloseAccount d)
          | account.balance == 0 -> ModelAccepts (AccountClosed (AccountClosedData d.accountId))
        (AcctClosed, CloseAccount {}) -> ModelNoOp
        _ -> ModelRejects

apply :: AccountEvent -> Model -> Model
apply event (Model accounts) = Model (Map.alter update accountId accounts)
  where
    accountId = eventAccountId event
    current = Map.findWithDefault (ModelAccount AcctUnopened 0 0) accountId accounts
    update _ = Just case event of
      AccountOpened d -> ModelAccount AcctOpen d.openingBalance 1
      Deposited d -> advance d.amount
      Withdrawn d -> advance (-d.amount)
      TransferDebited d -> advance (-d.amount)
      TransferAnnounced {} -> advance 0
      TransferCredited d -> advance d.amount
      TransferConfirmed {} -> advance 0
      BonusCredited d -> advance d.amount
      AccountClosed {} -> ModelAccount AcctClosed current.balance (current.entries + 1)
    advance delta = ModelAccount current.state (current.balance + delta) (current.entries + 1)

totalMoney :: Model -> Int
totalMoney (Model accounts) = sum (map (.balance) (Map.elems accounts))
