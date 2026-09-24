module Kenshou.Suite.Keiro.Workflow.ResumeRace (scenarios) where

import Control.Concurrent (threadDelay)
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
import Kenshou.Check.Ledger (sealLedger)
import Kenshou.Check.Ledger.Read (discoverLedgers, foldFacts)
import Kenshou.Check.Process (awaitReady, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (CheckEnv (..), withCheck)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (knobInt)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Workflow.Definitions (DefinitionParams (..), defaultDefinitionParams, expectedLinearSteps, linearName)
import Kenshou.Suite.Keiro.Workflow.Fixture (durableKirokuStore, withDurableStore)
import Kenshou.Suite.Keiro.Workflow.Knobs (workflowKnobName, workflowKnobs)
import Kenshou.Suite.Keiro.Workflow.Oracle (journalStepIdentity, recordWorkflowCells)
import Kiroku.Store (defaultConnectionSettings, readStreamForward, runStoreIO, runTransaction)
import Kiroku.Store.Types (RecordedEvent (..), StreamVersion (..))

scenarios :: [Scenario]
scenarios = [resumeWorkersRace]

resumeWorkersRace :: Scenario
resumeWorkersRace =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/workflow/concurrency/resume-workers-race"),
      revision = 1,
      summary = "Races multiple resume worker processes over deferred linear workflows, including advances above the store pool size.",
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
      run = runResumeRace
    }

runResumeRace :: RunContext -> IO ScenarioReport
runResumeRace context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let store = durableKirokuStore fixture
        instanceCount = fromIntegral (knobInt context.knobs (workflowKnobName "workflow.instances")) :: Int
        workerCount = fromIntegral (knobInt context.knobs (workflowKnobName "workflow.resume-processes")) :: Int
        params = defaultDefinitionParams {steps = fromIntegral (knobInt context.knobs (workflowKnobName "workflow.steps"))}
        wids = [WorkflowId ("resume-race-" <> Text.pack (show index)) | index <- [0 .. instanceCount - 1]]
        completed = do
          rows <- traverse (runStoreIO store . lookupInstance linearName) wids
          pure (all (\case Right (Just row) -> row.status == WfCompleted; _ -> False) rows)
    seeded <- traverse (\(WorkflowId wid) -> runStoreIO store (runTransaction (upsertInstanceTx wid "kenshouLinear" 0 WfRunning Nothing))) wids
    sealLedger check.ledger
    finished <- withSupervisor check \supervisor -> do
      workers <- forM [0 .. workerCount - 1] \index -> do
        spec <- roleProcess check "keiro/workflow-resume-worker" index (object [])
        worker <- spawn supervisor spec
        awaitReady worker 10000
        pure worker
      forM_ workers (\worker -> sendCommand worker CtlStart)
      done <- waitUntil completed 320
      forM_ workers (\worker -> stopGracefully supervisor worker 5000)
      pure done
    rows <- traverse (runStoreIO store . lookupInstance linearName) wids
    journals <- traverse (\wid -> runStoreIO store (readStreamForward (workflowStreamName linearName wid) (StreamVersion 0) (fromIntegral (params.steps + 2)))) wids
    ledgers <- discoverLedgers check.ledgerDirectory
    effects <- foldFacts ledgers Map.empty \counts fact ->
      pure if fact.kind == Effect then Map.insertWith (+) fact.key (1 :: Int) counts else counts
    let expectedSteps = expectedLinearSteps params
        expectedKeys = Set.fromList [wid <> "/0/" <> stepName | WorkflowId wid <- wids, stepName <- expectedSteps]
        journalCorrect wid result = case result of
          Left _ -> False
          Right events -> case traverse (decodeRecorded workflowJournalCodec) (Vector.toList events) of
            Left _ -> False
            Right decoded ->
              let steps = [(name, event.eventId) | (event, StepRecorded name _ _) <- zip (Vector.toList events) decoded]
               in length decoded == params.steps + 1
                    && length [() | WorkflowCompleted {} <- decoded] == 1
                    && journalStepIdentity linearName wid 0 expectedSteps steps
        terminal result = case result of Right (Just row) -> row.status == WfCompleted && row.attempts == 0; _ -> False
        failedRows = length [() | result <- rows, not (terminal result)]
    putSummary context Measurements "resume-workers-race" (object ["instances" .= instanceCount, "workers" .= workerCount, "maxConcurrentAdvances" .= knobInt context.knobs (workflowKnobName "workflow.max-concurrent-advances"), "poolSize" .= knobInt context.knobs (workflowKnobName "workflow.pool-size"), "failedRows" .= failedRows])
    recordWorkflowCells
      check
      [ ("all-deferred-instances-seeded", length seeded == instanceCount && all (== Right ()) seeded),
        ("all-workers-finished", finished && all terminal rows),
        ("journals-exactly-once", and (zipWith journalCorrect wids journals)),
        ("one-effect-per-step", Map.keysSet effects == expectedKeys && all (== 1) (Map.elems effects))
      ]

waitUntil :: IO Bool -> Int -> IO Bool
waitUntil _ 0 = pure False
waitUntil predicate remaining = do
  complete <- predicate
  if complete then pure True else threadDelay 250000 >> waitUntil predicate (remaining - 1)
