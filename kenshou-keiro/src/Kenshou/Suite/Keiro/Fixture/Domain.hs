module Kenshou.Suite.Keiro.Fixture.Domain where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)
import Keiki.Shape (CanonicalStateShape)

newtype AccountId = AccountId Text
  deriving stock (Generic, Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON)

newtype TransferId = TransferId Text
  deriving stock (Generic, Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON)

newtype BonusId = BonusId Text
  deriving stock (Generic, Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON)

data AccountState = AcctUnopened | AcctOpen | AcctClosed
  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)
  deriving anyclass (FromJSON, ToJSON)

instance CanonicalStateShape AccountState

data TransferSagaState = SagaIdle | SagaDebitSeen | SagaAnnounceSeen | SagaJoined
  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)
  deriving anyclass (FromJSON, ToJSON)

instance CanonicalStateShape TransferSagaState

data BonusState = BonusUndeclared | BonusDeclaredState
  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)
  deriving anyclass (FromJSON, ToJSON)

instance CanonicalStateShape BonusState

type AccountRegs = '[ '("balance", Int), '("entries", Int)]

type TransferSagaRegs = '[]

type BonusRegs = '[]

data AccountCommand
  = OpenAccount !OpenAccountData
  | Deposit !DepositData
  | Withdraw !WithdrawData
  | DebitTransfer !DebitTransferData
  | AnnounceTransfer !AnnounceTransferData
  | CreditTransfer !CreditTransferData
  | ConfirmTransfer !ConfirmTransferData
  | CreditBonus !CreditBonusData
  | CloseAccount !CloseAccountData
  deriving stock (Generic, Eq, Show)

data AccountEvent
  = AccountOpened !AccountOpenedData
  | Deposited !DepositedData
  | Withdrawn !WithdrawnData
  | TransferDebited !TransferDebitedData
  | TransferAnnounced !TransferAnnouncedData
  | TransferCredited !TransferCreditedData
  | TransferConfirmed !TransferConfirmedData
  | BonusCredited !BonusCreditedData
  | AccountClosed !AccountClosedData
  deriving stock (Generic, Eq, Show)

data TransferSagaCommand
  = ObserveDebit !ObserveDebitData
  | ObserveAnnounce !ObserveAnnounceData
  deriving stock (Generic, Eq, Show)

data TransferSagaEvent
  = DebitObserved !DebitObservedData
  | AnnounceObserved !AnnounceObservedData
  deriving stock (Generic, Eq, Show)

data BonusCommand
  = DeclareBonus !DeclareBonusData
  deriving stock (Generic, Eq, Show)

data BonusEvent
  = BonusDeclared !BonusDeclaredData
  deriving stock (Generic, Eq, Show)

data OpenAccountData = OpenAccountData
  { accountId :: !AccountId,
    openingBalance :: !Int
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data AccountOpenedData = AccountOpenedData
  { accountId :: !AccountId,
    openingBalance :: !Int
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data DepositData = DepositData
  { accountId :: !AccountId,
    amount :: !Int,
    memo :: !Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data DepositedData = DepositedData
  { accountId :: !AccountId,
    amount :: !Int,
    memo :: !Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data WithdrawData = WithdrawData
  { accountId :: !AccountId,
    amount :: !Int
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data WithdrawnData = WithdrawnData
  { accountId :: !AccountId,
    amount :: !Int
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data DebitTransferData = DebitTransferData
  { accountId :: !AccountId,
    transferId :: !TransferId,
    destination :: !AccountId,
    amount :: !Int,
    deadlineEpochSeconds :: !Int
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data TransferDebitedData = TransferDebitedData
  { accountId :: !AccountId,
    transferId :: !TransferId,
    destination :: !AccountId,
    amount :: !Int,
    deadlineEpochSeconds :: !Int
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data AnnounceTransferData = AnnounceTransferData
  { accountId :: !AccountId,
    transferId :: !TransferId
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data TransferAnnouncedData = TransferAnnouncedData
  { accountId :: !AccountId,
    transferId :: !TransferId
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data CreditTransferData = CreditTransferData
  { accountId :: !AccountId,
    transferId :: !TransferId,
    source :: !AccountId,
    amount :: !Int
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data TransferCreditedData = TransferCreditedData
  { accountId :: !AccountId,
    transferId :: !TransferId,
    source :: !AccountId,
    amount :: !Int
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data ConfirmTransferData = ConfirmTransferData
  { accountId :: !AccountId,
    transferId :: !TransferId
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data TransferConfirmedData = TransferConfirmedData
  { accountId :: !AccountId,
    transferId :: !TransferId
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data CreditBonusData = CreditBonusData
  { accountId :: !AccountId,
    bonusId :: !BonusId,
    amount :: !Int
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data BonusCreditedData = BonusCreditedData
  { accountId :: !AccountId,
    bonusId :: !BonusId,
    amount :: !Int
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data CloseAccountData = CloseAccountData
  { accountId :: !AccountId
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data AccountClosedData = AccountClosedData
  { accountId :: !AccountId
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data ObserveDebitData = ObserveDebitData
  { transferId :: !TransferId,
    accountId :: !AccountId,
    destination :: !AccountId,
    amount :: !Int,
    deadlineEpochSeconds :: !Int
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data DebitObservedData = DebitObservedData
  { transferId :: !TransferId,
    accountId :: !AccountId,
    destination :: !AccountId,
    amount :: !Int,
    deadlineEpochSeconds :: !Int
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data ObserveAnnounceData = ObserveAnnounceData
  { transferId :: !TransferId,
    accountId :: !AccountId
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data AnnounceObservedData = AnnounceObservedData
  { transferId :: !TransferId,
    accountId :: !AccountId
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data DeclareBonusData = DeclareBonusData
  { bonusId :: !BonusId,
    segment :: !Text,
    amount :: !Int
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data BonusDeclaredData = BonusDeclaredData
  { bonusId :: !BonusId,
    segment :: !Text,
    amount :: !Int
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

commandAccountId :: AccountCommand -> AccountId
commandAccountId = \case
  OpenAccount d -> d.accountId
  Deposit d -> d.accountId
  Withdraw d -> d.accountId
  DebitTransfer d -> d.accountId
  AnnounceTransfer d -> d.accountId
  CreditTransfer d -> d.accountId
  ConfirmTransfer d -> d.accountId
  CreditBonus d -> d.accountId
  CloseAccount d -> d.accountId

eventAccountId :: AccountEvent -> AccountId
eventAccountId = \case
  AccountOpened d -> d.accountId
  Deposited d -> d.accountId
  Withdrawn d -> d.accountId
  TransferDebited d -> d.accountId
  TransferAnnounced d -> d.accountId
  TransferCredited d -> d.accountId
  TransferConfirmed d -> d.accountId
  BonusCredited d -> d.accountId
  AccountClosed d -> d.accountId
