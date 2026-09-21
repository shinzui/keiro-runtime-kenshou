module Kenshou.Measure.Compare
  ( Verdict (..),
    MetricStatus (..),
    MetricComparison (..),
    Comparison (..),
    CompareError (..),
    compareRuns,
    compareMetricPairs,
    verdictExitCode,
  )
where

import Data.Aeson
import Data.Aeson.Key (fromText)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.List (find, nub)
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import Kenshou.Core.Id (newRunId, renderRunId)
import Kenshou.Measure.Compare.Compatibility
import Kenshou.Measure.Compare.Ordering
import Kenshou.Measure.Compare.Policy
import Kenshou.Measure.Metrics
import Kenshou.Measure.Stats
import Kenshou.Measure.Summary

data Verdict = VerdictPass | VerdictRegression | VerdictInconclusive | VerdictInfrastructureFailure deriving stock (Eq, Ord, Show)

data MetricStatus = MetricPass | MetricRegression | MetricInconclusive deriving stock (Eq, Ord, Show)

data MetricComparison = MetricComparison
  { metric :: Text,
    unit :: Text,
    pairs :: [(Double, Double)],
    ratio :: Interval,
    delta :: Interval,
    relativeLimit :: Double,
    absoluteFloor :: Double,
    baselineCv :: Double,
    status :: MetricStatus,
    message :: Text
  }
  deriving stock (Eq, Show)

data Comparison = Comparison
  { comparisonId :: Text,
    policy :: Policy,
    variedFactors :: [VaryingAxis],
    pairCount :: Int,
    metrics :: Map Text MetricComparison,
    reasons :: [Text],
    verdict :: Verdict
  }
  deriving stock (Eq, Show)

newtype CompareError = CompareError Text deriving stock (Eq, Show)

instance ToJSON Verdict where toJSON = String . verdictText

instance ToJSON MetricStatus where toJSON = String . statusText

instance ToJSON MetricComparison where
  toJSON value =
    object
      [ "metric" .= value.metric,
        "unit" .= value.unit,
        "pairs" .= [object ["baseline" .= baseline, "candidate" .= candidate] | (baseline, candidate) <- value.pairs],
        "ratio" .= value.ratio,
        "delta" .= value.delta,
        "relativeLimit" .= value.relativeLimit,
        "absoluteFloor" .= value.absoluteFloor,
        "baselineCv" .= value.baselineCv,
        "status" .= value.status,
        "message" .= value.message
      ]

instance ToJSON Comparison where
  toJSON value =
    object
      [ "schema" .= ("kenshou.comparison/v1" :: Text),
        "comparisonId" .= value.comparisonId,
        "algorithm" .= object ["name" .= ("paired-bootstrap-t-envelope" :: Text), "version" .= (1 :: Int), "generator" .= ("splitmix" :: Text), "iterations" .= value.policy.bootstrapIterations, "seed" .= value.policy.resamplingSeed, "confidenceLevel" .= value.policy.confidenceLevel],
        "policy" .= value.policy,
        "variedFactors" .= value.variedFactors,
        "pairCount" .= value.pairCount,
        "metrics" .= value.metrics,
        "reasons" .= value.reasons,
        "verdict" .= value.verdict,
        "exitCode" .= verdictExitCode value.verdict
      ]

data RunData = RunData
  { result :: Value,
    inputs :: Value,
    fingerprint :: Value,
    summary :: MeasurementSummary,
    outcome :: Text,
    startedAt :: Maybe UTCTime
  }

compareRuns :: Policy -> NonEmpty VaryingAxis -> [FilePath] -> [FilePath] -> IO (Either CompareError Comparison)
compareRuns policy axes baselineDirs candidateDirs
  | null baselineDirs || length baselineDirs /= length candidateDirs = pure (Left (CompareError "baseline and candidate runs must form the same non-zero number of pairs"))
  | otherwise = do
      baselineResults <- traverse loadRun baselineDirs
      candidateResults <- traverse loadRun candidateDirs
      case (sequence baselineResults, sequence candidateResults) of
        (Left err, _) -> pure (Left err)
        (_, Left err) -> pure (Left err)
        (Right baselines, Right candidates) -> compareLoaded baselines candidates
  where
    compareLoaded baselines candidates = case compatibilityProblem axes (baselines <> candidates) of
      Just message -> pure (Left (CompareError message))
      Nothing -> case varyingProblem axes baselines candidates of
        Just message -> pure (Left (CompareError message))
        Nothing -> do
          identifier <- renderRunId <$> newRunId
          let referenceFingerprint = maybe Null (.fingerprint) (headMay baselines)
              environmentChanged = any ((/= referenceFingerprint) . (.fingerprint)) (tailSafe baselines <> candidates)
              badOutcomes = any ((`elem` ["errored", "infrastructure-failure"]) . (.outcome)) (baselines <> candidates)
              metricComparisons = compareMetrics policy baselines candidates
              interleaving = validateInterleaving (catMaybes (concat (zipWith trialRows [0 ..] (zip baselines candidates))))
              lowGrade = any ((/= policy.requireGrade) . (.grade) . (.summary)) (baselines <> candidates)
              reasons =
                ["machine profiles differ" | environmentChanged]
                  <> ["an input run has an infrastructure outcome" | badOutcomes]
                  <> ["fewer than the required number of pairs" | length baselines < policy.minimumPairs]
                  <> ["runs are not interleaved" | policy.requireInterleaving && either (const True) (const False) interleaving]
                  <> ["an input run is below the required evidence grade" | lowGrade]
              statuses = fmap (.status) (Map.elems metricComparisons)
              verdict
                | environmentChanged || badOutcomes = VerdictInfrastructureFailure
                | MetricRegression `elem` statuses = VerdictRegression
                | not (null reasons) || null statuses || MetricInconclusive `elem` statuses = VerdictInconclusive
                | otherwise = VerdictPass
          pure (Right (Comparison identifier policy (toList axes) (length baselines) metricComparisons reasons verdict))

loadRun :: FilePath -> IO (Either CompareError RunData)
loadRun directory = do
  decoded <- eitherDecodeFileStrict' (directory <> "/run-result.json") :: IO (Either String Value)
  summarized <- summarizeRunDir directory
  pure do
    result <- either (Left . CompareError . Text.pack) Right decoded
    summary <- either (Left . CompareError . (\(SummaryError message) -> message)) Right summarized
    inputs <- maybe (Left (CompareError "run result has no compatibility inputs")) Right (compatibilityInputs result)
    fingerprint <- maybe (Left (CompareError "run result has no environment fingerprint")) Right (environmentFingerprint result)
    let outcome = fromMaybe "unknown" (textAt ["outcome"] result)
        started = textAt ["timings", "startedAt"] result >>= parseUtc
    Right RunData {result, inputs, fingerprint, summary, outcome, startedAt = started}

compatibilityProblem :: NonEmpty VaryingAxis -> [RunData] -> Maybe Text
compatibilityProblem _ [] = Just "no runs"
compatibilityProblem axes (first : rest) = case [message | run <- rest, Left message <- [compatibleExcept axes first.inputs run.inputs]] of
  message : _ -> Just message
  [] -> Nothing

varyingProblem :: NonEmpty VaryingAxis -> [RunData] -> [RunData] -> Maybe Text
varyingProblem axes baselines candidates = findProblem (toList axes)
  where
    findProblem [] = Nothing
    findProblem (axis : rest) =
      let baselineValues = nub (fmap (varyingValue axis . (.inputs)) baselines)
          candidateValues = nub (fmap (varyingValue axis . (.inputs)) candidates)
       in if length baselineValues /= 1 || length candidateValues /= 1 || baselineValues == candidateValues
            then Just "each varying axis must have one distinct value per arm"
            else findProblem rest

compareMetrics :: Policy -> [RunData] -> [RunData] -> Map Text MetricComparison
compareMetrics policy baselines candidates = Map.fromList (mapMaybe compareOne commonNames)
  where
    allMetricMaps = fmap ((.metrics) . (.summary)) (baselines <> candidates)
    commonNames = case allMetricMaps of [] -> []; first : rest -> filter (\name -> all (Map.member name) rest) (Map.keys first)
    compareOne name = do
      rule <- find (\candidate -> matchesRule candidate.match name) policy.metricRules
      pairedValues <- traverse (pairMetric name) (zip baselines candidates)
      let unit = fromMaybe "" do
            baseline <- headMay baselines
            (.unit) <$> Map.lookup name baseline.summary.metrics
      pure (name, compareMetricPairs policy name unit rule pairedValues)
    pairMetric name (baseline, candidate) = do
      baselineMetric <- Map.lookup name baseline.summary.metrics
      candidateMetric <- Map.lookup name candidate.summary.metrics
      pure (baselineMetric.value, candidateMetric.value)

compareMetricPairs :: Policy -> Text -> Text -> MetricRule -> [(Double, Double)] -> MetricComparison
compareMetricPairs policy name unit rule pairedValues =
  let baselineValues = fmap fst pairedValues
      adverseRatios = fmap (adverseRatio rule.direction) pairedValues
      adverseDeltas = fmap (adverseDelta rule.direction) pairedValues
      ratioBootstrap = bootstrapInterval policy.resamplingSeed policy.bootstrapIterations policy.confidenceLevel geometricMean adverseRatios
      logT = studentTInterval policy.confidenceLevel (fmap log adverseRatios)
      ratioT = Interval (exp logT.low) (exp logT.estimate) (exp logT.high)
      ratioInterval = intervalEnvelope ratioBootstrap ratioT
      deltaInterval = intervalEnvelope (bootstrapInterval (policy.resamplingSeed + 1) policy.bootstrapIterations policy.confidenceLevel arithmeticMean adverseDeltas) (studentTInterval policy.confidenceLevel adverseDeltas)
      tooWide = ratioInterval.low <= 0 || ratioInterval.high / ratioInterval.low > 1 + policy.maxCiRelativeWidth
      comparisonStatus
        | tooWide = MetricInconclusive
        | ratioInterval.low > 1 + rule.relativeLimit && deltaInterval.low > rule.absoluteFloor = MetricRegression
        | ratioInterval.high <= 1 + rule.relativeLimit || deltaInterval.high <= rule.absoluteFloor = MetricPass
        | otherwise = MetricInconclusive
      comparisonMessage = case comparisonStatus of MetricPass -> "within policy limits"; MetricRegression -> "both relative and absolute regression limits exceeded"; MetricInconclusive -> "confidence interval crosses a policy limit or is too wide"
   in MetricComparison name unit pairedValues ratioInterval deltaInterval rule.relativeLimit rule.absoluteFloor (coefficientOfVariation baselineValues) comparisonStatus comparisonMessage
  where
    adverseRatio LowerIsBetter (baseline, candidate) = candidate / max 1e-12 baseline
    adverseRatio HigherIsBetter (baseline, candidate) = baseline / max 1e-12 candidate
    adverseDelta LowerIsBetter (baseline, candidate) = candidate - baseline
    adverseDelta HigherIsBetter (baseline, candidate) = baseline - candidate

trialRows :: Int -> (RunData, RunData) -> [Maybe (Arm, Int, UTCTime)]
trialRows pair (baseline, candidate) = [fmap (Baseline,pair,) baseline.startedAt, fmap (Candidate,pair,) candidate.startedAt]

tailSafe :: [value] -> [value]
tailSafe [] = []; tailSafe (_ : rest) = rest

textAt :: [Text] -> Value -> Maybe Text
textAt [] (String value) = Just value
textAt (key : rest) (Object objectValue) = KeyMap.lookup (fromText key) objectValue >>= textAt rest
textAt _ _ = Nothing

headMay :: [value] -> Maybe value
headMay [] = Nothing
headMay (value : _) = Just value

parseUtc :: Text -> Maybe UTCTime
parseUtc = parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" . Text.unpack

verdictExitCode :: Verdict -> Int
verdictExitCode VerdictPass = 0
verdictExitCode VerdictRegression = 1
verdictExitCode VerdictInconclusive = 3
verdictExitCode VerdictInfrastructureFailure = 4

verdictText :: Verdict -> Text
verdictText VerdictPass = "pass"
verdictText VerdictRegression = "regression"
verdictText VerdictInconclusive = "inconclusive"
verdictText VerdictInfrastructureFailure = "infrastructure-failure"

statusText :: MetricStatus -> Text
statusText MetricPass = "pass"
statusText MetricRegression = "regression"
statusText MetricInconclusive = "inconclusive"

toList :: NonEmpty value -> [value]
toList = foldr (:) []
