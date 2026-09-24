module Kenshou.Suite.Keiro.Workflow.LinearSmoke (scenarios) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (getCurrentTime)
import Data.Vector qualified as Vector
import Keiro.Codec (decodeRecorded)
import Keiro.Workflow (WorkflowId (..), WorkflowJournalEvent (..), WorkflowOutcome (..), completedStepName, loadStepIndex, runWorkflow, workflowJournalCodec, workflowStreamName)
import Kenshou.Check.Fact (FactKind (..))
import Kenshou.Check.Ledger (recordDurable)
import Kenshou.Check.Scenario (CheckEnv (..), finishWithVerdicts, withCheck)
import Kenshou.Check.Verdict (InvariantClass (..), Verdict (..), VerdictStatus (..))
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Workflow.Definitions
import Kenshou.Suite.Keiro.Workflow.Effects (EffectFact (..), EffectSink (..))
import Kenshou.Suite.Keiro.Workflow.Fixture (durableKirokuStore, withDurableStore)
import Kenshou.Suite.Keiro.Workflow.Oracle (effectCoverage, journalStepIdentity)
import Kiroku.Store (defaultConnectionSettings, readStreamForward, runStoreIO)
import Kiroku.Store.Types (RecordedEvent (..), StreamVersion (..))

scenarios :: [Scenario]
scenarios = [linearReplaySmoke]

-- | An incremental end-to-end probe; the full all-kind replay scenario is
-- added once the other eight definitions and wake drivers are available.
linearReplaySmoke :: Scenario
linearReplaySmoke =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/workflow/correctness/linear-replay-smoke"),
      revision = 1,
      summary = "Replays a completed linear workflow and checks effects, journal event identifiers, and its step index.",
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
      run = runLinearReplaySmoke
    }

runLinearReplaySmoke :: RunContext -> IO ScenarioReport
runLinearReplaySmoke context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    observed <- newIORef Map.empty
    let params = defaultDefinitionParams
        wid = WorkflowId "linear-replay-smoke"
        sink =
          EffectSink
            { recordEffect = \fact -> do
                recordDurable
                  check.ledger
                  Effect
                  fact.key
                  0
                  fact.key
                  (KeyMap.fromList [("effect-kind", String fact.kind), ("process", String fact.process), ("attributes", fact.attributes)])
                atomicModifyIORef' observed (\counts -> (Map.insertWith (+) fact.key (1 :: Int) counts, ())),
              boundary = \_ -> pure ()
            }
        store = durableKirokuStore fixture
    first <- runStoreIO store $ runWorkflow linearName wid (linearWorkflow sink params wid)
    second <- runStoreIO store $ runWorkflow linearName wid (linearWorkflow sink params wid)
    journal <- runStoreIO store $ readStreamForward (workflowStreamName linearName wid) (StreamVersion 0) 256
    stepIndex <- runStoreIO store $ loadStepIndex linearName wid 0
    effects <- readIORef observed
    checkedAt <- getCurrentTime
    let expected = expectedLinearSteps params
        result = Right (Completed (expectedLinearResult params wid))
        events = either (const []) Vector.toList journal
        decoded = traverse (decodeRecorded workflowJournalCodec) events
        stepEvents = case decoded of
          Right rows -> [(name, event) | (event, StepRecorded name _ _) <- zip events rows]
          Left _ -> []
        cells =
          [ ("first-run-result", first == result),
            ("replay-result", second == result),
            ("one-effect-per-step", effectCoverage (map ("linear-replay-smoke/0/" <>) expected) effects Map.empty),
            ("journal-decodes", either (const False) (const True) decoded),
            ("one-journal-event-per-step", map fst stepEvents == expected && length events == length expected + 1),
            ("journal-ids", journalStepIdentity linearName wid 0 expected [(name, event.eventId) | (name, event) <- stepEvents]),
            ("index-matches-journal", either (const False) (\rows -> all (`Map.member` rows) expected && Map.member completedStepName rows && Map.size rows == length expected + 1) stepIndex)
          ]
        verdict (name, held) =
          Verdict
            { checker = "workflow-" <> name,
              invariant = name,
              cls = Contract,
              status = if held then Held else Violated,
              reason = Nothing,
              summary = if held then "Expected durable workflow state observed" else "Durable workflow state differed from expectation",
              counts = Map.singleton "instances" 1,
              parameters = object ["workflow" .= ("kenshouLinear" :: Text)],
              counterExamples = if held then [] else [object ["workflowId" .= ("linear-replay-smoke" :: Text)]],
              counterExamplesTruncated = False,
              inputs = [],
              replay = Nothing,
              checkedAt = checkedAt,
              durationMillis = 0
            }
    finishWithVerdicts check (map verdict cells)
