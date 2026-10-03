module Kenshou.Suite.Keiro.Workflow.Roles (roles) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (race)
import Control.Monad (forM_, void, when)
import Data.Aeson (Value, object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Keiro.Wake (WakeSignal (..), neverWake, wakeSignalFromStore)
import Keiro.Workflow (WorkflowId (..), WorkflowName (..), WorkflowRunOptions (..), defaultWorkflowRunOptions, mkWorkflowName)
import Keiro.Workflow.Child (runChildWorkflow)
import Keiro.Workflow.Instance (CancelWorkflowOutcome (..), WorkflowStatus (..), cancelWorkflow)
import Keiro.Workflow.Resume (ResumeSummary (..), WorkflowResumeOptions (..), defaultWorkflowResumeOptions, resumeWorkflowsOnce)
import Kenshou.Core.Knob (knobInt, knobText, resolvedKnobsMap)
import Kenshou.Core.Role (ControlMessage (..), PostgresConnInfo (..), RoleContext (..), RoleName, WorkerInit (..), WorkerMessage (..), WorkerRole (..), mkRoleName)
import Kenshou.Suite.Keiro.Workflow.Definitions (DefinitionParams (..), approvalRegistry, childName, childRegistry, childWorkflow, defaultDefinitionParams, flakyRegistry, linearRegistry, sleeperRegistry)
import Kenshou.Suite.Keiro.Workflow.Effects (BoundaryPoint (..), CrashPlan (..), EffectSink (..), withEffectSink)
import Kenshou.Suite.Keiro.Workflow.Fixture (durableKirokuStore, withDurableStore)
import Kenshou.Suite.Keiro.Workflow.Knobs (resumeOptionsFrom, workflowKnobName)
import Kiroku.Store (defaultConnectionSettings, runStoreIO)
import Kiroku.Store.Connection (ConnectionSettingsM (..))

roles :: [WorkerRole]
roles =
  [ WorkerRole (roleName "keiro/workflow-resume-worker") "Advances registered durable workflows; can self-kill at a named step boundary." resumeWorker,
    WorkerRole (roleName "keiro/workflow-driver") "Drives a child completion with a crash hook, or races operator cancellations." driverWorker
  ]

roleName :: Text -> RoleName
roleName = either (error . Text.unpack) id . mkRoleName

resumeWorker :: RoleContext -> IO ()
resumeWorker context = case context.init.postgres of
  Nothing -> context.send (WrkError "workflow resume worker requires PostgreSQL")
  Just postgres -> case parseMaybe (withObject "workflow worker args" (\value -> (,,,,) <$> value .:? "killAfter" <*> value .:? "stepDelayMicros" <*> value .:? "repairFlaky" <*> value .:? "wakeMode" <*> value .:? "maxAttempts")) context.init.args of
    Nothing -> context.send (WrkError "invalid workflow worker arguments")
    Just (killAfter, stepDelayMicros, repairFlaky, wakeModeOverride, maxAttemptsOverride) -> case optionsResult of
      Left err -> context.send (WrkError err)
      Right configuredOptions -> do
        let options = maybe configuredOptions (\ceiling' -> configuredOptions {maxAttempts = ceiling'}) maxAttemptsOverride
        context.send WrkReady
        context.receive >>= \case
          Just CtlStart ->
            withDurableStore settings \fixture ->
              withEffectSink context (maybe [] (\name -> [CrashPlan (AfterStepAction name) 1]) killAfter) \sink -> do
                let delayedSink =
                      sink
                        { recordEffect = \fact -> do
                            sink.recordEffect fact
                            case stepDelayMicros of
                              Just delay | delay > 0 -> context.send (WrkCustom "effect-flushed" (object [])) >> threadDelay delay
                              _ -> pure ()
                        }
                    registry = Map.unions [linearRegistry delayedSink params, sleeperRegistry delayedSink, approvalRegistry delayedSink, flakyRegistry delayedSink (repairFlaky == Just True), childRegistry delayedSink]
                wake <- case maybe wakeMode id wakeModeOverride of
                  "push" -> wakeSignalFromStore (durableKirokuStore fixture)
                  _ -> pure neverWake
                let loop = do
                      result <- runStoreIO (durableKirokuStore fixture) (resumeWorkflowsOnce options registry)
                      case result of
                        Left err -> context.send (WrkError (Text.pack (show err)))
                        Right summary -> context.send (WrkCustom "resume-pass" (summaryJson summary))
                      race context.receive (waitForWake wake options.pollInterval) >>= \case
                        Left (Just (CtlStop _)) -> context.send (WrkDone Nothing)
                        Left Nothing -> pure ()
                        _ -> loop
                loop
          _ -> void (context.send (WrkDone (Just "not started")))
      where
        configured = Map.member (workflowKnobName "workflow.lease-ttl-seconds") (resolvedKnobsMap context.init.knobs)
        settings =
          (defaultConnectionSettings postgres.connectionString)
            { poolSize = if configured then fromIntegral (knobInt context.init.knobs (workflowKnobName "workflow.pool-size")) else 10
            }
        params =
          defaultDefinitionParams
            { steps = if configured then fromIntegral (knobInt context.init.knobs (workflowKnobName "workflow.steps")) else defaultDefinitionParams.steps
            }
        optionsResult =
          if configured
            then resumeOptionsFrom context.init.knobs
            else Right defaultWorkflowResumeOptions {pollInterval = 100000, leaseTtl = 2}
        wakeMode = if configured then knobText context.init.knobs (workflowKnobName "workflow.wake-mode") else "poll"

-- | Every count a pass reports. A lost lease surfaces as 'leaseSkipped'.
summaryJson :: ResumeSummary -> Value
summaryJson summary =
  object
    [ "discovered" .= summary.discovered,
      "advanced" .= summary.advanced,
      "resumed" .= summary.resumed,
      "completed" .= summary.completed,
      "stillSuspended" .= summary.stillSuspended,
      "failed" .= summary.failed,
      "transientErrors" .= summary.transientErrors,
      "leaseSkipped" .= summary.leaseSkipped,
      "paced" .= summary.paced,
      "sleepDue" .= summary.sleepDue
    ]

-- | One-shot operations that need their own operating-system process.
-- @run-child@ drives a child through 'runChildWorkflow' and self-kills on the
-- @killOnAppend@-th committed journal append. @cancel@ calls 'cancelWorkflow'
-- for each target in order and reports every outcome.
driverWorker :: RoleContext -> IO ()
driverWorker context = case context.init.postgres of
  Nothing -> context.send (WrkError "workflow driver requires PostgreSQL")
  Just postgres -> case parseMaybe (withObject "workflow driver args" (.: "op")) context.init.args of
    Just ("run-child" :: Text) -> case parseMaybe (withObject "run-child args" (\value -> (,) <$> value .: "childId" <*> value .: "killOnAppend")) context.init.args of
      Nothing -> context.send (WrkError "invalid run-child arguments")
      Just (cid, killOnAppend) -> started \fixture -> withEffectSink context [CrashPlan AfterChildCompletionMarker 1] \sink -> do
        appends <- newIORef (0 :: Int)
        let hook = do
              nth <- atomicModifyIORef' appends (\count -> (count + 1, count + 1))
              when (nth == killOnAppend) (sink.boundary AfterChildCompletionMarker)
            childId = WorkflowId cid
        outcome <- runStoreIO (durableKirokuStore fixture) (runChildWorkflow defaultWorkflowRunOptions {onJournalAppend = Just hook} childName childId (childWorkflow sink childId))
        context.send (WrkCustom "child-run" (object ["outcome" .= Text.pack (show outcome)]))
    Just "cancel" -> case parseMaybe (withObject "cancel args" (.: "targets")) context.init.args of
      Nothing -> context.send (WrkError "invalid cancel arguments")
      Just (targets :: [(Text, Text)]) -> started \fixture ->
        forM_ targets \(rawName, wid) -> case mkWorkflowName rawName of
          Left err -> context.send (WrkError (Text.pack (show err)))
          Right name -> do
            outcome <- runStoreIO (durableKirokuStore fixture) (cancelWorkflow name (WorkflowId wid))
            context.send (WrkCustom "cancel-result" (object ["workflowName" .= unWorkflowName name, "workflowId" .= wid, "outcome" .= renderCancel outcome]))
    _ -> context.send (WrkError "unknown workflow driver operation")
    where
      started action = do
        context.send WrkReady
        context.receive >>= \case
          Just CtlStart -> withDurableStore (defaultConnectionSettings postgres.connectionString) action
          _ -> void (context.send (WrkDone (Just "not started")))

renderCancel :: Either error CancelWorkflowOutcome -> Text
renderCancel = \case
  Left _ -> "store-error"
  Right WorkflowCancelRecorded -> "recorded"
  Right (WorkflowAlreadyTerminal status) ->
    "already-" <> case status of
      WfCompleted -> "completed"
      WfCancelled -> "cancelled"
      WfFailed -> "failed"
      other -> Text.toLower (Text.pack (show other))
  Right WorkflowCancelUnknown -> "unknown"
