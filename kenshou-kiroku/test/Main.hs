module Main (main) where

import Data.Aeson (decode, encode)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Kenshou.Core.Bundle (LayerBundle (..), mkRegistry)
import Kenshou.Core.Dimension (MetricsArm (..), TracingArm (..))
import Kenshou.Core.Id (Kind (..), Layer (..), ScenarioId (..), mkSeed, parseRunId, renderScenarioId)
import Kenshou.Core.Knob (RawKnob (..), mkKnobName, resolveKnobs)
import Kenshou.Core.Scenario (Scenario (..))
import Kenshou.Suite.Kiroku (bundle)
import Kenshou.Suite.Kiroku.Fixture.Facts (CheckpointSample (..), Delivered (..), KirokuFact (..), Produced (..))
import Kenshou.Suite.Kiroku.Fixture.Model (Cmd (..), Model (..), Outcome (..), StoreErrorTag (..), stepModel)
import Kenshou.Suite.Kiroku.Fixture.Store (StoreOptions (..), storeOptionsFromValues)
import Kenshou.Suite.Kiroku.Fixture.Telemetry (HandlerArm (..), handlerArm)
import Kenshou.Suite.Kiroku.Fixture.Workload (IdPolicy (..), RunTag (..), eventIdFor, mkEvents, payloadOf, streamNameFor)
import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Kiroku.Store (EventData (..), EventId (..), ExpectedVersion (..), StreamVersion (..))
import Test.Hspec

main :: IO ()
main = hspec do
  describe "kiroku knobs" do
    it "declares the four store knobs" do
      length storeKnobs `shouldBe` 4
    it "maps resolved knobs to concrete store options" do
      let runId = either (error . show) id (parseRunId "01923456-789a-7abc-8def-0123456789ab")
          knob key = either (error . show) id (mkKnobName key)
          defaults = either (error . show) id (resolveKnobs storeKnobs [])
          overrides = either (error . show) id (resolveKnobs storeKnobs [(knob "kiroku.pool-size", RawText "3"), (knob "kiroku.statement-timeout-seconds", RawText "4"), (knob "kiroku.conn.keepalives", RawText "true")])
          standard = storeOptionsFromValues defaults runId "scenario"
          configured = storeOptionsFromValues overrides runId "reader"
      standard.poolSize `shouldBe` 10
      standard.statementTimeout `shouldBe` Nothing
      standard.idleInTransactionTimeout `shouldBe` 30
      standard.keepalives `shouldBe` False
      standard.applicationName `shouldBe` "kenshou-kiroku-scenario-01923456"
      configured.poolSize `shouldBe` 3
      configured.statementTimeout `shouldBe` Just 4
      configured.keepalives `shouldBe` True
      configured.applicationName `shouldBe` "kenshou-kiroku-reader-01923456"
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
  describe "pure stream model" do
    it "preserves OCC and soft-delete semantics" do
      let seed = either (error . show) id (mkSeed 42)
          EventId first = eventIdFor seed 0 1
          EventId second = eventIdFor seed 0 2
          empty = Model Map.empty
          (created, creation) = stepModel empty (CmdAppend "model" NoStream [first])
          (unchanged, wrong) = stepModel created (CmdAppend "model" (ExactVersion (StreamVersion 0)) [second])
          (deleted, deletion) = stepModel created (CmdSoftDelete "model")
          (_, hidden) = stepModel deleted (CmdReadForward "model" 0 10)
          (_, refused) = stepModel deleted (CmdAppend "model" AnyVersion [second])
          (restored, restoration) = stepModel deleted (CmdUndelete "model")
          (_, visible) = stepModel restored (CmdReadForward "model" 0 10)
      creation `shouldBe` Appended 1
      wrong `shouldBe` Rejected WrongVersion
      unchanged `shouldBe` created
      deletion `shouldBe` Done True
      hidden `shouldBe` Events []
      refused `shouldBe` Rejected NotFound
      restoration `shouldBe` Done True
      visible `shouldBe` Events [first]
    it "rejects duplicate identifiers without changing either stream" do
      let seed = either (error . show) id (mkSeed 42)
          EventId identifier = eventIdFor seed 0 1
          empty = Model Map.empty
          (created, _) = stepModel empty (CmdAppend "first" NoStream [identifier])
          (unchanged, response) = stepModel created (CmdAppend "second" NoStream [identifier])
      response `shouldBe` Rejected DuplicateId
      unchanged `shouldBe` created
  describe "kiroku bundle" do
    it "registers unique kiroku scenarios" do
      let scenarios = bundle.scenarios
          names = fmap (renderScenarioId . (.id)) scenarios
      length scenarios `shouldBe` 38
      length (nub names) `shouldBe` length names
      mapM_ (\scenario -> scenario.id.layer `shouldBe` Kiroku) scenarios
      length [scenario | scenario <- scenarios, scenario.id.kind == Correctness] `shouldBe` 19
      length [scenario | scenario <- scenarios, scenario.id.kind == Concurrency] `shouldBe` 13
      length [scenario | scenario <- scenarios, scenario.id.kind == Benchmark] `shouldBe` 6
    it "passes the registry's structural validation" do
      case mkRegistry [bundle] of
        Right _ -> pure ()
        Left errors -> expectationFailure (show errors)
