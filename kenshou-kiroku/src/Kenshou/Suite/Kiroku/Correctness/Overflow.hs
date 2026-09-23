module Kenshou.Suite.Kiroku.Correctness.Overflow (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Exception (fromException)
import Control.Monad (forM_)
import Data.Aeson (object, (.=))
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Vector qualified as Vector
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobInt, knobText, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario
import Kenshou.Suite.Kiroku.Correctness.Append (recordCells)
import Kenshou.Suite.Kiroku.Fixture.Store (withKirokuStoreWithTap)
import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Kiroku.Store hiding (id, withKirokuStore)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [overflowPolicies]

overflowPolicies :: Scenario
overflowPolicies =
  Scenario
    { id = either (error . show) id (parseScenarioId "kiroku/subscription/correctness/overflow-policies"),
      revision = 1,
      summary = "Checks bounded queue pause, drop-subscription and drop-oldest policies.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = storeKnobs <> [policyKnob, capacityKnob, latencyKnob],
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
      run = runOverflow
    }
  where
    name = either (error . show) id . mkKnobName
    policyKnob = KnobSpec (name "kiroku.subscription.overflow-policy") "Bounded queue policy" KnobText (VText "pause-and-resume") (OneOf (VText "pause-and-resume" :| [VText "drop-subscription", VText "drop-oldest"])) [VText "pause-and-resume", VText "drop-subscription", VText "drop-oldest"]
    capacityKnob = KnobSpec (name "kiroku.subscription.queue-capacity") "Publisher queue capacity in batches" KnobInt (VInt 1) (IntRange 1 1024) []
    latencyKnob = KnobSpec (name "kiroku.subscription.handler-latency-ms") "Per-event handler delay in milliseconds" KnobInt (VInt 20) (IntRange 1 1000) []

runOverflow :: RunContext -> IO ScenarioReport
runOverflow context = do
  eventsSeen <- newIORef []
  let tap event = atomicModifyIORef' eventsSeen (\events -> (event : events, ()))
  withKirokuStoreWithTap context (Just tap) \store -> do
    let name = either (error . show) id . mkKnobName
        policyText = knobText context.knobs (name "kiroku.subscription.overflow-policy")
        policy = case policyText of
          "drop-subscription" -> DropSubscription
          "drop-oldest" -> DropOldest
          _ -> PauseAndResume
        latency = fromIntegral (knobInt context.knobs (name "kiroku.subscription.handler-latency-ms")) :: Int
        capacity = fromIntegral (knobInt context.knobs (name "kiroku.subscription.queue-capacity"))
        stream = StreamName "overflow-events"
        subscriptionName = SubscriptionName "overflow-observer"
        event = EventData Nothing (EventType "Overflow") (object []) Nothing Nothing Nothing
        handler ref row = threadDelay (latency * 1000) >> modifyIORef' ref (row.globalPosition :) >> pure Continue
        config ref = (defaultSubscriptionConfig subscriptionName AllStreams (handler ref)) {queueCapacity = capacity, overflowPolicy = policy}
        checkpoint = do
          result <- runStoreIO store subscriptionCheckpointInventory
          pure $ case result of
            Right snapshot -> case [row.checkpointPosition | row <- Vector.toList snapshot.checkpoints, row.subscriptionName == subscriptionName] of
              [position] -> Just position
              _ -> Nothing
            Left _ -> Nothing
        awaitLive handle = timeout 10000000 loop
          where
            loop = do
              state <- handle.currentState
              case state of
                Just value | stateName value == "live" -> pure True
                _ -> threadDelay 10000 >> loop
        awaitCheckpoint goal samples = timeout (3000 * latency * 2000 + 10000000) loop
          where
            loop = do
              saved <- checkpoint
              maybe (pure ()) (\value -> modifyIORef' samples (value :)) saved
              if saved == Just goal then pure True else threadDelay 100000 >> loop
    deliveries <- newIORef []
    samples <- newIORef []
    (live, completed, dropped, alive) <- withSubscription store (config deliveries) \handle -> do
      live <- awaitLive handle
      forM_ [1 .. 3000 :: Int] \position -> do
        result <- runStoreIO store (appendToStream stream AnyVersion [event])
        case result of
          Right appended | appended.globalPosition == GlobalPosition (fromIntegral position) -> pure ()
          other -> fail ("overflow workload append failed: " <> show other)
      if policy == DropSubscription
        then do
          termination <- timeout 30000000 handle.wait
          state <- handle.currentState
          pure (live, Nothing, termination, state)
        else do
          reached <- awaitCheckpoint (GlobalPosition 3000) samples
          state <- handle.currentState
          pure (live, reached, Nothing, state)
    delivered <- reverse <$> readIORef deliveries
    saved <- checkpoint
    sampled <- reverse <$> readIORef samples
    tapped <- readIORef eventsSeen
    let positions = delivered
        expected = [GlobalPosition position | position <- [1 .. 3000]]
        paused = any (\case KirokuEventSubscriptionPaused actual _ _ -> actual == subscriptionName; _ -> False) tapped
        resumed = any (\case KirokuEventSubscriptionResumed actual _ _ -> actual == subscriptionName; _ -> False) tapped
        typedDrop = case dropped of
          Just (Left exception) -> case fromException exception of Just (SubscriptionOverflowed actual) -> actual == subscriptionName; _ -> False
          _ -> False
        prefix = positions == take (length positions) expected
        common =
          [ ("live-before-burst", live == Just True),
            ("delivered-in-order", positions == sort positions),
            ("checkpoint-monotonic", sampled == sort sampled)
          ]
    (extra, missing) <- case policy of
      PauseAndResume ->
        pure
          ( [ ("pause-and-resume-events", paused && resumed),
              ("pause-worker-stays-alive", case alive of Just _ -> True; _ -> False),
              ("pause-drains-to-head", completed == Just True && saved == Just (GlobalPosition 3000)),
              ("pause-no-loss", Set.fromList positions == Set.fromList expected)
            ],
            0 :: Int
          )
      DropOldest ->
        pure
          ( [ ("drop-oldest-worker-stays-alive", case alive of Just _ -> True; _ -> False),
              ("drop-oldest-drains-to-head", completed == Just True && saved == Just (GlobalPosition 3000))
            ],
            3000 - Set.size (Set.fromList positions)
          )
      DropSubscription -> do
        restarted <- newIORef []
        replayed <- withSubscription store ((defaultSubscriptionConfig subscriptionName AllStreams (\row -> modifyIORef' restarted (row.globalPosition :) >> pure Continue)) {queueCapacity = capacity}) \_ -> awaitCheckpoint (GlobalPosition 3000) samples
        rest <- reverse <$> readIORef restarted
        pure
          ( [ ("drop-subscription-typed-error", typedDrop),
              ("drop-subscription-prefix", prefix),
              ("drop-subscription-restart-completes", replayed == Just True && Set.fromList (positions <> rest) == Set.fromList expected)
            ],
            0 :: Int
          )
    putSummary context Measurements "overflow" (object ["policy" .= policyText, "delivered" .= length delivered, "missing" .= missing, "paused" .= paused, "resumed" .= resumed])
    recordCells context "overflow-policies" [] (common <> extra)
