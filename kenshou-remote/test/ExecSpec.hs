module ExecSpec (execSpec) where

import Data.Aeson (Value (..), eitherDecodeFileStrict', object, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Kenshou.Core.Bundle (LayerBundle (..), Registry, lookupScenario, mkRegistry)
import Kenshou.Core.Dimension (allTelemetryArms)
import Kenshou.Core.Env (EnvRequirements (..))
import Kenshou.Core.Id (Layer (..), mkSeed, newRunId, parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), RawKnob (..), mkKnobName)
import Kenshou.Core.RunSpec (ConnectionSource (..), EnvironmentSpec (..), PostgresSpec (..), RunSpec (..), SpecPlacement (..), minimalRunSpec)
import Kenshou.Core.Scenario (Scenario (..))
import Kenshou.Core.Selftest qualified as Selftest
import Kenshou.Plan.Change (Change (..), ChangeSource (..), Reason (..))
import Kenshou.Plan.Components (ComponentId (..), ComponentRef (..))
import Kenshou.Plan.Policy (defaultPlanPolicy)
import Kenshou.Plan.RunPlan (PlanContext (..), PlanInputs (..), PlannedRun (..), RunPlan (..))
import Kenshou.Plan.Selector (parseSelector)
import Kenshou.Remote.Cell.Docs (CellBroker (..), CellEnvironment (..), CellPostgres (..), OtlpEndpoint (..), OtlpSinks (..))
import Kenshou.Remote.Cell.Exec (resolveOnCell)
import Kenshou.Remote.Cell.Prepare (OtlpSink (..))
import Test.Hspec

execSpec :: Spec
execSpec = describe "cell-side run-plan resolution" do
  it "binds durable PostgreSQL to the cell connection without changing run identity" do
    (plan, environment) <- fixtures
    let durable = withDimensions [("pg.durability", "durable"), ("pg.version", "18")] plan
    case resolveOnCell registry environment NullSink durable of
      Left problem -> expectationFailure (show problem)
      Right resolved -> do
        resolved.planId `shouldBe` durable.planId
        fmap (.runId) resolved.runs `shouldBe` fmap (.runId) durable.runs
        case resolved.runs of
          [run] -> do
            run.spec.environment.placement `shouldBe` RunOnCell
            run.spec.environment.postgres `shouldBe` Just (PostgresExternal (ConnFromEnv "KENSHOU_CELL_PG_URL"))
          _ -> expectationFailure "expected one resolved run"

  it "refuses a non-durable or wrong-major PostgreSQL run" do
    (plan, environment) <- fixtures
    resolveOnCell registry environment NullSink plan `shouldSatisfy` isLeft
    let pg = environment.postgres
        pg17 = CellPostgres 17 pg.host pg.port pg.database pg.user pg.connectionString
        cell17 = CellEnvironment environment.cell environment.runId environment.leaseId pg17 environment.broker environment.otlp environment.victoriaMetricsUrl environment.drivers environment.clockSkewBoundMicros environment.faultHook
        durable = withDimensions [("pg.durability", "durable"), ("pg.version", "18")] plan
    resolveOnCell registry cell17 NullSink durable `shouldSatisfy` isLeft

  it "binds the cell broker and selected OTLP endpoint for a tracing run" do
    (plan, environment) <- fixtures
    let broker = CellBroker "10.0.0.5:9092" "http://10.0.0.5:9644" "redpanda" "v25"
        sinks = OtlpSinks (OtlpEndpoint "http://10.0.0.4:4317" "http://10.0.0.4:4318") (OtlpEndpoint "http://10.0.0.4:5317" "http://10.0.0.4:5318")
        cell = withEndpoints environment (Just broker) (Just sinks)
        tracing = withDimensions [("pg.durability", "durable"), ("pg.version", "18"), ("telemetry.tracing", "sdk-otlp")] plan
        endpoint = either (error . Text.unpack) id (mkKnobName "otel.endpoint")
    case resolveOnCell tracingRegistry cell FileSink tracing of
      Left problem -> expectationFailure (show problem)
      Right resolved -> case resolved.runs of
        [run] -> do
          run.spec.environment.kafka `shouldBe` Just (object ["backend" .= ("external" :: Text), "brokers" .= (["10.0.0.5:9092"] :: [Text]), "lanes" .= (0 :: Int)])
          lookup endpoint run.spec.knobs `shouldBe` Just (RawText "http://10.0.0.4:5318")
        _ -> expectationFailure "expected one tracing run"
    resolveOnCell tracingRegistry environment FileSink tracing `shouldSatisfy` isLeft
    resolveOnCell tracingRegistry (withEndpoints environment (Just broker) Nothing) FileSink tracing `shouldSatisfy` isLeft

fixtures :: IO (RunPlan, CellEnvironment)
fixtures = do
  planId <- newRunId
  runId <- newRunId
  now <- getCurrentTime
  let scenario = either (error . Text.unpack) id (parseScenarioId "selftest/kernel/correctness/postgres-roundtrip")
      selector = either (error . Text.unpack) id (parseSelector "selftest/kernel/**")
      reason = Reason (Change (ComponentRef (ComponentId "kernel") Nothing) Named "cell test") [] selector 0
      base = minimalRunSpec scenario
      spec = RunSpec (Just runId) scenario base.scenarioRevision base.knobs base.dimensions base.seed base.phases base.timeoutSeconds base.environment base.cohortExpectation base.comparison base.labels
      entry = PlannedRun 0 runId 1 (reason :| []) Nothing spec
      planContext = PlanContext Nothing "fixture" "released" "sha256:fixture" (PlanInputs Null) [] []
      seed = either (error . Text.unpack) id (mkSeed 7)
      plan = RunPlan planId now planContext (defaultPlanPolicy seed) [entry] [] 1
  environment <- eitherDecodeFileStrict' "test/golden/cell/cell.environment.v1.json" >>= either fail pure
  pure (plan, environment)

registry :: Registry
registry = either (error . show) id (mkRegistry [Selftest.bundle])

tracingRegistry :: Registry
tracingRegistry = either (error . show) id (mkRegistry [LayerBundle Selftest [enhanced] []])
  where
    scenarioId = either (error . Text.unpack) id (parseScenarioId "selftest/kernel/correctness/postgres-roundtrip")
    original = maybe (error "missing PostgreSQL selftest") id (lookupScenario registry scenarioId)
    endpoint = either (error . Text.unpack) id (mkKnobName "otel.endpoint")
    knob = KnobSpec endpoint "OTLP endpoint" KnobText (VText "") AnyValue []
    requirements = EnvRequirements original.requires.postgres original.requires.extraPostgres True
    enhanced = Scenario original.id original.revision original.summary original.tier original.placement (knob : original.knobs) (allTelemetryArms original.dimensions) original.phases requirements original.knownDefect original.run

withEndpoints :: CellEnvironment -> Maybe CellBroker -> Maybe OtlpSinks -> CellEnvironment
withEndpoints environment broker otlp =
  CellEnvironment environment.cell environment.runId environment.leaseId environment.postgres broker otlp environment.victoriaMetricsUrl environment.drivers environment.clockSkewBoundMicros environment.faultHook

withDimensions :: [(Text, Text)] -> RunPlan -> RunPlan
withDimensions dimensions plan =
  let runs = fmap update plan.runs
   in RunPlan plan.planId plan.createdAt plan.context plan.policy runs plan.skipped plan.estimateMinutes
  where
    update entry =
      let spec = entry.spec
          changed = RunSpec spec.runId spec.scenario spec.scenarioRevision spec.knobs dimensions spec.seed spec.phases spec.timeoutSeconds spec.environment spec.cohortExpectation spec.comparison spec.labels
       in PlannedRun entry.ordinal entry.runId entry.estimateMinutes entry.reasons entry.trial changed

isLeft :: Either left right -> Bool
isLeft (Left _) = True
isLeft _ = False
