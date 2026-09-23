module Kenshou.Suite.Kiroku.Correctness.Subscription (scenarios) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (finally, fromException)
import Control.Monad (forM, unless)
import Data.Aeson (object)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobInt, knobText, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario
import Kenshou.Suite.Kiroku.Correctness.Append (recordCells)
import Kenshou.Suite.Kiroku.Fixture.Store (withKirokuStore)
import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Kiroku.Store hiding (id, withKirokuStore)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [checkpointPolicies, filtersAdvanceCheckpoint, catchupLiveHandoff]

catchupLiveHandoff :: Scenario
catchupLiveHandoff =
  checkpointPolicies
    { id = either (error . show) id (parseScenarioId "kiroku/subscription/correctness/catchup-live-handoff"),
      summary = "Checks repeated catch-up to live handoffs and graceful restart checkpoint continuity.",
      tier = TierStandard,
      knobs = storeKnobs <> [targetKnob, batchKnob, roundsKnob, prepopulateKnob],
      run = runHandoff
    }
  where
    name = either (error . show) id . mkKnobName
    targetKnob = KnobSpec (name "kiroku.subscription.target") "Subscription target" KnobText (VText "all") (OneOf (VText "all" :| [VText "category"])) [VText "all", VText "category"]
    batchKnob = KnobSpec (name "kiroku.subscription.batch-size") "Catch-up batch size" KnobInt (VInt 100) (IntRange 1 10000) [VInt 1, VInt 100, VInt 1000]
    roundsKnob = KnobSpec (name "handoff.rounds") "Graceful restart count" KnobInt (VInt 20) (IntRange 1 100) []
    prepopulateKnob = KnobSpec (name "workload.prepopulate") "Events before subscription starts" KnobInt (VInt 5000) (IntRange 1 100000) []

runHandoff :: RunContext -> IO ScenarioReport
runHandoff context = withKirokuStore context \store -> do
  let name = either (error . show) id . mkKnobName
      batchSizeValue = fromIntegral (knobInt context.knobs (name "kiroku.subscription.batch-size"))
      rounds = fromIntegral (knobInt context.knobs (name "handoff.rounds")) :: Int
      prepopulate = fromIntegral (knobInt context.knobs (name "workload.prepopulate")) :: Int
      isCategory = knobText context.knobs (name "kiroku.subscription.target") == "category"
      target = if isCategory then Category (CategoryName "handoff") else AllStreams
      stream = StreamName "handoff-events"
      subscriptionName = SubscriptionName "handoff-observer"
      event = EventData Nothing (EventType "Handoff") (object []) Nothing Nothing Nothing
      config seen =
        (defaultSubscriptionConfig subscriptionName target (\row -> modifyIORef' seen (row.globalPosition :) >> pure Continue))
          { batchSize = batchSizeValue
          }
      awaitLive handle = timeout 10000000 loop
        where
          loop = do
            state <- handle.currentState
            case state of
              Just value | stateName value == "live" -> pure True
              _ -> threadDelay 10000 >> loop
      checkpoint = do
        result <- runStoreIO store subscriptionCheckpointInventory
        pure $ case result of
          Right snapshot -> case [row.checkpointPosition | row <- Vector.toList snapshot.checkpoints, row.subscriptionName == subscriptionName] of
            [position] -> Just position
            _ -> Nothing
          Left _ -> Nothing
      awaitCheckpoint goal = timeout 10000000 loop
        where
          loop = do
            current <- checkpoint
            if current == Just goal then pure True else threadDelay 10000 >> loop
      readGlobal = go (GlobalPosition 0) []
        where
          go cursor chunks = do
            result <- runStoreIO store (readAllForward cursor 1000)
            case result of
              Right page | Vector.null page -> pure (concat (reverse chunks))
              Right page -> go (Vector.last page).globalPosition (Vector.toList page : chunks)
              Left err -> fail ("handoff global read failed: " <> show err)
      appenderLoop stopFlag errorRef = do
        stop <- readIORef stopFlag
        unless stop do
          result <- runStoreIO store (appendToStream stream AnyVersion [event])
          case result of
            Right _ -> threadDelay 5000 >> appenderLoop stopFlag errorRef
            Left err -> modifyIORef' errorRef (const (Just (Text.pack (show err))))
  seeded <- runStoreIO store (appendToStream stream NoStream (replicate prepopulate event))
  stopAppender <- newIORef False
  appenderError <- newIORef Nothing
  done <- newEmptyMVar
  _ <- forkIO (appenderLoop stopAppender appenderError `finally` putMVar done ())
  incarnations <- forM [1 .. rounds] \_ -> do
    seen <- newIORef []
    live <- withSubscription store (config seen) \handle -> do
      reached <- awaitLive handle
      threadDelay 200000
      pure reached
    delivered <- reverse <$> readIORef seen
    saved <- checkpoint
    pure (live, delivered, saved)
  modifyIORef' stopAppender (const True)
  takeMVar done
  errorValue <- readIORef appenderError
  globalRows <- readGlobal
  let headPosition = GlobalPosition (fromIntegral (length globalRows))
  finalSeen <- newIORef []
  finalCaughtUp <- withSubscription store (config finalSeen) \handle -> do
    live <- awaitLive handle
    saved <- awaitCheckpoint headPosition
    pure (live, saved)
  finalDelivered <- reverse <$> readIORef finalSeen
  finalCheckpoint <- checkpoint
  let deliveries = fmap (\(_, rows, _) -> rows) incarnations <> [finalDelivered]
      allPositions = concat deliveries
      expected = fmap (.globalPosition) globalRows
      checkpoints = [position | (_, _, Just position) <- incarnations] <> maybe [] pure finalCheckpoint
      duplicates = length allPositions - Set.size (Set.fromList allPositions)
      duplicateBudget = fromIntegral (if isCategory then batchSizeValue else max batchSizeValue 1000) * rounds
      cells =
        [ ("prepopulated", case seeded of Right result -> result.globalPosition == GlobalPosition (fromIntegral prepopulate); _ -> False),
          ("steady-appender-had-no-error", errorValue == Nothing),
          ("steady-appender-produced-events", length globalRows > prepopulate),
          ("all-incarnations-reached-live", all (\(live, _, _) -> live == Just True) incarnations && fst finalCaughtUp == Just True),
          ("final-checkpoint-at-head", snd finalCaughtUp == Just True && finalCheckpoint == Just headPosition),
          ("no-delivery-loss", Set.fromList allPositions == Set.fromList expected),
          ("positions-nondecreasing-per-incarnation", all (\rows -> rows == sort rows) deliveries),
          ("checkpoints-monotonic", length checkpoints == rounds + 1 && checkpoints == sort checkpoints),
          ("no-duplicates-inside-incarnation", all (\rows -> Set.size (Set.fromList rows) == length rows) deliveries),
          ("graceful-restart-duplicate-budget", duplicates <= duplicateBudget)
        ]
  recordCells context "catchup-live-handoff" ["no-duplicates-inside-incarnation", "graceful-restart-duplicate-budget"] cells

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
