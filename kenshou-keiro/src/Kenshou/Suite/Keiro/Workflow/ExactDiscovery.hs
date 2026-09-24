module Kenshou.Suite.Keiro.Workflow.ExactDiscovery (scenarios) where

import Control.Monad (forM)
import Data.Aeson (object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Clock (getMonotonicTimeNSec)
import Keiro.Workflow (WorkflowId (..), WorkflowOutcome (..), runWorkflow)
import Keiro.Workflow.Awakeable (AwakeableId, signalAwakeable)
import Keiro.Workflow.Resume (ResumeSummary (..), WorkflowResumeOptions (..), defaultWorkflowResumeOptions, resumeWorkflowsOnce)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), knobInt)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Workflow.Definitions (approvalName, approvalRegistry, approvalWorkflow)
import Kenshou.Suite.Keiro.Workflow.Effects (EffectFact (..), EffectSink (..))
import Kenshou.Suite.Keiro.Workflow.Fixture (durableKirokuStore, withDurableStore)
import Kenshou.Suite.Keiro.Workflow.Knobs (workflowKnobName, workflowKnobs)
import Kenshou.Suite.Keiro.Workflow.Oracle (recordWorkflowCells)
import Kiroku.Store (defaultConnectionSettings, runStoreIO)

scenarios :: [Scenario]
scenarios = [exactDiscovery]

populationKnob :: KnobSpec
populationKnob = case filter (\spec -> spec.name == workflowKnobName "workflow.population.parked") workflowKnobs of
  [spec] -> spec {allowed = IntRange 1 1000000}
  _ -> error "workflow population knob was not declared"

exactDiscovery :: Scenario
exactDiscovery =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/workflow/correctness/exact-discovery"),
      revision = 1,
      summary = "Parks an awakeable population, proves zero discovery, then signals a subset and proves exact discovery.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = [populationKnob],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgFsyncOff :| [PgDurable]) PgFsyncOff),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku, SchemaKeiro] [] False)},
      knownDefect = Nothing,
      run = runExactDiscovery
    }

runExactDiscovery :: RunContext -> IO ScenarioReport
runExactDiscovery context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    publications <- newIORef Map.empty
    accepted <- newIORef Map.empty
    let store = durableKirokuStore fixture
        population = fromIntegral (knobInt context.knobs (workflowKnobName "workflow.population.parked")) :: Int
        waking = min 10 population
        sink =
          EffectSink
            { recordEffect = \fact ->
                if fact.kind == "arm"
                  then case parseMaybe (withObject "publication" (\value -> value .: "awakeableId")) fact.attributes of
                    Just aid -> atomicModifyIORef' publications (\rows -> (Map.insert fact.key aid rows, ()))
                    Nothing -> pure ()
                  else atomicModifyIORef' accepted (\rows -> (Map.insertWith (+) fact.key (1 :: Int) rows, ())),
              boundary = \_ -> pure ()
            }
        workflowId n = WorkflowId ("discovery-" <> Text.pack (show n))
        options = defaultWorkflowResumeOptions {pollInterval = 100000, leaseTtl = 3}
    parked <- forM [0 .. population - 1] \n ->
      runStoreIO store (runWorkflow approvalName (workflowId n) (approvalWorkflow sink (workflowId n)))
    beforeEffects <- readIORef accepted
    started <- getMonotonicTimeNSec
    first <- runStoreIO store (resumeWorkflowsOnce options (approvalRegistry sink))
    ended <- getMonotonicTimeNSec
    published <- readIORef publications
    signals <- forM [0 .. waking - 1] \n ->
      case Map.lookup ("discovery-" <> Text.pack (show n) <> "/approval") published of
        Nothing -> pure (Right False)
        Just aid -> runStoreIO store (signalAwakeable (aid :: AwakeableId) ("approved" :: Text))
    second <- runStoreIO store (resumeWorkflowsOnce options (approvalRegistry sink))
    afterEffects <- readIORef accepted
    putSummary context Measurements "exact-discovery" (object ["parked" .= population, "signalled" .= waking, "idlePassMillis" .= ((fromIntegral (ended - started) / 1000000) :: Double)])
    let cells =
          [ ("population-parked", all (== Right Suspended) parked && Map.size published == population),
            ("idle-pass-discovers-none", case first of Right summary -> summary.discovered == 0 && summary.advanced == 0; _ -> False),
            ("idle-pass-runs-no-step", Map.null beforeEffects),
            ("signals-transition", length signals == waking && all (== Right True) signals),
            ("exact-wake-discovery", case second of Right summary -> summary.discovered == waking && summary.advanced == waking; _ -> False),
            ("one-effect-per-wake", Map.size afterEffects == waking && all (== 1) (Map.elems afterEffects))
          ]
    recordWorkflowCells check cells
