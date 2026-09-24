module Kenshou.Suite.Keiro.Workflow.ParkedPassBench (scenarios) where

import Control.Monad (forM)
import Data.Aeson (object, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as Text
import Keiro.Workflow (WorkflowId (..), WorkflowOutcome (..), runWorkflow)
import Keiro.Workflow.Resume (ResumeSummary (..), WorkflowResumeOptions (..), defaultWorkflowResumeOptions, resumeWorkflowsOnce)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (Kind (..), parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobInt)
import Kenshou.Core.Phase (PhasePlan (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport (..), Tier (..))
import Kenshou.Measure.Knobs (measureKnobs)
import Kenshou.Measure.Load (ClosedConfig (..), LoadModel (..), LoadReport (..), Operation (..), runLoad)
import Kenshou.Measure.Recorder (ErrorCause (..), OpName (..), OpResult (..))
import Kenshou.Measure.Session (measureConfigFromKnobs, measuredOutcome, phasePlanFromCore, withMeasurement)
import Kenshou.Suite.Keiro.Workflow.Definitions (approvalName, approvalRegistry, approvalWorkflow)
import Kenshou.Suite.Keiro.Workflow.Effects (EffectSink (..))
import Kenshou.Suite.Keiro.Workflow.Fixture (durableKirokuStore, withDurableStore)
import Kenshou.Suite.Keiro.Workflow.Knobs (workflowKnobName, workflowKnobs)
import Kenshou.Suite.Keiro.Workflow.Oracle (recordWorkflowCells)
import Kiroku.Store (defaultConnectionSettings, runStoreIO)

scenarios :: [Scenario]
scenarios = [parkedPassCost]

parkedPassCost :: Scenario
parkedPassCost =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/workflow/benchmark/parked-population-pass-cost"),
      revision = 1,
      summary = "Measures idle resume-pass latency across a parked awakeable population.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = workflowKnobs <> measureKnobs Benchmark <> [durationKnob],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      phases = PhasePlan 0 120 0,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku, SchemaKeiro] [("shared_preload_libraries", "'pg_stat_statements'")] False)},
      knownDefect = Nothing,
      run = runParkedPassCost
    }

durationKnob :: KnobSpec
durationKnob = KnobSpec (workflowKnobName "workflow.benchmark-duration-seconds") "Duration of measured idle passes" KnobInt (VInt 120) (IntRange 2 3600) []

runParkedPassCost :: RunContext -> IO ScenarioReport
runParkedPassCost context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let store = durableKirokuStore fixture
        population = fromIntegral (knobInt context.knobs (workflowKnobName "workflow.population.parked")) :: Int
        durationSeconds = fromIntegral (knobInt context.knobs (workflowKnobName "workflow.benchmark-duration-seconds")) :: Int
        sink = EffectSink {recordEffect = \_ -> pure (), boundary = \_ -> pure ()}
        options = defaultWorkflowResumeOptions {pollInterval = 100000, leaseTtl = 3}
        wid index = WorkflowId ("parked-bench-" <> Text.pack (show index))
    parked <- forM [0 .. population - 1] \index ->
      runStoreIO store (runWorkflow approvalName (wid index) (approvalWorkflow sink (wid index)))
    let configResult = measureConfigFromKnobs context (phasePlanFromCore (PhasePlan 0 (fromIntegral durationSeconds) 0))
    case configResult of
      Left reason -> fail (Text.unpack reason)
      Right config -> do
        (loadReport, report) <- withMeasurement context config \measurement ->
          runLoad
            measurement
            (ClosedLoop (ClosedConfig 1 0 0))
            ( Operation
                (OpName "parked-resume-pass")
                ( \_ _ -> do
                    result <- runStoreIO store (resumeWorkflowsOnce options (approvalRegistry sink))
                    pure case result of
                      Right summary | summary.discovered == 0 && summary.advanced == 0 -> OpOk 1
                      _ -> OpFailed (ErrorCause "non-idle-pass")
                )
            )
        putSummary context Measurements "parked-pass-cost" (object ["parked" .= population, "completed" .= loadReport.completed, "failed" .= loadReport.failed, "durationSeconds" .= durationSeconds])
        base <- recordWorkflowCells check [("population-parked", length parked == population && all (== Right Suspended) parked), ("all-passes-idle", loadReport.completed > 0 && loadReport.failed == 0)]
        pure (base {outcome = measuredOutcome report base.outcome})
