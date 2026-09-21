module Kenshou.Core.Compat
  ( CompatField (..),
    CompatInputs (..),
    compatInputs,
    comparisonKey,
    seriesKey,
    compatibleExcept,
  )
where

import Data.Aeson (ToJSON (..), Value, object, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Kenshou.Core.Canonical (canonicalEncode, sha256Hex)
import Kenshou.Core.Cohort (CohortIdentity (..), PlanHash (..))
import Kenshou.Core.Dimension (DimensionName (..), Dimensions (..))
import Kenshou.Core.Env (SchemaComponent)
import Kenshou.Core.Env.Postgres (PgSettingsSnapshot)
import Kenshou.Core.Knob (KnobName)
import Kenshou.Core.Knob qualified as Knob
import Kenshou.Core.RunSpec (EffectiveRunSpec (..), EnvironmentSpec (..))
import Kenshou.Core.Version (suiteVersion)

data CompatField
  = CfSuiteVersion
  | CfScenario
  | CfKnob KnobName
  | CfDimension DimensionName
  | CfPhases
  | CfMachineProfile
  | CfPostgresProfile
  | CfSchemas
  | CfCohort
  deriving stock (Eq, Show)

data CompatInputs = CompatInputs
  { suiteVersion :: Text,
    spec :: EffectiveRunSpec,
    postgres :: Maybe PgSettingsSnapshot,
    schemas :: [SchemaComponent],
    cohortPlanHash :: Text
  }
  deriving stock (Eq, Show)

compatInputs :: EffectiveRunSpec -> Maybe PgSettingsSnapshot -> [SchemaComponent] -> CohortIdentity -> CompatInputs
compatInputs spec postgres schemas cohort = CompatInputs suiteVersion spec postgres schemas (unPlanHash cohort.identityPlanHash)

comparisonKey :: CompatInputs -> Text
comparisonKey = sha256Hex . canonicalEncode . comparisonValue

seriesKey :: CompatInputs -> Text
seriesKey = sha256Hex . canonicalEncode . toJSON

compatibleExcept :: [CompatField] -> CompatInputs -> CompatInputs -> Either (NonEmpty CompatField) ()
compatibleExcept allowed left right = case filter (`notElem` allowed) (differences left right) of
  [] -> Right ()
  first : rest -> Left (first :| rest)

instance ToJSON CompatInputs where
  toJSON = compatibilityValue True

comparisonValue :: CompatInputs -> Value
comparisonValue = compatibilityValue False

compatibilityValue :: Bool -> CompatInputs -> Value
compatibilityValue includeCohort inputs =
  object $
    [ "suiteVersion" .= inputs.suiteVersion,
      "scenario" .= inputs.spec.scenario,
      "scenarioRevision" .= inputs.spec.scenarioRevision,
      "knobs" .= inputs.spec.knobs,
      "dimensions" .= inputs.spec.dimensions,
      "phases" .= inputs.spec.phases,
      "machineProfile" .= inputs.spec.environment.machineProfile,
      "postgresProfile" .= inputs.postgres,
      "schemas" .= fmap schemaText inputs.schemas
    ]
      <> ["cohortPlanHash" .= inputs.cohortPlanHash | includeCohort]
  where
    schemaText schema = case show schema of "SchemaKiroku" -> ("kiroku" :: Text); "SchemaKeiro" -> "keiro"; _ -> "pgmq"

differences :: CompatInputs -> CompatInputs -> [CompatField]
differences left right =
  [CfSuiteVersion | left.suiteVersion /= right.suiteVersion]
    <> [CfScenario | left.spec.scenario /= right.spec.scenario || left.spec.scenarioRevision /= right.spec.scenarioRevision]
    <> [CfPhases | left.spec.phases /= right.spec.phases]
    <> [CfMachineProfile | left.spec.environment.machineProfile /= right.spec.environment.machineProfile]
    <> [CfPostgresProfile | left.postgres /= right.postgres]
    <> [CfCohort | left.cohortPlanHash /= right.cohortPlanHash]
    <> [CfSchemas | left.schemas /= right.schemas]
    <> [CfDimension DimTracing | left.spec.dimensions.tracing /= right.spec.dimensions.tracing]
    <> [CfDimension DimMetrics | left.spec.dimensions.metrics /= right.spec.dimensions.metrics]
    <> [CfDimension DimPgDurability | left.spec.dimensions.pgDurability /= right.spec.dimensions.pgDurability]
    <> [CfDimension DimPgVersion | left.spec.dimensions.pgVersion /= right.spec.dimensions.pgVersion]
    <> [CfKnob name | name <- Set.toAscList knobNames, Map.lookup name leftKnobs /= Map.lookup name rightKnobs]
  where
    leftKnobs = Knob.resolvedKnobsMap left.spec.knobs
    rightKnobs = Knob.resolvedKnobsMap right.spec.knobs
    knobNames = Map.keysSet leftKnobs <> Map.keysSet rightKnobs
