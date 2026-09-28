module PrepareSpec (spec) where

import Data.Aeson (Value (..), eitherDecode, eitherDecodeFileStrict')
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Kenshou.Core.Bundle (LayerBundle (..), lookupScenario, mkRegistry)
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..))
import Kenshou.Core.Id (Kind (..), Layer (..), mkSeed, newRunId, parseScenarioId, renderKind)
import Kenshou.Core.RunSpec (ConnectionSource (..), EnvironmentSpec (..), PostgresSpec (..), RunSpec (..), minimalRunSpec)
import Kenshou.Core.RunSpec qualified as RunSpec
import Kenshou.Core.Scenario (Scenario (..))
import Kenshou.Core.Selftest qualified as Selftest
import Kenshou.Plan.Change (Change (..), ChangeSource (..), Reason (..))
import Kenshou.Plan.Components (ComponentId (..), ComponentRef (..))
import Kenshou.Plan.Policy (defaultPlanPolicy)
import Kenshou.Plan.RunPlan (PlanContext (..), PlanInputs (..), PlannedRun (PlannedRun), RunPlan (..))
import Kenshou.Plan.Selector (parseSelector)
import Kenshou.Remote.Cell.Docs (CachePolicy (..), CellDescriptor (..), Limits (..), PgReset (..), ResetBlock (..), Submission (..))
import Kenshou.Remote.Cell.Lease (CellRef (..))
import Kenshou.Remote.Cell.Prepare (Granularity (..), OtlpSink (..), PrepareOptions (..), Prepared (..), PreparedRun (..), RejectReason (..), Slice (..), SubmissionInputs (..), prepareForCell, slicePlan, sliceRuns, submissionFor)
import Kenshou.Remote.Cell.Submit (workObjectFor)
import Kenshou.Remote.Payload (Bundle (..), CellPayload (..), PayloadDescriptor (..))
import Kenshou.Remote.Store (Bucket (..))
import Test.Hspec

spec :: Spec
spec = describe "cell run slicing" do
  it "prepares durable PostgreSQL work and records reset settings and payload cohort" do
    (plan, descriptor, payload) <- preparationFixture
    let registry = either (error . show) id (mkRegistry [Selftest.bundle])
        payloads = Map.singleton "default" payload
        options = PrepareOptions False False [] Cold
        rejected = prepareForCell registry descriptor payloads options plan
        accepted = prepareForCell registry descriptor payloads (options {coerceDurable = True}) plan
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
    fmap snd (prepareForCell registry (descriptor {postgresMajor = 17}) payloads (options {coerceDurable = True}) plan).rejected `shouldBe` [PgVersionMismatch 18 17]
    fmap snd (prepareForCell registry descriptor payloads (options {coerceDurable = True, pgSettings = [("fsync", "off")]}) plan).rejected `shouldBe` [ConflictingPostgresSetting "fsync"]

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
    fmap snd (prepareForCell registry descriptor payloads options plan).rejected `shouldBe` [NeedsServerControl "primary"]
    case (prepareForCell registry descriptor payloads (options {ephemeralOnDriver = True}) plan).accepted of
      [run] -> do
        run.spec.environment.postgres `shouldBe` Just (PostgresEphemeral [])
        run.reset.postgres `shouldBe` Nothing
      _ -> expectationFailure "expected one driver-local prepared run"

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
    Map.lookup "GHCRTS" submission.env `shouldBe` Just "-N2 -T"
    Map.lookup "payload" submission.labels `shouldBe` Just "default"
    defaultSubmission <- either (\problem -> expectationFailure (Text.unpack problem) >> error "unreachable") pure (submissionFor ref (inputs {otlpSink = NullSink, rtsOptions = Nothing}) payload slice work)
    Map.lookup "KENSHOU_OTLP_SINK" defaultSubmission.env `shouldBe` Just "null"
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
