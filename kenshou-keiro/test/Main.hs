module Main (main) where

import Data.Aeson (object)
import Data.IORef (newIORef, readIORef)
import Data.Proxy (Proxy (..))
import Data.Time (getCurrentTime)
import Data.UUID qualified as UUID
import Effectful (runEff)
import Keiki.Core (RegFile (..), step)
import Keiro.Codec (Codec (..))
import Keiro.ProcessManager (ProcessManager (..))
import Kenshou.Suite.Keiro.Fixture.Account
import Kenshou.Suite.Keiro.Fixture.Bonus
import Kenshou.Suite.Keiro.Fixture.Bridge
import Kenshou.Suite.Keiro.Fixture.Domain
import Kenshou.Suite.Keiro.Fixture.Model qualified as Model
import Kenshou.Suite.Keiro.Fixture.Transfer
import Kenshou.Suite.Keiro.Fixture.Workload qualified as Workload
import Kiroku.Store.Types (EventId (..), EventType (..), GlobalPosition (..), RecordedEvent (..), StreamId (..), StreamVersion (..))
import Shibuya.Adapter (Adapter (..))
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import Test.Hspec

main :: IO ()
main = hspec do
  describe "account event stream validation" do
    it "accepts every snapshot policy" do
      let accepted = accountEventStream SnapNever `seq` accountEventStream (SnapEvery 1) `seq` accountEventStream (SnapEvery 10) `seq` accountEventStream SnapOnTerminal `seq` True
      accepted `shouldBe` True
    it "accepts the bonus and transfer transducers" do
      let manager = transferManager (accountEventStream SnapNever) (const [])
          strict = strictTransferManager (accountEventStream SnapNever)
          accepted = bonusEventStream `seq` manager.eventStream `seq` strict.eventStream `seq` True
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
    it "gives setup and generated operations different event identifiers" do
      let setup = Workload.Op (-1) 0 (Workload.ActOpen (AccountId "0") 100)
          generated = Workload.Op 0 0 (Workload.ActDeposit (AccountId "0") 1)
      Workload.opEventId 91 setup 0 `shouldNotBe` Workload.opEventId 91 generated 0
  describe "list adapter" do
    it "records one acknowledgement for every delivery" do
      now <- getCurrentTime
      acknowledgements <- newIORef []
      let recorded =
            RecordedEvent
              { eventId = EventId UUID.nil,
                eventType = EventType "TransferDebited",
                streamVersion = StreamVersion 1,
                globalPosition = GlobalPosition 1,
                originalStreamId = StreamId 1,
                originalVersion = StreamVersion 1,
                payload = object [],
                metadata = Nothing,
                causationId = Nothing,
                correlationId = Nothing,
                createdAt = now
              }
          adapter = listAdapter "test" acknowledgements [(recorded, Just 0), (recorded, Just 1)]
      runEff do
        ingested <- Stream.fold Fold.toList adapter.source
        mapM_ (\item -> let AckHandle finalize = item.ack in finalize AckOk) ingested
      records <- readIORef acknowledgements
      map (.decision) records `shouldBe` [AckOk, AckOk]
      length records `shouldBe` 2
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
