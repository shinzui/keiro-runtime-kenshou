module Kenshou.Suite.Kiroku.Correctness.Subscription (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Exception (fromException)
import Data.Aeson (object)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Vector qualified as Vector
import Kenshou.Core.Context (RunContext)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario
import Kenshou.Suite.Kiroku.Correctness.Append (recordCells)
import Kenshou.Suite.Kiroku.Fixture.Store (withKirokuStore)
import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Kiroku.Store hiding (id, withKirokuStore)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [checkpointPolicies, filtersAdvanceCheckpoint]

filtersAdvanceCheckpoint :: Scenario
filtersAdvanceCheckpoint =
  checkpointPolicies
    { id = either (error . show) id (parseScenarioId "kiroku/subscription/correctness/filters-advance-checkpoint"),
      summary = "Checks type and selector filters while skipped rows still advance the durable checkpoint.",
      run = runFilters
    }

runFilters :: RunContext -> IO ScenarioReport
runFilters context = withKirokuStore context \store -> do
  let stream = StreamName "filter-events"
      name = SubscriptionName "filter-subscription"
      key = SubscriptionCheckpointKey name 0
      keepType = EventType "Keep"
      event eventType = EventData Nothing eventType (object []) Nothing Nothing Nothing
      config ref =
        (defaultSubscriptionConfig name AllStreams (\row -> modifyIORef' ref (row.globalPosition :) >> pure Continue))
          { eventTypeFilter = OnlyEventTypes (Set.singleton keepType),
            selector = Just (\row -> row.globalPosition == GlobalPosition 2)
          }
      awaitHead = timeout 10000000 loop
      loop = do
        inventory <- runStoreIO store subscriptionCheckpointInventory
        case inventory of
          Right snapshot
            | [row.checkpointPosition | row <- Vector.toList snapshot.checkpoints, row.subscriptionName == name] == [GlobalPosition 2003] -> pure True
          _ -> threadDelay 10000 >> loop
  initial <- runStoreIO store (appendToStream stream NoStream [event keepType, event keepType, event (EventType "Drop")])
  skipped <- runStoreIO store (appendToStream stream (ExactVersion (StreamVersion 3)) (replicate 2000 (event (EventType "Drop"))))
  seen <- newIORef []
  caughtUp <- withSubscription store (config seen) \_ -> awaitHead
  delivered <- reverse <$> readIORef seen
  inventory <- runStoreIO store subscriptionCheckpointInventory
  let cells =
        [ ("seed-appended", case initial of Right result -> result.globalPosition == GlobalPosition 3; _ -> False),
          ("nonmatching-run-appended", case skipped of Right result -> result.globalPosition == GlobalPosition 2003; _ -> False),
          ("checkpoint-reaches-head", caughtUp == Just True),
          ("filters-compose", delivered == [GlobalPosition 2]),
          ( "checkpoint-durable",
            case inventory of
              Right snapshot ->
                snapshot.storePosition == GlobalPosition 2003
                  && [row.checkpointPosition | row <- Vector.toList snapshot.checkpoints, row.subscriptionName == name] == [GlobalPosition 2003]
              _ -> False
          ),
          ( "checkpoint-key",
            case inventory of
              Right snapshot ->
                [SubscriptionCheckpointKey row.subscriptionName row.consumerGroupMember | row <- Vector.toList snapshot.checkpoints] == [key]
              _ -> False
          )
        ]
  recordCells context "filters-advance-checkpoint" [] cells

checkpointPolicies :: Scenario
checkpointPolicies =
  Scenario
    { id = either (error . show) id (parseScenarioId "kiroku/subscription/correctness/checkpoint-policies"),
      revision = 1,
      summary = "Checks absent and existing checkpoint policies, startup refusal and explicit reset.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = storeKnobs,
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgFsyncOff :| [PgDurable]) PgFsyncOff),
            pgVersion = Supported (Support (Pg18 :| [Pg17]) Pg18)
          },
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku] [] False)},
      knownDefect = Nothing,
      run = runPolicies
    }

runPolicies :: RunContext -> IO ScenarioReport
runPolicies context = withKirokuStore context \store -> do
  let stream = StreamName "checkpoint-policies"
      event = EventData Nothing (EventType "Checkpoint") (object []) Nothing Nothing Nothing
      beginning = SubscriptionName "checkpoint-beginning"
      current = SubscriptionName "checkpoint-current"
      missing = SubscriptionName "checkpoint-missing"
      absent = SubscriptionName "checkpoint-absent"
      beginKey = SubscriptionCheckpointKey beginning 0
      currentKey = SubscriptionCheckpointKey current 0
      missingKey = SubscriptionCheckpointKey missing 0
      waitFor ref count = timeout 10000000 (loop ref count)
      loop ref count = do
        seen <- readIORef ref
        if length seen >= count then pure (reverse seen) else threadDelay 10000 >> loop ref count
      collect ref row = modifyIORef' ref (row.globalPosition :) >> pure Continue
      config name policy ref =
        (defaultSubscriptionConfig name AllStreams (collect ref)) {missingCheckpointPolicy = policy}
  initial <- runStoreIO store (appendToStream stream NoStream (replicate 3 event))
  firstMissing <- runStoreIO store (initializeSubscriptionCheckpoint missing 0 FailIfMissing)
  missingCalls <- newIORef []
  failed <- withSubscription store (config missing FailIfMissing missingCalls) \handle -> timeout 10000000 handle.wait
  missingDelivered <- readIORef missingCalls
  beginInit <- runStoreIO store (initializeSubscriptionCheckpoint beginning 0 FromBeginning)
  beginAgain <- runStoreIO store (initializeSubscriptionCheckpoint beginning 0 FromCurrentHead)
  beginCalls <- newIORef []
  beginSeen <- withSubscription store (config beginning FailIfMissing beginCalls) \_ -> waitFor beginCalls 3
  headInit <- runStoreIO store (initializeSubscriptionCheckpoint current 0 FromCurrentHead)
  currentCalls <- newIORef []
  currentSeen <- withSubscription store (config current FromBeginning currentCalls) \_ -> do
    before <- readIORef currentCalls
    appended <- runStoreIO store (appendToStream stream (ExactVersion (StreamVersion 3)) [event])
    after <- waitFor currentCalls 1
    pure (before, appended, after)
  beforeReset <- runStoreIO store subscriptionCheckpointInventory
  reset <- runStoreIO store (runTransaction (resetSubscriptionCheckpointsTx (beginning :| [absent]) (GlobalPosition 1)))
  afterReset <- runStoreIO store subscriptionCheckpointInventory
  beginReplayed <- withSubscription store (config beginning FromCurrentHead beginCalls) \_ -> waitFor beginCalls 6
  let checkpointPosition name inventory =
        case inventory of
          Right snapshot ->
            [row.checkpointPosition | row <- Vector.toList snapshot.checkpoints, row.subscriptionName == name]
          Left _ -> []
      initialOk = case initial of Right result -> result.globalPosition == GlobalPosition 3; _ -> False
      failedTyped = case failed of Just (Left exception) -> fromException exception == Just (SubscriptionCheckpointMissing missingKey); _ -> False
      cells =
        [ ("initial-events", initialOk),
          ("fail-if-missing-initializer", firstMissing == Right (Left (SubscriptionCheckpointMissing missingKey))),
          ("fail-if-missing-worker", failedTyped && null missingDelivered),
          ("from-beginning-initializes-zero", beginInit == Right (Right (InitializedCheckpoint FromBeginning beginKey (GlobalPosition 0)))),
          ("existing-row-wins-policy", beginAgain == Right (Right (ExistingCheckpoint beginKey (GlobalPosition 0)))),
          ("from-beginning-replays", beginSeen == Just [GlobalPosition 1, GlobalPosition 2, GlobalPosition 3]),
          ("from-current-head-initializes", headInit == Right (Right (InitializedCheckpoint FromCurrentHead currentKey (GlobalPosition 3)))),
          ("from-current-head-only-new", case currentSeen of ([], Right _, Just [GlobalPosition 4]) -> True; _ -> False),
          ("checkpoints-advanced", checkpointPosition beginning beforeReset == [GlobalPosition 3] && checkpointPosition current beforeReset == [GlobalPosition 4]),
          ("reset-reports-keys-and-absence", case reset of Right report -> Vector.toList report.resetCheckpointKeys == [beginKey] && Vector.toList report.missingSubscriptionNames == [absent]; _ -> False),
          ("reset-moves-position-backward", checkpointPosition beginning afterReset == [GlobalPosition 1]),
          ("restart-redelivers-from-reset", beginReplayed == Just [GlobalPosition 1, GlobalPosition 2, GlobalPosition 3, GlobalPosition 2, GlobalPosition 3, GlobalPosition 4])
        ]
  recordCells context "checkpoint-policies" [] cells
