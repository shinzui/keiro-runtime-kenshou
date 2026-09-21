{-# LANGUAGE FieldSelectors #-}

module Kenshou.Plan.RunPlan
  ( PlanInputs (..),
    PlanContext (..),
    TrialInfo (..),
    PlannedRun (..),
    SkipReason (..),
    Skipped (..),
    SkeletonRun (..),
    PlanSkeleton (..),
    RunPlan (..),
    buildPlan,
    stampPlan,
  )
where

import Data.Aeson (ToJSON (..), Value, object, (.=))
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, getCurrentTime)
import Kenshou.Core.Id
import Kenshou.Core.Knob (RawKnob (..))
import Kenshou.Core.RunSpec
import Kenshou.Core.RunSpec qualified as RunSpec
import Kenshou.Core.Scenario (Placement (..), renderPlacement, renderTier)
import Kenshou.Plan.Catalog (ScenarioInfo (..))
import Kenshou.Plan.Change
import Kenshou.Plan.Matrix
import Kenshou.Plan.Policy
import System.Random.SplitMix (nextWord64)

newtype PlanInputs = PlanInputs {value :: Value}
  deriving stock (Eq, Show)

data PlanContext = PlanContext
  { suite :: Maybe Text,
    graphDigest :: Text,
    cohortName :: Text,
    cohortPlanHash :: Text,
    inputs :: PlanInputs,
    changes :: [Change],
    warnings :: [Text]
  }
  deriving stock (Eq, Show)

data TrialInfo = TrialInfo {group :: Text, arm :: Text, index :: Int, of_ :: Int}
  deriving stock (Eq, Show)

data PlannedRun = PlannedRun
  { ordinal :: Int,
    runId :: RunId,
    estimateMinutes :: Int,
    reasons :: NonEmpty Reason,
    trial :: Maybe TrialInfo,
    spec :: RunSpec
  }
  deriving stock (Eq, Show)

data SkipReason
  = SkipTier
  | SkipKind
  | SkipPlacement
  | SkipExcluded
  | SkipUnsupportedDimension
  | SkipBenchmarkWithoutDurable
  | SkipUnsupportedKnob
  | SkipOverBudget
  deriving stock (Eq, Ord, Show)

data Skipped = Skipped {scenario :: ScenarioId, reason :: SkipReason, detail :: Text}
  deriving stock (Eq, Show)

data SkeletonRun = SkeletonRun
  { estimateMinutes :: Int,
    reasons :: NonEmpty Reason,
    trial :: Maybe TrialInfo,
    spec :: RunSpec
  }
  deriving stock (Eq, Show)

data PlanSkeleton = PlanSkeleton
  { context :: PlanContext,
    policy :: PlanPolicy,
    runs :: [SkeletonRun],
    skipped :: [Skipped],
    estimateMinutes :: Int
  }
  deriving stock (Eq, Show)

data RunPlan = RunPlan
  { planId :: RunId,
    createdAt :: UTCTime,
    context :: PlanContext,
    policy :: PlanPolicy,
    runs :: [PlannedRun],
    skipped :: [Skipped],
    estimateMinutes :: Int
  }
  deriving stock (Eq, Show)

buildPlan :: PlanContext -> PlanPolicy -> [Selected] -> PlanSkeleton
buildPlan context policy selected =
  PlanSkeleton
    { context,
      policy,
      runs = kept,
      skipped = initialSkipped <> budgetSkipped,
      estimateMinutes = sum (fmap (.estimateMinutes) kept)
    }
  where
    ordered = sortOn selectedKey selected
    expanded = fmap expandOne ordered
    candidates = concatMap fst expanded
    initialSkipped = concatMap snd expanded
    (kept, budgetSkipped) = applyBudget policy.budgetMinutes candidates
    selectedKey value =
      ( minimum (fmap (.distance) (NonEmpty.toList value.reasons)),
        value.scenario.tier,
        kindRank value.scenario.id.kind,
        renderScenarioId value.scenario.id
      )
    kindRank Correctness = (0 :: Int)
    kindRank Concurrency = 1
    kindRank Benchmark = 2
    kindRank Soak = 3
    expandOne selectedValue
      | selectedValue.scenario.tier > policy.maxTier = ([], [skip SkipTier ("tier " <> renderTier selectedValue.scenario.tier <> " exceeds " <> renderTier policy.maxTier)])
      | selectedValue.scenario.id.kind `Set.notMember` policy.kinds = ([], [skip SkipKind "scenario kind is not enabled"])
      | not (placementMatches policy.placement selectedValue.scenario.placement) = ([], [skip SkipPlacement ("scenario placement is " <> renderPlacement selectedValue.scenario.placement)])
      | otherwise = case expandScenario policy selectedValue of
          ([], matrixSkips) -> ([], fmap (matrixSkip selectedValue.scenario.id) matrixSkips)
          (configs, _) -> (makeRuns selectedValue configs, [])
      where
        skip reason detail = Skipped selectedValue.scenario.id reason detail
    matrixSkip scenarioId problem = Skipped scenarioId (matrixReason problem.reason) problem.detail
    matrixReason "benchmark-without-durable" = SkipBenchmarkWithoutDurable
    matrixReason "unsupported-dimension" = SkipUnsupportedDimension
    matrixReason _ = SkipUnsupportedKnob
    makeRuns selectedValue configs
      | selectedValue.scenario.id.kind == Benchmark = concatMap makeTrial [0 .. policy.trials - 1]
      | otherwise = fmap (makeRun selectedValue Nothing 0) configs
      where
        makeTrial trialIndex =
          [ makeRun selectedValue (Just (TrialInfo (renderScenarioId selectedValue.scenario.id) ("arm-" <> Text.pack (show armIndex)) trialIndex policy.trials)) trialIndex config
          | (armIndex, config) <- zip [0 :: Int ..] (if even trialIndex then configs else reverse configs)
          ]
    makeRun selectedValue trial trialIndex config =
      SkeletonRun
        { estimateMinutes = Map.findWithDefault 10 selectedValue.scenario.tier policy.tierMinutes,
          reasons = selectedValue.reasons,
          trial,
          spec =
            (minimalRunSpec selectedValue.scenario.id)
              { RunSpec.scenarioRevision = Just selectedValue.scenario.revision,
                RunSpec.knobs = [(name, RawJson (toJSON value)) | (name, value) <- Map.toAscList config.knobs],
                RunSpec.dimensions = Map.toAscList config.dimensions,
                RunSpec.seed = Just (derivedSeed policy.seed selectedValue.scenario.id trialIndex),
                RunSpec.environment = defaultEnvironment policy.placement,
                RunSpec.cohortExpectation = Just (CohortExpectation (Just context.cohortName) context.cohortPlanHash),
                RunSpec.comparison = fmap toComparison trial
              }
        }
    toComparison trial = ComparisonMembership trial.group trial.arm trial.index (trial.index + 1)

applyBudget :: Maybe Int -> [SkeletonRun] -> ([SkeletonRun], [Skipped])
applyBudget Nothing runs = (runs, [])
applyBudget (Just budget) runs = go 0 [] [] (groupRuns runs)
  where
    go _ kept skipped [] = (reverse kept, reverse skipped)
    go used kept skipped ([] : rest) = go used kept skipped rest
    go used kept skipped (group@(first : _) : rest)
      | used + groupCost <= budget = go (used + groupCost) (reverse group <> kept) skipped rest
      | otherwise =
          let scenarioId = first.spec.scenario
              item = Skipped scenarioId SkipOverBudget ("group costs " <> Text.pack (show groupCost) <> " minutes with " <> Text.pack (show (budget - used)) <> " remaining")
           in go used kept (item : skipped) rest
      where
        groupCost = sum (fmap (.estimateMinutes) group)
    groupRuns [] = []
    groupRuns (first : rest) =
      let (same, later) = span ((== first.spec.scenario) . (.scenario) . (.spec)) rest
       in (first : same) : groupRuns later

stampPlan :: PlanSkeleton -> IO RunPlan
stampPlan skeleton = do
  planId <- newRunId
  createdAt <- getCurrentTime
  runs <- traverse stamp (zip [1 :: Int ..] skeleton.runs)
  pure
    RunPlan
      { planId,
        createdAt,
        context = skeleton.context,
        policy = skeleton.policy,
        runs,
        skipped = skeleton.skipped,
        estimateMinutes = skeleton.estimateMinutes
      }
  where
    stamp (ordinal, candidate) = do
      runId <- newRunId
      pure
        PlannedRun
          { ordinal,
            runId,
            estimateMinutes = candidate.estimateMinutes,
            reasons = candidate.reasons,
            trial = candidate.trial,
            spec = candidate.spec
          }

derivedSeed :: Seed -> ScenarioId -> Int -> Seed
derivedSeed seed scenario trialIndex = case mkSeed (word `mod` 9007199254740992) of
  Right value -> value
  Left _ -> seed
  where
    (word, _) = nextWord64 (deriveGen seed (renderScenarioId scenario <> ":" <> Text.pack (show trialIndex)))

placementMatches :: SpecPlacement -> Placement -> Bool
placementMatches RunLocal PlaceLocal = True
placementMatches RunLocal PlaceEither = True
placementMatches RunOnCell PlaceCell = True
placementMatches RunOnCell PlaceEither = True
placementMatches _ _ = False

defaultEnvironment :: SpecPlacement -> EnvironmentSpec
defaultEnvironment placement = EnvironmentSpec placement Nothing Nothing Map.empty Nothing Nothing

instance ToJSON RunPlan where
  toJSON plan =
    object
      [ "schema" .= ("kenshou.run-plan/v1" :: Text),
        "planId" .= plan.planId,
        "createdAt" .= plan.createdAt,
        "suite" .= plan.context.suite,
        "graphDigest" .= plan.context.graphDigest,
        "cohort" .= object ["name" .= plan.context.cohortName, "planHash" .= plan.context.cohortPlanHash],
        "inputs" .= plan.context.inputs.value,
        "policy" .= plan.policy,
        "changes" .= plan.context.changes,
        "runs" .= plan.runs,
        "skipped" .= plan.skipped,
        "warnings" .= plan.context.warnings,
        "estimateMinutes" .= plan.estimateMinutes
      ]

instance ToJSON PlannedRun where
  toJSON run = object ["ordinal" .= run.ordinal, "runId" .= run.runId, "estimateMinutes" .= run.estimateMinutes, "reasons" .= run.reasons, "trial" .= run.trial, "spec" .= run.spec]

instance ToJSON TrialInfo where
  toJSON trial = object ["group" .= trial.group, "arm" .= trial.arm, "index" .= trial.index, "of" .= trial.of_]

instance ToJSON Skipped where
  toJSON skipped = object ["scenario" .= skipped.scenario, "reason" .= renderSkipReason skipped.reason, "detail" .= skipped.detail]

renderSkipReason :: SkipReason -> Text
renderSkipReason SkipTier = "tier"
renderSkipReason SkipKind = "kind"
renderSkipReason SkipPlacement = "placement"
renderSkipReason SkipExcluded = "excluded"
renderSkipReason SkipUnsupportedDimension = "unsupported-dimension"
renderSkipReason SkipBenchmarkWithoutDurable = "benchmark-without-durable"
renderSkipReason SkipUnsupportedKnob = "unsupported-knob"
renderSkipReason SkipOverBudget = "over-budget"
