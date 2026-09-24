module Kenshou.Suite.Keiro.Workflow.ExactDiscovery (scenarios) where

import Control.Monad (forM)
import Data.Aeson (object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (addUTCTime, getCurrentTime)
import GHC.Clock (getMonotonicTimeNSec)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx
import Keiro.Workflow (WorkflowId (..), WorkflowOutcome (..), defaultWorkflowRunOptions, runWorkflow)
import Keiro.Workflow.Awakeable (AwakeableId, signalAwakeable)
import Keiro.Workflow.Child (runChildWorkflow)
import Keiro.Workflow.Resume (ResumeSummary (..), WorkflowDef (..), WorkflowResumeOptions (..), defaultWorkflowResumeOptions, resumeWorkflowsOnce)
import Keiro.Workflow.Sleep (drainWorkflowSleepTimers)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobValue (..), knobInt, knobText)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Workflow.Definitions (approvalName, approvalRegistry, approvalWorkflow, discoveryParentName, discoveryParentWorkflow, sleeperName, sleeperWorkflowWithDelay)
import Kenshou.Suite.Keiro.Workflow.Effects (EffectFact (..), EffectSink (..))
import Kenshou.Suite.Keiro.Workflow.Fixture (durableKirokuStore, withDurableStore)
import Kenshou.Suite.Keiro.Workflow.Knobs (workflowKnobName, workflowKnobs)
import Kenshou.Suite.Keiro.Workflow.Oracle (recordWorkflowCells)
import Kiroku.Store (KirokuStore, defaultConnectionSettings, runStoreIO, runTransaction)

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
      summary = "Parks awakeable or sleep workflows, proves zero idle discovery, then wakes a subset and proves exact discovery.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = [populationKnob, parkedOnKnob],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgFsyncOff :| [PgDurable]) PgFsyncOff),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku, SchemaKeiro] [("shared_preload_libraries", "'pg_stat_statements'")] False)},
      knownDefect = Nothing,
      run = runExactDiscovery
    }

runExactDiscovery :: RunContext -> IO ScenarioReport
runExactDiscovery context
  | knobText context.knobs (workflowKnobName "workflow.parked-on") == "sleep" = runSleepDiscovery context
  | knobText context.knobs (workflowKnobName "workflow.parked-on") == "child" = runChildDiscovery context
  | otherwise = runAwakeableDiscovery context

parkedOnKnob :: KnobSpec
parkedOnKnob = case filter (\spec -> spec.name == workflowKnobName "workflow.parked-on") workflowKnobs of
  [spec] -> spec {allowed = OneOf (VText "awakeable" :| [VText "sleep", VText "child"])}
  _ -> error "workflow parked-on knob was not declared"

runAwakeableDiscovery :: RunContext -> IO ScenarioReport
runAwakeableDiscovery context = withCheck context \check ->
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
    statsBefore <- awakeableCountStats store
    started <- getMonotonicTimeNSec
    first <- runStoreIO store (resumeWorkflowsOnce options (approvalRegistry sink))
    ended <- getMonotonicTimeNSec
    statsAfter <- awakeableCountStats store
    published <- readIORef publications
    signals <- forM [0 .. waking - 1] \n ->
      case Map.lookup ("discovery-" <> Text.pack (show n) <> "/approval") published of
        Nothing -> pure (Right False)
        Just aid -> runStoreIO store (signalAwakeable (aid :: AwakeableId) ("approved" :: Text))
    second <- runStoreIO store (resumeWorkflowsOnce options (approvalRegistry sink))
    afterEffects <- readIORef accepted
    putSummary context Measurements "exact-discovery" (object ["parked" .= population, "signalled" .= waking, "parkedOn" .= ("awakeable" :: Text), "idlePassMillis" .= ((fromIntegral (ended - started) / 1000000) :: Double), "awakeableCountStats" .= statsDelta statsBefore statsAfter])
    let cells =
          [ ("population-parked", all (== Right Suspended) parked && Map.size published == population),
            ("idle-pass-discovers-none", case first of Right summary -> summary.discovered == 0 && summary.advanced == 0; _ -> False),
            ("idle-pass-runs-no-step", Map.null beforeEffects),
            ("idle-pass-statement-sampled", statsMeasured statsBefore statsAfter),
            ("signals-transition", length signals == waking && all (== Right True) signals),
            ("exact-wake-discovery", case second of Right summary -> summary.discovered == waking && summary.advanced == waking; _ -> False),
            ("one-effect-per-wake", Map.size afterEffects == waking && all (== 1) (Map.elems afterEffects))
          ]
    recordWorkflowCells check cells

runChildDiscovery :: RunContext -> IO ScenarioReport
runChildDiscovery context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    effects <- newIORef Map.empty
    let store = durableKirokuStore fixture
        population = fromIntegral (knobInt context.knobs (workflowKnobName "workflow.population.parked")) :: Int
        waking = min 10 population
        sink =
          EffectSink
            { recordEffect = \fact -> atomicModifyIORef' effects (\rows -> (Map.insertWith (+) fact.key (1 :: Int) rows, ())),
              boundary = \_ -> pure ()
            }
        workflowId n = WorkflowId ("discovery-child-" <> Text.pack (show n))
        childId n = WorkflowId ("discovery-child-" <> Text.pack (show n) <> "-child")
        options = defaultWorkflowResumeOptions {pollInterval = 100000, leaseTtl = 3}
        registry = Map.fromList [(discoveryParentName, WorkflowDef (discoveryParentWorkflow sink)), (sleeperName, WorkflowDef (sleeperWorkflowWithDelay sink True 60))]
    parked <- forM [0 .. population - 1] \n -> do
      parent <- runStoreIO store (runWorkflow discoveryParentName (workflowId n) (discoveryParentWorkflow sink (workflowId n)))
      child <- runStoreIO store (runChildWorkflow defaultWorkflowRunOptions sleeperName (childId n) (sleeperWorkflowWithDelay sink True 60 (childId n)))
      pure (parent, child)
    beforeEffects <- readIORef effects
    statsBefore <- awakeableCountStats store
    started <- getMonotonicTimeNSec
    first <- runStoreIO store (resumeWorkflowsOnce options registry)
    ended <- getMonotonicTimeNSec
    statsAfter <- awakeableCountStats store
    afterIdle <- readIORef effects
    now <- getCurrentTime
    drained <- runStoreIO store (drainWorkflowSleepTimers Nothing (addUTCTime 61 now) waking (\_ -> pure Nothing))
    second <- runStoreIO store (resumeWorkflowsOnce options registry)
    third <- runStoreIO store (resumeWorkflowsOnce options registry)
    afterWake <- readIORef effects
    let newEffects = Map.difference afterWake beforeEffects
        passHasExactly expected result = case result of
          Right summary -> summary.discovered == expected && summary.advanced == expected
          _ -> False
        cells =
          [ ("population-parked", all (== (Right Suspended, Right Suspended)) parked && Map.size beforeEffects == population),
            ("idle-pass-discovers-none", passHasExactly 0 first),
            ("idle-pass-runs-no-step", afterIdle == beforeEffects),
            ("idle-pass-statement-sampled", statsMeasured statsBefore statsAfter),
            ("timer-drain-wakes-subset", drained == Right waking),
            ("exact-child-discovery", passHasExactly waking second),
            ("exact-parent-discovery", passHasExactly waking third),
            ("one-effect-per-wake", Map.size newEffects == waking && all (== 1) (Map.elems newEffects))
          ]
    putSummary context Measurements "exact-discovery" (object ["parked" .= population, "woken" .= waking, "parkedOn" .= ("child" :: Text), "idlePassMillis" .= ((fromIntegral (ended - started) / 1000000) :: Double), "awakeableCountStats" .= statsDelta statsBefore statsAfter])
    recordWorkflowCells check cells

runSleepDiscovery :: RunContext -> IO ScenarioReport
runSleepDiscovery context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    effects <- newIORef Map.empty
    let store = durableKirokuStore fixture
        population = fromIntegral (knobInt context.knobs (workflowKnobName "workflow.population.parked")) :: Int
        waking = min 10 population
        sink =
          EffectSink
            { recordEffect = \fact -> atomicModifyIORef' effects (\rows -> (Map.insertWith (+) fact.key (1 :: Int) rows, ())),
              boundary = \_ -> pure ()
            }
        workflowId n = WorkflowId ("discovery-sleep-" <> Text.pack (show n))
        options = defaultWorkflowResumeOptions {pollInterval = 100000, leaseTtl = 3}
        registry = Map.singleton sleeperName (WorkflowDef (sleeperWorkflowWithDelay sink True 60))
    parked <- forM [0 .. population - 1] \n ->
      runStoreIO store (runWorkflow sleeperName (workflowId n) (sleeperWorkflowWithDelay sink True 60 (workflowId n)))
    beforeEffects <- readIORef effects
    statsBefore <- awakeableCountStats store
    started <- getMonotonicTimeNSec
    first <- runStoreIO store (resumeWorkflowsOnce options registry)
    ended <- getMonotonicTimeNSec
    statsAfter <- awakeableCountStats store
    afterIdle <- readIORef effects
    now <- getCurrentTime
    drained <- runStoreIO store (drainWorkflowSleepTimers Nothing (addUTCTime 61 now) waking (\_ -> pure Nothing))
    second <- runStoreIO store (resumeWorkflowsOnce options registry)
    afterWake <- readIORef effects
    let newEffects = Map.difference afterWake beforeEffects
        cells =
          [ ("population-parked", all (== Right Suspended) parked && Map.size beforeEffects == population),
            ("idle-pass-discovers-none", case first of Right summary -> summary.discovered == 0 && summary.advanced == 0; _ -> False),
            ("idle-pass-runs-no-step", afterIdle == beforeEffects),
            ("idle-pass-statement-sampled", statsMeasured statsBefore statsAfter),
            ("timer-drain-wakes-subset", drained == Right waking),
            ("exact-wake-discovery", case second of Right summary -> summary.discovered == waking && summary.advanced == waking; _ -> False),
            ("one-effect-per-wake", Map.size newEffects == waking && all (== 1) (Map.elems newEffects))
          ]
    putSummary context Measurements "exact-discovery" (object ["parked" .= population, "woken" .= waking, "parkedOn" .= ("sleep" :: Text), "idlePassMillis" .= ((fromIntegral (ended - started) / 1000000) :: Double), "awakeableCountStats" .= statsDelta statsBefore statsAfter])
    recordWorkflowCells check cells

awakeableCountStats :: KirokuStore -> IO (Maybe (Int64, Double))
awakeableCountStats store = do
  created <- runStoreIO store (runTransaction (Tx.statement () createStatements))
  case created of
    Left _ -> pure Nothing
    Right () -> either (const Nothing) Just <$> runStoreIO store (runTransaction (Tx.statement () awakeableCountStatement))

statsDelta :: Maybe (Int64, Double) -> Maybe (Int64, Double) -> Maybe (Int64, Double)
statsDelta (Just (beforeCalls, beforeMillis)) (Just (afterCalls, afterMillis)) = Just (afterCalls - beforeCalls, afterMillis - beforeMillis)
statsDelta _ _ = Nothing

statsMeasured :: Maybe (Int64, Double) -> Maybe (Int64, Double) -> Bool
statsMeasured before after = case statsDelta before after of
  Just (calls, millis) -> calls == 1 && millis >= 0
  Nothing -> False

createStatements :: Statement.Statement () ()
createStatements = Statement.unpreparable "CREATE EXTENSION IF NOT EXISTS pg_stat_statements" Encoders.noParams Decoders.noResult

awakeableCountStatement :: Statement.Statement () (Int64, Double)
awakeableCountStatement =
  Statement.unpreparable
    "SELECT coalesce(sum(calls),0)::bigint, coalesce(sum(total_exec_time),0)::double precision FROM pg_stat_statements(true) WHERE dbid=(SELECT oid FROM pg_database WHERE datname=current_database()) AND ltrim(query) LIKE 'SELECT count(*)%' AND query LIKE '%keiro.keiro_awakeables%'"
    Encoders.noParams
    (Decoders.singleRow ((,) <$> Decoders.column (Decoders.nonNullable Decoders.int8) <*> Decoders.column (Decoders.nonNullable Decoders.float8)))
