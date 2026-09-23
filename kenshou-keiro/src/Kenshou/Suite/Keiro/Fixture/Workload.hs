module Kenshou.Suite.Keiro.Fixture.Workload
  ( WorkloadSpec (..),
    OpMix (..),
    OpAction (..),
    Op (..),
    defaultWorkloadSpec,
    setupOps,
    workerOps,
    opCommands,
    opEventId,
  )
where

import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.UUID.V5 qualified as UUID.V5
import Data.Word (Word64)
import Keiro.Stream (Stream)
import Kenshou.Suite.Keiro.Fixture.Account
import Kenshou.Suite.Keiro.Fixture.Bonus
import Kenshou.Suite.Keiro.Fixture.Domain
import Kiroku.Store.Types (EventId (..))
import System.Random (mkStdGen, randomR, split)

data WorkloadSpec = WorkloadSpec
  { accounts :: !Int,
    openingBalance :: !Int,
    maxAmount :: !Int,
    hotAccountShare :: !Double,
    mix :: !OpMix,
    memoBytes :: !Int,
    transferDeadlineSeconds :: !Int
  }
  deriving stock (Eq, Show)

data OpMix = OpMix
  { deposits :: !Int,
    withdrawals :: !Int,
    transfers :: !Int,
    bonuses :: !Int
  }
  deriving stock (Eq, Show)

data OpAction
  = ActOpen !AccountId !Int
  | ActDeposit !AccountId !Int
  | ActWithdraw !AccountId !Int
  | ActTransfer !TransferId !AccountId !AccountId !Int
  | ActBonus !BonusId !Text !Int
  | ActClose !AccountId
  deriving stock (Eq, Show)

data Op = Op
  { worker :: !Int,
    index :: !Word64,
    action :: !OpAction
  }
  deriving stock (Eq, Show)

defaultWorkloadSpec :: WorkloadSpec
defaultWorkloadSpec =
  WorkloadSpec
    { accounts = 100,
      openingBalance = 10000,
      maxAmount = 100,
      hotAccountShare = 0.1,
      mix = OpMix 5 3 1 1,
      memoBytes = 64,
      transferDeadlineSeconds = 3600
    }

accountAt :: Int -> AccountId
accountAt n = AccountId (Text.pack (show n))

setupOps :: WorkloadSpec -> [Op]
setupOps spec = [Op (-1) (fromIntegral n) (ActOpen (accountAt n) spec.openingBalance) | n <- [0 .. spec.accounts - 1]]

workerOps :: Word64 -> WorkloadSpec -> Int -> Int -> [Op]
workerOps seed spec workerCount workers = go 0 (fst (split (mkStdGen (fromIntegral seed + workerCount))))
  where
    owned = [i | i <- [0 .. max 0 (spec.accounts - 1)], i `mod` max 1 workers == workerCount]
    accountIds = if null owned then [0] else owned
    pickAccount n = accountAt (accountIds !! (n `mod` length accountIds))
    totalWeight = max 1 (spec.mix.deposits + spec.mix.withdrawals + spec.mix.transfers + spec.mix.bonuses)
    go idx gen =
      let (choice, gen1) = randomR (1, totalWeight) gen
          (which, gen2) = randomR (0, length accountIds - 1) gen1
          (rawAmount, gen3) = randomR (1, max 1 spec.maxAmount) gen2
          source = pickAccount which
          destination = pickAccount (which + 1)
          opAction
            | choice <= spec.mix.deposits = ActDeposit source rawAmount
            | choice <= spec.mix.deposits + spec.mix.withdrawals = ActWithdraw source rawAmount
            | choice <= spec.mix.deposits + spec.mix.withdrawals + spec.mix.transfers =
                ActTransfer (TransferId (Text.pack (show workerCount <> "-" <> show idx))) source destination rawAmount
            | otherwise = ActBonus (BonusId (Text.pack (show workerCount <> "-" <> show idx))) "all" rawAmount
       in Op workerCount idx opAction : go (idx + 1) gen3

opEventId :: Word64 -> Op -> Int -> EventId
opEventId seed op leg =
  EventId
    ( UUID.V5.generateNamed UUID.V5.namespaceURL $
        ByteString.unpack $
          Text.encodeUtf8 $
            Text.intercalate ":" ["kenshou", "op", showText seed, showText op.worker, showText op.index, showText leg]
    )
  where
    showText :: (Show a) => a -> Text
    showText = Text.pack . show

opCommands :: Word64 -> Op -> [(Either (Stream BonusEventStream, BonusCommand) (Stream AccountEventStream, AccountCommand), EventId)]
opCommands seed op = case op.action of
  ActOpen account amount -> [accountLeg 0 account (OpenAccount (OpenAccountData account amount))]
  ActDeposit account amount -> [accountLeg 0 account (Deposit (DepositData account amount "workload"))]
  ActWithdraw account amount -> [accountLeg 0 account (Withdraw (WithdrawData account amount))]
  ActTransfer transfer source destination amount ->
    let debit = accountLeg 0 source (DebitTransfer (DebitTransferData source transfer destination amount 4102444800))
        announce = accountLeg 1 destination (AnnounceTransfer (AnnounceTransferData destination transfer))
     in if even (seed + op.index) then [debit, announce] else [announce, debit]
  ActBonus bonus segment amount ->
    [(Left (bonusStream bonus, DeclareBonus (DeclareBonusData bonus segment amount)), opEventId seed op 0)]
  ActClose account -> [accountLeg 0 account (CloseAccount (CloseAccountData account))]
  where
    accountLeg leg account command = (Right (accountStream account, command), opEventId seed op leg)
