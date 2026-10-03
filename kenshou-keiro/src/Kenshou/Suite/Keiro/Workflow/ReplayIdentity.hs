module Kenshou.Suite.Keiro.Workflow.ReplayIdentity
  ( scenarios,
    generationIdentity,
  )
where

import Control.Concurrent (threadDelay)
import Data.Aeson (FromJSON, ToJSON, Value, object, parseJSON, toJSON, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Time (getCurrentTime)
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Error.Static (Error)
import Keiro.Codec (decodeRecorded)
import Keiro.Workflow (StepName (..), Workflow, WorkflowId (..), WorkflowJournalEvent (..), WorkflowName, WorkflowOutcome (..), deterministicJournalId, loadStepIndex, mkWorkflowName, runWorkflow, step, workflowGenerationStreamName, workflowJournalCodec)
import Keiro.Workflow.Awakeable (AwakeableId, awakeableNamed, signalAwakeable)
import Keiro.Workflow.Resume (defaultWorkflowResumeOptions, resumeWorkflowsOnce)
import Keiro.Workflow.Sleep (drainWorkflowSleepTimers)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Workflow.Definitions qualified as Definitions
import Kenshou.Suite.Keiro.Workflow.Effects (EffectFact (..), EffectSink (..))
import Kenshou.Suite.Keiro.Workflow.Fixture (durableKirokuStore, withDurableStore)
import Kenshou.Suite.Keiro.Workflow.Oracle (recordWorkflowExampleCells)
import Kiroku.Store (KirokuStore, Store, defaultConnectionSettings, readStreamForward, runStoreIO)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Types (EventId, RecordedEvent (..), StreamName (..), StreamVersion (..))

scenarios :: [Scenario]
scenarios = [replayAndJournalIdentity]

replayAndJournalIdentity :: Scenario
replayAndJournalIdentity =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/workflow/correctness/replay-and-journal-identity"),
      revision = 1,
      summary = "Runs every fixture workflow kind to completion through its suspensions, checks journal identity per generation, then replays a reordered and renamed body.",
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
      run = runReplay
    }

-- | One closed or open generation is exact when each journaled step carries
-- Keiro's deterministic identifier, no step name repeats, every step is in
-- the index, and at most one non-step marker closes it as its last event.
generationIdentity :: WorkflowName -> WorkflowId -> Int -> Map Text Value -> [(EventId, WorkflowJournalEvent)] -> Bool
generationIdentity name wid generation index events =
  all (\(eventId, stepName) -> eventId == deterministicJournalId name wid generation stepName) steps
    && Map.size (Map.fromList [(stepName, ()) | (_, stepName) <- steps]) == length steps
    && all (\(_, stepName) -> Map.member stepName index) steps
    && length markers <= 1
    && case markers of
      [] -> True
      _ -> case reverse events of
        (_, final) : _ -> not (isStep final)
        [] -> False
  where
    steps = [(recorded, stepName) | (recorded, StepRecorded stepName _ _) <- events]
    markers = [event | (_, event) <- events, not (isStep event)]
    isStep = \case
      StepRecorded {} -> True
      _ -> False

replayProbeName :: WorkflowName
replayProbeName = either (error . show) id (mkWorkflowName "kenshouReplayProbe")

-- | The first deployment journals a, b and c, then parks on an awakeable.
replayProbeV1 :: (IOE :> es, Store :> es) => EffectSink -> WorkflowId -> Eff (Workflow : es) Value
replayProbeV1 sink wid = do
  a <- probeStep sink wid "a" (1 :: Int)
  b <- probeStep sink wid "b" ("bee" :: Text)
  c <- probeStep sink wid "c" (Map.fromList [("k" :: Text, 0.1 :: Double)])
  (_, await) <- awakeableNamed (StepName "hold")
  (_ :: Text) <- await
  pure (object ["a" .= a, "b" .= b, "c" .= c])

-- | The redeployed body reorders the journaled steps and renames b. Named
-- replay must return a and c from the journal and run the renamed step fresh.
replayProbeV2 :: (IOE :> es, Store :> es) => EffectSink -> WorkflowId -> Eff (Workflow : es) Value
replayProbeV2 sink wid = do
  c <- probeStep sink wid "c" (Map.fromList [("k" :: Text, 9 :: Double)])
  a <- probeStep sink wid "a" (2 :: Int)
  renamed <- probeStep sink wid "bRenamed" ("renamed" :: Text)
  (_, await) <- awakeableNamed (StepName "hold")
  answer <- await
  pure (object ["a" .= a, "bRenamed" .= renamed, "c" .= c, "answer" .= (answer :: Text)])

probeStep :: (IOE :> es, ToJSON value, FromJSON value) => EffectSink -> WorkflowId -> Text -> value -> Eff (Workflow : es) value
probeStep sink wid name value = step (StepName name) do
  liftIO $ sink.recordEffect (EffectFact "step" (unWorkflowId wid <> "/" <> name) "workflow" (object []))
  pure value

runReplay :: RunContext -> IO ScenarioReport
runReplay context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    effects <- newIORef (Map.empty :: Map Text Int)
    published <- newIORef (Map.empty :: Map Text AwakeableId)
    let store = durableKirokuStore fixture
        sink =
          EffectSink
            { recordEffect = \fact -> do
                atomicModifyIORef' effects \counts -> (Map.insertWith (+) fact.key 1 counts, ())
                case parseMaybe (withObject "publication" (.: "awakeableId")) fact.attributes of
                  Just aid -> atomicModifyIORef' published \ids -> (Map.insert fact.key aid ids, ())
                  Nothing -> pure (),
              boundary = \_ -> pure ()
            }
        drainSleeps = do
          threadDelay 400000
          now <- getCurrentTime
          runStoreIO store (drainWorkflowSleepTimers Nothing now 100 (\_ -> pure Nothing))
        wid = WorkflowId
        params = Definitions.defaultDefinitionParams
    -- Every fixture kind reaches completion through its own suspensions.
    linear <- runIn store Definitions.linearName (wid "replay-linear") (Definitions.linearWorkflow sink params (wid "replay-linear"))
    namedParked <- runIn store Definitions.sleeperName (wid "replay-sleeper") (Definitions.sleeperWorkflow sink True (wid "replay-sleeper"))
    ordinalParked <- runIn store Definitions.ordinalSleeperName (wid "replay-ordinal") (Definitions.sleeperWorkflow sink False (wid "replay-ordinal"))
    rotatedFirst <- runIn store Definitions.rotatedSleeperName (wid "replay-rotated") (Definitions.rotatedSleeperWorkflow (wid "replay-rotated"))
    rotatedParked <- runIn store Definitions.rotatedSleeperName (wid "replay-rotated") (Definitions.rotatedSleeperWorkflow (wid "replay-rotated"))
    _ <- drainSleeps
    named <- runIn store Definitions.sleeperName (wid "replay-sleeper") (Definitions.sleeperWorkflow sink True (wid "replay-sleeper"))
    ordinal <- runIn store Definitions.ordinalSleeperName (wid "replay-ordinal") (Definitions.sleeperWorkflow sink False (wid "replay-ordinal"))
    rotated <- runIn store Definitions.rotatedSleeperName (wid "replay-rotated") (Definitions.rotatedSleeperWorkflow (wid "replay-rotated"))
    approvalParked <- runIn store Definitions.approvalName (wid "replay-approval") (Definitions.approvalWorkflow sink (wid "replay-approval"))
    approvalId <- Map.lookup "replay-approval/approval" <$> readIORef published
    signalled <- maybe (pure (Right False)) (\aid -> runStoreIO store (signalAwakeable aid ("approved" :: Text))) approvalId
    approval <- runIn store Definitions.approvalName (wid "replay-approval") (Definitions.approvalWorkflow sink (wid "replay-approval"))
    parentParked <- runIn store Definitions.parentName (wid "replay-parent") (Definitions.parentWorkflow sink (wid "replay-parent"))
    _ <- runStoreIO store (resumeWorkflowsOnce defaultWorkflowResumeOptions (Definitions.childRegistry sink))
    _ <- runStoreIO store (resumeWorkflowsOnce defaultWorkflowResumeOptions (Definitions.childRegistry sink))
    parent <- runIn store Definitions.parentName (wid "replay-parent") (Definitions.parentWorkflow sink (wid "replay-parent"))
    patched <- runIn store Definitions.patchedName (wid "replay-patched") (Definitions.patchedWorkflow sink False (wid "replay-patched"))
    flaky <- runIn store Definitions.flakyName (wid "replay-flaky") (Definitions.flakyWorkflow sink True (wid "replay-flaky"))
    -- A redeployed body replays by name, not by position.
    probeParked <- runIn store replayProbeName (wid "replay-probe") (replayProbeV1 sink (wid "replay-probe"))
    probeIndexBefore <- runStoreIO store (loadStepIndex replayProbeName (wid "replay-probe") 0)
    holdId <- runStoreIO store (lookupHold (wid "replay-probe"))
    probeSignalled <- either (const (pure (Right False))) (maybe (pure (Right False)) (\aid -> runStoreIO store (signalAwakeable aid ("go" :: Text)))) holdId
    probe <- runIn store replayProbeName (wid "replay-probe") (replayProbeV2 sink (wid "replay-probe"))
    probeIndex <- runStoreIO store (loadStepIndex replayProbeName (wid "replay-probe") 0)
    observed <- readIORef effects
    let generations =
          [ (Definitions.linearName, wid "replay-linear", [0]),
            (Definitions.sleeperName, wid "replay-sleeper", [0]),
            (Definitions.ordinalSleeperName, wid "replay-ordinal", [0]),
            (Definitions.rotatedSleeperName, wid "replay-rotated", [0, 1]),
            (Definitions.approvalName, wid "replay-approval", [0]),
            (Definitions.parentName, wid "replay-parent", [0]),
            (Definitions.childName, wid "replay-parent-child", [0]),
            (Definitions.patchedName, wid "replay-patched", [0]),
            (Definitions.flakyName, wid "replay-flaky", [0]),
            (replayProbeName, wid "replay-probe", [0])
          ]
    identities <- traverse (\(name, workflowId, gens) -> traverse (journalIdentity store name workflowId) gens) generations
    let expectedLinear = Definitions.expectedLinearResult params (wid "replay-linear")
        once key = Map.lookup key observed == Just 1
        failing :: [(Text, Bool)] -> [Value]
        failing examples = [object ["case" .= label] | (label, held) <- examples, not held]
        identityExamples = [object ["workflow" .= show name, "workflowId" .= unWorkflowId workflowId] | ((name, workflowId, _), results) <- zip generations identities, not (and results)]
        roundTrip key returned = case probeIndex of
          Right rows -> Map.lookup key rows == Just returned
          Left _ -> False
        probeFields = case probe of
          Right (Completed value) -> parseMaybe (withObject "probe" \fields -> (,,) <$> fields .: "a" <*> fields .: "c" <*> fields .: "answer") value
          _ -> Nothing
        streamNames =
          [ ("generation-zero-stream", workflowGenerationStreamName Definitions.rotatedSleeperName (wid "replay-rotated") 0 == StreamName "wf:kenshouRotatedSleeper-replay-rotated"),
            ("generation-one-stream", workflowGenerationStreamName Definitions.rotatedSleeperName (wid "replay-rotated") 1 == StreamName "wf:kenshouRotatedSleeper-replay-rotated#1")
          ]
        completions =
          [ ("linear", linear == Right (Completed expectedLinear)),
            ("sleeper-named", namedParked == Right Suspended && named == Right (Completed 3)),
            ("sleeper-ordinal", ordinalParked == Right Suspended && ordinal == Right (Completed 3)),
            ("rotated-sleeper", rotatedFirst == Right ContinuedAsNew && rotatedParked == Right Suspended && rotated == Right (Completed 1)),
            ("approval", approvalParked == Right Suspended && signalled == Right True && approval == Right (Completed "approved")),
            ("parent-child", parentParked == Right Suspended && parent == Right (Completed 43)),
            ("patched", patched == Right (Completed "old")),
            ("flaky-repaired", flaky == Right (Completed 42))
          ]
        singleEffects =
          [ (key, once key)
          | key <-
              [ "replay-sleeper/0/before",
                "replay-sleeper/0/after",
                "replay-ordinal/0/before",
                "replay-ordinal/0/after",
                "replay-approval/accepted",
                "replay-parent-child/work",
                "replay-parent/after",
                "replay-patched/old",
                "replay-flaky/0/boom"
              ]
                <> ["replay-linear/0/" <> stepName | stepName <- Definitions.expectedLinearSteps params]
          ]
        renamedReplay =
          [ ("probe-parked-after-three-steps", probeParked == Right Suspended && either (const False) (\rows -> all (`Map.member` rows) ["a", "b", "c"]) probeIndexBefore && probeSignalled == Right True),
            ("reordered-steps-not-reexecuted", once "replay-probe/a" && once "replay-probe/b" && once "replay-probe/c"),
            ("renamed-step-executed-fresh", once "replay-probe/bRenamed" && either (const False) (Map.member "bRenamed") probeIndex),
            ("old-entry-retained", either (const False) (Map.member "b") probeIndex),
            ("replayed-values-are-journaled-values", case probeFields of Just (a, c, answer) -> a == toJSON (1 :: Int) && c == object ["k" .= (0.1 :: Double)] && answer == toJSON ("go" :: Text) && roundTrip "a" a && roundTrip "c" c; Nothing -> False)
          ]
    putSummary context Measurements "replay-and-journal-identity" (object ["kinds" .= length completions, "generationsChecked" .= sum (map length identities), "effects" .= observed])
    recordWorkflowExampleCells
      check
      [ ("every-kind-completes-with-expected-result", length completions, failing completions),
        ("journal-identity-per-generation", length generations, identityExamples),
        ("generation-stream-names", length streamNames, failing streamNames),
        ("completed-steps-effect-once", length singleEffects, failing singleEffects),
        ("named-replay-across-redeploy", length renamedReplay, failing renamedReplay)
      ]

runIn :: KirokuStore -> WorkflowName -> WorkflowId -> Eff '[Workflow, Store, Error StoreError, IOE] a -> IO (Either StoreError (WorkflowOutcome a))
runIn store name wid body = runStoreIO store (runWorkflow name wid body)

journalIdentity :: KirokuStore -> WorkflowName -> WorkflowId -> Int -> IO Bool
journalIdentity store name wid generation = do
  journal <- runStoreIO store (readStreamForward (workflowGenerationStreamName name wid generation) (StreamVersion 0) 1000)
  index <- runStoreIO store (loadStepIndex name wid generation)
  pure case (journal, index) of
    (Right events, Right rows) -> case traverse (\event -> (event.eventId,) <$> decodeRecorded workflowJournalCodec event) (Vector.toList events) of
      Right decoded -> not (null decoded) && generationIdentity name wid generation rows decoded
      Left _ -> False
    _ -> False

-- | The probe never publishes its awakeable id, so read the journaled
-- allocation for the label from the index.
lookupHold :: (Store :> es) => WorkflowId -> Eff es (Maybe AwakeableId)
lookupHold workflowId = do
  rows <- loadStepIndex replayProbeName workflowId 0
  pure (listToMaybe [aid | (key, value) <- Map.toList rows, key == "awkid:hold", Just aid <- [parseMaybe parseJSON value]])
