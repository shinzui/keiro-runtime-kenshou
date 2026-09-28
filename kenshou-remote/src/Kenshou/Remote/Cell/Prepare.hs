module Kenshou.Remote.Cell.Prepare
  ( Granularity (..),
    RejectReason (..),
    PrepareOptions (..),
    Prepared (..),
    Routed (..),
    PreparedRun (..),
    Slice (..),
    OtlpSink (..),
    SubmissionInputs (..),
    sliceRuns,
    slicePlan,
    submissionFor,
    prepareForCell,
    routePlan,
    routePlanWithoutPayload,
  )
where

import Data.Aeson (eitherDecode, encode)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Int (Int64)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing)
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Bundle (Registry, lookupScenario)
import Kenshou.Core.Canonical (sha256Hex)
import Kenshou.Core.Cohort (CohortIdentity (..), PlanHash (..))
import Kenshou.Core.Dimension (Dimensions (..), PgDurability (..), PgVersion (..), resolveDimensions)
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..))
import Kenshou.Core.Id (Kind (..), RunId, ScenarioId (..), renderRunId)
import Kenshou.Core.RunSpec (CohortExpectation (..), ConnectionSource (..), EnvironmentSpec (..), PostgresSpec (..), RunSpec (..), SpecPlacement (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..))
import Kenshou.Plan.RunPlan (PlannedRun (..), RunPlan (..), TrialInfo (..))
import Kenshou.Remote.Cell.Docs (BrokerReset (..), CachePolicy (..), CellDescriptor (..), CellImages (..), Limits (..), PgReset (..), Requirements (..), ResetBlock (..), Submission (..), WorkObject (..))
import Kenshou.Remote.Cell.Lease (CellRef (..))
import Kenshou.Remote.Cell.RouteRules (CellCapabilities (..), RoutingRule (..), capabilityKnown, descriptorDigest, matchingRules)
import Kenshou.Remote.Payload (Bundle (..), CellPayload (..), PayloadDescriptor (..))
import Kenshou.Remote.Store (Bucket (..))

data Granularity = GranularityAuto | GranularityPlan | GranularityRun
  deriving stock (Eq, Show)

data RejectReason
  = PlacementLocalOnly
  | UnknownScenario
  | PgVersionMismatch Int Int
  | DurabilityNotDurable
  | NeedsServerControl Text
  | NeedsBrokerButCellHasNone
  | PayloadLabelUnknown Text
  | ConflictingPostgresSetting Text
  | CollidingExtraPostgresName Text
  | RunIdMismatch
  | InvalidTimeout
  | MissingCapability Text
  | UnsupportedDimensions Text
  deriving stock (Eq, Show)

data PrepareOptions = PrepareOptions
  { coerceDurable :: !Bool,
    ephemeralOnDriver :: !Bool,
    pgSettings :: ![(Text, Text)],
    cachePolicy :: !CachePolicy
  }
  deriving stock (Eq, Show)

data Prepared = Prepared
  { accepted :: ![PreparedRun],
    rejected :: ![(PlannedRun, RejectReason)],
    warnings :: ![Text]
  }
  deriving stock (Eq, Show)

data Routed = Routed
  { perCell :: !(Map.Map Text RunPlan),
    local :: !(Maybe RunPlan),
    unroutable :: ![(PlannedRun, RejectReason)],
    warnings :: ![Text]
  }
  deriving stock (Eq, Show)

data PreparedRun = PreparedRun
  { ordinal :: !Int,
    runId :: !RunId,
    spec :: !RunSpec,
    payloadLabel :: !Text,
    reset :: !ResetBlock,
    timeoutSeconds :: !Int
  }
  deriving stock (Eq, Show)

data Slice = Slice
  { index :: !Int,
    payloadLabel :: !Text,
    reset :: !ResetBlock,
    entries :: !(NonEmpty PreparedRun),
    wallClockSeconds :: !Int
  }
  deriving stock (Eq, Show)

data OtlpSink = NullSink | FileSink
  deriving stock (Eq, Show)

data SubmissionInputs = SubmissionInputs
  { cellRun :: !RunId,
    leaseId :: !RunId,
    sessionId :: !RunId,
    planId :: !RunId,
    otlpSink :: !OtlpSink,
    rtsOptions :: !(Maybe Text),
    memoryMaxBytes :: !Int64,
    outputMaxBytes :: !Int64,
    minAgentVersion :: !Text,
    requiredCapabilities :: !(Maybe [Text])
  }
  deriving stock (Eq, Show)

-- Preflight a plan before it is sliced. Nothing is dropped silently: every
-- rejected entry remains paired with its original run identity.
prepareForCell :: Registry -> CellDescriptor -> Maybe CellCapabilities -> [RoutingRule] -> Map.Map Text PayloadDescriptor -> PrepareOptions -> RunPlan -> Prepared
prepareForCell registry descriptor cachedCapabilities routingRules payloads options plan =
  prepareWithPayload registry descriptor cachedCapabilities routingRules (Just payloads) options plan

prepareWithPayload :: Registry -> CellDescriptor -> Maybe CellCapabilities -> [RoutingRule] -> Maybe (Map.Map Text PayloadDescriptor) -> PrepareOptions -> RunPlan -> Prepared
prepareWithPayload registry descriptor cachedCapabilities routingRules payloads options plan =
  Prepared
    [prepared | Right (prepared, _) <- results]
    [(entry, reason) | (entry, Left reason) <- zip plan.runs results]
    (concat [notices | Right (_, notices) <- results])
  where
    results = fmap prepare plan.runs
    activeCapabilities = case cachedCapabilities of
      Just cache | cache.cell == descriptor.name && cache.descriptorSha256 == descriptorDigest descriptor -> Just cache
      _ -> Nothing
    profile =
      "gcp/"
        <> descriptor.zone
        <> "/shape-"
        <> Text.take 16 (Text.drop 7 (sha256Hex (LazyByteString.toStrict (encode descriptor.shape))))
        <> "/pg"
        <> Text.pack (show descriptor.postgresMajor)

    prepare entry = do
      if maybe True (== entry.runId) entry.spec.runId then pure () else Left RunIdMismatch
      scenario <- maybe (Left UnknownScenario) Right (lookupScenario registry entry.spec.scenario)
      if scenario.placement == PlaceLocal then Left PlacementLocalOnly else pure ()
      let label = maybe "default" (\trial -> if maybe False (Map.member trial.arm) payloads then trial.arm else "default") entry.trial
      payload <- traverse (\available -> maybe (Left (PayloadLabelUnknown label)) Right (Map.lookup label available)) payloads
      let requirements = scenario.requires
          controlled = case requirements.postgres of
            Just requirement | requirement.needsServerControl -> Just "primary"
            _ -> fst <$> find (\(_, requirement) -> requirement.needsServerControl) requirements.extraPostgres
          driverLocal = maybe False (const (options.ephemeralOnDriver && entry.spec.scenario.kind `elem` [Correctness, Concurrency])) controlled
      case controlled of
        Just name | not driverLocal -> Left (NeedsServerControl name)
        _ -> pure ()
      if requirements.kafka && Text.null descriptor.images.broker then Left NeedsBrokerButCellHasNone else pure ()
      let rules = matchingRules routingRules entry.spec
          denied = find (\rule -> maybe False (\cache -> capabilityKnown cache rule.requires == Just False) activeCapabilities) rules
      case denied of
        Just rule -> Left (MissingCapability rule.requires)
        Nothing -> pure ()
      let originalSpec = entry.spec
          dimensions =
            if options.coerceDurable && not driverLocal && controlled == Nothing && (requirements.postgres /= Nothing || not (null requirements.extraPostgres))
              then ("pg.durability", "durable") : filter ((/= "pg.durability") . fst) originalSpec.dimensions
              else originalSpec.dimensions
      resolved <- either (Left . UnsupportedDimensions . Text.intercalate "; " . NonEmpty.toList) Right (resolveDimensions scenario.dimensions dimensions)
      let needsPostgres = requirements.postgres /= Nothing || not (null requirements.extraPostgres)
      if needsPostgres && not driverLocal && resolved.pgDurability /= Just PgDurable then Left DurabilityNotDurable else pure ()
      let requestedMajor = case resolved.pgVersion of Just Pg17 -> 17; Just Pg18 -> 18; Nothing -> descriptor.postgresMajor
      if needsPostgres && not driverLocal && requestedMajor /= descriptor.postgresMajor
        then Left (PgVersionMismatch requestedMajor descriptor.postgresMajor)
        else pure ()
      let extraVariables = fmap (variableName . fst) requirements.extraPostgres
      case find (\name -> length (filter (== name) extraVariables) > 1) extraVariables of
        Just name -> Left (CollidingExtraPostgresName name)
        Nothing -> pure ()
      settings <- if needsPostgres && not driverLocal then combinedSettings scenario originalSpec else Right Map.empty
      let prior = originalSpec.environment
          primary =
            if requirements.postgres == Nothing
              then Nothing
              else
                if driverLocal
                  then Just (case prior.postgres of Just ephemeral@(PostgresEphemeral _) -> ephemeral; _ -> PostgresEphemeral [])
                  else Just (PostgresExternal (ConnFromEnv "KENSHOU_CELL_PG_URL"))
          extras =
            if driverLocal
              then Map.fromList [(name, case Map.lookup name prior.extraPostgres of Just ephemeral@(PostgresEphemeral _) -> ephemeral; _ -> PostgresEphemeral []) | (name, _) <- requirements.extraPostgres]
              else Map.fromList [(name, PostgresExternal (ConnFromEnv ("KENSHOU_CELL_PG_URL_" <> variableName name))) | (name, _) <- requirements.extraPostgres]
          env = EnvironmentSpec RunOnCell (Just profile) primary extras prior.kafka prior.telemetry
          expectation = maybe originalSpec.cohortExpectation (\selected -> Just (CohortExpectation (Just selected.cohort) selected.cohortIdentity.identityPlanHash.unPlanHash)) payload
          labels = Map.insert "postgresPlacement" (if driverLocal then "driver-ephemeral" else "cell-server") originalSpec.labels
          spec = RunSpec (Just entry.runId) originalSpec.scenario originalSpec.scenarioRevision originalSpec.knobs dimensions originalSpec.seed originalSpec.phases originalSpec.timeoutSeconds env expectation originalSpec.comparison labels
          reset = ResetBlock options.cachePolicy (if Map.null settings then Nothing else Just (PgReset descriptor.postgresMajor [] settings)) (if requirements.kafka then Just (BrokerReset True) else Nothing)
          timeout = fromMaybe (max 60 (entry.estimateMinutes * 60)) originalSpec.timeoutSeconds
          notices =
            ["coerced pg.durability=durable for " <> renderRunId entry.runId | dimensions /= originalSpec.dimensions]
              <> ["capability " <> rule.requires <> " is unprobed for " <> renderRunId entry.runId <> "; run kenshou cell probe" | rule <- rules, maybe True (\cache -> capabilityKnown cache rule.requires == Nothing) activeCapabilities]
              <> ["payload not selected for " <> renderRunId entry.runId <> "; cohort expectation will be set at submission" | isNothing payloads]
      if timeout <= 0 then Left InvalidTimeout else Right (PreparedRun entry.ordinal entry.runId spec label reset timeout, notices)

    combinedSettings scenario spec = foldl add (Right Map.empty) sources
      where
        required = maybe [] (.settings) scenario.requires.postgres <> concatMap ((.settings) . snd) scenario.requires.extraPostgres
        primary = case spec.environment.postgres of Just (PostgresEphemeral values) -> values; _ -> []
        extras = concatMap (\value -> case value of PostgresEphemeral values -> values; _ -> []) (Map.elems spec.environment.extraPostgres)
        sources = [("fsync", "on"), ("synchronous_commit", "on"), ("full_page_writes", "on")] <> required <> primary <> extras <> options.pgSettings
        add previous (name, value) = do
          settings <- previous
          case Map.lookup name settings of
            Nothing -> Right (Map.insert name value settings)
            Just existing | existing == value -> Right settings
            _ -> Left (ConflictingPostgresSetting name)

variableName :: Text -> Text
variableName = Text.map (\character -> if character == '-' then '_' else character) . Text.toUpper

-- Prefer the caller's cell order. A rejected run is either retained for local
-- execution or named as unroutable; its original identity never disappears.
routePlan :: Registry -> NonEmpty (CellDescriptor, Maybe CellCapabilities) -> [RoutingRule] -> Map.Map Text PayloadDescriptor -> PrepareOptions -> RunPlan -> Routed
routePlan registry cells routingRules payloads options plan = routePlanWith registry cells routingRules (Just payloads) options plan

routePlanWithoutPayload :: Registry -> NonEmpty (CellDescriptor, Maybe CellCapabilities) -> [RoutingRule] -> PrepareOptions -> RunPlan -> Routed
routePlanWithoutPayload registry cells routingRules options plan = routePlanWith registry cells routingRules Nothing options plan

routePlanWith :: Registry -> NonEmpty (CellDescriptor, Maybe CellCapabilities) -> [RoutingRule] -> Maybe (Map.Map Text PayloadDescriptor) -> PrepareOptions -> RunPlan -> Routed
routePlanWith registry cells routingRules payloads options plan =
  Routed (Map.map makePlan assigned) (if null localRuns then Nothing else Just (makePlan localRuns)) rejectedRuns notices
  where
    choices = fmap routeEntry plan.runs
    assigned = foldl addCell Map.empty [(name, selected) | Right (name, selected, _) <- choices]
    localRuns = [entry | Left (entry, reason) <- choices, localReason reason]
    rejectedRuns = [(entry, reason) | Left (entry, reason) <- choices, not (localReason reason)]
    notices = concat [messages | Right (_, _, messages) <- choices]

    routeEntry entry = choose (NonEmpty.toList cells) Nothing
      where
        choose [] firstFailure = Left (entry, fromMaybe UnknownScenario firstFailure)
        choose ((descriptor, capabilities) : rest) firstFailure =
          let one = RunPlan plan.planId plan.createdAt plan.context plan.policy [entry] [] entry.estimateMinutes
              prepared = prepareWithPayload registry descriptor capabilities routingRules payloads options one
           in case prepared.accepted of
                [accepted] -> Right (descriptor.name, preparedEntry accepted, prepared.warnings)
                _ -> case prepared.rejected of
                  [(_, reason)] -> choose rest (Just (fromMaybe reason firstFailure))
                  _ -> choose rest (Just (fromMaybe UnknownScenario firstFailure))
        preparedEntry accepted = PlannedRun entry.ordinal entry.runId entry.estimateMinutes entry.reasons entry.trial accepted.spec

    addCell grouped (name, entry) = Map.insertWith (flip (<>)) name [entry] grouped
    makePlan entries = RunPlan plan.planId plan.createdAt plan.context plan.policy entries plan.skipped (sum (fmap (.estimateMinutes) entries))
    localReason PlacementLocalOnly = True
    localReason (NeedsServerControl _) = True
    localReason _ = False

sliceRuns :: Granularity -> [PreparedRun] -> Either Text [Slice]
sliceRuns granularity prepared = do
  if all valid prepared && unique (fmap (.runId) prepared) && unique (fmap (.ordinal) prepared)
    then pure ()
    else Left "prepared runs have an empty payload, invalid timeout, duplicate identity or invalid ordinal"
  groups <- case granularity of
    GranularityRun -> pure (fmap (:| []) prepared)
    GranularityAuto -> pure (autoGroups prepared)
    GranularityPlan -> case NonEmpty.nonEmpty prepared of
      Nothing -> pure []
      Just group
        | all (compatible (NonEmpty.head group)) (NonEmpty.tail group) -> pure [group]
        | otherwise -> Left "plan granularity requires one payload and reset for every run"
  traverse makeSlice (zip [0 ..] groups)
  where
    valid run = run.ordinal >= 0 && run.timeoutSeconds > 0 && not (Text.null run.payloadLabel) && maybe True (== run.runId) run.spec.runId
    makeSlice (index, group) =
      let total = 300 + sum (fmap (toInteger . (.timeoutSeconds)) (NonEmpty.toList group))
       in if total > toInteger (maxBound :: Int)
            then Left "cell slice wall-clock limit is too large"
            else Right (Slice index (NonEmpty.head group).payloadLabel (NonEmpty.head group).reset group (fromInteger total))

slicePlan :: RunPlan -> Slice -> Either Text RunPlan
slicePlan plan slice = do
  selected <- traverse select (NonEmpty.toList slice.entries)
  pure (RunPlan plan.planId plan.createdAt plan.context plan.policy selected plan.skipped (sum (fmap (.estimateMinutes) selected)))
  where
    select prepared = case find ((== prepared.runId) . (.runId)) plan.runs of
      Nothing -> Left "slice contains a run absent from its plan"
      Just original
        | original.ordinal /= prepared.ordinal -> Left "slice ordinal differs from its plan"
        | original.spec.scenario /= prepared.spec.scenario -> Left "slice scenario differs from its plan"
        | otherwise -> Right (PlannedRun original.ordinal original.runId original.estimateMinutes original.reasons original.trial prepared.spec)

submissionFor :: CellRef -> SubmissionInputs -> PayloadDescriptor -> Slice -> WorkObject -> Either Text Submission
submissionFor ref inputs descriptor slice work = do
  case eitherDecode (encode descriptor) :: Either String PayloadDescriptor of
    Left failure -> Left ("invalid payload descriptor: " <> Text.pack failure)
    Right _ -> pure ()
  case eitherDecode (encode work) :: Either String WorkObject of
    Left failure -> Left ("invalid work object: " <> Text.pack failure)
    Right _ -> pure ()
  if work.mediaType /= "application/json" || work.bytes <= 0
    then Left "cell work must be a nonempty JSON run plan"
    else pure ()
  let bundle = descriptor.cell.bundle
      expectedPrefix = "gs://" <> ref.controlBucket.unBucket <> "/payloads/sha256/"
  if not (expectedPrefix `Text.isPrefixOf` bundle.uri)
    then Left "payload bundle is outside the cell control bucket"
    else pure ()
  if inputs.memoryMaxBytes <= 0 || inputs.outputMaxBytes <= 0 || Text.null inputs.minAgentVersion || maybe False Text.null inputs.rtsOptions
    then Left "invalid cell submission limits or options"
    else pure ()
  let env =
        Map.fromList
          ( [ ("KENSHOU_PAYLOAD_BUNDLE_SHA256", bundle.sha256),
              ("KENSHOU_PAYLOAD_STORE_PATH", descriptor.cell.storePath),
              ("KENSHOU_PAYLOAD_NAR_HASH", descriptor.cell.narHash),
              ("KENSHOU_PAYLOAD_COHORT", descriptor.cohort),
              ("KENSHOU_OTLP_SINK", case inputs.otlpSink of NullSink -> "null"; FileSink -> "file")
            ]
              <> maybe [] (\options -> [("GHCRTS", options)]) inputs.rtsOptions
          )
      labels =
        Map.fromList
          [ ("session", renderRunId inputs.sessionId),
            ("plan", renderRunId inputs.planId),
            ("slice", Text.pack (show slice.index)),
            ("payload", slice.payloadLabel)
          ]
      submission = Submission inputs.cellRun inputs.leaseId descriptor.cell work env slice.reset (Limits (fromIntegral slice.wallClockSeconds) inputs.memoryMaxBytes inputs.outputMaxBytes) (Requirements inputs.minAgentVersion inputs.requiredCapabilities) labels
  case eitherDecode (encode submission) :: Either String Submission of
    Left failure -> Left ("invalid cell submission: " <> Text.pack failure)
    Right _ -> Right submission

autoGroups :: [PreparedRun] -> [NonEmpty PreparedRun]
autoGroups [] = []
autoGroups (first : rest)
  | isolated first = (first :| []) : autoGroups rest
  | otherwise =
      let (same, later) = span (\candidate -> not (isolated candidate) && compatible first candidate) rest
       in (first :| same) : autoGroups later

compatible :: PreparedRun -> PreparedRun -> Bool
compatible first second = first.payloadLabel == second.payloadLabel && first.reset == second.reset

isolated :: PreparedRun -> Bool
isolated run = run.spec.scenario.kind `elem` [Benchmark, Soak]

unique :: (Eq value) => [value] -> Bool
unique [] = True
unique (first : rest) = first `notElem` rest && unique rest
