module Kenshou.Suite.Keiro.Workflow.DirectRace (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (mapConcurrently)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Keiro.Codec (decodeRecorded)
import Keiro.Workflow (WorkflowId (..), WorkflowJournalEvent (..), WorkflowOutcome (..), runWorkflow, workflowJournalCodec, workflowStreamName)
import Keiro.Workflow.Instance (WorkflowInstanceRow (..), WorkflowStatus (..), lookupInstance)
import Kenshou.Check.Fact (Fact (..), FactKind (..))
import Kenshou.Check.Ledger (recordDurable, sealLedger)
import Kenshou.Check.Ledger.Read (discoverLedgers, foldFacts)
import Kenshou.Check.Process (awaitReady, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (CheckEnv (..), withCheck)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (KnobSpec (..), KnobValue (..), knobInt)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Workflow.Definitions (DefinitionParams (..), defaultDefinitionParams, expectedLinearResult, expectedLinearSteps, linearName, linearWorkflow)
import Kenshou.Suite.Keiro.Workflow.Effects (EffectFact (..), EffectSink (..))
import Kenshou.Suite.Keiro.Workflow.Fixture (durableKirokuStore, withDurableStore)
import Kenshou.Suite.Keiro.Workflow.Knobs (workflowKnobName, workflowKnobs)
import Kenshou.Suite.Keiro.Workflow.Oracle (journalStepIdentity, recordWorkflowCells)
import Kiroku.Store (defaultConnectionSettings, readStreamForward, runStoreIO)
import Kiroku.Store.Types (RecordedEvent (..), StreamVersion (..))

scenarios :: [Scenario]
scenarios = [directRunVsResumeWorker]

directRunVsResumeWorker :: Scenario
directRunVsResumeWorker =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/workflow/concurrency/direct-run-vs-resume-worker"),
      revision = 1,
      summary = "Races inline linear workflow runs with a polling resume worker and measures duplicate effects without a crash.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = [if spec.name == workflowKnobName "workflow.start-mode" then KnobSpec spec.name spec.summary spec.knobType (VText "inline") spec.allowed spec.variants else spec | spec <- workflowKnobs],
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
      run = runDirectRace
    }

runDirectRace :: RunContext -> IO ScenarioReport
runDirectRace context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let store = durableKirokuStore fixture
        instanceCount = fromIntegral (knobInt context.knobs (workflowKnobName "workflow.instances")) :: Int
        params = defaultDefinitionParams {steps = fromIntegral (knobInt context.knobs (workflowKnobName "workflow.steps"))}
        wids = [WorkflowId ("direct-race-" <> Text.pack (show index)) | index <- [0 .. instanceCount - 1]]
        sink =
          EffectSink
            { recordEffect = \fact -> recordDurable check.ledger Effect fact.key 0 fact.key (KeyMap.fromList [("effect-kind", String fact.kind), ("process", String fact.process), ("attributes", fact.attributes)]),
              boundary = \_ -> pure ()
            }
        completed = do
          rows <- traverse (runStoreIO store . lookupInstance linearName) wids
          pure (all (\case Right (Just row) -> row.status == WfCompleted; _ -> False) rows)
    direct <- withSupervisor check \supervisor -> do
      spec <- roleProcess check "keiro/workflow-resume-worker" 0 (object [])
      worker <- spawn supervisor spec
      awaitReady worker 10000
      sendCommand worker CtlStart
      results <- mapConcurrently (\wid -> runStoreIO store (runWorkflow linearName wid (linearWorkflow sink params wid))) wids
      _ <- waitUntil completed 160
      _ <- stopGracefully supervisor worker 5000
      pure results
    finalCompleted <- completed
    replayed <- traverse (\wid -> runStoreIO store (runWorkflow linearName wid (linearWorkflow sink params wid))) wids
    journals <- traverse (\wid -> runStoreIO store (readStreamForward (workflowStreamName linearName wid) (StreamVersion 0) (fromIntegral (params.steps + 2)))) wids
    sealLedger check.ledger
    ledgers <- discoverLedgers check.ledgerDirectory
    effects <- foldFacts ledgers Map.empty \counts fact ->
      pure if fact.kind == Effect then Map.insertWith (+) fact.key (1 :: Int) counts else counts
    let expectedSteps = expectedLinearSteps params
        keys = [identifier <> "/0/" <> stepName | WorkflowId identifier <- wids, stepName <- expectedSteps]
        duplicates = sum [max 0 (Map.findWithDefault 0 key effects - 1) | key <- keys]
        journalCorrect wid result = case result of
          Left _ -> False
          Right events ->
            let recorded = Vector.toList events
                decoded = traverse (decodeRecorded workflowJournalCodec) recorded
             in case decoded of
                  Left _ -> False
                  Right rows ->
                    let steps = [(name, event.eventId) | (event, StepRecorded name _ _) <- zip recorded rows]
                     in length recorded == params.steps + 1
                          && length [() | WorkflowCompleted {} <- rows] == 1
                          && journalStepIdentity linearName wid 0 expectedSteps steps
        replayCorrect wid result = result == Right (Completed (expectedLinearResult params wid))
    putSummary context Measurements "direct-run-vs-resume-worker" (object ["instances" .= instanceCount, "stepsPerInstance" .= params.steps, "duplicateStepEffects" .= duplicates])
    recordWorkflowCells
      check
      [ ("all-inline-runs-accepted", length direct == instanceCount && all (either (const False) (const True)) direct),
        ("all-instances-completed", finalCompleted),
        ("journals-exactly-once", and (zipWith journalCorrect wids journals)),
        ("effects-at-least-once", length keys == Map.size effects && all (\key -> Map.findWithDefault 0 key effects >= 1) keys),
        ("replay-results-correct", and (zipWith replayCorrect wids replayed))
      ]

waitUntil :: IO Bool -> Int -> IO Bool
waitUntil _ 0 = pure False
waitUntil predicate remaining = do
  complete <- predicate
  if complete then pure True else threadDelay 250000 >> waitUntil predicate (remaining - 1)
