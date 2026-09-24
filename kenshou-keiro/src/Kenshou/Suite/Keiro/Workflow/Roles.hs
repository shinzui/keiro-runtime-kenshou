module Kenshou.Suite.Keiro.Workflow.Roles (roles) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (race)
import Control.Monad (void)
import Data.Aeson (object, withObject, (.:?), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Keiro.Wake (WakeSignal (..), neverWake, wakeSignalFromStore)
import Keiro.Workflow.Resume (ResumeSummary (..), WorkflowResumeOptions (..), defaultWorkflowResumeOptions, resumeWorkflowsOnce)
import Kenshou.Core.Knob (knobInt, knobText, resolvedKnobsMap)
import Kenshou.Core.Role (ControlMessage (..), PostgresConnInfo (..), RoleContext (..), RoleName, WorkerInit (..), WorkerMessage (..), WorkerRole (..), mkRoleName)
import Kenshou.Suite.Keiro.Workflow.Definitions (DefinitionParams (..), approvalRegistry, defaultDefinitionParams, flakyRegistry, linearRegistry, sleeperRegistry)
import Kenshou.Suite.Keiro.Workflow.Effects (BoundaryPoint (..), CrashPlan (..), EffectSink (..), withEffectSink)
import Kenshou.Suite.Keiro.Workflow.Fixture (durableKirokuStore, withDurableStore)
import Kenshou.Suite.Keiro.Workflow.Knobs (resumeOptionsFrom, workflowKnobName)
import Kiroku.Store (defaultConnectionSettings, runStoreIO)
import Kiroku.Store.Connection (ConnectionSettingsM (..))

roles :: [WorkerRole]
roles = [WorkerRole (roleName "keiro/workflow-resume-worker") "Advances registered durable workflows; can self-kill at a named step boundary." resumeWorker]

roleName :: Text -> RoleName
roleName = either (error . Text.unpack) id . mkRoleName

resumeWorker :: RoleContext -> IO ()
resumeWorker context = case context.init.postgres of
  Nothing -> context.send (WrkError "workflow resume worker requires PostgreSQL")
  Just postgres -> case parseMaybe (withObject "workflow worker args" (\value -> (,,,) <$> value .:? "killAfter" <*> value .:? "stepDelayMicros" <*> value .:? "repairFlaky" <*> value .:? "wakeMode")) context.init.args of
    Nothing -> context.send (WrkError "invalid workflow worker arguments")
    Just (killAfter, stepDelayMicros, repairFlaky, wakeModeOverride) -> case optionsResult of
      Left err -> context.send (WrkError err)
      Right options -> do
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
                    registry = Map.unions [linearRegistry delayedSink params, sleeperRegistry delayedSink, approvalRegistry delayedSink, flakyRegistry delayedSink (repairFlaky == Just True)]
                wake <- case maybe wakeMode id wakeModeOverride of
                  "push" -> wakeSignalFromStore (durableKirokuStore fixture)
                  _ -> pure neverWake
                let loop = do
                      result <- runStoreIO (durableKirokuStore fixture) (resumeWorkflowsOnce options registry)
                      case result of
                        Left err -> context.send (WrkError (Text.pack (show err)))
                        Right summary -> context.send (WrkCustom "resume-pass" (object ["discovered" .= summary.discovered, "advanced" .= summary.advanced]))
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
