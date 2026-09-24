module Kenshou.Suite.Keiro.Workflow.SleepSmoke (scenarios) where

import Control.Concurrent (threadDelay)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (addUTCTime, getCurrentTime)
import Keiro.Timer (TimerRow (..), TimerStatus (..), lookupTimer)
import Keiro.Workflow (StepName (..), WorkflowId (..), WorkflowOutcome (..), loadStepIndex, runWorkflow)
import Keiro.Workflow.Instance (WorkflowInstanceRow (..), lookupInstance)
import Keiro.Workflow.Resume (ResumeSummary (..), defaultWorkflowResumeOptions, resumeWorkflowsOnce)
import Keiro.Workflow.Sleep (drainWorkflowSleepTimers, sleepStepName, sleepTimerId, sleepTimerPayload)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Timer.Oracle (recordTimerCells)
import Kenshou.Suite.Keiro.Workflow.Definitions (ordinalSleeperName, sleeperName, sleeperRegistry, sleeperWorkflow)
import Kenshou.Suite.Keiro.Workflow.Effects (EffectFact (..), EffectSink (..))
import Kenshou.Suite.Keiro.Workflow.Fixture (durableKirokuStore, withDurableStore)
import Kiroku.Store (defaultConnectionSettings, runStoreIO)

scenarios :: [Scenario]
scenarios = [sleepTimerSmoke]

sleepTimerSmoke :: Scenario
sleepTimerSmoke =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/workflow/correctness/sleep-timer-smoke"),
      revision = 1,
      summary = "Checks named and ordinal sleep timer arming, stable replay deadline, due discovery, batched wake, and journal completion.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
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
      run = runSleepTimerSmoke
    }

runSleepTimerSmoke :: RunContext -> IO ScenarioReport
runSleepTimerSmoke context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    counts <- newIORef Map.empty
    let sink =
          EffectSink
            { recordEffect = \fact -> atomicModifyIORef' counts (\rows -> (Map.insertWith (+) fact.key (1 :: Int) rows, ())),
              boundary = \_ -> pure ()
            }
        store = durableKirokuStore fixture
        namedId = WorkflowId "sleep-named-smoke"
        ordinalId = WorkflowId "sleep-ordinal-smoke"
        namedStep = sleepStepName (StepName "nap")
        ordinalStep = sleepStepName (StepName "0")
        namedTimer = sleepTimerId sleeperName namedId 0 namedStep
        ordinalTimer = sleepTimerId ordinalSleeperName ordinalId 0 ordinalStep
    firstNamed <- runStoreIO store $ runWorkflow sleeperName namedId (sleeperWorkflow sink True namedId)
    firstOrdinal <- runStoreIO store $ runWorkflow ordinalSleeperName ordinalId (sleeperWorkflow sink False ordinalId)
    armedNamed <- runStoreIO store $ lookupTimer namedTimer
    armedOrdinal <- runStoreIO store $ lookupTimer ordinalTimer
    instanceNamed <- runStoreIO store $ lookupInstance sleeperName namedId
    replayNamed <- runStoreIO store $ runWorkflow sleeperName namedId (sleeperWorkflow sink True namedId)
    replayOrdinal <- runStoreIO store $ runWorkflow ordinalSleeperName ordinalId (sleeperWorkflow sink False ordinalId)
    replayTimer <- runStoreIO store $ lookupTimer namedTimer
    replayInstance <- runStoreIO store $ lookupInstance sleeperName namedId
    threadDelay 300000
    now <- addUTCTime 1 <$> getCurrentTime
    due <- runStoreIO store $ resumeWorkflowsOnce defaultWorkflowResumeOptions (sleeperRegistry sink)
    beforeWake <- readIORef counts
    drained <- runStoreIO store $ drainWorkflowSleepTimers Nothing now 10 (\_ -> pure Nothing)
    afterDrain <- runStoreIO store $ lookupTimer namedTimer
    namedDone <- runStoreIO store $ runWorkflow sleeperName namedId (sleeperWorkflow sink True namedId)
    ordinalDone <- runStoreIO store $ runWorkflow ordinalSleeperName ordinalId (sleeperWorkflow sink False ordinalId)
    namedIndex <- runStoreIO store $ loadStepIndex sleeperName namedId 0
    ordinalIndex <- runStoreIO store $ loadStepIndex ordinalSleeperName ordinalId 0
    afterWake <- readIORef counts
    let row result predicate = case result of Right (Just value) -> predicate value; _ -> False
        indexHas result key = either (const False) (Map.member key) result
        cells =
          [ ("initial-suspension", firstNamed == Right Suspended && firstOrdinal == Right Suspended),
            ("deterministic-timer-rows", row armedNamed (\value -> value.timerId == namedTimer && value.status == Scheduled && value.payload == sleepTimerPayload 0 namedStep) && row armedOrdinal (\value -> value.timerId == ordinalTimer && value.status == Scheduled && value.payload == sleepTimerPayload 0 ordinalStep)),
            ( "stable-first-arm",
              replayNamed == Right Suspended && replayOrdinal == Right Suspended && case (armedNamed, replayTimer, instanceNamed, replayInstance) of
                (Right (Just initial), Right (Just again), Right (Just firstInstance), Right (Just secondInstance)) -> initial.fireAt == again.fireAt && firstInstance.wakeAfter == secondInstance.wakeAfter
                _ -> False
            ),
            ("due-without-worker", case due of Right summary -> summary.sleepDue >= 1 && summary.advanced == 0; _ -> False),
            ("batched-wake", drained == Right 2 && row afterDrain (\value -> value.status == Fired)),
            ("completion-and-journal", namedDone == Right (Completed 3) && ordinalDone == Right (Completed 3) && indexHas namedIndex namedStep && indexHas ordinalIndex ordinalStep),
            ("single-step-effects", all (== Just 1) [Map.lookup (key :: Text) afterWake | key <- ["sleep-named-smoke/0/before", "sleep-named-smoke/0/after", "sleep-ordinal-smoke/0/before", "sleep-ordinal-smoke/0/after"]] && Map.size beforeWake == 2)
          ]
    recordTimerCells check cells
