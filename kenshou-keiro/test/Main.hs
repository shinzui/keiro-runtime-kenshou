module Main (main) where

import Data.Proxy (Proxy (..))
import Keiki.Core (RegFile (..), step)
import Keiro.Codec (Codec (..))
import Kenshou.Suite.Keiro.Fixture.Account
import Kenshou.Suite.Keiro.Fixture.Domain
import Kenshou.Suite.Keiro.Fixture.Model qualified as Model
import Kenshou.Suite.Keiro.Fixture.Workload qualified as Workload
import Test.Hspec

main :: IO ()
main = hspec do
  describe "account event stream validation" do
    it "accepts every snapshot policy" do
      let accepted = accountEventStream SnapNever `seq` accountEventStream (SnapEvery 1) `seq` accountEventStream (SnapEvery 10) `seq` accountEventStream SnapOnTerminal `seq` True
      accepted `shouldBe` True
  describe "account codec" do
    it "round trips every event constructor" do
      mapM_ checkCodec events
  describe "reference model" do
    it "agrees with the keiki transducer on a command sequence" do
      compareSteps commands
  describe "workload" do
    it "is deterministic for a seed and worker" do
      take 50 (Workload.workerOps 91 Workload.defaultWorkloadSpec 0 2)
        `shouldBe` take 50 (Workload.workerOps 91 Workload.defaultWorkloadSpec 0 2)
  where
    a = AccountId "a"
    b = AccountId "b"
    t = TransferId "t"
    events =
      [ AccountOpened (AccountOpenedData a 100),
        Deposited (DepositedData a 7 "memo"),
        Withdrawn (WithdrawnData a 2),
        TransferDebited (TransferDebitedData a t b 3 900),
        TransferAnnounced (TransferAnnouncedData a t),
        TransferCredited (TransferCreditedData a t b 3),
        TransferConfirmed (TransferConfirmedData a t),
        BonusCredited (BonusCreditedData a (BonusId "bonus") 1),
        AccountClosed (AccountClosedData a)
      ]
    checkCodec event = accountCodec.decode (accountCodec.eventType event) (accountCodec.encode event) `shouldBe` Right event
    commands =
      [ OpenAccount (OpenAccountData a 100),
        Deposit (DepositData a 7 "memo"),
        Withdraw (WithdrawData a 2),
        DebitTransfer (DebitTransferData a t b 3 900),
        AnnounceTransfer (AnnounceTransferData a t),
        CreditTransfer (CreditTransferData a t b 3),
        ConfirmTransfer (ConfirmTransferData a t),
        CreditBonus (CreditBonusData a (BonusId "bonus") 1)
      ]
    compareSteps = go Model.emptyModel (AcctUnopened, RCons (Proxy @"balance") (0 :: Int) (RCons (Proxy @"entries") (0 :: Int) RNil))
    go _ _ [] = pure ()
    go model state (command : rest) =
      case (Model.decide model command, step accountTransducer state command) of
        (Model.ModelAccepts expected, Just (nextState, nextRegs, [actual])) -> do
          actual `shouldBe` expected
          go (Model.apply actual model) (nextState, nextRegs) rest
        other -> expectationFailure ("model/transducer disagreement: " <> show (fst other))
