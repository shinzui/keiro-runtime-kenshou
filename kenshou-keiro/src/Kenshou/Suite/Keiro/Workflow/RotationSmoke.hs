module Kenshou.Suite.Keiro.Workflow.RotationSmoke (scenarios) where

import Data.Aeson (withObject, (.:))
import Data.Aeson.Types (parseMaybe)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Keiro.Workflow (WorkflowId (..), WorkflowOutcome (..), awakeableStepPrefix, loadStepIndex, runWorkflow)
import Keiro.Workflow.Awakeable (AwakeableId (..), awakeableIdText, signalAwakeable)
import Keiro.Workflow.Awakeable.Schema (AwakeableRow (..), lookupAwakeable)
import Keiro.Workflow.Awakeable.Schema qualified as Awakeable
import Keiro.Workflow.Instance (WorkflowInstanceRow (..), WorkflowStatus (..), lookupInstance)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Check.Verdict (InvariantClass (..))
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Workflow.Definitions (rotatingApprovalName, rotatingApprovalWorkflow)
import Kenshou.Suite.Keiro.Workflow.Effects (EffectFact (..), EffectSink (..))
import Kenshou.Suite.Keiro.Workflow.Fixture (durableKirokuStore, withDurableStore)
import Kenshou.Suite.Keiro.Workflow.Oracle (recordWorkflowCellsAs)
import Kiroku.Store (defaultConnectionSettings, runStoreIO)

scenarios :: [Scenario]
scenarios = [rotationAbandonsOldId]

rotationAbandonsOldId :: Scenario
rotationAbandonsOldId =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/workflow/correctness/continue-as-new-abandons-awakeable-ids"),
      revision = 1,
      summary = "Checks that a rotated approval publishes a new id and only the new id completes its workflow.",
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
      run = runRotationAbandonsOldId
    }

runRotationAbandonsOldId :: RunContext -> IO ScenarioReport
runRotationAbandonsOldId context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    publications <- newIORef ([] :: [(Int, AwakeableId)])
    let store = durableKirokuStore fixture
        wid = WorkflowId "rotating-approval"
        sink =
          EffectSink
            { recordEffect = \fact -> case parseMaybe (withObject "publication" (\value -> (,) <$> value .: "generation" <*> value .: "awakeableId")) fact.attributes of
                Just publication -> atomicModifyIORef' publications (\rows -> (rows <> [publication], ()))
                Nothing -> pure (),
              boundary = \_ -> pure ()
            }
        run = runStoreIO store (runWorkflow rotatingApprovalName wid (rotatingApprovalWorkflow sink wid))
        index generation = runStoreIO store (loadStepIndex rotatingApprovalName wid generation)
        has result key = either (const False) (Map.member key) result
    rotated <- run
    firstIndex <- index 0
    parked <- run
    published <- readIORef publications
    let oldId = lookup 0 published
        newId = lookup 1 published
    before <- runStoreIO store (lookupInstance rotatingApprovalName wid)
    oldSignal <- traverse (\aid -> runStoreIO store (signalAwakeable aid ("obsolete" :: Text))) oldId
    afterOld <- runStoreIO store (lookupInstance rotatingApprovalName wid)
    oldRow <- traverse (\aid -> runStoreIO store (lookupAwakeable (case aid of AwakeableId value -> value))) oldId
    afterOldRun <- run
    secondIndex <- index 1
    newSignal <- traverse (\aid -> runStoreIO store (signalAwakeable aid ("current" :: Text))) newId
    finished <- run
    finalIndex <- index 1
    let indexSize result = either (const (-1)) Map.size result
        cells =
          [ ("rotates-and-parks", rotated == Right ContinuedAsNew && parked == Right Suspended && case before of Right (Just row) -> row.generation == 1 && row.status == WfSuspended; _ -> False),
            ("fresh-id-per-generation", oldId /= newId && oldId /= Nothing && newId /= Nothing),
            ("old-row-settles", oldSignal == Just (Right True) && case oldRow of Just (Right (Just row)) -> row.status == Awakeable.Completed; _ -> False),
            ("old-id-does-not-wake", afterOldRun == Right Suspended && case afterOld of Right (Just row) -> row.status == WfSuspended; _ -> False),
            ("old-id-not-journaled-in-new-generation", maybe False (\aid -> not (has secondIndex (awakeableStepPrefix <> awakeableIdText aid))) oldId),
            ("new-id-completes", newSignal == Just (Right True) && finished == Right (Completed "current") && maybe False (\aid -> has finalIndex (awakeableStepPrefix <> awakeableIdText aid)) newId),
            ("bounded-generations", indexSize firstIndex <= 4 && indexSize finalIndex <= 5)
          ]
    recordWorkflowCellsAs Implementation check cells
