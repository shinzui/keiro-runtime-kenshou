module Main (main) where

import Data.List (nub)
import Kenshou.Core.Bundle (LayerBundle (..), mkRegistry)
import Kenshou.Core.Dimension (MetricsArm (..), TracingArm (..))
import Kenshou.Core.Id (Kind (..), Layer (..), ScenarioId (..), renderScenarioId)
import Kenshou.Core.Scenario (Scenario (..))
import Kenshou.Suite.Kiroku (bundle)
import Kenshou.Suite.Kiroku.Fixture.Telemetry (HandlerArm (..), handlerArm)
import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Test.Hspec

main :: IO ()
main = hspec do
  describe "kiroku knobs" do
    it "declares the four store knobs" do
      length storeKnobs `shouldBe` 4
  describe "event handler composition" do
    it "selects the four metric and tracing arms" do
      handlerArm TracingOff MetricsOff `shouldBe` HandlerNone
      handlerArm TracingOff MetricsCollect `shouldBe` HandlerMetrics
      handlerArm TracingSdkInMemory MetricsOff `shouldBe` HandlerTrace
      handlerArm TracingSdkInMemory MetricsCollect `shouldBe` HandlerMetricsAndTrace
  describe "kiroku bundle" do
    it "registers unique kiroku scenarios" do
      let scenarios = bundle.scenarios
          names = fmap (renderScenarioId . (.id)) scenarios
      length scenarios `shouldBe` 21
      length (nub names) `shouldBe` length names
      mapM_ (\scenario -> scenario.id.layer `shouldBe` Kiroku) scenarios
      length [scenario | scenario <- scenarios, scenario.id.kind == Correctness] `shouldBe` 19
      length [scenario | scenario <- scenarios, scenario.id.kind == Concurrency] `shouldBe` 2
    it "passes the registry's structural validation" do
      case mkRegistry [bundle] of
        Right _ -> pure ()
        Left errors -> expectationFailure (show errors)
