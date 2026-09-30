module Main (main) where

import Control.Exception (evaluate)
import Keiro.Codec (Codec (..))
import Kenshou.Suite.Runtime.System.Contracts (CustomerId (..), OrderId (..), Sku (..))
import Kenshou.Suite.Runtime.System.Fulfilment qualified as Fulfilment
import Kenshou.Suite.Runtime.System.Ledger qualified as Ledger
import Kenshou.Suite.Runtime.System.Model
import Kenshou.Suite.Runtime.System.Order qualified as Order
import Kenshou.Suite.Runtime.System.SagaLog qualified as SagaLog
import Test.Hspec

main :: IO ()
main = hspec do
  describe "assembled-runtime terminal contract" do
    it "accepts one matching order and fulfilment completion" do
      advanceOrder OrderNotPlaced PlaceOrder `shouldBe` Right OrderPlaced
      advanceOrder OrderPlaced CompleteOrder `shouldBe` Right OrderCompleted
      advanceFulfilment FulfilmentNotRequested RequestFulfilment `shouldBe` Right FulfilmentRequested
      advanceFulfilment FulfilmentRequested ShipFulfilment `shouldBe` Right FulfilmentShipped
      matchingTerminal OrderCompleted FulfilmentShipped `shouldBe` True

    it "allows either shipping or expiry to win, then rejects the rival" do
      advanceFulfilment FulfilmentRequested ShipFulfilment `shouldBe` Right FulfilmentShipped
      advanceFulfilment FulfilmentShipped ExpireFulfilment `shouldBe` Left (InvalidFulfilmentTransition FulfilmentShipped ExpireFulfilment)
      advanceFulfilment FulfilmentRequested ExpireFulfilment `shouldBe` Right FulfilmentExpired
      advanceFulfilment FulfilmentExpired ShipFulfilment `shouldBe` Left (InvalidFulfilmentTransition FulfilmentExpired ShipFulfilment)
      matchingTerminal OrderCompleted FulfilmentExpired `shouldBe` False

    it "rejects every terminal command after an order outcome" do
      let terminal = [OrderCompleted, OrderRejected, OrderExpired]
          commands = [CompleteOrder, RejectOrder, ExpireOrder]
      and [either (const True) (const False) (advanceOrder phase action) | phase <- terminal, action <- commands] `shouldBe` True

    it "accepts direct refusal only before fulfilment is requested" do
      advanceFulfilment FulfilmentNotRequested RefuseFulfilment `shouldBe` Right FulfilmentRefused
      advanceFulfilment FulfilmentRequested RefuseFulfilment `shouldBe` Left (InvalidFulfilmentTransition FulfilmentRequested RefuseFulfilment)
      matchingTerminal OrderRejected FulfilmentRefused `shouldBe` True

  describe "order event stream" do
    it "validates the Keiki transition graph" do
      _ <- evaluate Order.orderEventStream
      pure ()

    it "round-trips every event through its versioned codec" do
      let identifier = OrderId "order-1"
          events =
            [ Order.OrderPlaced (Order.OrderPlacedData identifier (CustomerId "customer-1") (Sku "sku-1") 2 900 False),
              Order.OrderCompleted (Order.OrderCompletedData identifier),
              Order.OrderRejected (Order.OrderRejectedData identifier "discontinued"),
              Order.OrderExpired (Order.OrderExpiredData identifier)
            ]
          codec = Order.orderCodec
      map (\event -> codec.decode (codec.eventType event) (codec.encode event)) events `shouldBe` map Right events

  describe "fulfilment event stream" do
    it "validates the Keiki transition graph" do
      _ <- evaluate Fulfilment.fulfilmentEventStream
      pure ()

    it "round-trips every event through its versioned codec" do
      let identifier = OrderId "order-1"
          events =
            [ Fulfilment.FulfilmentRequested (Fulfilment.FulfilmentRequestedData identifier (Sku "sku-1") 2),
              Fulfilment.FulfilmentRefused (Fulfilment.FulfilmentRefusedData identifier "discontinued"),
              Fulfilment.FulfilmentShipped (Fulfilment.FulfilmentShippedData identifier),
              Fulfilment.FulfilmentExpired (Fulfilment.FulfilmentExpiredData identifier)
            ]
          codec = Fulfilment.fulfilmentCodec
      map (\event -> codec.decode (codec.eventType event) (codec.encode event)) events `shouldBe` map Right events

  describe "saga observation stream" do
    it "validates its repeatable one-state graph" do
      _ <- evaluate SagaLog.sagaEventStream
      pure ()

    it "round-trips its versioned observation event" do
      let event = SagaLog.SagaObserved (SagaLog.SagaObservedData (OrderId "order-1") "reserved" "source-1")
          codec = SagaLog.sagaCodec
      codec.decode (codec.eventType event) (codec.encode event) `shouldBe` Right event

  describe "fixture ledger seam" do
    it "assigns one stable transfer reference per order purpose" do
      Ledger.transferRef (OrderId "order-1") "hold" `shouldBe` Ledger.TransferRef "order-1:hold"

    it "rejects invalid amounts before building fixture commands" do
      Ledger.openAccount (Ledger.AccountId "customer") (-1) `shouldBe` Left Ledger.NegativeOpeningBalance
      Ledger.debitTransfer (Ledger.AccountId "customer") (Ledger.TransferRef "order-1:hold") (Ledger.AccountId "escrow") 0 10 `shouldBe` Left Ledger.NonPositiveTransfer
