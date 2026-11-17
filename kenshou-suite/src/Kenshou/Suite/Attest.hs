{-# LANGUAGE CPP #-}

module Kenshou.Suite.Attest (FencingFacts (..), fencingFacts, runOutcomeRecomputer, measurementRecomputer, pairedComparisonRecomputer) where

import Control.Exception (IOException, try)
import Data.Aeson (Result (..), Value (..), eitherDecodeFileStrict', eitherDecodeStrict', fromJSON, object, toJSON, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString.Char8
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Cli.Attest (measurementRecomputer, pairedComparisonRecomputer)
#ifdef FULL_RUNTIME_SUITES
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
import Kenshou.Cli.Attest.KeiroZombie (recomputeZombie)
#endif
import Kenshou.Core.Cohort (CohortIdentity (..), PackageSource (..), ResolvedComponent (..), ResolvedPackage (..))
import Kenshou.Core.Id (renderScenarioId)
import Kenshou.Core.Outcome (Outcome (..), outcomeExitCode)
import Kenshou.Evidence.Attest (Recomputation (..), Recomputer (..), coreRecomputers)
import Kenshou.Evidence.Source (RunResultView (..), RunSource (..), loadRunSource)
import System.FilePath ((</>))

runOutcomeRecomputer :: Recomputer
runOutcomeRecomputer = Recomputer "run-outcome" 1 $ \root -> do
  loaded <- loadRunSource root
  case loaded of
    Left err -> pure (Left (Text.pack (show err)))
    Right source -> case lookup (renderScenarioId source.result.resultScenario) runtimeRecomputers of
      Just recompute -> recompute root source
      Nothing -> case coreRecomputers of
        core : _ -> core.recompute root
        [] -> pure (Left "the core outcome oracle is unavailable")

runtimeRecomputers :: [(Text, FilePath -> RunSource -> IO (Either Text Recomputation))]
runtimeRecomputers = [("kafka/consumer/concurrency/static-membership-fencing-is-observable", fencingRecomputation)] <> keiroRecomputers

keiroRecomputers :: [(Text, FilePath -> RunSource -> IO (Either Text Recomputation))]
#ifdef FULL_RUNTIME_SUITES
keiroRecomputers = [("keiro/queue/concurrency/lease-extension", recomputeLease),
  ("keiro/inbox/correctness/effectively-once-matrix", recomputeInbox),
  ("keiro/inbox/correctness/batch-fast-path-and-fallback", recomputeBatch),
  ("keiro/inbox/correctness/poison-accounting", recomputePoison),
  ("keiro/queue/concurrency/workers-survive-transient-polling-error", recomputeQueuePolling),
  ("keiro/queue/concurrency/fifo-heads-strict-order", recomputeQueueOrdering),
  ("keiro/queue/correctness/job-outcome-semantics", recomputeQueueOutcomes),
  ("keiro/queue/correctness/consumption-config-rejections", recomputeQueueConfig),
  ("keiro/outbox/correctness/producer-identity", recomputeProducerIdentity),
  ("keiro/outbox/correctness/terminal-state-matrix", recomputeTerminal),
  ("keiro/outbox/concurrency/zombie-publisher-finalization", recomputeZombie)]
#else
keiroRecomputers = []
#endif

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
