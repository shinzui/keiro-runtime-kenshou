{-# LANGUAGE FieldSelectors #-}

module Kenshou.Perf.Plan
  ( RequiredMetric (..),
    PerfProfile (..),
    ProfileCatalog (..),
    PlannedProfile (..),
    PerfPlan (..),
    validateProfile,
    workloadDigest,
    planPerformance,
    conservativeChanges,
  )
where

import Control.Monad (unless)
import Data.Aeson
import Data.List (nub, sort, sortOn)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Canonical (canonicalEncode, sha256Hex)
import Kenshou.Core.Dimension (Dimensions (..), PgDurability (..), renderDimensions, resolveDimensions)
import Kenshou.Core.Id (Kind (..), ScenarioId (..), renderScenarioId)
import Kenshou.Core.Knob
import Kenshou.Perf.Request
import Kenshou.Plan.Catalog qualified as Catalog
import Kenshou.Plan.Change
import Kenshou.Plan.Components

data RequiredMetric = RequiredMetric {name :: Text, unit :: Text, minimumSteadySamples :: Int}
  deriving stock (Eq, Show)

data PerfProfile = PerfProfile
  { name :: Text,
    revision :: Int,
    scenario :: Text,
    scenarioRevision :: Int,
    knobs :: Map Text Value,
    dimensions :: Map Text Text,
    workloadPurpose :: Text,
    warmupSeconds :: Int,
    steadyCount :: Int,
    cooldownSeconds :: Int,
    timeoutSeconds :: Int,
    cachePolicy :: Text,
    policy :: FilePath,
    requiredMetrics :: [RequiredMetric],
    capabilities :: [Text],
    machineProfile :: Text,
    trialSeconds :: Int,
    resetSeconds :: Int,
    sealSeconds :: Int,
    minimumPairs :: Int,
    replacementPairs :: Int,
    calibration :: Maybe Value
  }
  deriving stock (Eq, Show)

newtype ProfileCatalog = ProfileCatalog {profiles :: [PerfProfile]}
  deriving stock (Eq, Show)

data PlannedProfile = PlannedProfile
  { profile :: PerfProfile,
    workloadSha256 :: Text,
    effectiveKnobs :: ResolvedKnobs,
    reasons :: [Value],
    estimateSeconds :: Integer
  }
  deriving stock (Eq, Show)

data PerfPlan = PerfPlan
  { request :: PerfRequest,
    requestSha256 :: Text,
    graphSha256 :: Text,
    catalogSha256 :: Text,
    profileCatalogSha256 :: Text,
    selected :: [PlannedProfile],
    excluded :: [(Text, Text)],
    affectedScenarios :: [Text],
    uncoveredScenarios :: [Text],
    unmappedPaths :: [FilePath],
    documentationProof :: [FilePath],
    coverage :: Text,
    changeCoverage :: Text,
    estimateSeconds :: Integer,
    gatingEligible :: Bool
  }
  deriving stock (Eq, Show)

-- Calibration references are deliberately excluded from the workload identity.
-- Attaching evidence to an unchanged workload must not create a digest cycle.
workloadDigest :: PerfProfile -> Text -> Text
workloadDigest profile policyDigest = sha256Hex (canonicalEncode (object ["workload" .= profile {calibration = Nothing}, "policySha256" .= policyDigest]))

validateProfile :: [Catalog.ScenarioInfo] -> PerfProfile -> Either Text ResolvedKnobs
validateProfile catalog profile = do
  scenario <- case filter ((== profile.scenario) . renderScenarioId . (.id)) catalog of
    [value] -> Right value
    _ -> Left ("profile names an unknown or duplicate scenario: " <> profile.scenario)
  require (scenario.id.kind == Benchmark && scenario.revision == profile.scenarioRevision) "profile scenario revision/kind mismatch"
  require (profile.revision > 0 && not (Text.null profile.name) && Text.all (`elem` (['a' .. 'z'] <> ['0' .. '9'] <> ['-'])) profile.name) "invalid profile identity"
  require (profile.workloadPurpose == "fixed-load-latency") "unsupported workload purpose; paced throughput is not capacity"
  -- These two revisions implement count-bound steady work, not timed phases.
  require
    ( (profile.scenario, profile.scenarioRevision)
        `elem` [("shibuya/core-ordering/benchmark/concurrency-sweep", 2), ("shibuya/pgmq-adapter/benchmark/end-to-end-throughput-latency", 1)]
    )
    "scenario phase contract has not been reviewed"
  require (profile.warmupSeconds == 0 && profile.cooldownSeconds == 0 && profile.timeoutSeconds == 180) "scenario revision does not honor requested phases/timeout"
  require (profile.cachePolicy == "cold-reset") "unsupported cache policy"
  require (profile.minimumPairs >= 5 && profile.replacementPairs >= 0 && profile.replacementPairs <= 2) "invalid fixed pair/replacement allowance"
  require (profile.trialSeconds > 0 && profile.resetSeconds >= 0 && profile.sealSeconds >= 0) "cost estimate needs positive trial time and nonnegative overheads"
  require (not (null profile.requiredMetrics) && nub (map (.name) profile.requiredMetrics) == map (.name) profile.requiredMetrics) "required metrics must be nonempty and unique"
  require (all (\metric -> not (Text.null metric.name) && not (Text.null metric.unit) && metric.minimumSteadySamples > 0) profile.requiredMetrics) "invalid required metric"
  require (all ((<= profile.steadyCount) . (.minimumSteadySamples)) profile.requiredMetrics) "required sample count exceeds planned work"
  require (not (Text.null profile.machineProfile) && not (null profile.capabilities)) "profile needs a machine profile and cell capabilities"
  assignments <- traverse (\(key, value) -> (,RawJson value) <$> mkKnobName key) (Map.toAscList profile.knobs)
  resolved <- either (Left . Text.pack . show) Right (resolveKnobs scenario.knobs assignments)
  dimensionValues <- either (Left . Text.pack . show) Right (resolveDimensions scenario.dimensions (Map.toAscList profile.dimensions))
  require (dimensionValues.pgDurability /= Just PgFsyncOff) "performance profiles require durable PostgreSQL"
  messageKnob <- mkKnobName "shibuya.messages"
  rawKnob <- mkKnobName "measure.raw-samples"
  require (Map.lookup messageKnob (resolvedKnobsMap resolved) == Just (VInt (fromIntegral profile.steadyCount))) "profile steady count disagrees with effective workload"
  require (Map.lookup rawKnob (resolvedKnobsMap resolved) == Just (VText "full")) "performance profiles require full raw samples"
  rateKnob <- mkKnobName "bench.rate"
  let offeredRate = case Map.lookup rateKnob (resolvedKnobsMap resolved) of Just (VInt rate) -> rate; _ -> 0
  require (offeredRate > 0 && fromIntegral profile.trialSeconds * offeredRate >= fromIntegral profile.steadyCount) "trial estimate is shorter than the declared offered workload"
  pure resolved
  where
    require condition message = unless condition (Left (profile.name <> ": " <> message))

-- Paths absent from the graph are not a documentation proof. Only explicit
-- documentation names outside all source roots can be excluded safely.
conservativeChanges :: ComponentGraph -> Text -> [FilePath] -> [Change] -> ([Change], [FilePath], [FilePath])
conservativeChanges graph repository paths mapped = (changes, unknown, documentation)
  where
    components = filter ((== repository) . (.repository)) graph.components
    inRoot path = any (\component -> any (\root -> Text.pack root `Text.isPrefixOf` Text.pack path) component.sourceRoots) components
    isDocumentation path = not (inRoot path) && ("docs/" `Text.isPrefixOf` Text.pack path || path `elem` ["README.md", "CHANGELOG.md", "LICENSE", "LICENSE.md"])
    documentation = filter isDocumentation paths
    unknown = filter (\path -> not (inRoot path) && not (isDocumentation path)) paths
    changes =
      if null components || not (null unknown)
        then mapped <> [Change (ComponentRef (ComponentId "all") Nothing) Everything "unmapped upstream input; conservative selection"]
        else mapped

-- The admission map is populated only by an evidence verifier, never by a
-- catalog's self-asserted calibrated flag. It maps workload digest to verified
-- calibration evidence digest. A catalog link cannot populate this map without
-- full receipt retrieval, raw report replay and acceptance-batch verification.
planPerformance :: PerfRequest -> ComponentGraph -> [Catalog.ScenarioInfo] -> ProfileCatalog -> [Change] -> [FilePath] -> [FilePath] -> Map Text Text -> Map Text Text -> Either Text PerfPlan
planPerformance request graph catalog profiles changes unknown documentation policyDigests admitted = do
  validateRequest request
  unless (nub profileNames == profileNames) (Left "duplicate performance profile")
  unless (all (`elem` profileNames) request.profiles) (Left "unknown requested performance profile")
  checked <- traverse check (sortOn (.name) profiles.profiles)
  let affected = selectScenarios graph catalog changes
      affectedNames = sort (map (renderScenarioId . (.id) . (.scenario)) affected)
      candidates = filter (wanted affectedNames) checked
      (selected, excluded, _) = foldl admit ([], [], 0) candidates
      covered = map (.scenario) (map (.profile) selected)
      telemetryMissing = [renderScenarioId item.scenario.id | item <- affected, item.minPolicy == Just "telemetry-corners", not (any (coversTelemetry item) selected)]
      uncovered = nub (filter (`notElem` covered) affectedNames <> telemetryMissing)
      notApplicable = request.control == "none" && null changes && null unknown && not (null documentation) && null request.profiles
      scopeComplete = if request.coverageMode == "selected-profiles" then sort (map (.name) (map (.profile) selected)) == sort request.profiles else null uncovered && not (null selected)
      scope = if notApplicable then "not-applicable" else if scopeComplete && null excluded then "complete" else "incomplete"
  pure
    PerfPlan
      { request,
        requestSha256 = requestDigest request,
        graphSha256 = graphDigest graph,
        catalogSha256 = sha256Hex (canonicalEncode (toJSON catalog)),
        profileCatalogSha256 = sha256Hex (canonicalEncode (toJSON profiles)),
        selected,
        excluded,
        affectedScenarios = affectedNames,
        uncoveredScenarios = uncovered,
        unmappedPaths = unknown,
        documentationProof = documentation,
        coverage = scope,
        changeCoverage = if notApplicable then "not-applicable" else if null uncovered && not (null affectedNames) then "complete" else "incomplete",
        estimateSeconds = sum (map (.estimateSeconds) selected),
        gatingEligible = request.purpose == "gating" && scope == "complete" && all (\item -> Map.member item.workloadSha256 admitted) selected
      }
  where
    profileNames = map (.name) profiles.profiles
    check profile = do
      effective <- validateProfile catalog profile
      scenario <- case filter ((== profile.scenario) . renderScenarioId . (.id)) catalog of
        [value] -> Right value
        _ -> Left "profile scenario is missing"
      effectiveDimensions <- either (Left . Text.pack . show) Right (resolveDimensions scenario.dimensions (Map.toAscList profile.dimensions))
      let normalized =
            (profile :: PerfProfile)
              { knobs = Map.fromList [(renderKnobName name, toJSON value) | (name, value) <- Map.toAscList (resolvedKnobsMap effective)],
                dimensions = Map.fromList (renderDimensions effectiveDimensions)
              }
      policyDigest <- maybe (Left ("missing policy digest: " <> Text.pack profile.policy)) Right (Map.lookup (Text.pack profile.policy) policyDigests)
      pure (normalized, (effective, workloadDigest normalized policyDigest))
    wanted affected (profile, _) = (null request.profiles || profile.name `elem` request.profiles) && (request.control == "aa" || request.coverageMode == "selected-profiles" || profile.scenario `elem` affected)
    admit (selected, excluded, spent) (profile, (effective, digest))
      | request.purpose /= "calibration" && Map.notMember digest admitted = (selected, excluded <> [(profile.name, "uncalibrated")], spent)
      | spent + cost > fromIntegral request.budgetMinutes * 60 = (selected, excluded <> [(profile.name, "over-budget")], spent)
      | otherwise = (selected <> [PlannedProfile profile digest effective reasons cost], excluded, spent + cost)
      where
        cost = 2 * (fromIntegral profile.minimumPairs + fromIntegral profile.replacementPairs) * (fromIntegral profile.trialSeconds + fromIntegral profile.resetSeconds + fromIntegral profile.sealSeconds)
        reasons =
          [toJSON reason | item <- selectScenarios graph catalog changes, renderScenarioId item.scenario.id == profile.scenario, reason <- NonEmpty.toList item.reasons]
            <> [ object
                   [ "component" .= ("request/profile/" <> profile.name),
                     "source" .= ("named" :: Text),
                     "via" .= [if request.control == "aa" then "aa-control" else "selected-profiles" :: Text],
                     "selector" .= profile.scenario,
                     "distance" .= (0 :: Int)
                   ]
               | profile.name `elem` request.profiles
               ]
    coversTelemetry item selected =
      selected.profile.scenario == renderScenarioId item.scenario.id
        && Map.lookup "telemetry.tracing" selected.profile.dimensions `elem` [Just "sdk-inmemory", Just "sdk-otlp"]
        && Map.lookup "telemetry.metrics" selected.profile.dimensions `elem` [Just "collect", Just "serve", Just "serve-scraped"]

instance ToJSON RequiredMetric where
  toJSON metric = object ["name" .= metric.name, "unit" .= metric.unit, "minimumSteadySamples" .= metric.minimumSteadySamples]

instance FromJSON RequiredMetric where
  parseJSON = withObject "RequiredMetric" \value -> do
    strictObject ["name", "unit", "minimumSteadySamples"] value
    RequiredMetric <$> value .: "name" <*> value .: "unit" <*> value .: "minimumSteadySamples"

instance ToJSON PerfProfile where
  toJSON profile =
    object
      [ "name" .= profile.name,
        "revision" .= profile.revision,
        "scenario" .= profile.scenario,
        "scenarioRevision" .= profile.scenarioRevision,
        "knobs" .= profile.knobs,
        "dimensions" .= profile.dimensions,
        "workloadPurpose" .= profile.workloadPurpose,
        "warmupSeconds" .= profile.warmupSeconds,
        "steadyCount" .= profile.steadyCount,
        "cooldownSeconds" .= profile.cooldownSeconds,
        "timeoutSeconds" .= profile.timeoutSeconds,
        "cachePolicy" .= profile.cachePolicy,
        "policy" .= profile.policy,
        "requiredMetrics" .= profile.requiredMetrics,
        "capabilities" .= profile.capabilities,
        "machineProfile" .= profile.machineProfile,
        "trialSeconds" .= profile.trialSeconds,
        "resetSeconds" .= profile.resetSeconds,
        "sealSeconds" .= profile.sealSeconds,
        "minimumPairs" .= profile.minimumPairs,
        "replacementPairs" .= profile.replacementPairs,
        "calibration" .= profile.calibration
      ]

instance FromJSON PerfProfile where
  parseJSON = withObject "PerfProfile" \value -> do
    strictObject ["name", "revision", "scenario", "scenarioRevision", "knobs", "dimensions", "workloadPurpose", "warmupSeconds", "steadyCount", "cooldownSeconds", "timeoutSeconds", "cachePolicy", "policy", "requiredMetrics", "capabilities", "machineProfile", "trialSeconds", "resetSeconds", "sealSeconds", "minimumPairs", "replacementPairs", "calibration"] value
    PerfProfile
      <$> value .: "name"
      <*> value .: "revision"
      <*> value .: "scenario"
      <*> value .: "scenarioRevision"
      <*> value .: "knobs"
      <*> value .: "dimensions"
      <*> value .: "workloadPurpose"
      <*> value .: "warmupSeconds"
      <*> value .: "steadyCount"
      <*> value .: "cooldownSeconds"
      <*> value .: "timeoutSeconds"
      <*> value .: "cachePolicy"
      <*> value .: "policy"
      <*> value .: "requiredMetrics"
      <*> value .: "capabilities"
      <*> value .: "machineProfile"
      <*> value .: "trialSeconds"
      <*> value .: "resetSeconds"
      <*> value .: "sealSeconds"
      <*> value .: "minimumPairs"
      <*> value .: "replacementPairs"
      <*> value .:? "calibration"

instance ToJSON ProfileCatalog where
  toJSON catalog = object ["schema" .= ("kenshou.perf-catalog/v1" :: Text), "profiles" .= catalog.profiles]

instance FromJSON ProfileCatalog where
  parseJSON = withObject "ProfileCatalog" \value -> do
    strictObject ["schema", "profiles"] value
    schema <- value .: "schema"
    unless (schema == ("kenshou.perf-catalog/v1" :: Text)) (fail "unsupported performance catalog schema")
    ProfileCatalog <$> value .: "profiles"

instance ToJSON PlannedProfile where
  toJSON planned = object ["profile" .= planned.profile, "workloadSha256" .= planned.workloadSha256, "effectiveKnobs" .= planned.effectiveKnobs, "reasons" .= planned.reasons, "estimateSeconds" .= planned.estimateSeconds]

instance ToJSON PerfPlan where
  toJSON plan =
    object
      [ "schema" .= ("kenshou.perf-plan/v1" :: Text),
        "request" .= plan.request,
        "requestSha256" .= plan.requestSha256,
        "graphSha256" .= plan.graphSha256,
        "catalogSha256" .= plan.catalogSha256,
        "profileCatalogSha256" .= plan.profileCatalogSha256,
        "selected" .= plan.selected,
        "excluded" .= [object ["profile" .= name, "reason" .= reason] | (name, reason) <- plan.excluded],
        "affectedScenarios" .= plan.affectedScenarios,
        "uncoveredScenarios" .= plan.uncoveredScenarios,
        "unmappedPaths" .= plan.unmappedPaths,
        "documentationProof" .= plan.documentationProof,
        "coverage" .= plan.coverage,
        "changeCoverage" .= plan.changeCoverage,
        "estimateSeconds" .= plan.estimateSeconds,
        "gatingEligible" .= plan.gatingEligible
      ]

instance FromJSON PlannedProfile where
  parseJSON = withObject "PlannedProfile" \value -> do
    strictObject ["profile", "workloadSha256", "effectiveKnobs", "reasons", "estimateSeconds"] value
    planned <- PlannedProfile <$> value .: "profile" <*> value .: "workloadSha256" <*> value .: "effectiveKnobs" <*> value .: "reasons" <*> value .: "estimateSeconds"
    unless (planned.estimateSeconds > 0) (fail "invalid planned configuration estimate")
    pure planned

instance FromJSON PerfPlan where
  parseJSON = withObject "PerfPlan" \value -> do
    strictObject ["schema", "request", "requestSha256", "graphSha256", "catalogSha256", "profileCatalogSha256", "selected", "excluded", "affectedScenarios", "uncoveredScenarios", "unmappedPaths", "documentationProof", "coverage", "changeCoverage", "estimateSeconds", "gatingEligible"] value
    schema <- value .: "schema"
    unless (schema == ("kenshou.perf-plan/v1" :: Text)) (fail "unsupported performance plan schema")
    omissions <-
      value .: "excluded"
        >>= traverse
          ( withObject "ExcludedProfile" \item -> do
              strictObject ["profile", "reason"] item
              (,) <$> item .: "profile" <*> item .: "reason"
          )
    plan <- PerfPlan <$> value .: "request" <*> value .: "requestSha256" <*> value .: "graphSha256" <*> value .: "catalogSha256" <*> value .: "profileCatalogSha256" <*> value .: "selected" <*> pure omissions <*> value .: "affectedScenarios" <*> value .: "uncoveredScenarios" <*> value .: "unmappedPaths" <*> value .: "documentationProof" <*> value .: "coverage" <*> value .: "changeCoverage" <*> value .: "estimateSeconds" <*> value .: "gatingEligible"
    unless (plan.requestSha256 == requestDigest plan.request) (fail "performance plan request digest mismatch")
    unless (plan.estimateSeconds == sum (map (.estimateSeconds) plan.selected) && plan.estimateSeconds <= fromIntegral plan.request.budgetMinutes * 60) (fail "performance plan estimate mismatch or budget exceeded")
    unless (all (`elem` ["complete", "incomplete", "not-applicable"]) [plan.coverage, plan.changeCoverage]) (fail "unknown performance coverage")
    unless (nub (map (.name) (map (.profile) plan.selected)) == map (.name) (map (.profile) plan.selected)) (fail "duplicate selected performance profile")
    unless (not plan.gatingEligible || plan.request.purpose == "gating" && plan.coverage == "complete" && not (null plan.selected)) (fail "invalid gating eligibility")
    pure plan
