module PrepareSpec (spec) where

import Data.Aeson (Value (..), eitherDecode, eitherDecodeFileStrict', encode, toJSON)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Kenshou.Core.Bundle (LayerBundle (..), lookupScenario, mkRegistry)
import Kenshou.Core.Dimension (PgDurability (..), PgVersion (..), noDimensions, postgresDimensions)
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..))
import Kenshou.Core.Id (Kind (..), Layer (..), mkSeed, newRunId, parseScenarioId, renderKind)
import Kenshou.Core.Knob (RawKnob (..), mkKnobName)
import Kenshou.Core.RunSpec (ConnectionSource (..), EnvironmentSpec (..), PostgresSpec (..), RunSpec (..), minimalRunSpec)
import Kenshou.Core.RunSpec qualified as RunSpec
import Kenshou.Core.Scenario (Scenario (..))
import Kenshou.Core.Selftest qualified as Selftest
import Kenshou.Plan.Change (Change (..), ChangeSource (..), Reason (..))
import Kenshou.Plan.Components (ComponentId (..), ComponentRef (..))
import Kenshou.Plan.Policy (defaultPlanPolicy)
import Kenshou.Plan.RunPlan (PlanContext (..), PlanInputs (..), PlannedRun (PlannedRun), RunPlan (..))
import Kenshou.Plan.Selector (parseSelector)
import Kenshou.Remote.Cell.Docs (CachePolicy (..), CellBuckets (..), CellDescriptor (..), CollectOptions (..), Limits (..), PgReset (..), ResetBlock (..), Submission (..))
import Kenshou.Remote.Cell.Lease (CellRef (..))
import Kenshou.Remote.Cell.Prepare (Granularity (..), OtlpSink (..), PrepareOptions (..), Prepared (..), PreparedRun (..), RejectReason (..), Routed (..), Slice (..), SubmissionInputs (..), prepareForCell, routePlan, slicePlan, sliceRuns, submissionFor)
import Kenshou.Remote.Cell.RouteJson (RouteDocuments (..), routeWorkJson)
import Kenshou.Remote.Cell.RouteRules (CellCapabilities (..), RoutingRule (..), RuleCondition (..), defaultRoutingRules, descriptorDigest, loadCellCapabilities, matchingRules)
import Kenshou.Remote.Cell.Session.Build (BuildOptions (..), BuiltSession (..), buildSession)
import Kenshou.Remote.Cell.Session.Journal (SessionJournal (..), SliceJournal (..))
import Kenshou.Remote.Cell.Submit (workObjectFor)
import Kenshou.Remote.Cell.WorkJson (decodeWorkPlan, renderPreparedWork)
import Kenshou.Remote.Payload (Bundle (..), CellPayload (..), PayloadDescriptor (..))
import Kenshou.Remote.Store (Bucket (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "cell run slicing" do
  it "prepares durable PostgreSQL work and records reset settings and payload cohort" do
    (plan, descriptor, payload) <- preparationFixture
    let registry = either (error . show) id (mkRegistry [Selftest.bundle])
        payloads = Map.singleton "default" payload
        options = PrepareOptions False False [] Cold
        rejected = prepareForCell registry descriptor Nothing [] payloads options plan
        accepted = prepareForCell registry descriptor Nothing [] payloads (options {coerceDurable = True}) plan
    fmap snd rejected.rejected `shouldBe` [DurabilityNotDurable]
    case accepted.accepted of
      [run] -> do
        run.spec.environment.postgres `shouldBe` Just (PostgresExternal (ConnFromEnv "KENSHOU_CELL_PG_URL"))
        case run.reset.postgres of
          Just reset -> do
            Map.lookup "fsync" reset.settings `shouldBe` Just "on"
            Map.lookup "synchronous_commit" reset.settings `shouldBe` Just "on"
          Nothing -> expectationFailure "expected PostgreSQL reset"
        run.spec.cohortExpectation `shouldSatisfy` (/= Nothing)
        accepted.warnings `shouldSatisfy` (not . null)
      _ -> expectationFailure "expected one prepared run"
    fmap snd (prepareForCell registry (descriptor {postgresMajor = 17}) Nothing [] payloads (options {coerceDurable = True}) plan).rejected `shouldBe` [PgVersionMismatch 18 17]
    fmap snd (prepareForCell registry descriptor Nothing [] payloads (options {coerceDurable = True, pgSettings = [("fsync", "off")]}) plan).rejected `shouldBe` [ConflictingPostgresSetting "fsync"]

  it "keeps image-owned preloaded libraries out of PostgreSQL reset settings" do
    (plan, descriptor, payload) <- preparationFixture
    let originalRegistry = either (error . show) id (mkRegistry [Selftest.bundle])
        scenarioId = case plan.runs of
          [PlannedRun _ _ _ _ _ runSpec] -> runSpec.scenario
          _ -> error "expected one planned run"
        original = maybe (error "missing selftest") id (lookupScenario originalRegistry scenarioId)
        requirement = maybe (error "missing PostgreSQL requirement") id original.requires.postgres
        required = PostgresRequirement requirement.schemas [("shared_preload_libraries", "'pg_stat_statements'")] requirement.needsServerControl
        withPreload = Scenario original.id original.revision original.summary original.tier original.placement original.knobs original.dimensions original.phases (EnvRequirements (Just required) original.requires.extraPostgres original.requires.kafka) original.knownDefect original.run
        registry = either (error . show) id (mkRegistry [LayerBundle Selftest [withPreload] []])
        prepared = prepareForCell registry descriptor Nothing [] (Map.singleton "default" payload) (PrepareOptions True False [] Cold) plan
    case prepared.accepted of
      [run] -> case run.reset.postgres of
        Just reset -> Map.member "shared_preload_libraries" reset.settings `shouldBe` False
        Nothing -> expectationFailure "expected PostgreSQL reset"
      _ -> expectationFailure "expected one prepared run"

  it "keeps the owner PostgreSQL reset path for a worker with no database requirement" do
    (plan, descriptor, payload) <- preparationFixture
    worker <- either (\problem -> expectationFailure (Text.unpack problem) >> error "unreachable") pure (parseScenarioId "selftest/kernel/concurrency/worker-echo")
    let registry = either (error . show) id (mkRegistry [Selftest.bundle])
        payloads = Map.singleton "default" payload
        workerPlan = case plan.runs of
          [PlannedRun ordinal identifier estimate reasons trial _] ->
            let base = minimalRunSpec worker
                workerSpec = RunSpec (Just identifier) worker base.scenarioRevision base.knobs base.dimensions base.seed base.phases base.timeoutSeconds base.environment base.cohortExpectation base.comparison base.labels
             in plan {runs = [PlannedRun ordinal identifier estimate reasons trial workerSpec]}
          _ -> error "expected one planned run"
    case (prepareForCell registry descriptor Nothing [] payloads (PrepareOptions False False [] Warm) workerPlan).accepted of
      [preparedRun] -> do
        preparedRun.spec.environment.postgres `shouldBe` Nothing
        preparedRun.reset.postgres `shouldBe` Just (PgReset descriptor.postgresMajor [] Map.empty)
      _ -> expectationFailure "expected one worker run"

  it "keeps server-control work off the cell server unless the driver is explicitly selected" do
    (plan, descriptor, payload) <- preparationFixture
    let originalRegistry = either (error . show) id (mkRegistry [Selftest.bundle])
        scenarioId = case plan.runs of
          [PlannedRun _ _ _ _ _ runSpec] -> runSpec.scenario
          _ -> error "expected one planned run"
        original = maybe (error "missing selftest") id (lookupScenario originalRegistry scenarioId)
        requirement = maybe (error "missing PostgreSQL requirement") id original.requires.postgres
        controlled = Scenario original.id original.revision original.summary original.tier original.placement original.knobs original.dimensions original.phases (EnvRequirements (Just (requirement {needsServerControl = True})) original.requires.extraPostgres original.requires.kafka) original.knownDefect original.run
        registry = either (error . show) id (mkRegistry [LayerBundle Selftest [controlled] []])
        payloads = Map.singleton "default" payload
        options = PrepareOptions False False [] Cold
    fmap snd (prepareForCell registry descriptor Nothing [] payloads options plan).rejected `shouldBe` [NeedsServerControl "primary"]
    case (prepareForCell registry descriptor Nothing [] payloads (options {ephemeralOnDriver = True}) plan).accepted of
      [run] -> do
        run.spec.environment.postgres `shouldBe` Just (PostgresEphemeral [])
        run.reset.postgres `shouldBe` Just (PgReset descriptor.postgresMajor [] Map.empty)
      _ -> expectationFailure "expected one driver-local prepared run"
    let routed = routePlan registry ((descriptor, Nothing) :| []) [] payloads options plan
    fmap (.planId) routed.local `shouldBe` Just plan.planId
    Map.null routed.perCell `shouldBe` True

  it "routes PostgreSQL majors to matching cells while preserving plan order and run IDs" do
    (plan, descriptor18, payload) <- preparationFixture
    secondId <- newRunId
    let original = case plan.runs of
          [PlannedRun _ _ _ originalReasons originalTrial originalSpec] -> (originalReasons, originalTrial, originalSpec)
          _ -> error "expected one planned run"
        (reasons, trial, firstSpec) = original
        secondSpec = RunSpec (Just secondId) firstSpec.scenario firstSpec.scenarioRevision firstSpec.knobs [("pg.version", "17")] firstSpec.seed firstSpec.phases firstSpec.timeoutSeconds firstSpec.environment firstSpec.cohortExpectation firstSpec.comparison firstSpec.labels
        second = PlannedRun 1 secondId 1 reasons trial secondSpec
        twoRunPlan = RunPlan plan.planId plan.createdAt plan.context plan.policy (plan.runs <> [second]) plan.skipped 2
        descriptor17 = descriptor18 {name = "beta", postgresMajor = 17}
        baseRegistry = either (error . show) id (mkRegistry [Selftest.bundle])
        scenario = maybe (error "missing selftest") id (lookupScenario baseRegistry firstSpec.scenario)
        bothMajors = Scenario scenario.id scenario.revision scenario.summary scenario.tier scenario.placement scenario.knobs (postgresDimensions (PgFsyncOff :| [PgDurable]) (Pg18 :| [Pg17]) noDimensions) scenario.phases (EnvRequirements (Just (PostgresRequirement [] [] False)) [] False) scenario.knownDefect scenario.run
        registry = either (error . show) id (mkRegistry [LayerBundle Selftest [bothMajors] []])
        routed = routePlan registry ((descriptor17, Nothing) :| [(descriptor18, Nothing)]) [] (Map.singleton "default" payload) (PrepareOptions True False [] Cold) twoRunPlan
        runIds selected = fmap (\(PlannedRun _ identifier _ _ _ _) -> identifier) selected.runs
    fmap runIds (Map.lookup "alpha" routed.perCell) `shouldBe` Just [case plan.runs of [PlannedRun _ identifier _ _ _ _] -> identifier; _ -> error "expected one planned run"]
    fmap runIds (Map.lookup "beta" routed.perCell) `shouldBe` Just [secondId]
    routed.local `shouldBe` Nothing
    routed.unroutable `shouldBe` []

  it "routes a public JSON plan while preserving its provenance and reporting refusals" do
    (plan, descriptor, payload) <- preparationFixture
    let registry = either (error . show) id (mkRegistry [Selftest.bundle])
        input = toJSON plan
        route = routeWorkJson registry ((descriptor, Nothing) :| []) [] (Just (Map.singleton "default" payload)) (PrepareOptions True False [] Cold) input
    documents <- either (\problem -> expectationFailure (Text.unpack problem) >> error "unreachable") pure route
    documents.routeComplete `shouldBe` True
    documents.local `shouldBe` Nothing
    case (input, Map.lookup descriptor.name documents.perCell) of
      (Object source, Just (Object selected)) -> do
        KeyMap.lookup "planId" selected `shouldBe` KeyMap.lookup "planId" source
        KeyMap.lookup "createdAt" selected `shouldBe` KeyMap.lookup "createdAt" source
        KeyMap.lookup "policy" selected `shouldBe` KeyMap.lookup "policy" source
        KeyMap.lookup "changes" selected `shouldBe` KeyMap.lookup "changes" source
        KeyMap.lookup "runs" selected `shouldNotBe` KeyMap.lookup "runs" source
      _ -> expectationFailure "expected a routed plan object"
    case input of
      Object source -> do
        let originalRun = case KeyMap.lookup "runs" source of
              Just (Array runs) -> case toList runs of
                [run] -> run
                _ -> error "expected one run"
              _ -> error "missing runs"
            duplicate = Object (KeyMap.insert "runs" (toJSON [originalRun, originalRun]) source)
        routeWorkJson registry ((descriptor, Nothing) :| []) [] (Just (Map.singleton "default" payload)) (PrepareOptions True False [] Cold) duplicate `shouldSatisfy` isLeft
      _ -> expectationFailure "expected a plan object"
    withoutPayload <- either (\problem -> expectationFailure (Text.unpack problem) >> error "unreachable") pure (routeWorkJson registry ((descriptor, Nothing) :| []) [] Nothing (PrepareOptions True False [] Cold) input)
    withoutPayload.routeComplete `shouldBe` True
    case Map.lookup descriptor.name withoutPayload.perCell of
      Just (Object selected) -> case KeyMap.lookup "runs" selected of
        Just (Array rows) -> case toList rows of
          [Object row] -> case KeyMap.lookup "spec" row of
            Just (Object selectedSpec) -> KeyMap.lookup "cohortExpectation" selectedSpec `shouldBe` Just Null
            _ -> expectationFailure "expected a selected spec"
          _ -> expectationFailure "expected one selected run"
        _ -> expectationFailure "expected runs"
      _ -> expectationFailure "expected a routed plan"

  it "renders prepared slices from the original plan with reset settings intact" do
    (plan, descriptor, payload) <- preparationFixture
    let input = toJSON plan
        registry = either (error . show) id (mkRegistry [Selftest.bundle])
        options = PrepareOptions True False [] Cold
    decoded <- either (\problem -> expectationFailure (Text.unpack problem) >> error "unreachable") pure (decodeWorkPlan input)
    decoded.planId `shouldBe` plan.planId
    let selectedWork = prepareForCell registry descriptor Nothing [] (Map.singleton "default" payload) options decoded
    case selectedWork.accepted of
      [selected] -> do
        rendered <- either (\problem -> expectationFailure (Text.unpack problem) >> error "unreachable") pure (renderPreparedWork input [selected])
        case (input, rendered) of
          (Object original, Object slice) -> do
            KeyMap.lookup "policy" slice `shouldBe` KeyMap.lookup "policy" original
            KeyMap.lookup "changes" slice `shouldBe` KeyMap.lookup "changes" original
            KeyMap.lookup "runs" slice `shouldNotBe` KeyMap.lookup "runs" original
          _ -> expectationFailure "expected a rendered slice"
        renderPreparedWork input [selected {ordinal = 99}] `shouldSatisfy` isLeft
      _ -> expectationFailure "expected a prepared run"

  it "builds a durable session and refuses incompatible work before publication" do
    (plan, descriptor, payload) <- preparationFixture
    lease <- newRunId
    let registry = either (error . show) id (mkRegistry [Selftest.bundle])
        payloads = Map.singleton "default" payload
        matchingDescriptor = descriptor {buckets = descriptor.buckets {control = "control"}}
        options coerce = BuildOptions (PrepareOptions coerce False [] Cold) GranularityAuto False NullSink Nothing (24 * 1024 * 1024 * 1024) (20 * 1024 * 1024 * 1024) "0.1.0"
        source = encode plan
    rejected <- buildSession registry matchingDescriptor Nothing [] payloads (options False) "file:fixture" lease source
    rejected `shouldSatisfy` isLeft
    built <- buildSession registry matchingDescriptor Nothing [] payloads (options True) "file:fixture" lease source
    case built of
      Left problem -> expectationFailure (Text.unpack problem)
      Right session -> do
        session.journal.leaseId `shouldBe` lease
        length session.journal.slices `shouldBe` 1
        length session.workFiles `shouldBe` 1
        case (session.journal.slices, session.workFiles) of
          ([slice], [(_, bytes)]) -> do
            slice.runIds `shouldBe` fmap (\(PlannedRun _ identifier _ _ _ _) -> identifier) plan.runs
            case eitherDecode bytes of
              Right (Object rendered) -> KeyMap.lookup "policy" rendered `shouldBe` case toJSON plan of Object original -> KeyMap.lookup "policy" original; _ -> Nothing
              _ -> expectationFailure "expected a work plan"
          _ -> expectationFailure "expected one slice and work file"

  it "uses cached denials and warns when a matching capability has not been probed" do
    (plan, descriptor, payload) <- preparationFixture
    now <- getCurrentTime
    selector <- either (error . Text.unpack) pure (parseSelector "selftest/kernel/**")
    let registry = either (error . show) id (mkRegistry [Selftest.bundle])
        rule = RoutingRule (ScenarioMatches selector) "postgres.pg_partman" "requires extension"
        options = PrepareOptions True False [] Cold
        payloads = Map.singleton "default" payload
        unprobed = prepareForCell registry descriptor Nothing [rule] payloads options plan
        deniedCache = CellCapabilities descriptor.name (descriptorDigest descriptor) plan.planId now (Map.singleton "postgres.pg_partman" (Bool False))
        denied = prepareForCell registry descriptor (Just deniedCache) [rule] payloads options plan
        stale = prepareForCell registry (descriptor {postgresMajor = 17}) (Just deniedCache) [rule] payloads options plan
    length unprobed.accepted `shouldBe` 1
    unprobed.warnings `shouldSatisfy` any (Text.isInfixOf "kenshou cell probe")
    fmap snd denied.rejected `shouldBe` [MissingCapability "postgres.pg_partman"]
    fmap snd stale.rejected `shouldBe` [PgVersionMismatch 18 17]

  it "loads the seeded partitioned-queue routing rule" do
    rules <- eitherDecodeFileStrict' "../policies/cell-routing.json" >>= either fail pure
    rules `shouldBe` defaultRoutingRules
    scenario <- either (error . Text.unpack) pure (parseScenarioId "selftest/kernel/correctness/always-pass")
    knob <- either (error . Text.unpack) pure (mkKnobName "pgmq.queue-kind")
    let base = minimalRunSpec scenario
        withKnob = RunSpec base.runId base.scenario base.scenarioRevision [(knob, RawText "partitioned")] base.dimensions base.seed base.phases base.timeoutSeconds base.environment base.cohortExpectation base.comparison base.labels
    fmap (.requires) (matchingRules rules withKnob) `shouldBe` ["postgres.pg_partman"]

  it "round-trips a probed capability cache" do
    cache <- eitherDecodeFileStrict' "test/golden/cell-capabilities.json" >>= either fail pure
    eitherDecode (encode cache) `shouldBe` Right (cache :: CellCapabilities)

  it "loads only a valid cache for the current cell descriptor" $
    withSystemTempDirectory "kenshou-capabilities" \directory -> do
      (plan, descriptor, _) <- preparationFixture
      now <- getCurrentTime
      let path = directory </> Text.unpack descriptor.name <> ".capabilities.json"
          cache = CellCapabilities descriptor.name (descriptorDigest descriptor) plan.planId now (Map.singleton "postgres.pg_partman" (Bool False))
      loadCellCapabilities directory descriptor `shouldReturn` Right Nothing
      LazyByteString.writeFile path (encode cache)
      loadCellCapabilities directory descriptor `shouldReturn` Right (Just cache)
      loadCellCapabilities directory (descriptor {postgresMajor = 17}) `shouldReturn` Right Nothing
      LazyByteString.writeFile path "invalid JSON"
      malformed <- loadCellCapabilities directory descriptor
      malformed `shouldSatisfy` isLeft

  it "shares adjacent correctness resets and isolates benchmark and soak runs" do
    first <- prepared 0 Correctness "default" cold
    second <- prepared 1 Concurrency "default" cold
    benchmark <- prepared 2 Benchmark "default" cold
    third <- prepared 3 Correctness "default" cold
    soak <- prepared 4 Soak "default" cold
    fourth <- prepared 5 Correctness "default" cold
    slices <- expectSlices (sliceRuns GranularityAuto [first, second, benchmark, third, soak, fourth])
    fmap (NonEmpty.length . (.entries)) slices `shouldBe` [2, 1, 1, 1, 1]
    fmap (.index) slices `shouldBe` [0, 1, 2, 3, 4]
    fmap (.wallClockSeconds) slices `shouldBe` [320, 310, 310, 310, 310]

  it "starts a new automatic slice when the payload or reset changes" do
    first <- prepared 0 Correctness "default" cold
    second <- prepared 1 Correctness "candidate" cold
    third <- prepared 2 Correctness "candidate" warm
    fourth <- prepared 3 Correctness "candidate" warm
    slices <- expectSlices (sliceRuns GranularityAuto [first, second, third, fourth])
    fmap (NonEmpty.length . (.entries)) slices `shouldBe` [1, 1, 2]
    fmap (.payloadLabel) slices `shouldBe` ["default", "candidate", "candidate"]

  it "requires a homogeneous plan slice and refuses duplicate identities" do
    first <- prepared 0 Correctness "default" cold
    second <- prepared 1 Correctness "default" cold
    runSlices <- expectSlices (sliceRuns GranularityRun [first, second])
    fmap (NonEmpty.length . (.entries)) runSlices `shouldBe` [1, 1]
    planSlices <- expectSlices (sliceRuns GranularityPlan [first, second])
    fmap (NonEmpty.length . (.entries)) planSlices `shouldBe` [2]
    sliceRuns GranularityPlan [first, PreparedRun second.ordinal second.runId second.spec second.payloadLabel warm second.timeoutSeconds] `shouldBe` Left "plan granularity requires one payload and reset for every run"
    sliceRuns GranularityRun [first, first {ordinal = 1}] `shouldSatisfy` isLeft

  it "keeps the original plan metadata while replacing only selected run specs" do
    first <- prepared 0 Correctness "default" cold
    second <- prepared 1 Correctness "default" cold
    planId <- newRunId
    now <- getCurrentTime
    selector <- either (\problem -> expectationFailure (Text.unpack problem) >> error "unreachable") pure (parseSelector "selftest/**")
    seed <- either (\problem -> expectationFailure (Text.unpack problem) >> error "unreachable") pure (mkSeed 1)
    let reason = Reason (Change (ComponentRef (ComponentId "remote") Nothing) Everything "fixture") [] selector 0
        planned run = PlannedRun run.ordinal run.runId 1 (reason :| []) Nothing run.spec
        planContext = PlanContext Nothing "graph" "released" "plan-hash" (PlanInputs Null) [] []
        original = RunPlan planId now planContext (defaultPlanPolicy seed) [planned first, planned second] [] 2
        changed = PreparedRun first.ordinal first.runId (first.spec {RunSpec.timeoutSeconds = Just 42}) first.payloadLabel first.reset first.timeoutSeconds
    slices <- expectSlices (sliceRuns GranularityAuto [changed, second])
    case slices of
      [slice] -> do
        sliced <- either (\problem -> expectationFailure (Text.unpack problem) >> error "unreachable") pure (slicePlan original slice)
        sliced.planId `shouldBe` original.planId
        fmap (\(PlannedRun _ identifier _ _ _ _) -> identifier) sliced.runs `shouldBe` [first.runId, second.runId]
        fmap (\(PlannedRun _ _ _ _ _ runSpec) -> runSpec.timeoutSeconds) sliced.runs `shouldBe` [Just 42, Nothing]
        sliced.estimateMinutes `shouldBe` 2
        slicePlan (original {runs = [planned first]}) slice `shouldSatisfy` isLeft
      _ -> expectationFailure "expected one slice"

  it "builds a cell submission with payload transport, limits and session labels" do
    planned <- prepared 0 Correctness "default" cold
    slices <- expectSlices (sliceRuns GranularityRun [planned])
    slice <- case slices of
      [value] -> pure value
      _ -> expectationFailure "expected one slice" >> error "unreachable"
    bytes <- LazyByteString.readFile "test/golden/payload.json"
    payload <- either (\problem -> expectationFailure problem >> error "unreachable") pure (eitherDecode bytes :: Either String PayloadDescriptor)
    cellRun <- newRunId
    lease <- newRunId
    session <- newRunId
    plan <- newRunId
    let inputs = SubmissionInputs cellRun lease session plan FileSink (Just "-N2 -T") (24 * 1024 * 1024 * 1024) (20 * 1024 * 1024 * 1024) "0.1.0" Nothing
        ref = CellRef "alpha" (Bucket "control")
        work = workObjectFor "application/json" "{}"
    submission <- either (\problem -> expectationFailure (Text.unpack problem) >> error "unreachable") pure (submissionFor ref inputs payload slice work)
    submission.runId `shouldBe` cellRun
    submission.payload `shouldBe` payload.cell
    submission.limits.wallClockSeconds `shouldBe` 310
    Map.lookup "KENSHOU_PAYLOAD_BUNDLE_SHA256" submission.env `shouldBe` Just payload.cell.bundle.sha256
    Map.lookup "KENSHOU_OTLP_SINK" submission.env `shouldBe` Just "file"
    fmap (.traces) submission.collect `shouldBe` Just True
    Map.lookup "GHCRTS" submission.env `shouldBe` Just "-N2 -T"
    Map.lookup "payload" submission.labels `shouldBe` Just "default"
    defaultSubmission <- either (\problem -> expectationFailure (Text.unpack problem) >> error "unreachable") pure (submissionFor ref (inputs {otlpSink = NullSink, rtsOptions = Nothing}) payload slice work)
    Map.lookup "KENSHOU_OTLP_SINK" defaultSubmission.env `shouldBe` Just "null"
    defaultSubmission.collect `shouldBe` Nothing
    Map.lookup "GHCRTS" defaultSubmission.env `shouldBe` Nothing
    submissionFor (CellRef "alpha" (Bucket "other")) inputs payload slice work `shouldBe` Left "payload bundle is outside the cell control bucket"
    submissionFor ref inputs payload slice (workObjectFor "text/plain" "{}") `shouldBe` Left "cell work must be a nonempty JSON run plan"

prepared :: Int -> Kind -> Text -> ResetBlock -> IO PreparedRun
prepared ordinal kind label reset = do
  identifier <- newRunId
  scenario <- either (\problem -> expectationFailure (Text.unpack problem) >> error "unreachable") pure (parseScenarioId ("selftest/remote/" <> renderKind kind <> "/slice"))
  pure (PreparedRun ordinal identifier (minimalRunSpec scenario) label reset 10)

expectSlices :: Either Text [Slice] -> IO [Slice]
expectSlices = either (\problem -> expectationFailure (Text.unpack problem) >> error "unreachable") pure

isLeft :: Either left right -> Bool
isLeft (Left _) = True
isLeft _ = False

cold :: ResetBlock
cold = ResetBlock Cold Nothing Nothing

warm :: ResetBlock
warm = ResetBlock Warm Nothing Nothing

preparationFixture :: IO (RunPlan, CellDescriptor, PayloadDescriptor)
preparationFixture = do
  planId <- newRunId
  runId <- newRunId
  now <- getCurrentTime
  selector <- either (error . Text.unpack) pure (parseSelector "selftest/kernel/**")
  scenario <- either (error . Text.unpack) pure (parseScenarioId "selftest/kernel/correctness/postgres-roundtrip")
  seed <- either (error . Text.unpack) pure (mkSeed 7)
  descriptor <- eitherDecodeFileStrict' "test/golden/cell/cell.descriptor.v1.json" >>= either fail pure
  payload <- eitherDecodeFileStrict' "test/golden/payload.json" >>= either fail pure
  let reason = Reason (Change (ComponentRef (ComponentId "kernel") Nothing) Named "cell prepare") [] selector 0
      base = minimalRunSpec scenario
      runSpec = RunSpec (Just runId) scenario base.scenarioRevision base.knobs base.dimensions base.seed base.phases base.timeoutSeconds base.environment base.cohortExpectation base.comparison base.labels
      run = PlannedRun 0 runId 1 (reason :| []) Nothing runSpec
      planContext = PlanContext Nothing "fixture" "released" "sha256:fixture" (PlanInputs Null) [] []
  pure (RunPlan planId now planContext (defaultPlanPolicy seed) [run] [] 1, descriptor, payload)
