module PrepareSpec (spec) where

import Data.Aeson (Value (..))
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Kenshou.Core.Id (Kind (..), mkSeed, newRunId, parseScenarioId, renderKind)
import Kenshou.Core.RunSpec (RunSpec (..), minimalRunSpec)
import Kenshou.Core.RunSpec qualified as RunSpec
import Kenshou.Plan.Change (Change (..), ChangeSource (..), Reason (..))
import Kenshou.Plan.Components (ComponentId (..), ComponentRef (..))
import Kenshou.Plan.Policy (defaultPlanPolicy)
import Kenshou.Plan.RunPlan (PlanContext (..), PlanInputs (..), PlannedRun (PlannedRun), RunPlan (..))
import Kenshou.Plan.Selector (parseSelector)
import Kenshou.Remote.Cell.Docs (CachePolicy (..), ResetBlock (..))
import Kenshou.Remote.Cell.Prepare (Granularity (..), PreparedRun (..), Slice (..), slicePlan, sliceRuns)
import Test.Hspec

spec :: Spec
spec = describe "cell run slicing" do
  it "shares adjacent correctness resets and isolates benchmark and soak runs" do
    first <- prepared 0 Correctness "default" cold
    second <- prepared 1 Concurrency "default" cold
    benchmark <- prepared 2 Benchmark "default" cold
    third <- prepared 3 Correctness "default" cold
    soak <- prepared 4 Soak "default" cold
    fourth <- prepared 5 Correctness "default" cold
    slices <- expectSlices (sliceRuns GranularityAuto [first, second, benchmark, third, soak, fourth])
    fmap (NonEmpty.length . (.entries)) slices `shouldBe` [2, 1, 1, 1, 1]
    fmap (.index) slices `shouldBe` [0, 1, 2, 3, 4]
    fmap (.wallClockSeconds) slices `shouldBe` [320, 310, 310, 310, 310]

  it "starts a new automatic slice when the payload or reset changes" do
    first <- prepared 0 Correctness "default" cold
    second <- prepared 1 Correctness "candidate" cold
    third <- prepared 2 Correctness "candidate" warm
    fourth <- prepared 3 Correctness "candidate" warm
    slices <- expectSlices (sliceRuns GranularityAuto [first, second, third, fourth])
    fmap (NonEmpty.length . (.entries)) slices `shouldBe` [1, 1, 2]
    fmap (.payloadLabel) slices `shouldBe` ["default", "candidate", "candidate"]

  it "requires a homogeneous plan slice and refuses duplicate identities" do
    first <- prepared 0 Correctness "default" cold
    second <- prepared 1 Correctness "default" cold
    runSlices <- expectSlices (sliceRuns GranularityRun [first, second])
    fmap (NonEmpty.length . (.entries)) runSlices `shouldBe` [1, 1]
    planSlices <- expectSlices (sliceRuns GranularityPlan [first, second])
    fmap (NonEmpty.length . (.entries)) planSlices `shouldBe` [2]
    sliceRuns GranularityPlan [first, PreparedRun second.ordinal second.runId second.spec second.payloadLabel warm second.timeoutSeconds] `shouldBe` Left "plan granularity requires one payload and reset for every run"
    sliceRuns GranularityRun [first, first {ordinal = 1}] `shouldSatisfy` isLeft

  it "keeps the original plan metadata while replacing only selected run specs" do
    first <- prepared 0 Correctness "default" cold
    second <- prepared 1 Correctness "default" cold
    planId <- newRunId
    now <- getCurrentTime
    selector <- either (\problem -> expectationFailure (Text.unpack problem) >> error "unreachable") pure (parseSelector "selftest/**")
    seed <- either (\problem -> expectationFailure (Text.unpack problem) >> error "unreachable") pure (mkSeed 1)
    let reason = Reason (Change (ComponentRef (ComponentId "remote") Nothing) Everything "fixture") [] selector 0
        planned run = PlannedRun run.ordinal run.runId 1 (reason :| []) Nothing run.spec
        planContext = PlanContext Nothing "graph" "released" "plan-hash" (PlanInputs Null) [] []
        original = RunPlan planId now planContext (defaultPlanPolicy seed) [planned first, planned second] [] 2
        changed = PreparedRun first.ordinal first.runId (first.spec {RunSpec.timeoutSeconds = Just 42}) first.payloadLabel first.reset first.timeoutSeconds
    slices <- expectSlices (sliceRuns GranularityAuto [changed, second])
    case slices of
      [slice] -> do
        sliced <- either (\problem -> expectationFailure (Text.unpack problem) >> error "unreachable") pure (slicePlan original slice)
        sliced.planId `shouldBe` original.planId
        fmap (\(PlannedRun _ identifier _ _ _ _) -> identifier) sliced.runs `shouldBe` [first.runId, second.runId]
        fmap (\(PlannedRun _ _ _ _ _ runSpec) -> runSpec.timeoutSeconds) sliced.runs `shouldBe` [Just 42, Nothing]
        sliced.estimateMinutes `shouldBe` 2
        slicePlan (original {runs = [planned first]}) slice `shouldSatisfy` isLeft
      _ -> expectationFailure "expected one slice"

prepared :: Int -> Kind -> Text -> ResetBlock -> IO PreparedRun
prepared ordinal kind label reset = do
  identifier <- newRunId
  scenario <- either (\problem -> expectationFailure (Text.unpack problem) >> error "unreachable") pure (parseScenarioId ("selftest/remote/" <> renderKind kind <> "/slice"))
  pure (PreparedRun ordinal identifier (minimalRunSpec scenario) label reset 10)

expectSlices :: Either Text [Slice] -> IO [Slice]
expectSlices = either (\problem -> expectationFailure (Text.unpack problem) >> error "unreachable") pure

isLeft :: Either left right -> Bool
isLeft (Left _) = True
isLeft _ = False

cold :: ResetBlock
cold = ResetBlock Cold Nothing Nothing

warm :: ResetBlock
warm = ResetBlock Warm Nothing Nothing
