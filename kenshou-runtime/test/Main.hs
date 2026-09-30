module Main (main) where

import Kenshou.Suite.Runtime.System.Model
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
