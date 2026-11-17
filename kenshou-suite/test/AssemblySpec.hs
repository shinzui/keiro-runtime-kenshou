module AssemblySpec (AssemblySpec.spec) where

import Data.Aeson (eitherDecodeFileStrict')
import Data.Map.Strict qualified as Map
import Kenshou.Core.Bundle (mkRegistry)
import Kenshou.Core.Cli (Program (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.RunSpec (RunSpec (..), minimalRunSpec)
import Kenshou.Plan.RunPlan (PlannedRun (..), RunPlan (..))
import Kenshou.Remote.Cell.Docs (BrokerReset (..), CachePolicy (..), CellDescriptor (..), CellImages (..), ResetBlock (..))
import Kenshou.Remote.Cell.Prepare (PrepareOptions (..), Prepared (..), PreparedRun (..), prepareForCell)
import Kenshou.Remote.Cell.WorkJson (decodeWorkPlan)
import Kenshou.Suite.Registry (program)
import Test.Hspec

spec :: Spec
spec = describe "runtime assembly on the extracted harness" do
  it "preserves the legacy cell broker wipe for a registered Kafka scenario" do
    raw <- eitherDecodeFileStrict' "fixtures/core/golden/run-plan.minimal.json" >>= either fail pure
    plan <- either (fail . show) pure (decodeWorkPlan raw)
    descriptor <- eitherDecodeFileStrict' "fixtures/remote/golden/cell/cell.descriptor.v1.json" >>= either fail pure
    payload <- eitherDecodeFileStrict' "fixtures/remote/golden/payload.json" >>= either fail pure
    registry <- either (fail . show) pure (mkRegistry program.bundles)
    scenario <- either (fail . show) pure (parseScenarioId "kafka/adapter/correctness/ack-ok-commits-and-resumes")
    let first = head (plan :: RunPlan).runs
        kafkaRun = PlannedRun first.ordinal first.runId first.estimateMinutes first.reasons first.trial ((minimalRunSpec scenario) {runId = Just first.runId})
        prepared = prepareForCell registry (descriptor {images = descriptor.images {broker = "fixture-broker-image"}}) Nothing [] (Map.singleton "default" payload) (PrepareOptions False False [] Cold) plan {runs = [kafkaRun]}
    prepared.rejected `shouldSatisfy` null
    case prepared.accepted of
      [run] -> do
        run.reset.broker `shouldBe` Just (BrokerReset True)
        run.reset.resources `shouldSatisfy` Map.null
      _ -> expectationFailure "expected one prepared Kafka run"
