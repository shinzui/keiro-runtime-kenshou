module Kenshou.Core.RunResult
  ( RunResult (..),
    KnownDefectStatus (..),
  )
where

import Data.Aeson hiding (Error)
import Data.Aeson.Key qualified as Key
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (UTCTime)
import Data.Word (Word64)
import Kenshou.Core.Cohort (CohortIdentity)
import Kenshou.Core.Context (Observation (..), PhaseTiming, SummarySection (..))
import Kenshou.Core.Id (RunId, ScenarioId (..), renderKind, renderLayer, renderScenarioId, unSegment)
import Kenshou.Core.Log (Severity (..))
import Kenshou.Core.Outcome (Outcome)
import Kenshou.Core.RunSpec (ComparisonMembership)
import Kenshou.Core.Scenario (KnownDefect (..), Tier, renderTier)

data KnownDefectStatus = DefectReproduced | DefectDifferentFailure | DefectNotReproduced deriving stock (Eq, Show)

data RunResult = RunResult
  { runId :: RunId,
    scenario :: ScenarioId,
    scenarioRevision :: Int,
    tier :: Tier,
    outcome :: Outcome,
    blocking :: Bool,
    exitCode :: Int,
    reason :: Maybe Text,
    failures :: [Text],
    knownDefect :: Maybe (KnownDefect, KnownDefectStatus),
    seed :: Word64,
    specSha256 :: Text,
    comparison :: Maybe ComparisonMembership,
    startedAt :: UTCTime,
    endedAt :: UTCTime,
    durationSeconds :: Double,
    phases :: [PhaseTiming],
    cohort :: CohortIdentity,
    fingerprint :: Value,
    compatibility :: Value,
    summaries :: Map SummarySection (Map Text Value),
    observations :: [Observation],
    invocation :: Value
  }
  deriving stock (Eq, Show)

instance ToJSON RunResult where
  toJSON result =
    object
      [ "schema" .= ("kenshou.run-result/v1" :: Text),
        "runId" .= result.runId,
        "scenario" .= renderScenarioId result.scenario,
        "scenarioRevision" .= result.scenarioRevision,
        "layer" .= renderLayer result.scenario.layer,
        "component" .= unSegment result.scenario.component,
        "kind" .= renderKind result.scenario.kind,
        "tier" .= renderTier result.tier,
        "outcome" .= result.outcome,
        "blocking" .= result.blocking,
        "exitCode" .= result.exitCode,
        "reason" .= result.reason,
        "failures" .= result.failures,
        "knownDefect" .= fmap knownDefectValue result.knownDefect,
        "seed" .= result.seed,
        "spec" .= object ["path" .= ("run-spec.json" :: Text), "sha256" .= result.specSha256],
        "comparison" .= result.comparison,
        "timings" .= object ["clock" .= ("GHC.Clock.getMonotonicTimeNSec" :: Text), "startedAt" .= result.startedAt, "endedAt" .= result.endedAt, "durationSeconds" .= result.durationSeconds, "phases" .= result.phases],
        "cohort" .= result.cohort,
        "fingerprint" .= result.fingerprint,
        "compatibility" .= result.compatibility,
        "summaries" .= summaryValue result.summaries,
        "observations" .= fmap observationValue result.observations,
        "invocation" .= result.invocation
      ]

knownDefectValue :: (KnownDefect, KnownDefectStatus) -> Value
knownDefectValue (defect, status) = object ["reference" .= defect.reference, "summary" .= defect.summary, "expectedFailures" .= defect.expectedFailures, "status" .= statusText status]

statusText :: KnownDefectStatus -> Text
statusText DefectReproduced = "reproduced"
statusText DefectDifferentFailure = "different-failure"
statusText DefectNotReproduced = "not-reproduced"

summaryValue :: Map SummarySection (Map Text Value) -> Value
summaryValue summaries =
  object
    [ "measurements" .= section Measurements,
      "verdicts" .= section Verdicts,
      "diagnosis" .= section Diagnosis,
      "telemetry" .= section Telemetry
    ]
  where
    section name = object [Key.fromText key .= value | (key, value) <- Map.toAscList (Map.findWithDefault Map.empty name summaries)]

observationValue :: Observation -> Value
observationValue observation = object ["source" .= observation.source, "severity" .= severityText observation.severity, "message" .= observation.message, "at" .= observation.at]

severityText :: Severity -> Text
severityText Debug = "debug"
severityText Info = "info"
severityText Warning = "warning"
severityText Error = "error"
