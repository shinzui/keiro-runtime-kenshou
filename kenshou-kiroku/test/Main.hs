module Main (main) where

import Data.List (nub)
import Kenshou.Core.Bundle (LayerBundle (..), mkRegistry)
import Kenshou.Core.Id (Kind (..), Layer (..), ScenarioId (..), renderScenarioId)
import Kenshou.Core.Scenario (Scenario (..))
import Kenshou.Suite.Kiroku (bundle)
import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Test.Hspec

main :: IO ()
main = hspec do
  describe "kiroku knobs" do
    it "declares the four store knobs" do
      length storeKnobs `shouldBe` 4
  describe "kiroku bundle" do
    it "registers unique kiroku correctness scenarios" do
      let scenarios = bundle.scenarios
          names = fmap (renderScenarioId . (.id)) scenarios
      length scenarios `shouldBe` 18
      length (nub names) `shouldBe` length names
      mapM_ (\scenario -> scenario.id.layer `shouldBe` Kiroku) scenarios
      mapM_ (\scenario -> scenario.id.kind `shouldBe` Correctness) scenarios
    it "passes the registry's structural validation" do
      case mkRegistry [bundle] of
        Right _ -> pure ()
        Left errors -> expectationFailure (show errors)
