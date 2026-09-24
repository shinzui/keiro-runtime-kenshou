module Kenshou.Suite.Keiro.Workflow.DatabaseFaults (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically)
import Control.Monad (forM, forM_)
import Data.Aeson (object, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Keiro.Codec (decodeRecorded)
import Keiro.Workflow (WorkflowId (..), WorkflowJournalEvent (..), workflowJournalCodec, workflowStreamName)
import Keiro.Workflow.Instance (WorkflowInstanceRow (..), WorkflowStatus (..), lookupInstance, upsertInstanceTx)
import Kenshou.Check.Fact (Fact (..), FactKind (..))
import Kenshou.Check.Fault (Fault (..), FaultHandle (..))
import Kenshou.Check.Fault.Postgres (Backend (..), BackendSelector (..), listBackends, terminateBackends, withApplicationName)
import Kenshou.Check.Ledger (sealLedger)
import Kenshou.Check.Ledger.Read (discoverLedgers, foldFacts)
import Kenshou.Check.Process (ProgressSnapshot (..), awaitMark, awaitReady, progress, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (CheckEnv (..), withCheck)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (knobInt)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..), WorkerMessage (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Workflow.Definitions (DefinitionParams (..), defaultDefinitionParams, expectedLinearSteps, linearName)
import Kenshou.Suite.Keiro.Workflow.Fixture (durableKirokuStore, withDurableStore)
import Kenshou.Suite.Keiro.Workflow.Knobs (workflowKnobName, workflowKnobs)
import Kenshou.Suite.Keiro.Workflow.Oracle (journalStepIdentity, recordWorkflowCells)
import Kiroku.Store (defaultConnectionSettings, readStreamForward, runStoreIO, runTransaction)
import Kiroku.Store.Types (RecordedEvent (..), StreamVersion (..))

scenarios :: [Scenario]
scenarios = [databaseFaults]

databaseFaults :: Scenario
databaseFaults =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/workflow/concurrency/database-faults"),
      revision = 1,
      summary = "Terminates a resume worker's PostgreSQL backends during a step and checks worker survival and recovery.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = workflowKnobs,
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku, SchemaKeiro] [] False)},
      knownDefect = Nothing,
      run = runDatabaseFaults
    }

runDatabaseFaults :: RunContext -> IO ScenarioReport
runDatabaseFaults context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let store = durableKirokuStore fixture
        count = fromIntegral (knobInt context.knobs (workflowKnobName "workflow.instances")) :: Int
        params = defaultDefinitionParams {steps = fromIntegral (knobInt context.knobs (workflowKnobName "workflow.steps"))}
        wids = [WorkflowId ("database-fault-" <> Text.pack (show index)) | index <- [0 .. count - 1]]
        completed = do
          rows <- traverse (runStoreIO store . lookupInstance linearName) wids
          pure (all (\case Right (Just row) -> row.status == WfCompleted; _ -> False) rows)
    seeded <- traverse (\(WorkflowId wid) -> runStoreIO store (runTransaction (upsertInstanceTx wid "kenshouLinear" 0 WfRunning Nothing))) wids
    sealLedger check.ledger
    (backendPresent, survived, recovered) <- withSupervisor check \supervisor -> do
      spec <- roleProcess check "keiro/workflow-resume-worker" 0 (object ["stepDelayMicros" .= (500000 :: Int)])
      worker <- spawn supervisor (withApplicationName "kenshou-workflow-fault" spec)
      awaitReady worker 10000
      sendCommand worker CtlStart
      awaitMark worker "effect-flushed" 15000
      backends <- listBackends (requirePostgres context)
      let backendPresent = any (Text.isPrefixOf "kenshou-workflow-fault" . (.applicationName)) backends
      handle <- (terminateBackends (requirePostgres context) (ByApplicationName "kenshou-workflow-fault%")).inject
      handle.heal
      survivors <- forM [1, 2] \index -> do
        survivorSpec <- roleProcess check "keiro/workflow-resume-worker" index (object [])
        survivor <- spawn supervisor survivorSpec
        awaitReady survivor 10000
        sendCommand survivor CtlStart
        pure survivor
      done <- waitUntil completed 480
      state <- atomically (progress worker)
      let survived = case state.lastMessage of Just (WrkDone _) -> False; _ -> True
      _ <- stopGracefully supervisor worker 5000
      forM_ survivors (\survivor -> stopGracefully supervisor survivor 5000)
      pure (backendPresent, survived, done)
    rows <- traverse (runStoreIO store . lookupInstance linearName) wids
    journals <- traverse (\wid -> runStoreIO store (readStreamForward (workflowStreamName linearName wid) (StreamVersion 0) (fromIntegral (params.steps + 2)))) wids
    ledgers <- discoverLedgers check.ledgerDirectory
    effects <- foldFacts ledgers Map.empty \counts fact ->
      pure if fact.kind == Effect then Map.insertWith (+) fact.key (1 :: Int) counts else counts
    let expectedSteps = expectedLinearSteps params
        expectedKeys = Set.fromList [wid <> "/0/" <> stepName | WorkflowId wid <- wids, stepName <- expectedSteps]
        terminal result = case result of Right (Just row) -> row.status == WfCompleted && row.attempts == 0; _ -> False
        journalCorrect wid result = case result of
          Left _ -> False
          Right events -> case traverse (decodeRecorded workflowJournalCodec) (Vector.toList events) of
            Left _ -> False
            Right decoded ->
              let steps = [(name, event.eventId) | (event, StepRecorded name _ _) <- zip (Vector.toList events) decoded]
               in length decoded == params.steps + 1 && length [() | WorkflowCompleted {} <- decoded] == 1 && journalStepIdentity linearName wid 0 expectedSteps steps
    putSummary context Measurements "workflow-database-faults" (object ["instances" .= count, "duplicateEffects" .= sum [max 0 (value - 1) | value <- Map.elems effects]])
    recordWorkflowCells
      check
      [ ("instances-seeded", length seeded == count && all (== Right ()) seeded),
        ("backend-target-present", backendPresent),
        ("worker-survived-backend-kill", survived),
        ("all-instances-completed", recovered && all terminal rows),
        ("journals-exactly-once", and (zipWith journalCorrect wids journals)),
        ("effects-at-least-once", Map.keysSet effects == expectedKeys && all (>= 1) (Map.elems effects))
      ]

waitUntil :: IO Bool -> Int -> IO Bool
waitUntil _ 0 = pure False
waitUntil predicate remaining = do
  done <- predicate
  if done then pure True else threadDelay 250000 >> waitUntil predicate (remaining - 1)
