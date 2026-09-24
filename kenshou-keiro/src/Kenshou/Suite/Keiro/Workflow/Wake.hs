module Kenshou.Suite.Keiro.Workflow.Wake (scenarios) where

import Control.Concurrent (threadDelay)
import Data.Aeson (object, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.UUID (UUID)
import GHC.Clock (getMonotonicTimeNSec)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx
import Keiro.Workflow (WorkflowId (..))
import Keiro.Workflow.Awakeable (AwakeableId (..), signalAwakeable)
import Keiro.Workflow.Instance (WorkflowInstanceRow (..), WorkflowStatus (..), lookupInstance, upsertInstanceTx)
import Kenshou.Check.Fault (Fault (..), FaultHandle (..))
import Kenshou.Check.Fault.Postgres (Backend (..), BackendSelector (..), listBackends, terminateBackends)
import Kenshou.Check.Process (awaitReady, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (knobInt)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Workflow.Definitions (approvalName)
import Kenshou.Suite.Keiro.Workflow.Fixture (durableKirokuStore, withDurableStore)
import Kenshou.Suite.Keiro.Workflow.Knobs (workflowKnobName, workflowKnobs)
import Kenshou.Suite.Keiro.Workflow.Oracle (recordWorkflowCells)
import Kiroku.Store (defaultConnectionSettings, runStoreIO, runTransaction)

scenarios :: [Scenario]
scenarios = [pushFallback]

pushFallback :: Scenario
pushFallback =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/wake/correctness/push-fallback-when-notify-dropped"),
      revision = 1,
      summary = "Checks that a never-waking push source and a killed listener both fall back to durable polling.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = workflowKnobs,
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
      run = runFallback
    }

runFallback :: RunContext -> IO ScenarioReport
runFallback context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let store = durableKirokuStore fixture
        fallbackMs = fromIntegral (knobInt context.knobs (workflowKnobName "workflow.poll-interval-ms")) :: Int
        deadlineMs = fallbackMs + 2000
        instanceRow wid = runStoreIO store (lookupInstance approvalName wid)
        status wid expected = do
          row <- instanceRow wid
          pure (case row of Right (Just value) -> value.status == expected; _ -> False)
        awakeable wid = runStoreIO store (runTransaction (Tx.statement (unWorkflowId wid) awakeableStatement))
        runArm index mode killListener = do
          let wid = WorkflowId ("wake-fallback-" <> Text.pack (show index))
          seeded <- runStoreIO store (runTransaction (upsertInstanceTx (unWorkflowId wid) "kenshouApproval" 0 WfRunning Nothing))
          (parked, found, listenerPresent, signal, finished, elapsedMs) <- withSupervisor check \supervisor -> do
            spec <- roleProcess check "keiro/workflow-resume-worker" index (object ["wakeMode" .= (mode :: Text)])
            worker <- spawn supervisor spec
            awaitReady worker 10000
            sendCommand worker CtlStart
            parked <- waitUntil (status wid WfSuspended) 80
            aid <- awakeable wid
            backends <- listBackends (requirePostgres context)
            let listenerPresent = any ((== "kiroku-listener") . (.applicationName)) backends
            if killListener
              then do
                handle <- (terminateBackends (requirePostgres context) (ByApplicationName "kiroku-listener")).inject
                handle.heal
              else pure ()
            start <- getMonotonicTimeNSec
            signal <- traverse (\value -> runStoreIO store (signalAwakeable (AwakeableId value) ("approved" :: Text))) (either (const Nothing) id aid)
            finished <- waitUntil (status wid WfCompleted) 80
            end <- getMonotonicTimeNSec
            _ <- stopGracefully supervisor worker 5000
            pure (parked, aid, listenerPresent, signal, finished, fromIntegral ((end - start) `div` 1000000) :: Int)
          pure (seeded == Right (), parked, either (const False) (/= Nothing) found, listenerPresent, signal == Just (Right True), finished, elapsedMs)
    never <- runArm 0 "push-never-wake" False
    dropped <- runArm 1 "push" True
    let armPassed (seeded, parked, found, _, signalled, finished, durationMs) = seeded && parked && found && signalled && finished && durationMs <= deadlineMs
        listenerFound (_, _, _, found, _, _, _) = found
        elapsed (_, _, _, _, _, _, value) = value
    putSummary context Measurements "wake-fallback" (object ["fallbackMillis" .= fallbackMs, "neverWakeMillis" .= elapsed never, "listenerKillMillis" .= elapsed dropped])
    recordWorkflowCells
      check
      [ ("never-wake-falls-back", armPassed never),
        ("listener-backend-found", listenerFound dropped),
        ("listener-kill-falls-back", armPassed dropped)
      ]

waitUntil :: IO Bool -> Int -> IO Bool
waitUntil _ 0 = pure False
waitUntil predicate remaining = do
  done <- predicate
  if done then pure True else threadDelay 250000 >> waitUntil predicate (remaining - 1)

awakeableStatement :: Statement.Statement Text (Maybe UUID)
awakeableStatement =
  Statement.preparable
    "SELECT awakeable_id FROM keiro.keiro_awakeables WHERE owner_workflow_name = 'kenshouApproval' AND owner_workflow_id = $1 ORDER BY created_at DESC LIMIT 1"
    (Encoders.param (Encoders.nonNullable Encoders.text))
    (Decoders.rowMaybe (Decoders.column (Decoders.nonNullable Decoders.uuid)))
