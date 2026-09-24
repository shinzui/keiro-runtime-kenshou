module Kenshou.Suite.Keiro.Workflow.StepBoundary (scenarios) where

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
import Kenshou.Check.Fact (Fact (..), FactKind (..), ProcId (..))
import Kenshou.Check.Ledger (sealLedger)
import Kenshou.Check.Ledger.Read (discoverLedgers, foldFacts)
import Kenshou.Check.Process (awaitMark, awaitReady, childPid, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
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
import System.Posix.Signals (sigKILL, signalProcessGroup)

scenarios :: [Scenario]
scenarios = [sigkillStepBoundary]

sigkillStepBoundary :: Scenario
sigkillStepBoundary =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/workflow/concurrency/sigkill-step-boundary"),
      revision = 1,
      summary = "Kills two workers after flushed step effects and one at an arbitrary point, then checks crash-bounded duplicates and terminal journals.",
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
      run = runBoundary
    }

runBoundary :: RunContext -> IO ScenarioReport
runBoundary context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let store = durableKirokuStore fixture
        instanceCount = fromIntegral (knobInt context.knobs (workflowKnobName "workflow.instances")) :: Int
        params = defaultDefinitionParams {steps = fromIntegral (knobInt context.knobs (workflowKnobName "workflow.steps"))}
        wids = [WorkflowId ("step-boundary-" <> Text.pack (show index)) | index <- [0 .. instanceCount - 1]]
        completed = do
          rows <- traverse (runStoreIO store . lookupInstance linearName) wids
          pure (all (\case Right (Just row) -> row.status == WfCompleted; _ -> False) rows)
    seeded <- traverse (\(WorkflowId wid) -> runStoreIO store (runTransaction (upsertInstanceTx wid "kenshouLinear" 0 WfRunning Nothing))) wids
    sealLedger check.ledger
    (targeted, randomKilled, finished) <- withSupervisor check \supervisor -> do
      targetResults <- forM [0, 1] \index -> do
        spec <- roleProcess check "keiro/workflow-resume-worker" index (object ["killAfter" .= ("s2" :: Text.Text)])
        worker <- spawn supervisor spec
        awaitReady worker 10000
        sendCommand worker CtlStart
        awaitEffect check index "s2" 240
      randomSpec <- roleProcess check "keiro/workflow-resume-worker" 2 (object ["stepDelayMicros" .= (500000 :: Int)])
      randomWorker <- spawn supervisor randomSpec
      awaitReady randomWorker 10000
      sendCommand randomWorker CtlStart
      awaitMark randomWorker "effect-flushed" 10000
      signalProcessGroup sigKILL (childPid randomWorker)
      survivors <- forM [3, 4] \index -> do
        spec <- roleProcess check "keiro/workflow-resume-worker" index (object [])
        worker <- spawn supervisor spec
        awaitReady worker 10000
        sendCommand worker CtlStart
        pure worker
      done <- waitUntil completed 480
      forM_ survivors (\worker -> stopGracefully supervisor worker 5000)
      pure (and targetResults, True, done)
    rows <- traverse (runStoreIO store . lookupInstance linearName) wids
    journals <- traverse (\wid -> runStoreIO store (readStreamForward (workflowStreamName linearName wid) (StreamVersion 0) (fromIntegral (params.steps + 2)))) wids
    ledgers <- discoverLedgers check.ledgerDirectory
    effects <- foldFacts ledgers Map.empty \counts fact ->
      pure if fact.kind == Effect then Map.insertWith (+) (fact.key, fact.proc.index) (1 :: Int) counts else counts
    let expectedSteps = expectedLinearSteps params
        expectedKeys = Set.fromList [wid <> "/0/" <> stepName | WorkflowId wid <- wids, stepName <- expectedSteps]
        totals = Map.fromListWith (+) [(key, count) | ((key, _), count) <- Map.toList effects]
        killedCounts = Map.fromListWith (+) [(key, count) | ((key, index), count) <- Map.toList effects, index <= 2]
        crashBounded = Map.keysSet totals == expectedKeys && all (\key -> let total = Map.findWithDefault 0 key totals in total >= 1 && total <= 1 + Map.findWithDefault 0 key killedCounts) (Set.toList expectedKeys)
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
        duplicates = sum (map (\count -> max 0 (count - 1)) (Map.elems totals))
    putSummary context Measurements "sigkill-step-boundary" (object ["instances" .= instanceCount, "targetedKills" .= (2 :: Int), "randomKills" .= (1 :: Int), "duplicateEffects" .= duplicates])
    recordWorkflowCells
      check
      [ ("all-deferred-instances-seeded", length seeded == instanceCount && all (== Right ()) seeded),
        ("targeted-crash-arms-flushed", targeted),
        ("random-kill-during-effect", randomKilled),
        ("all-replacements-completed", finished && all terminal rows),
        ("journals-exactly-once", and (zipWith journalCorrect wids journals)),
        ("effects-bounded-by-killed-workers", crashBounded)
      ]

awaitEffect :: CheckEnv -> Int -> Text.Text -> Int -> IO Bool
awaitEffect _ _ _ 0 = pure False
awaitEffect check index stepName remaining = do
  ledgers <- discoverLedgers check.ledgerDirectory
  found <- foldFacts ledgers False \seen fact -> pure (seen || fact.kind == Mark && fact.proc.index == index && fact.id == "crash-armed" && fact.key == "after-step-action:" <> stepName)
  if found then pure True else threadDelay 50000 >> awaitEffect check index stepName (remaining - 1)

waitUntil :: IO Bool -> Int -> IO Bool
waitUntil _ 0 = pure False
waitUntil predicate remaining = do
  complete <- predicate
  if complete then pure True else threadDelay 250000 >> waitUntil predicate (remaining - 1)
