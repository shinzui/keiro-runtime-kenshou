module Kenshou.Suite.Keiro.Workflow.CrashBackoff (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM, forM_)
import Data.Aeson (object, (.=))
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Data.Vector qualified as Vector
import Keiro.Codec (decodeRecorded)
import Keiro.Workflow (WorkflowId (..), WorkflowJournalEvent (..), WorkflowOutcome (..), runWorkflow, workflowJournalCodec, workflowStreamName)
import Keiro.Workflow.Instance (ResurrectOutcome (..), WorkflowInstanceRow (..), WorkflowStatus (..), lookupInstance, resurrectFailedWorkflow, upsertInstanceTx)
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
import Kenshou.Suite.Keiro.Workflow.Definitions (flakyName, flakyWorkflow)
import Kenshou.Suite.Keiro.Workflow.Effects (EffectSink (..))
import Kenshou.Suite.Keiro.Workflow.Fixture (durableKirokuStore, withDurableStore)
import Kenshou.Suite.Keiro.Workflow.Knobs (workflowKnobName, workflowKnobs)
import Kenshou.Suite.Keiro.Workflow.Oracle (backoffLadder, recordWorkflowCells)
import Kiroku.Store (defaultConnectionSettings, readStreamForward, runStoreIO, runTransaction)
import Kiroku.Store.Types (StreamVersion (..))

scenarios :: [Scenario]
scenarios = [crashBackoff]

crashBackoff :: Scenario
crashBackoff =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/workflow/concurrency/crash-backoff-and-max-attempts"),
      revision = 1,
      summary = "Checks the durable retry ladder, failure marker, quiet terminal state, and operator resurrection of a repaired workflow.",
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
      run = runBackoff
    }

runBackoff :: RunContext -> IO ScenarioReport
runBackoff context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let store = durableKirokuStore fixture
        wid = WorkflowId "flaky-backoff"
        maxAttempts = fromIntegral (knobInt context.knobs (workflowKnobName "workflow.max-attempts")) :: Int
        row = runStoreIO store (lookupInstance flakyName wid)
        failed = do
          result <- row
          pure (case result of Right (Just value) -> value.status == WfFailed; _ -> False)
        completed = do
          result <- row
          pure (case result of Right (Just value) -> value.status == WfCompleted; _ -> False)
    seeded <- runStoreIO store (runTransaction (upsertInstanceTx "flaky-backoff" "kenshouFlaky" 0 WfRunning Nothing))
    sealLedger check.ledger
    reachedFailure <- withSupervisor check \supervisor -> do
      workers <- forM [0, 1] \index -> do
        spec <- roleProcess check "keiro/workflow-resume-worker" index (object [])
        worker <- spawn supervisor spec
        awaitReady worker 10000
        sendCommand worker CtlStart
        pure worker
      done <- waitUntil failed 280
      if done then threadDelay 16000000 else pure ()
      forM_ workers (\worker -> stopGracefully supervisor worker 5000)
      pure done
    failureRow <- row
    firstFacts <- effectFacts check
    let firstTimes = sort [posixSecondsToUTCTime (fromIntegral fact.wall / 1000000) | fact <- firstFacts]
        noExtra = length firstTimes == maxAttempts
        backoff = length firstTimes == maxAttempts && backoffLadder 2 1.5 firstTimes == Right ()
        quietSink = EffectSink {recordEffect = \_ -> pure (), boundary = \_ -> pure ()}
    direct <- runStoreIO store (runWorkflow flakyName wid (flakyWorkflow quietSink False wid))
    resurrected <- runStoreIO store (resurrectFailedWorkflow flakyName wid)
    repaired <- withSupervisor check \supervisor -> do
      spec <- roleProcess check "keiro/workflow-resume-worker" 2 (object ["repairFlaky" .= True])
      worker <- spawn supervisor spec
      awaitReady worker 10000
      sendCommand worker CtlStart
      done <- waitUntil completed 80
      _ <- stopGracefully supervisor worker 5000
      pure done
    finalRow <- row
    journal <- runStoreIO store (readStreamForward (workflowStreamName flakyName wid) (StreamVersion 0) 16)
    finalFacts <- effectFacts check
    let retainedFailure = case journal of
          Right rows -> case traverse (decodeRecorded workflowJournalCodec) (Vector.toList rows) of
            Right events -> length [() | WorkflowFailed {} <- events] == 1 && length [() | StepRecorded "boom" _ _ <- events] == 1 && length [() | WorkflowCompleted {} <- events] == 1
            Left _ -> False
          Left _ -> False
        terminal rowResult status = case rowResult of Right (Just value) -> value.status == status; _ -> False
    putSummary context Measurements "crash-backoff" (object ["attempts" .= maxAttempts, "effectCountBeforeRepair" .= length firstTimes, "effectCountAfterRepair" .= length finalFacts])
    recordWorkflowCells
      check
      [ ("instance-seeded", seeded == Right ()),
        ("failed-at-ceiling", reachedFailure && terminal failureRow WfFailed && case failureRow of Right (Just value) -> value.attempts == fromIntegral maxAttempts; _ -> False),
        ("backoff-ladder", backoff),
        ("terminal-stays-quiet", noExtra && direct == Right Failed),
        ("resurrection-accepted", resurrected == Right WorkflowResurrected),
        ("repaired-completes", repaired && terminal finalRow WfCompleted && length finalFacts == maxAttempts + 1),
        ("failed-marker-retained", retainedFailure)
      ]

effectFacts :: CheckEnv -> IO [Fact]
effectFacts check = do
  ledgers <- discoverLedgers check.ledgerDirectory
  foldFacts ledgers [] \facts fact -> pure (if fact.kind == Effect && fact.key == "flaky-backoff/0/boom" then fact : facts else facts)

waitUntil :: IO Bool -> Int -> IO Bool
waitUntil _ 0 = pure False
waitUntil predicate remaining = do
  done <- predicate
  if done then pure True else threadDelay 250000 >> waitUntil predicate (remaining - 1)
