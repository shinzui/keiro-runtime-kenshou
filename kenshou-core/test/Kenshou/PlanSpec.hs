module Kenshou.PlanSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Plan.Catalog (readCatalogFile)
import Kenshou.Plan.Components
import Kenshou.Plan.Components.Check
import Kenshou.Plan.Selector
import Test.Hspec

spec :: Spec
spec = do
  describe "Kenshou.Plan.Selector" do
    it "round-trips and matches recursive selectors" do
      selector <- expectRight (parseSelector "shibuya/pgmq-adapter/**")
      scenario <- expectRight (parseScenarioId "shibuya/pgmq-adapter/correctness/finalize")
      renderSelector selector `shouldBe` "shibuya/pgmq-adapter/**"
      matches selector scenario `shouldBe` True
    it "rejects recursive wildcards before the final position" do
      parseSelector "shibuya/**/correctness/*" `shouldBe` Left "** is permitted only as the final segment"

  describe "Kenshou.Plan.Catalog" do
    it "decodes the planned scenario catalog" do
      result <- readCatalogFile "test/fixtures/plan/catalog-planned.json"
      catalog <- expectRight result
      length catalog `shouldSatisfy` (> 40)

  describe "Kenshou.Plan.Components" do
    it "validates the embedded graph" do
      graph <- expectRight embeddedGraph
      validateGraph graph `shouldBe` []
    it "computes the pgmq dependent closure" do
      graph <- expectRight embeddedGraph
      origin <- expectRight (parseRef graph "pgmq-hs")
      let affected = dependents graph (Set.singleton origin)
          present text = either (const False) (`Map.member` affected) (parseRef graph text)
      present "shibuya-pgmq-adapter" `shouldBe` True
      present "keiro-pgmq" `shouldBe` True
      present "kenshou-harness" `shouldBe` True
      present "runtime-assembly" `shouldBe` True
    it "keeps shibuya runner changes away from keiro contract consumers" do
      graph <- expectRight embeddedGraph
      origin <- expectRight (parseRef graph "shibuya-core:runner")
      let affected = dependents graph (Set.singleton origin)
          present text = either (const False) (`Map.member` affected) (parseRef graph text)
      present "keiro-pgmq" `shouldBe` True
      present "shibuya-metrics" `shouldBe` True
      present "shibuya-kiroku-adapter" `shouldBe` True
      present "runtime-assembly" `shouldBe` True
      present "keiro" `shouldBe` False
      present "keiro:router" `shouldBe` False
    it "routes shibuya contract changes to the three keiro consumers" do
      graph <- expectRight embeddedGraph
      origin <- expectRight (parseRef graph "shibuya-core:contract")
      let affected = dependents graph (Set.singleton origin)
          present text = either (const False) (`Map.member` affected) (parseRef graph text)
      present "keiro:process-manager" `shouldBe` True
      present "keiro:router" `shouldBe` True
      present "keiro:inbox" `shouldBe` True
      present "keiro:command" `shouldBe` False
      present "keiro:outbox" `shouldBe` False
      present "keiro:workflow" `shouldBe` False

  describe "Kenshou.Plan.Components.Check" do
    it "resolves shortened unit ids and finds a planted missing edge" do
      graph <- expectRight embeddedGraph
      result <- checkAgainstPlanJson graph "test/fixtures/plan/plan-missing-edge.json"
      findings <- expectRight result
      findings `shouldSatisfy` any isMissing
  where
    isMissing (MissingEdge (ComponentId "pgmq-hs") (ComponentId "kiroku-store") _) = True
    isMissing _ = False

expectRight :: (Show problem) => Either problem value -> IO value
expectRight (Right value) = pure value
expectRight (Left problem) = expectationFailure (show problem) >> fail "unreachable"
