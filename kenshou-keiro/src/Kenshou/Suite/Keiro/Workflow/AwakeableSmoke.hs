module Kenshou.Suite.Keiro.Workflow.AwakeableSmoke (scenarios) where

import Control.Exception (try)
import Data.Aeson (Value (..), withObject, (.:))
import Data.Aeson.Types (parseMaybe)
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.UUID qualified as UUID
import Keiro.Workflow (CancelWorkflowOutcome (..), WorkflowId (..), WorkflowOutcome (..), awakeableStepPrefix, loadStepIndex, runWorkflow)
import Keiro.Workflow.Awakeable (AwakeableId (..), WorkflowAwakeableCancelled, awakeableIdText, cancelAwakeable, signalAwakeable)
import Keiro.Workflow.Awakeable.Schema (AwakeableRow (..), lookupAwakeable)
import Keiro.Workflow.Awakeable.Schema qualified as Awakeable
import Keiro.Workflow.Instance (cancelWorkflow)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Workflow.Definitions (approvalName, approvalWorkflow)
import Kenshou.Suite.Keiro.Workflow.Effects (EffectFact (..), EffectSink (..))
import Kenshou.Suite.Keiro.Workflow.Fixture (durableKirokuStore, withDurableStore)
import Kenshou.Suite.Keiro.Workflow.Oracle (recordWorkflowCells)
import Kiroku.Store (defaultConnectionSettings, runStoreIO)

scenarios :: [Scenario]
scenarios = [awakeableSignalSemantics]

awakeableSignalSemantics :: Scenario
awakeableSignalSemantics =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/workflow/correctness/awakeable-signal-semantics"),
      revision = 1,
      summary = "Checks durable approval ids, idempotent signals, terminal-owner refusal, and cancellation.",
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
      run = runAwakeableSignalSemantics
    }

runAwakeableSignalSemantics :: RunContext -> IO ScenarioReport
runAwakeableSignalSemantics context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    published <- newIORef (Nothing :: Maybe AwakeableId)
    earlySignal <- newIORef []
    let store = durableKirokuStore fixture
        capture =
          EffectSink
            { recordEffect = \fact -> case parseMaybe (withObject "publication" (\value -> value .: "awakeableId")) fact.attributes of
                Just aid -> writeIORef published (Just aid)
                Nothing -> pure (),
              boundary = \_ -> pure ()
            }
        runApproval wid = runStoreIO store (runWorkflow approvalName wid (approvalWorkflow capture wid))
        readAid = readIORef published >>= maybe (fail "approval did not publish an awakeable id") pure
        lookupRow aid = runStoreIO store (lookupAwakeable (case aid of AwakeableId value -> value))
        stepKey aid = awakeableStepPrefix <> awakeableIdText aid
        normalId = WorkflowId "approval-normal"
        terminalId = WorkflowId "approval-terminal"
        cancelledId = WorkflowId "approval-cancelled"
        earlyId = WorkflowId "approval-early"
        earlySink =
          capture
            { recordEffect = \fact -> case parseMaybe (withObject "publication" (\value -> value .: "awakeableId")) fact.attributes of
                Just aid -> do
                  writeIORef published (Just aid)
                  result <- runStoreIO store (signalAwakeable aid ("early" :: Text))
                  atomicModifyIORef' earlySignal (\results -> (results <> [result], ()))
                Nothing -> pure ()
            }
    first <- runApproval normalId
    normalAid <- readAid
    pending <- lookupRow normalAid
    signalled <- runStoreIO store (signalAwakeable normalAid ("yes" :: Text))
    duplicate <- runStoreIO store (signalAwakeable normalAid ("no" :: Text))
    completedRow <- lookupRow normalAid
    unknown <- runStoreIO store (signalAwakeable (AwakeableId UUID.nil) ("unknown" :: Text))
    resumed <- runApproval normalId
    normalIndex <- runStoreIO store (loadStepIndex approvalName normalId 0)
    writeIORef published Nothing
    terminalFirst <- runApproval terminalId
    terminalAid <- readAid
    cancelledOwner <- runStoreIO store (cancelWorkflow approvalName terminalId)
    terminalSignal <- runStoreIO store (signalAwakeable terminalAid ("late" :: Text))
    terminalRow <- lookupRow terminalAid
    terminalIndex <- runStoreIO store (loadStepIndex approvalName terminalId 0)
    writeIORef published Nothing
    cancelledFirst <- runApproval cancelledId
    cancelledAid <- readAid
    abandoned <- runStoreIO store (cancelAwakeable cancelledAid)
    abandonedRow <- lookupRow cancelledAid
    cancelledIndex <- runStoreIO store (loadStepIndex approvalName cancelledId 0)
    afterCancel <- try @WorkflowAwakeableCancelled (runApproval cancelledId)
    writeIORef published Nothing
    early <- runStoreIO store (runWorkflow approvalName earlyId (approvalWorkflow earlySink earlyId))
    earlyAid <- readAid
    earlySignalResult <- readIORef earlySignal
    earlyIndex <- runStoreIO store (loadStepIndex approvalName earlyId 0)
    let row result predicate = case result of Right (Just value) -> predicate value; _ -> False
        indexHas result key = either (const False) (Map.member key) result
        cells =
          [ ("pending-after-publication", first == Right Suspended && row pending (\value -> value.status == Awakeable.Pending && value.payload == Nothing)),
            ("first-signal-wins", signalled == Right True && duplicate == Right False && row completedRow (\value -> value.status == Awakeable.Completed && value.payload == Just (String "yes"))),
            ("unknown-refused", unknown == Right False),
            ("signal-journal-and-resume", resumed == Right (Completed "yes") && indexHas normalIndex (stepKey normalAid)),
            ("terminal-signal-settles-row-only", terminalFirst == Right Suspended && cancelledOwner == Right WorkflowCancelRecorded && terminalSignal == Right True && row terminalRow (\value -> value.status == Awakeable.Completed && value.payload == Just (String "late")) && not (indexHas terminalIndex (stepKey terminalAid))),
            ("cancel-without-result-journal", cancelledFirst == Right Suspended && abandoned == Right True && row abandonedRow (\value -> value.status == Awakeable.Cancelled && value.payload == Nothing) && not (indexHas cancelledIndex (stepKey cancelledAid))),
            ("cancelled-await-throws", either (const True) (const False) afterCancel),
            ("signal-before-await", case earlySignalResult of Right True : rest -> all (== Right False) rest && early == Right (Completed "early") && indexHas earlyIndex (stepKey earlyAid); _ -> False)
          ]
    recordWorkflowCells check cells
