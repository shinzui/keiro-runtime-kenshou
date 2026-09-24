module Kenshou.Suite.Keiro.Workflow.ChildSmoke (scenarios) where

import Control.Exception (try)
import Data.Aeson (object, toJSON, (.=))
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Keiro.Workflow (WorkflowId (..), WorkflowOutcome (..), loadStepIndex, runWorkflow)
import Keiro.Workflow.Child (ChildHandle (..), WorkflowChildCancelled, WorkflowChildFailed, cancelChild, childResultStepName, childSpawnStepName)
import Keiro.Workflow.Child.Schema (ChildRow (..), ChildStatus (..), lookupChild)
import Keiro.Workflow.Instance (WorkflowInstanceRow (..), WorkflowStatus (..), lookupInstance)
import Keiro.Workflow.Resume (ResumeSummary (..), WorkflowResumeOptions (..), defaultWorkflowResumeOptions, resumeWorkflowsOnce)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Workflow.Definitions qualified as Definitions
import Kenshou.Suite.Keiro.Workflow.Effects (EffectFact (..), EffectSink (..))
import Kenshou.Suite.Keiro.Workflow.Fixture (durableKirokuStore, withDurableStore)
import Kenshou.Suite.Keiro.Workflow.Oracle (recordWorkflowCells)
import Kiroku.Store (defaultConnectionSettings, runStoreIO)

scenarios :: [Scenario]
scenarios = [childrenSpawnAwaitCancelFail]

childrenSpawnAwaitCancelFail :: Scenario
childrenSpawnAwaitCancelFail =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/workflow/correctness/children-spawn-await-cancel-fail"),
      revision = 1,
      summary = "Checks durable child spawn, discovery, completion propagation, and the parked parent.",
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
      run = runChildren
    }

runChildren :: RunContext -> IO ScenarioReport
runChildren context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    effects <- newIORef Map.empty
    let store = durableKirokuStore fixture
        wid = WorkflowId "child-parent"
        cid = WorkflowId "child-parent-child"
        cancelledParent = WorkflowId "child-cancel-parent"
        cancelledChild = WorkflowId "child-cancel-parent-child"
        failedParent = WorkflowId "child-fail-parent"
        failedChild = WorkflowId "child-fail-parent-child"
        sink =
          EffectSink
            { recordEffect = \fact -> atomicModifyIORef' effects (\rows -> (Map.insertWith (+) fact.key (1 :: Int) rows, ())),
              boundary = \_ -> pure ()
            }
        runParentFor workflowId = runStoreIO store (runWorkflow Definitions.parentName workflowId (Definitions.parentWorkflow sink workflowId))
        runParent = runParentFor wid
        index name workflowId = runStoreIO store (loadStepIndex name workflowId 0)
        resume = runStoreIO store (resumeWorkflowsOnce defaultWorkflowResumeOptions (Definitions.childRegistry sink))
    parked <- runParent
    spawned <- runStoreIO store (lookupChild (unWorkflowId cid) "kenshouChild")
    childBefore <- runStoreIO store (lookupInstance Definitions.childName cid)
    parentBefore <- runStoreIO store (lookupInstance Definitions.parentName wid)
    childIndexBefore <- index Definitions.childName cid
    parentIndexBefore <- index Definitions.parentName wid
    pass1 <- resume
    childAfter <- runStoreIO store (lookupChild (unWorkflowId cid) "kenshouChild")
    parentIndexAfter <- index Definitions.parentName wid
    pass2 <- resume
    finished <- runParent
    finalIndex <- index Definitions.parentName wid
    observed <- readIORef effects
    cancelParked <- runParentFor cancelledParent
    cancelFirst <- runStoreIO store (cancelChild (ChildHandle Definitions.childName cancelledChild :: ChildHandle Int))
    cancelAgain <- runStoreIO store (cancelChild (ChildHandle Definitions.childName cancelledChild :: ChildHandle Int))
    cancelledRow <- runStoreIO store (lookupChild (unWorkflowId cancelledChild) "kenshouChild")
    cancelledIndex <- index Definitions.parentName cancelledParent
    childCancelledIndex <- index Definitions.childName cancelledChild
    cancelledAwait <- try @WorkflowChildCancelled (runParentFor cancelledParent)
    failParked <- runParentFor failedParent
    failPass <- runStoreIO store (resumeWorkflowsOnce (defaultWorkflowResumeOptions {maxAttempts = 1}) (Definitions.childRegistry sink))
    failedRow <- runStoreIO store (lookupChild (unWorkflowId failedChild) "kenshouChild")
    failedIndex <- index Definitions.parentName failedParent
    failedAwait <- try @WorkflowChildFailed (runParentFor failedParent)
    let has result key = either (const False) (Map.member key) result
        spawnKey = childSpawnStepName cid
        resultKey = childResultStepName cid
        cells =
          [ ("spawn-journaled-once", parked == Right Suspended && has parentIndexBefore spawnKey && case parentIndexBefore of Right rows -> Map.size rows == 1; _ -> False),
            ("child-discoverable-before-step", case (spawned, childBefore, childIndexBefore) of (Right (Just link), Right (Just instanceRow), Right rows) -> link.status == Running && instanceRow.status == WfRunning && Map.null rows; _ -> False),
            ("parent-parked-while-child-runs", case parentBefore of Right (Just row) -> row.status == WfSuspended; _ -> False),
            ("child-completion-propagated", case childAfter of Right (Just row) -> row.status == ChildCompleted && row.result == Just (toJSON (42 :: Int)); _ -> False),
            ("result-envelope-journaled", case parentIndexAfter of Right rows -> Map.lookup resultKey rows == Just (object ["ok" .= (42 :: Int)]); _ -> False),
            ("parent-completes-on-resume", case (pass1, pass2) of (Right first, Right second) -> first.discovered >= 1 && second.discovered >= 1 && finished == Right (Completed 43); _ -> False),
            ("no-repeated-effects", has finalIndex "after" && Map.lookup (unWorkflowId cid <> "/work") observed == Just 1 && Map.lookup (unWorkflowId wid <> "/after") observed == Just 1),
            ("cancel-is-idempotent", cancelParked == Right Suspended && cancelFirst == Right True && cancelAgain == Right False && case cancelledRow of Right (Just row) -> row.status == ChildCancelled; _ -> False),
            ("cancel-propagates-to-parent", case cancelledIndex of Right rows -> Map.lookup (childResultStepName cancelledChild) rows == Just (object ["cancelled" .= True]); _ -> False),
            ("cancel-marks-child-journal", has childCancelledIndex "__workflow_cancelled__"),
            ("cancelled-await-throws", either (const True) (const False) cancelledAwait),
            ("failed-child-persisted", failParked == Right Suspended && case (failPass, failedRow) of (Right summary, Right (Just row)) -> summary.failed >= 1 && row.status == ChildFailed && row.failureReason /= Nothing; _ -> False),
            ("failed-result-envelope", case failedIndex of Right rows -> Map.member (childResultStepName failedChild) rows; _ -> False),
            ("failed-await-throws", either (const True) (const False) failedAwait)
          ]
    recordWorkflowCells check cells
