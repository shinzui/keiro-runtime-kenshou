module Kenshou.Suite.Keiro.Workflow.CrashSmoke (scenarios) where

import Control.Concurrent (threadDelay)
import Data.Aeson (object, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (getCurrentTime)
import Data.Vector qualified as Vector
import Keiro.Codec (decodeRecorded)
import Keiro.Workflow (WorkflowId (..), WorkflowJournalEvent (..), WorkflowName (..), completedStepName, loadStepIndex, workflowJournalCodec, workflowStreamName)
import Keiro.Workflow.Instance (WorkflowInstanceRow (..), WorkflowStatus (..), lookupInstance, upsertInstanceTx)
import Kenshou.Check.Fact (Fact (..), FactKind (..))
import Kenshou.Check.Ledger (sealLedger)
import Kenshou.Check.Ledger.Read (discoverLedgers, foldFacts)
import Kenshou.Check.Process (awaitReady, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (CheckEnv (..), finishWithVerdicts, withCheck)
import Kenshou.Check.Verdict (InvariantClass (..), Verdict (..), VerdictStatus (..))
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Workflow.Definitions (defaultDefinitionParams, expectedLinearSteps, linearName)
import Kenshou.Suite.Keiro.Workflow.Fixture (durableKirokuStore, withDurableStore)
import Kenshou.Suite.Keiro.Workflow.Oracle (effectCoverage, journalStepIdentity)
import Kiroku.Store (KirokuStore, defaultConnectionSettings, readStreamForward, runStoreIO, runTransaction)
import Kiroku.Store.Types (RecordedEvent (..), StreamVersion (..))

scenarios :: [Scenario]
scenarios = [linearSelfKillSmoke]

linearSelfKillSmoke :: Scenario
linearSelfKillSmoke =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/workflow/concurrency/linear-self-sigkill-smoke"),
      revision = 1,
      summary = "Kills a real resume-worker process after one linear step effect, then verifies restart, replay, and the bounded duplicate.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = [],
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
      run = runLinearSelfKillSmoke
    }

runLinearSelfKillSmoke :: RunContext -> IO ScenarioReport
runLinearSelfKillSmoke context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let store = durableKirokuStore fixture
        wid = WorkflowId "linear-self-sigkill-smoke"
    seeded <- runStoreIO store $ runTransaction (upsertInstanceTx (unWorkflowId wid) (unWorkflowName linearName) 0 WfRunning Nothing)
    either (fail . show) pure seeded
    sealLedger check.ledger
    (armed, completed) <- withSupervisor check \supervisor -> do
      firstSpec <- roleProcess check "keiro/workflow-resume-worker" 0 (object ["killAfter" .= ("s2" :: Text)])
      first <- spawn supervisor firstSpec
      awaitReady first 10000
      sendCommand first CtlStart
      armed <- awaitCrashArm check 100
      secondSpec <- roleProcess check "keiro/workflow-resume-worker" 1 (object [])
      second <- spawn supervisor secondSpec
      awaitReady second 10000
      sendCommand second CtlStart
      completed <- awaitTerminal store wid 120
      _ <- stopGracefully supervisor second 2000
      pure (armed, completed)
    journal <- runStoreIO store $ readStreamForward (workflowStreamName linearName wid) (StreamVersion 0) 256
    index <- runStoreIO store $ loadStepIndex linearName wid 0
    instanceRow <- runStoreIO store $ lookupInstance linearName wid
    ledgers <- discoverLedgers check.ledgerDirectory
    effects <- foldFacts ledgers Map.empty \counts fact ->
      pure if fact.kind == Effect then Map.insertWith (+) fact.key (1 :: Int) counts else counts
    now <- getCurrentTime
    let expected = expectedLinearSteps defaultDefinitionParams
        events = either (const []) Vector.toList journal
        decoded = traverse (decodeRecorded workflowJournalCodec) events
        steps = case decoded of
          Right rows -> [(name, event) | (event, StepRecorded name _ _) <- zip events rows]
          Left _ -> []
        cells =
          [ ("crash-arm-flushed", armed),
            ("replacement-completed", completed),
            ("terminal-no-attempt", case instanceRow of Right (Just row) -> row.status == WfCompleted && row.attempts == 0; _ -> False),
            ("one-journal-entry-per-step", map fst steps == expected && length events == length expected + 1),
            ("journal-ids", journalStepIdentity linearName wid 0 expected [(name, event.eventId) | (name, event) <- steps]),
            ("index-matches", case index of Right rows -> all (`Map.member` rows) expected && Map.member completedStepName rows && Map.size rows == length expected + 1; _ -> False),
            ("one-bounded-duplicate", effectCoverage (map (\name -> unWorkflowId wid <> "/0/" <> name) expected) effects (Map.singleton (unWorkflowId wid <> "/0/s2") 1) && Map.lookup (unWorkflowId wid <> "/0/s2") effects == Just 2)
          ]
        verdict (name, held) =
          Verdict
            { checker = "workflow-crash-" <> name,
              invariant = name,
              cls = Contract,
              status = if held then Held else Violated,
              reason = Nothing,
              summary = if held then "Crash recovery invariant held" else "Crash recovery invariant failed",
              counts = Map.singleton "instances" 1,
              parameters = object ["killAfter" .= ("s2" :: Text)],
              counterExamples = if held then [] else [object ["workflowId" .= unWorkflowId wid]],
              counterExamplesTruncated = False,
              inputs = [],
              replay = Nothing,
              checkedAt = now,
              durationMillis = 0
            }
    finishWithVerdicts check (map verdict cells)

awaitCrashArm :: CheckEnv -> Int -> IO Bool
awaitCrashArm _ 0 = pure False
awaitCrashArm check remaining = do
  ledgers <- discoverLedgers check.ledgerDirectory
  found <- foldFacts ledgers False \seen fact -> pure (seen || fact.kind == Mark && fact.id == "crash-armed")
  if found then pure True else threadDelay 50000 >> awaitCrashArm check (remaining - 1)

awaitTerminal :: KirokuStore -> WorkflowId -> Int -> IO Bool
awaitTerminal _ _ 0 = pure False
awaitTerminal store wid remaining = do
  current <- runStoreIO store $ lookupInstance linearName wid
  case current of
    Right (Just row) | row.status == WfCompleted -> pure True
    _ -> threadDelay 50000 >> awaitTerminal store wid (remaining - 1)
