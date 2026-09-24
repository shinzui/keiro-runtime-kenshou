module Kenshou.Suite.Keiro.Workflow.PatchSmoke (scenarios) where

import Control.Concurrent.Async (concurrently)
import Data.Aeson (toJSON, withObject, (.:))
import Data.Aeson.Types (parseMaybe)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Keiro.Workflow (PatchId (..), WorkflowId (..), WorkflowOutcome (..), WorkflowRunOptions (..), defaultWorkflowRunOptions, loadStepIndex, patchSetStepName, patchStepName, runWorkflowWith)
import Keiro.Workflow.Awakeable (AwakeableId, signalAwakeable)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Workflow.Definitions (patchedName, patchedWorkflow)
import Kenshou.Suite.Keiro.Workflow.Effects (EffectFact (..), EffectSink (..))
import Kenshou.Suite.Keiro.Workflow.Fixture (durableKirokuStore, withDurableStore)
import Kenshou.Suite.Keiro.Workflow.Oracle (recordWorkflowCells)
import Kiroku.Store (defaultConnectionSettings, runStoreIO)

scenarios :: [Scenario]
scenarios = [patchDecisionsAreFrozen]

patchDecisionsAreFrozen :: Scenario
patchDecisionsAreFrozen =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/workflow/correctness/patch-decisions-are-frozen"),
      revision = 1,
      summary = "Checks that an in-flight patch decision is frozen and fresh instances use the deployed patch set.",
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
      run = runPatchDecisionsAreFrozen
    }

runPatchDecisionsAreFrozen :: RunContext -> IO ScenarioReport
runPatchDecisionsAreFrozen context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    published <- newIORef (Nothing :: Maybe AwakeableId)
    let store = durableKirokuStore fixture
        sink =
          EffectSink
            { recordEffect = \fact -> case parseMaybe (withObject "publication" (\value -> value .: "awakeableId")) fact.attributes of
                Just aid -> writeIORef published (Just aid)
                Nothing -> pure (),
              boundary = \_ -> pure ()
            }
        old = defaultWorkflowRunOptions
        new = old {activePatches = Set.singleton (PatchId "p1")}
        inflightId = WorkflowId "patched-inflight"
        freshId = WorkflowId "patched-fresh"
        raceId = WorkflowId "patched-race"
        run options gated wid = runStoreIO store (runWorkflowWith options patchedName wid (patchedWorkflow sink gated wid))
        index wid = runStoreIO store (loadStepIndex patchedName wid 0)
        decision = patchStepName (PatchId "p1")
        has result key value = case result of Right rows -> Map.lookup key rows == Just value; _ -> False
    parked <- run old True inflightId
    aid <- readIORef published
    signalled <- traverse (\value -> runStoreIO store (signalAwakeable value ("continue" :: Text))) aid
    oldCompleted <- run new True inflightId
    oldReplay <- run new True inflightId
    oldIndex <- index inflightId
    freshCompleted <- run new False freshId
    freshIndex <- index freshId
    (raceOld, raceNew) <- concurrently (run old False raceId) (run new False raceId)
    raceIndex <- index raceId
    let cells =
          [ ("inflight-started-before-patch", parked == Right Suspended && signalled == Just (Right True)),
            ("inflight-decision-frozen", oldCompleted == Right (Completed "old") && oldReplay == oldCompleted && has oldIndex decision (toJSON False)),
            ("inflight-old-branch-only", has oldIndex "old" (toJSON ("old" :: Text)) && not (either (const False) (Map.member "new") oldIndex)),
            ("fresh-patch-set-recorded", freshCompleted == Right (Completed "new") && has freshIndex patchSetStepName (toJSON (["p1"] :: [Text]))),
            ("fresh-new-branch-only", has freshIndex decision (toJSON True) && has freshIndex "new" (toJSON ("new" :: Text)) && not (either (const False) (Map.member "old") freshIndex)),
            ( "racing-deployments-agree",
              case raceIndex of
                Right rows ->
                  case Map.lookup decision rows of
                    Just value | value == toJSON True -> Map.member "new" rows && not (Map.member "old" rows) && raceOld == Right (Completed "new") && raceNew == Right (Completed "new")
                    Just value | value == toJSON False -> Map.member "old" rows && not (Map.member "new" rows) && raceOld == Right (Completed "old") && raceNew == Right (Completed "old")
                    _ -> False
                _ -> False
            )
          ]
    recordWorkflowCells check cells
