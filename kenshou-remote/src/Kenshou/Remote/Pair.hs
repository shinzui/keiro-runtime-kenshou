module Kenshou.Remote.Pair
  ( PairRequest (..),
    PairState (..),
    SliceResult (..),
    pairPlan,
    judgePairs,
  )
where

import Data.List (nub, nubBy)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word64)
import Kenshou.Core.Canonical (sha256Hex)
import Kenshou.Core.Id (Kind (..), RunId, ScenarioId (..), mkSeed, parseRunId, renderRunId, renderScenarioId)
import Kenshou.Core.RunSpec (ComparisonMembership (..), RunSpec (..))
import Kenshou.Measure.Compare.Ordering (Arm (..), PairedOrdering, TrialSlot (..), pairedSchedule)
import Kenshou.Plan.RunPlan (PlannedRun (..), RunPlan (..), TrialInfo (..))

data PairRequest = PairRequest
  { candidate :: !Text,
    baseline :: !Text,
    pairs :: !Int,
    ordering :: !PairedOrdering,
    seed :: !Word64,
    maxReplacements :: !Int
  }
  deriving stock (Eq, Show)

data PairState = PairValid | PairInvalid !Text
  deriving stock (Eq, Show)

data SliceResult = SliceResult
  { group :: !Text,
    pairIndex :: !Int,
    arm :: !Arm,
    passed :: !Bool
  }
  deriving stock (Eq, Show)

-- A planned benchmark may already have planner-generated trial repeats. The
-- cell schedule replaces those repeats with adjacent, same-seed pairs.
pairPlan :: PairRequest -> RunPlan -> Either Text RunPlan
pairPlan request source = do
  if request.pairs < 3 then Left "paired comparisons need at least three pairs" else pure ()
  if request.maxReplacements < 0 then Left "max replacements cannot be negative" else pure ()
  if Text.null request.baseline || Text.null request.candidate || request.baseline == request.candidate
    then Left "baseline and candidate payload labels must be distinct"
    else pure ()
  if null source.runs then Left "paired comparison plan has no runs" else pure ()
  if any ((/= Benchmark) . (.kind) . (.scenario) . (.spec)) source.runs
    then Left "paired comparisons require benchmark runs only"
    else pure ()
  let configurations = nubBy sameConfiguration source.runs
      slots = pairedSchedule request.ordering (request.pairs + request.maxReplacements) request.seed
      selected = [(configurationIndex, entry, slot) | (configurationIndex, entry) <- zip [0 :: Int ..] configurations, slot <- slots]
  planned <- traverse makeRun (zip [1 :: Int ..] selected)
  pure source {runs = planned, estimateMinutes = sum (fmap (.estimateMinutes) planned)}
  where
    sameConfiguration left right =
      let first = left.spec
          second = right.spec
       in first.scenario == second.scenario
            && first.knobs == second.knobs
            && first.dimensions == second.dimensions
            && first.phases == second.phases
            && first.environment == second.environment

    makeRun (ordinal, (configurationIndex, original, slot)) = do
      identifier <- derivedRunId original.runId configurationIndex slot.position
      pairSeed <- mkSeed (slot.pairSeed `mod` 9007199254740992)
      let groupName = renderScenarioId original.spec.scenario <> "/config-" <> Text.pack (show configurationIndex)
          armName = case slot.arm of Baseline -> request.baseline; Candidate -> request.candidate
          trial = TrialInfo groupName armName slot.pairIndex (request.pairs + request.maxReplacements)
          spec = original.spec {runId = Just identifier, seed = Just pairSeed, comparison = Just (ComparisonMembership groupName armName slot.pairIndex slot.position)}
      pure original {ordinal, runId = identifier, trial = Just trial, spec}

derivedRunId :: RunId -> Int -> Int -> Either Text RunId
derivedRunId original configurationIndex position =
  parseRunId (Text.take 18 (renderRunId original) <> "-a" <> Text.take 3 digest <> "-" <> Text.take 12 (Text.drop 3 digest))
  where
    digest = Text.drop 7 (sha256Hex (TextEncoding.encodeUtf8 (renderRunId original <> ":" <> Text.pack (show configurationIndex) <> ":" <> Text.pack (show position))))

judgePairs :: [SliceResult] -> [((Text, Int), PairState)]
judgePairs results = fmap judge keys
  where
    keys = nub [(result.group, result.pairIndex) | result <- results]
    judge key =
      let members = [result | result <- results, (result.group, result.pairIndex) == key]
          baseline = filter ((== Baseline) . (.arm)) members
          candidate = filter ((== Candidate) . (.arm)) members
       in (key, if length baseline == 1 && length candidate == 1 && all (.passed) members then PairValid else PairInvalid "one or both cell trials failed or are missing")
