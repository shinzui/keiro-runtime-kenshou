module Kenshou.Cli.Attest (FencingFacts (..), fencingFacts, runOutcomeRecomputer, measurementRecomputer, pairedComparisonRecomputer) where

import Control.Exception (IOException, try)
import Control.Monad (forM)
import Data.Aeson (Result (..), Value (..), eitherDecodeFileStrict', eitherDecodeStrict', fromJSON, object, toJSON, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString.Char8
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Cli.Attest.KeiroBatch (recomputeBatch)
import Kenshou.Cli.Attest.KeiroInbox (recomputeInbox)
import Kenshou.Cli.Attest.KeiroLease (recomputeLease)
import Kenshou.Cli.Attest.KeiroPoison (recomputePoison)
import Kenshou.Cli.Attest.KeiroProducerIdentity (recomputeProducerIdentity)
import Kenshou.Cli.Attest.KeiroQueueConfig (recomputeQueueConfig)
import Kenshou.Cli.Attest.KeiroQueueOrdering (recomputeQueueOrdering)
import Kenshou.Cli.Attest.KeiroQueueOutcomes (recomputeQueueOutcomes)
import Kenshou.Cli.Attest.KeiroQueuePolling (recomputeQueuePolling)
import Kenshou.Cli.Attest.KeiroTerminal (recomputeTerminal)
import Kenshou.Core.Cohort (CohortIdentity (..), PackageSource (..), ResolvedComponent (..), ResolvedPackage (..))
import Kenshou.Core.Id (renderScenarioId)
import Kenshou.Core.Outcome (Outcome (..), outcomeExitCode)
import Kenshou.Evidence.Attest (Recomputation (..), Recomputer (..), coreRecomputers)
import Kenshou.Evidence.Source (RunResultView (..), RunSource (..), loadRunSource)
import Kenshou.Measure.Compare (CompareError (..), compareRuns)
import Kenshou.Measure.Compare.Compatibility (VaryingAxis, parseVaryingAxis)
import Kenshou.Measure.Compare.Policy (Policy)
import Kenshou.Measure.Summary (SummaryError (..), summarizeRunDir)
import System.FilePath ((</>))

runOutcomeRecomputer :: Recomputer
runOutcomeRecomputer = Recomputer "run-outcome" 1 $ \root -> do
  loaded <- loadRunSource root
  case loaded of
    Left err -> pure (Left (Text.pack (show err)))
    Right source
      | renderScenarioId source.result.resultScenario == "kafka/consumer/concurrency/static-membership-fencing-is-observable" -> fencingRecomputation root source
      | renderScenarioId source.result.resultScenario == "keiro/queue/concurrency/lease-extension" -> recomputeLease root source
      | renderScenarioId source.result.resultScenario == "keiro/inbox/correctness/effectively-once-matrix" -> recomputeInbox root source
      | renderScenarioId source.result.resultScenario == "keiro/inbox/correctness/batch-fast-path-and-fallback" -> recomputeBatch root source
      | renderScenarioId source.result.resultScenario == "keiro/inbox/correctness/poison-accounting" -> recomputePoison root source
      | renderScenarioId source.result.resultScenario == "keiro/queue/concurrency/workers-survive-transient-polling-error" -> recomputeQueuePolling root source
      | renderScenarioId source.result.resultScenario == "keiro/queue/concurrency/fifo-heads-strict-order" -> recomputeQueueOrdering root source
      | renderScenarioId source.result.resultScenario == "keiro/queue/correctness/job-outcome-semantics" -> recomputeQueueOutcomes root source
      | renderScenarioId source.result.resultScenario == "keiro/queue/correctness/consumption-config-rejections" -> recomputeQueueConfig root source
      | renderScenarioId source.result.resultScenario == "keiro/outbox/correctness/producer-identity" -> recomputeProducerIdentity root source
      | renderScenarioId source.result.resultScenario == "keiro/outbox/correctness/terminal-state-matrix" -> recomputeTerminal root source
      | otherwise -> case coreRecomputers of
          (core : _) -> core.recompute root
          [] -> pure (Left "the core outcome oracle is unavailable")

data FencingFacts = FencingFacts
  { replacementHandled :: !Bool,
    fatalObserved :: !Bool,
    originalExited :: !Bool,
    errors :: ![Text],
    failures :: ![Text]
  }
  deriving stock (Eq, Show)

-- The worker control streams are captured separately from the scenario result.
-- Require a new record on the replacement, then derive the same failure labels
-- from the original member's fatal error and process-end messages.
fencingFacts :: [Value] -> [Value] -> Either Text FencingFacts
fencingFacts original replacement = do
  originalErrors <- traverse errorMessage [event | event <- original, eventType event == Just "error"]
  let replacementHandled = any isNewRecord replacement
      fatalObserved = any (Text.isInfixOf "RdKafkaRespErrFatal") originalErrors
      originalExited = any ((== Just "done") . eventType) original
      failures =
        ["fencing-replacement-did-not-handle" | not replacementHandled]
          <> ["fencing-unexpected-error" | not (null originalErrors) && not fatalObserved]
          <> ["fenced-member-still-alive-and-idle" | replacementHandled && null originalErrors && not originalExited]
          <> ["fencing-fatal-not-observable" | replacementHandled && not (fatalObserved && originalExited) && (not (null originalErrors) || originalExited)]
  pure FencingFacts {replacementHandled, fatalObserved, originalExited, errors = originalErrors, failures}
  where
    errorMessage (Object event) = case KeyMap.lookup "message" event of
      Just (String message) -> Right message
      _ -> Left "an original-consumer error event has no message"
    errorMessage _ = Left "an original-consumer error event is malformed"
    isNewRecord (Object event) =
      KeyMap.lookup "type" event == Just (String "custom")
        && KeyMap.lookup "name" event == Just (String "ok")
        && case KeyMap.lookup "payload" event of
          Just (Object payload) -> maybe False (\value -> value >= (10 :: Int) && value <= 19) (KeyMap.lookup "value" payload >>= intValue)
          _ -> False
    isNewRecord _ = False
    intValue value = case fromJSON value of
      Success integer -> Just integer
      Error _ -> Nothing

eventType :: Value -> Maybe Text
eventType (Object event) = case KeyMap.lookup "type" event of
  Just (String name) -> Just name
  _ -> Nothing
eventType _ = Nothing

fencingRecomputation :: FilePath -> RunSource -> IO (Either Text Recomputation)
fencingRecomputation root source = do
  original <- readControlEvents (root </> "logs/kafka-crash-consumer-0.0.control.jsonl")
  replacement <- readControlEvents (root </> "logs/kafka-crash-consumer-1.0.control.jsonl")
  stored <- eitherDecodeFileStrict' (root </> "run-result.json") :: IO (Either String Value)
  pure do
    originalEvents <- original
    replacementEvents <- replacement
    facts <- fencingFacts originalEvents replacementEvents
    if facts.originalExited && not facts.fatalObserved
      then Left "the original exited without a fatal error; control logs cannot place that exit before cleanup"
      else Right ()
    document <- either (Left . Text.pack) Right stored
    released <- releasedKafkaBinding source.result.resultCohort
    let outcome = if null facts.failures then Passed else Failed
        knownStatus
          | outcome == Failed && facts.failures == ["fenced-member-still-alive-and-idle"] = "reproduced"
          | outcome == Failed = "different-failure"
          | otherwise = "not-reproduced"
        expectedBlocking = outcome /= Passed && not (released && knownStatus == "reproduced")
        strictKnownDefects = case valueField "invocation" document >>= valueField "argv" of
          Just raw -> case fromJSON raw of
            Success (arguments :: [Text]) -> "--strict-known-defects" `elem` arguments
            Error _ -> False
          Nothing -> False
        expectedExitCode = if released && knownStatus == "reproduced" && not strictKnownDefects then 0 else outcomeExitCode outcome
        knownAgrees = case (released, source.result.resultKnownDefect) of
          (False, Nothing) -> True
          (True, Just known) ->
            valueField "reference" known == Just (String "mori://shinzui/keiro/masterplans/23-make-the-kafka-consumer-streaming-stack-surface-fatal-errors-and-close-deterministically")
              && valueField "status" known == Just (String knownStatus)
              && valueField "expectedFailures" known == Just (toJSON (["fenced-member-still-alive-and-idle"] :: [Text]))
          _ -> False
        expectedVerdict =
          object
            [ "replacementHandled" .= facts.replacementHandled,
              "fatalObserved" .= facts.fatalObserved,
              "originalExited" .= facts.originalExited,
              "errors" .= facts.errors
            ]
        agrees =
          valueField "scenarioRevision" document == Just (toJSON (1 :: Int))
            && valueField "failures" document == Just (toJSON facts.failures)
            && valueField "blocking" document == Just (Bool expectedBlocking)
            && valueField "exitCode" document == Just (toJSON expectedExitCode)
            && (source.result.resultSummaries >>= valueField "verdicts" >>= valueField "fencing") == Just expectedVerdict
            && knownAgrees
    Right
      Recomputation
        { agreesWithDocuments = agrees,
          outcome = Just outcome,
          comparisonVerdict = Nothing,
          detail = "recomputed fencing outcome and known-defect disposition from sealed worker control streams"
        }

releasedKafkaBinding :: CohortIdentity -> Either Text Bool
releasedKafkaBinding identity = case [package.resolvedPackageSource | component <- identity.identityComponents, package <- component.resolvedComponentPackages, package.resolvedPackageName == "hw-kafka-client"] of
  [FromHackage _] -> Right True
  [FromGit _ _ _] -> Right False
  _ -> Left "the cohort has no unique hw-kafka-client source"

readControlEvents :: FilePath -> IO (Either Text [Value])
readControlEvents path = do
  attempted <- try (ByteString.readFile path) :: IO (Either IOException ByteString.ByteString)
  pure case attempted of
    Left err -> Left (Text.pack (show err))
    Right bytes -> traverse (either (Left . Text.pack) Right . eitherDecodeStrict') (filter (not . ByteString.null) (ByteString.Char8.lines bytes))

valueField :: Text -> Value -> Maybe Value
valueField name (Object value) = KeyMap.lookup (Key.fromText name) value
valueField _ _ = Nothing

measurementRecomputer :: Recomputer
measurementRecomputer = Recomputer "kenshou-summary" 1 $ \root -> do
  measured <- summarizeRunDir root
  case measured of
    Left (SummaryError message) -> pure (Left message)
    Right summary -> do
      stored <- eitherDecodeFileStrict' (root </> "run-result.json") :: IO (Either String Value)
      pure case stored of
        Left message -> Left (Text.pack message)
        Right document ->
          Right
            Recomputation
              { agreesWithDocuments = storedMeasurements document == Just (toJSON summary),
                outcome = Nothing,
                comparisonVerdict = Nothing,
                detail = "recomputed kenshou.measurements/v1 from the sealed samples and series"
              }

storedMeasurements :: Value -> Maybe Value
storedMeasurements (Object result) = do
  Object summaries <- KeyMap.lookup "summaries" result
  Object measurements <- KeyMap.lookup "measurements" summaries
  KeyMap.lookup "measurements" measurements
storedMeasurements _ = Nothing

pairedComparisonRecomputer :: Recomputer
pairedComparisonRecomputer = Recomputer "paired-bootstrap-t-envelope" 1 $ \root -> do
  stored <- eitherDecodeFileStrict' (root </> "comparison.json") :: IO (Either String Value)
  case stored of
    Left message -> pure (Left (Text.pack message))
    Right document -> case comparisonInputs document of
      Left message -> pure (Left message)
      Right (policy, axes, pairs) -> do
        let baselines = [root </> "baseline" </> show index | index <- [0 .. pairs - 1]]
            candidates = [root </> "candidate" </> show index | index <- [0 .. pairs - 1]]
        verified <- forM (baselines <> candidates) $ \path -> do
          measured <- summarizeRunDir path
          result <- eitherDecodeFileStrict' (path </> "run-result.json") :: IO (Either String Value)
          pure case (measured, result) of
            (Right summary, Right value) | storedMeasurements value == Just (toJSON summary) -> Right ()
            (Left (SummaryError message), _) -> Left message
            (_, Left message) -> Left (Text.pack message)
            _ -> Left "arm measurements differ from the sealed samples and series"
        case sequence verified of
          Left message -> pure (Left message)
          Right _ -> do
            replayed <- compareRuns policy axes baselines candidates
            pure case replayed of
              Left (CompareError message) -> Left message
              Right comparison ->
                let actual = toJSON comparison
                    stableKeys = ["design", "baselineRuns", "candidateRuns", "algorithm", "policy", "variedFactors", "pairCount", "metrics", "reasons", "verdict", "exitCode"]
                    agrees = all (\key -> field key actual == field key document) stableKeys
                 in Right
                      Recomputation
                        { agreesWithDocuments = agrees,
                          outcome = Nothing,
                          comparisonVerdict = case field "verdict" actual of Just (String verdict) -> Just verdict; _ -> Nothing,
                          detail = "recomputed arm summaries and the paired comparison from sealed data"
                        }
  where
    field name (Object value) = KeyMap.lookup name value
    field _ _ = Nothing

comparisonInputs :: Value -> Either Text (Policy, NonEmpty.NonEmpty VaryingAxis, Int)
comparisonInputs (Object document) = do
  rawPolicy <- maybe (Left "comparison has no policy") Right (KeyMap.lookup "policy" document)
  policy <- case fromJSON rawPolicy of
    Error message -> Left (Text.pack message)
    Success value -> Right value
  rawAxes <- maybe (Left "comparison has no varied factors") Right (KeyMap.lookup "variedFactors" document)
  axisNames <- case fromJSON rawAxes of
    Error message -> Left (Text.pack message)
    Success value -> Right value
  axes <- traverse parseVaryingAxis axisNames >>= maybe (Left "comparison has no varied factors") Right . NonEmpty.nonEmpty
  rawPairs <- maybe (Left "comparison has no pair count") Right (KeyMap.lookup "pairCount" document)
  pairs <- case fromJSON rawPairs of
    Error message -> Left (Text.pack message)
    Success value -> Right value
  if pairs > 0 then Right (policy, axes, pairs) else Left "comparison pair count must be positive"
comparisonInputs _ = Left "comparison document is not an object"
