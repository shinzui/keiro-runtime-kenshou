module Kenshou.Measure.Perf
  ( AdmissionProblem (..),
    requiredMetricProblems,
    validateProfilePolicy,
    verifyPerformanceRun,
  )
where

import Control.Exception (IOException, displayException, try)
import Control.Monad (unless, when)
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseMaybe)
import Data.ByteString qualified as ByteString
import Data.Char (isAlphaNum)
import Data.IORef
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64)
import Kenshou.Measure.Compare.Policy qualified as Policy
import Kenshou.Measure.Histogram qualified as Histogram
import Kenshou.Measure.Histogram.Codec (decodeHistogram)
import Kenshou.Measure.Metrics (Metric (..))
import Kenshou.Measure.Samples
import Kenshou.Measure.Summary
import Kenshou.Perf.Artifacts (verifyPerfManifest)
import Kenshou.Perf.Plan (PerfProfile (..), RequiredMetric (..))
import System.FilePath ((</>))

data AdmissionProblem
  = MissingRequiredMetric Text
  | InsufficientSteadySamples Text Int Word64
  | InvalidPerformanceEvidence Text
  | RuntimeWorkFailure Text
  deriving stock (Eq, Show)

requiredMetricProblems :: [RequiredMetric] -> MeasurementSummary -> [AdmissionProblem]
requiredMetricProblems required summary = concatMap check required
  where
    check metric = case Map.lookup metric.name summary.metrics of
      Nothing -> [MissingRequiredMetric metric.name]
      Just value
        | value.unit /= metric.unit -> [InvalidPerformanceEvidence ("metric unit mismatch: " <> metric.name)]
        | isNaN value.value || isInfinite value.value -> [InvalidPerformanceEvidence ("non-finite metric: " <> metric.name)]
        | otherwise -> case operationFor metric.name >>= (`Map.lookup` summary.ops) >>= count of
            Nothing -> [InvalidPerformanceEvidence ("required metric has no steady sample count: " <> metric.name)]
            Just samples | samples < fromIntegral metric.minimumSteadySamples -> [InsufficientSteadySamples metric.name metric.minimumSteadySamples samples]
            _ -> []
    count = parseMaybe (withObject "operation summary" (.: "count"))

validateProfilePolicy :: PerfProfile -> Policy.Policy -> Either Text ()
validateProfilePolicy profile policy = do
  unless (profile.minimumPairs >= policy.minimumPairs) (Left "profile pair count is below the comparison policy minimum")
  unless (policy.requireInterleaving && policy.requireGrade == "benchmark") (Left "profile policy must require interleaved benchmark-grade evidence")
  unless (policy.confidenceLevel > 0 && policy.confidenceLevel < 1) (Left "invalid policy confidence level")
  unless (all (\rule -> rule.relativeLimit >= 0 && rule.absoluteFloor >= 0) policy.metricRules) (Left "invalid comparison policy effect limits")
  mapM_ required profile.requiredMetrics
  where
    required metric = unless (any (\rule -> Policy.matchesRule rule.match metric.name) policy.metricRules) (Left ("required metric has no policy rule: " <> metric.name))

-- Recompute from sealed raw samples and compare the retained histogram and
-- summary. The ordinary comparison engine trusts a stored summary if present;
-- performance orchestration must call this admission check before comparing.
verifyPerformanceRun :: PerfProfile -> FilePath -> IO (Either [AdmissionProblem] MeasurementSummary)
verifyPerformanceRun profile directory = do
  checked <- try @IOException verify
  pure case checked of
    Left problem -> Left [InvalidPerformanceEvidence (Text.pack (displayException problem))]
    Right result -> result
  where
    verify = do
      manifest <- verifyPerfManifest directory
      case manifest of
        Left problems -> pure (Left [InvalidPerformanceEvidence (Text.pack (show problems))])
        Right () -> do
          summarized <- summarizeRunDir directory
          case summarized of
            Left problem -> pure (Left [InvalidPerformanceEvidence (Text.pack (show problem))])
            Right summary -> do
              rawProblems <- concat <$> traverse (verifyOperation directory summary.window profile.steadyCount) operations
              result <- eitherDecodeFileStrict' (directory </> "run-result.json") :: IO (Either String Value)
              let retained = result >>= \document -> maybe (Left "missing retained measurement summary") Right (jsonAt ["summaries", "measurements", "measurements"] document)
                  summaryProblems = case retained of
                    Left problem -> [InvalidPerformanceEvidence (Text.pack problem)]
                    Right value | value /= toJSON summary -> [InvalidPerformanceEvidence "retained measurement summary differs from raw evidence"]
                    _ -> []
                  problems = requiredMetricProblems profile.requiredMetrics summary <> rawProblems <> summaryProblems
              pure if null problems then Right summary else Left problems
    operations = nub [operation | metric <- profile.requiredMetrics, Just operation <- [operationFor metric.name]]

verifyOperation :: FilePath -> SummaryWindow -> Int -> Text -> IO [AdmissionProblem]
verifyOperation directory window plannedCount operation
  | Text.null operation || not (Text.all (\c -> isAlphaNum c || c `elem` ['-', '_']) operation) = pure [InvalidPerformanceEvidence "unsafe required operation name"]
  | otherwise = do
      let base = directory </> "samples" </> Text.unpack operation
      latency <- decodeHistogram <$> ByteString.readFile (base <> ".hist")
      service <- decodeHistogram <$> ByteString.readFile (base <> ".service.hist")
      case (latency, service) of
        (Right expectedLatency, Right expectedService) -> do
          rebuiltLatency <- Histogram.newHistogram (Histogram.histogramConfig expectedLatency)
          rebuiltService <- Histogram.newHistogram (Histogram.histogramConfig expectedService)
          counts <- newIORef (0 :: Word64, 0 :: Word64, False)
          report <- readSamples (base <> ".raw") \sample -> do
            let steady = sample.intendedStartNs >= window.steadyStartMonoNs && sample.intendedStartNs < window.steadyEndMonoNs
                invalid = sample.actualStartNs > sample.endNs || sample.intendedStartNs > sample.endNs || sample.outcomeCode > 1
            modifyIORef' counts (\(count, failures, bad) -> (count + if steady then 1 else 0, failures + if steady && sample.outcomeCode /= 0 then 1 else 0, bad || invalid || not steady))
            when (steady && not invalid) do
              Histogram.recordValue rebuiltLatency (sample.endNs - sample.intendedStartNs)
              Histogram.recordValue rebuiltService (sample.endNs - sample.actualStartNs)
          actualLatency <- Histogram.freeze rebuiltLatency
          actualService <- Histogram.freeze rebuiltService
          (count, failures, malformed) <- readIORef counts
          pure
            ( [InvalidPerformanceEvidence (operation <> ": raw sample clock/schema/phase mismatch") | malformed || report.ignoredBytes /= 0 || report.header.clockKind /= MonotonicClock || report.header.operation /= operation]
                <> [InvalidPerformanceEvidence (operation <> ": histogram differs from raw samples") | expectedLatency /= actualLatency || expectedService /= actualService]
                <> [RuntimeWorkFailure (operation <> ": completed steady work differs from declared count") | count /= fromIntegral plannedCount]
                <> [RuntimeWorkFailure (operation <> ": failed steady operations") | failures > 0]
            )
        _ -> pure [InvalidPerformanceEvidence (operation <> ": invalid histogram schema")]

operationFor :: Text -> Maybe Text
operationFor name = case Text.splitOn "." name of
  "op" : operation : _ -> Just operation
  _ -> Nothing

jsonAt :: [Text] -> Value -> Maybe Value
jsonAt [] value = Just value
jsonAt (key : rest) (Object value) = KeyMap.lookup (Key.fromText key) value >>= jsonAt rest
jsonAt _ _ = Nothing
