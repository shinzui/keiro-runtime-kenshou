module Main (main) where

import Data.Aeson (decode, encode)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (nub)
import Kenshou.Core.Bundle (LayerBundle (..), mkRegistry)
import Kenshou.Core.Dimension (MetricsArm (..), TracingArm (..))
import Kenshou.Core.Id (Kind (..), Layer (..), ScenarioId (..), mkSeed, renderScenarioId)
import Kenshou.Core.Scenario (Scenario (..))
import Kenshou.Suite.Kiroku (bundle)
import Kenshou.Suite.Kiroku.Fixture.Facts (CheckpointSample (..), Delivered (..), KirokuFact (..), Produced (..))
import Kenshou.Suite.Kiroku.Fixture.Telemetry (HandlerArm (..), handlerArm)
import Kenshou.Suite.Kiroku.Fixture.Workload (IdPolicy (..), RunTag (..), eventIdFor, mkEvents, payloadOf, streamNameFor)
import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Kiroku.Store (EventData (..), EventId (..))
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
  describe "deterministic workload" do
    it "regenerates identifiers and exact-size varied payloads" do
      let seed = either (error . show) id (mkSeed 42)
          payload = payloadOf seed 3 10 256
      payload `shouldBe` payloadOf seed 3 10 256
      payload `shouldNotBe` payloadOf seed 3 11 256
      LazyByteString.length (encode payload) `shouldBe` 256
      eventIdFor seed 3 10 `shouldBe` eventIdFor seed 3 10
      eventIdFor seed 3 10 `shouldNotBe` eventIdFor seed 4 10
      eventIdFor seed 3 10 `shouldNotBe` eventIdFor seed 3 11
      let projection event = (event.eventId, event.payload)
      fmap projection (mkEvents seed CallerV7 3 10 3 64) `shouldBe` fmap projection (mkEvents seed CallerV7 3 10 3 64)
      streamNameFor (RunTag "abcdefgh") 2 9 `shouldBe` streamNameFor (RunTag "abcdefgh") 2 9
  describe "ledger facts" do
    it "round-trips all three fact variants" do
      let seed = either (error . show) id (mkSeed 42)
          EventId uuid = eventIdFor seed 3 10
          facts =
            [ ProducedFact (Produced "stream" 2 7 [uuid] 100),
              DeliveredFact (Delivered "subscription" 1 7 uuid 3 2 0 1 200),
              CheckpointFact (CheckpointSample "subscription" 1 7 300)
            ]
      map (decode . encode) facts `shouldBe` map Just facts
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
