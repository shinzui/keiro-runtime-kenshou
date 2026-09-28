module ExecSpec (execSpec) where

import Control.Exception (bracket)
import Data.Aeson (Value (..), eitherDecodeFileStrict', object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Kenshou.Core.Bundle (LayerBundle (..), Registry, lookupScenario, mkRegistry)
import Kenshou.Core.Dimension (allTelemetryArms)
import Kenshou.Core.Env (EnvRequirements (..))
import Kenshou.Core.Id (Layer (..), mkSeed, newRunId, parseScenarioId, renderRunId)
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
import Kenshou.Remote.Cell.Exec (cellExec, resolveOnCell, resolveWorkJson)
import Kenshou.Remote.Cell.Prepare (OtlpSink (..))
import Kenshou.Remote.Selftest qualified as RemoteSelftest
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
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
        resolveWorkJson registry environment NullSink (Aeson.toJSON durable) `shouldBe` Right (Aeson.toJSON resolved)
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

  it "fills the remote environment probe from the cell descriptor" do
    (plan, environment) <- fixtures
    let scenario = either (error . Text.unpack) id (parseScenarioId "selftest/remote/correctness/cell-environment")
        broker = CellBroker "10.0.0.5:9092" "http://10.0.0.5:9644" "redpanda" "v25"
        sinks = OtlpSinks (OtlpEndpoint "http://10.0.0.4:4317" "http://10.0.0.4:4318") (OtlpEndpoint "http://10.0.0.4:5317" "http://10.0.0.4:5318")
        cell = withEndpoints environment (Just broker) (Just sinks)
        change entry =
          let old = entry.spec
              spec = RunSpec old.runId scenario old.scenarioRevision old.knobs old.dimensions old.seed old.phases old.timeoutSeconds old.environment old.cohortExpectation old.comparison old.labels
           in PlannedRun entry.ordinal entry.runId entry.estimateMinutes entry.reasons entry.trial spec
        changed = RunPlan plan.planId plan.createdAt plan.context plan.policy (fmap change plan.runs) plan.skipped plan.estimateMinutes
        durable = withDimensions [("pg.durability", "durable"), ("pg.version", "18")] changed
        name text = either (error . Text.unpack) id (mkKnobName text)
    case resolveOnCell remoteRegistry cell FileSink durable of
      Left problem -> expectationFailure (show problem)
      Right resolved -> case resolved.runs of
        [run] -> do
          lookup (name "remote.expect-placement") run.spec.knobs `shouldBe` Just (RawText "cell")
          lookup (name "remote.otlp-endpoint") run.spec.knobs `shouldBe` Just (RawText "http://10.0.0.4:5318")
          lookup (name "remote.kafka-bootstrap") run.spec.knobs `shouldBe` Just (RawText "10.0.0.5:9092")
        _ -> expectationFailure "expected one remote probe run"

  it "leaves a secondary driver idle without requiring the work or environment" $
    withSystemTempDirectory "kenshou-cell-exec" \root ->
      withEnv "CELL_DRIVER_INDEX" (Just "1") $
        withEnv "CELL_DRIVER_COUNT" (Just "2") do
          let out = root </> "output"
          cellExec registry (root </> "missing-work.json") out `shouldReturn` ExitSuccess
          idle <- eitherDecodeFileStrict' (out </> "idle-driver.json")
          idle `shouldBe` Right (object ["schema" .= ("kenshou.cell-idle-driver/v1" :: Text), "index" .= (1 :: Int), "count" .= (2 :: Int)])

  it "records a cell adapter failure when the owner environment is missing" $
    withSystemTempDirectory "kenshou-cell-exec" \root ->
      withEnv "CELL_DRIVER_INDEX" (Just "0") $
        withEnv "CELL_DRIVER_COUNT" (Just "1") $
          withEnv "CELL_ENV_FILE" Nothing do
            let out = root </> "output"
            cellExec registry (root </> "missing-work.json") out `shouldReturn` ExitFailure 4
            failure <- eitherDecodeFileStrict' (out </> "kenshou-cell" </> "adapter-error.json")
            failure `shouldBe` Right (object ["schema" .= ("kenshou.cell-adapter-error/v1" :: Text), "reason" .= ("cell-environment-missing" :: Text), "detail" .= ("user error (CELL_ENV_FILE is required by the cell payload)" :: Text)])

  it "reports missing wrapper identity before reading cell work" $
    withSystemTempDirectory "kenshou-cell-exec" \root -> do
      (_, environment) <- fixtures
      withEnv "CELL_DRIVER_INDEX" (Just "0") $
        withEnv "CELL_DRIVER_COUNT" (Just "1") $
          withEnv "CELL_ENV_FILE" (Just "test/golden/cell/cell.environment.v1.json") $
            withEnv "CELL_RUN_ID" (Just (Text.unpack (renderRunId environment.runId))) $
              withEnv "CELL_SCRATCH_DIR" (Just (root </> "scratch")) $
                withEnv "KENSHOU_OTLP_SINK" (Just "null") $
                  withEnv "KENSHOU_COHORT_IDENTITY" Nothing do
                    let out = root </> "output"
                    cellExec registry (root </> "missing-work.json") out `shouldReturn` ExitFailure 4
                    failure <- eitherDecodeFileStrict' (out </> "kenshou-cell" </> "adapter-error.json")
                    case (failure :: Either String Value) of
                      Right (Object fields) -> KeyMap.lookup "reason" fields `shouldBe` Just (String "payload-identity-missing")
                      _ -> expectationFailure (show failure)

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

remoteRegistry :: Registry
remoteRegistry = either (error . show) id (mkRegistry [Selftest.bundle, RemoteSelftest.bundle])

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

withEnv :: String -> Maybe String -> IO result -> IO result
withEnv name value operation = bracket (lookupEnv name) (restore name) (const (apply name value >> operation))
  where
    apply key Nothing = unsetEnv key
    apply key (Just setting) = setEnv key setting
    restore key prior = apply key prior
