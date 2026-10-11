module Kenshou.Perf.Result
  ( ConfigurationResult (..),
    PerfResult (..),
    ArtifactReference (..),
    aggregateResult,
    validateResult,
    semanticComparison,
  )
where

import Control.Monad (unless)
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.Types (Parser, parseEither)
import Data.List (nub, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Perf.Plan
import Kenshou.Perf.Request

-- Attempts include unsuccessful infrastructure attempts. Only the complete,
-- healthy comparison represented by comparison supplies validPairs.
data ConfigurationResult = ConfigurationResult
  { profile :: Text,
    workloadSha256 :: Text,
    performanceVerdict :: Text,
    infrastructureState :: Text,
    runtimeFailures :: [Text],
    validPairs :: Int,
    requiredPairs :: Int,
    attempts :: [Value],
    comparison :: Maybe Value
  }
  deriving stock (Eq, Show)

data PerfResult = PerfResult
  { requestSha256 :: Text,
    preparedSha256 :: Text,
    purpose :: Text,
    coverage :: Text,
    changeCoverage :: Text,
    performanceVerdict :: Text,
    infrastructureState :: Text,
    blockingRuntimeFailures :: [Text],
    gatingEligible :: Bool,
    configurations :: [ConfigurationResult],
    exclusions :: [(Text, Text)],
    uncoveredScenarios :: [Text],
    evidenceVerified :: Bool,
    exitCode :: Int,
    stageSeconds :: Map Text Double,
    artifactReferences :: [ArtifactReference]
  }
  deriving stock (Eq, Show)

-- The root manifest and retrieval receipt anchor their own digests externally,
-- avoiding a self-referential report. Other links carry an artifact digest.
data ArtifactReference = ArtifactReference {kind :: Text, uri :: Text, sha256 :: Maybe Text}
  deriving stock (Eq, Show)

instance ToJSON ArtifactReference where
  toJSON reference = object ["kind" .= reference.kind, "uri" .= reference.uri, "sha256" .= reference.sha256]

instance FromJSON ArtifactReference where
  parseJSON = withObject "PerformanceArtifactReference" \v -> do
    strictObject ["kind", "uri", "sha256"] v
    reference <- ArtifactReference <$> v .: "kind" <*> v .: "uri" <*> v .:? "sha256"
    unless (not (Text.null reference.kind) && "gs://" `Text.isPrefixOf` reference.uri && not (Text.any (`elem` ['\n', '\r', ' ', '?', '#']) reference.uri) && maybe True digest reference.sha256) (fail "invalid performance artifact reference")
    pure reference

-- An aggregate's ordinary exit mapping also applies to calibration exercises;
-- their purpose and gatingEligible fields keep them out of production gates.
aggregateResult :: PerfPlan -> Text -> Bool -> [ConfigurationResult] -> Either Text PerfResult
aggregateResult plan preparedDigest verified configurations = do
  mapM_ validateConfiguration configurations
  let expected = sort [entry.profile.name | entry <- plan.selected]
      supplied = map (.profile) configurations
  unless (nub supplied == supplied && all (`elem` expected) supplied) (Left "unexpected or duplicate configuration result")
  mapM_ checkBinding configurations
  let complete = sort supplied == expected && all ((/= "pending") . (.infrastructureState)) configurations
      scope = if plan.coverage == "not-applicable" then "not-applicable" else if plan.coverage == "complete" && complete then "complete" else "incomplete"
      blockers = concatMap (.runtimeFailures) configurations
      infrastructure = if not verified || any ((== "failed") . (.infrastructureState)) configurations then "failed" else if any ((== "pending") . (.infrastructureState)) configurations || not complete then "pending" else "healthy"
      regression = any ((== "regression") . (.performanceVerdict)) configurations
      accepted = all ((== "pass") . (.performanceVerdict)) configurations && (not (null configurations) || scope == "not-applicable")
      verdict = if scope == "not-applicable" then "not-applicable" else if regression then "regression" else if accepted && scope == "complete" && infrastructure == "healthy" then "pass" else "inconclusive"
      code = outcomeExit infrastructure blockers scope verdict
      eligible = plan.gatingEligible && code == 0 && verdict == "pass"
      result = PerfResult plan.requestSha256 preparedDigest plan.request.purpose scope plan.changeCoverage verdict infrastructure blockers eligible configurations plan.excluded plan.uncoveredScenarios verified code Map.empty []
  validateResult result
  pure result
  where
    checkBinding result = case filter ((== result.profile) . (.name) . (.profile)) plan.selected of
      [entry] -> unless (result.workloadSha256 == entry.workloadSha256 && result.requiredPairs == entry.profile.minimumPairs) (Left "configuration workload or fixed pair count differs from pinned plan")
      _ -> Left "configuration has no unique selected profile"

outcomeExit :: Text -> [Text] -> Text -> Text -> Int
outcomeExit infrastructure blockers scope verdict
  | infrastructure == "failed" = 4
  | not (null blockers) || verdict == "regression" = 1
  | infrastructure /= "healthy" || scope == "incomplete" || verdict == "inconclusive" = 3
  | otherwise = 0

validateResult :: PerfResult -> Either Text ()
validateResult result = do
  unless (digest result.requestSha256 && digest result.preparedSha256) (Left "invalid aggregate input digest")
  unless (result.purpose `elem` ["gating", "calibration"] && result.coverage `elem` ["complete", "incomplete", "not-applicable"] && result.changeCoverage `elem` ["complete", "incomplete", "not-applicable"] && result.performanceVerdict `elem` ["pass", "regression", "inconclusive", "not-applicable"]) (Left "invalid aggregate purpose, scope or verdict")
  unless (result.infrastructureState `elem` ["healthy", "pending", "failed"]) (Left "invalid aggregate infrastructure state")
  mapM_ validateConfiguration result.configurations
  unless (all (\seconds -> not (isNaN seconds || isInfinite seconds) && seconds >= 0) (Map.elems result.stageSeconds)) (Left "invalid performance stage timing")
  mapM_ (\reference -> case fromJSON (toJSON reference) :: Result ArtifactReference of Error problem -> Left (Text.pack problem); Success _ -> Right ()) result.artifactReferences
  let names = map (.profile) result.configurations
      blockers = concatMap (.runtimeFailures) result.configurations
      regression = any ((== "regression") . (.performanceVerdict)) result.configurations
  unless (nub names == names && result.blockingRuntimeFailures == blockers) (Left "aggregate duplicates configurations or omits runtime blockers")
  unless (result.exitCode == outcomeExit result.infrastructureState blockers result.coverage result.performanceVerdict) (Left "aggregate exit mapping mismatch")
  unless (result.evidenceVerified || result.infrastructureState == "failed") (Left "unverified publication must be an infrastructure failure")
  unless (not (any ((== "failed") . (.infrastructureState)) result.configurations) || result.infrastructureState == "failed") (Left "aggregate hides unresolved infrastructure failure")
  unless (not regression || result.performanceVerdict == "regression") (Left "aggregate hides a regression")
  unless (not result.gatingEligible || (result.purpose == "gating" && result.exitCode == 0 && result.performanceVerdict == "pass")) (Left "ineligible aggregate claims a production gate")
  unless (result.performanceVerdict /= "pass" || (result.coverage == "complete" && result.infrastructureState == "healthy" && not (null result.configurations) && all ((== "pass") . (.performanceVerdict)) result.configurations)) (Left "aggregate performance pass lacks complete healthy evidence")
  unless (result.performanceVerdict /= "not-applicable" || (result.coverage == "not-applicable" && null result.configurations)) (Left "not-applicable aggregate contains executed configurations")

validateConfiguration :: ConfigurationResult -> Either Text ()
validateConfiguration result = do
  unless (not (Text.null result.profile) && digest result.workloadSha256 && result.requiredPairs >= 5 && result.validPairs >= 0 && result.validPairs <= result.requiredPairs) (Left "invalid configuration identity or pair count")
  unless (result.performanceVerdict `elem` ["pass", "regression", "inconclusive", "not-run"] && result.infrastructureState `elem` ["healthy", "pending", "failed"]) (Left "invalid configuration outcome")
  unless (result.performanceVerdict `notElem` ["pass", "regression"] || (result.validPairs == result.requiredPairs && result.infrastructureState == "healthy")) (Left "statistical verdict lacks complete healthy pairs")
  case result.comparison of
    Nothing -> unless (result.performanceVerdict `elem` ["inconclusive", "not-run"]) (Left "statistical verdict lacks its retained comparison")
    Just document ->
      either
        (Left . Text.pack)
        Right
        ( parseEither
            ( withObject "RetainedComparison" \v -> do
                schema <- v .: "schema"
                verdict <- v .: "verdict"
                count <- v .: "pairCount"
                let sameVerdict = verdict == result.performanceVerdict || (verdict == "infrastructure-failure" && result.infrastructureState == "failed" && result.performanceVerdict == "inconclusive")
                unless (schema == ("kenshou.comparison/v1" :: Text) && sameVerdict && count == result.validPairs) (fail "retained comparison differs from configuration result")
            )
            document
        )

digest :: Text -> Bool
digest value = "sha256:" `Text.isPrefixOf` value && Text.length value == 71 && Text.all (`elem` (['0' .. '9'] <> ['a' .. 'f'])) (Text.drop 7 value)

-- Reanalysis creates a new analysis ID, clock and host fingerprint. Compare the
-- evidence identities and calculation instead; preserve original sealed bytes.
semanticComparison :: Value -> Either Text Value
semanticComparison document = either (Left . Text.pack) Right (parseEither parser document)
  where
    parser = withObject "Comparison" \v -> do
      schema <- v .: "schema"
      unless (schema == ("kenshou.comparison/v1" :: Text)) (fail "unsupported retained comparison")
      fields <-
        traverse
          (\name -> (Key.fromText name,) <$> (v .: Key.fromText name :: Parser Value))
          ["schema", "design", "baselineRuns", "candidateRuns", "algorithm", "policy", "variedFactors", "pairCount", "metrics", "reasons", "verdict", "exitCode"]
      pure (object fields)

instance ToJSON ConfigurationResult where
  toJSON result = object ["profile" .= result.profile, "workloadSha256" .= result.workloadSha256, "performanceVerdict" .= result.performanceVerdict, "infrastructureState" .= result.infrastructureState, "runtimeFailures" .= result.runtimeFailures, "validPairs" .= result.validPairs, "requiredPairs" .= result.requiredPairs, "attempts" .= result.attempts, "comparison" .= result.comparison]

instance FromJSON ConfigurationResult where
  parseJSON = withObject "ConfigurationResult" \v -> do
    strictObject ["profile", "workloadSha256", "performanceVerdict", "infrastructureState", "runtimeFailures", "validPairs", "requiredPairs", "attempts", "comparison"] v
    result <- ConfigurationResult <$> v .: "profile" <*> v .: "workloadSha256" <*> v .: "performanceVerdict" <*> v .: "infrastructureState" <*> v .: "runtimeFailures" <*> v .: "validPairs" <*> v .: "requiredPairs" <*> v .: "attempts" <*> v .:? "comparison"
    either (fail . Text.unpack) pure (validateConfiguration result)
    pure result

instance ToJSON PerfResult where
  toJSON result = object ["schema" .= ("kenshou.perf-result/v1" :: Text), "requestSha256" .= result.requestSha256, "preparedSha256" .= result.preparedSha256, "purpose" .= result.purpose, "coverage" .= result.coverage, "changeCoverage" .= result.changeCoverage, "performanceVerdict" .= result.performanceVerdict, "infrastructureState" .= result.infrastructureState, "blockingRuntimeFailures" .= result.blockingRuntimeFailures, "gatingEligible" .= result.gatingEligible, "configurations" .= result.configurations, "exclusions" .= [object ["profile" .= name, "reason" .= reason] | (name, reason) <- result.exclusions], "uncoveredScenarios" .= result.uncoveredScenarios, "evidenceVerified" .= result.evidenceVerified, "exitCode" .= result.exitCode, "stageSeconds" .= result.stageSeconds, "artifactReferences" .= result.artifactReferences]

instance FromJSON PerfResult where
  parseJSON = withObject "PerfResult" \v -> do
    strictObject ["schema", "requestSha256", "preparedSha256", "purpose", "coverage", "changeCoverage", "performanceVerdict", "infrastructureState", "blockingRuntimeFailures", "gatingEligible", "configurations", "exclusions", "uncoveredScenarios", "evidenceVerified", "exitCode", "stageSeconds", "artifactReferences"] v
    schema <- v .: "schema"
    unless (schema == ("kenshou.perf-result/v1" :: Text)) (fail "unsupported performance result schema")
    exclusions <-
      v .: "exclusions"
        >>= traverse
          ( withObject "Exclusion" \e -> do
              strictObject ["profile", "reason"] e
              (,) <$> e .: "profile" <*> e .: "reason"
          )
    result <- PerfResult <$> v .: "requestSha256" <*> v .: "preparedSha256" <*> v .: "purpose" <*> v .: "coverage" <*> v .: "changeCoverage" <*> v .: "performanceVerdict" <*> v .: "infrastructureState" <*> v .: "blockingRuntimeFailures" <*> v .: "gatingEligible" <*> v .: "configurations" <*> pure exclusions <*> v .: "uncoveredScenarios" <*> v .: "evidenceVerified" <*> v .: "exitCode" <*> (v .:? "stageSeconds" .!= Map.empty) <*> (v .:? "artifactReferences" .!= [])
    either (fail . Text.unpack) pure (validateResult result)
    pure result
