module Kenshou.Suite.Kiroku.Concurrency.KnownDefects (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, throwIO, try)
import Control.Monad (forM)
import Data.Aeson (object, (.=))
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int32)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (PhasePlan (..), zeroPhases)
import Kenshou.Core.Scenario
import Kenshou.Suite.Kiroku.Correctness.Append (recordCells)
import Kenshou.Suite.Kiroku.Fixture.Store (withKirokuStore, withKirokuStoreWithDecodeHook)
import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Kiroku.Store hiding (id, withKirokuStore)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [batchSizeValidation, resizeLeavesGaps, decodeHookStallsSubscribers]

decodeHookStallsSubscribers :: Scenario
decodeHookStallsSubscribers =
  batchSizeValidation
    { id = either (error . show) id (parseScenarioId "kiroku/subscription/concurrency/decode-hook-stalls-subscribers"),
      summary = "Expects both subscribers to progress or stop when a publisher decode hook fails.",
      phases = PhasePlan 0 60 0,
      knownDefect = Just (KnownDefect "mori://shinzui/kiroku/plans/83-contain-persistent-publisher-decode-hook-failures" "Persistent publisher decode-hook failures leave subscribers live but stalled" ["subscriber-stalled"] AllCohorts),
      run = runDecodeHook
    }

runDecodeHook :: RunContext -> IO ScenarioReport
runDecodeHook context = do
  publisherErrors <- newIORef (0 :: Int)
  let hook row
        | row.eventType == EventType "Poison" = throwIO (userError "seeded decode-hook failure")
        | otherwise = pure row
      tap = \case
        KirokuEventPublisherLoopError _ -> atomicModifyIORef' publisherErrors (\count -> (count + 1, ()))
        _ -> pure ()
  withKirokuStoreWithDecodeHook context hook (Just tap) \store -> do
    firstSeen <- newIORef []
    secondSeen <- newIORef []
    let stream = StreamName "decode-hook-events"
        event eventType = EventData Nothing eventType (object []) Nothing Nothing Nothing
        config name ref = defaultSubscriptionConfig (SubscriptionName name) AllStreams (\row -> atomicModifyIORef' ref (\rows -> (row.globalPosition : rows, ())) >> pure Continue)
        awaitLive handles = timeout 10000000 loop
          where
            loop = do
              states <- traverse (.currentState) handles
              if all (\case Just state -> stateName state == "live"; _ -> False) states
                then pure True
                else threadDelay 10000 >> loop
        resolved handle ref = do
          positions <- readIORef ref
          finished <- timeout 1000 (wait handle)
          pure (GlobalPosition 3 `elem` positions || case finished of Just (Left _) -> True; _ -> False)
    initial <- runStoreIO store (appendToStream stream NoStream [event (EventType "Ordinary")])
    withSubscription store (config "decode-a" firstSeen) \first ->
      withSubscription store (config "decode-b" secondSeen) \second -> do
        live <- awaitLive [first, second]
        poison <- runStoreIO store (appendToStream stream (ExactVersion (StreamVersion 1)) [event (EventType "Poison")])
        tailEvent <- runStoreIO store (appendToStream stream (ExactVersion (StreamVersion 2)) [event (EventType "Ordinary")])
        threadDelay (round (context.phases.steadySeconds * 1000000))
        firstResolved <- resolved first firstSeen
        secondResolved <- resolved second secondSeen
        firstPositions <- readIORef firstSeen
        secondPositions <- readIORef secondSeen
        errors <- readIORef publisherErrors
        let cells =
              [ ("initial-appended", isRight initial),
                ("both-entered-live", live == Just True),
                ("poison-and-tail-appended", isRight poison && isRight tailEvent),
                ("pre-poison-delivered", GlobalPosition 1 `elem` firstPositions && GlobalPosition 1 `elem` secondPositions),
                ("subscriber-stalled", firstResolved && secondResolved)
              ]
        putSummary context Measurements "decode-hook" (object ["publisherLoopErrors" .= errors, "firstPositions" .= fmap (\(GlobalPosition value) -> value) (reverse firstPositions), "secondPositions" .= fmap (\(GlobalPosition value) -> value) (reverse secondPositions), "firstResolved" .= firstResolved, "secondResolved" .= secondResolved])
        recordCells context "decode-hook-stalls-subscribers" [] cells
  where
    isRight (Right _) = True
    isRight _ = False

resizeLeavesGaps :: Scenario
resizeLeavesGaps =
  batchSizeValidation
    { id = either (error . show) id (parseScenarioId "kiroku/consumer-group/concurrency/resize-leaves-gaps"),
      summary = "Expects a resized consumer group to cover every event or reject the topology change.",
      knownDefect = Just (KnownDefect "mori://shinzui/kiroku/plans/81-make-consumer-group-topology-durable-and-resize-without-gaps" "Consumer-group resize can skip events" ["coverage-or-topology-refusal"] AllCohorts),
      run = runResize
    }

runResize :: RunContext -> IO ScenarioReport
runResize context = withKirokuStore context \store -> do
  let name = SubscriptionName "resize-gap"
      event = EventData Nothing (EventType "Resize") (object []) Nothing Nothing Nothing
      config size member ref =
        (defaultSubscriptionConfig name AllStreams (\row -> atomicModifyIORef' ref (\rows -> (row.globalPosition : rows, ())) >> pure Continue))
          { consumerGroup = Just (ConsumerGroup member size)
          }
      awaitHead members = timeout 30000000 loop
        where
          loop = do
            inventory <- runStoreIO store subscriptionCheckpointInventory
            let positions = case inventory of
                  Right snapshot -> [(row.consumerGroupMember, row.checkpointPosition) | row <- Vector.toList snapshot.checkpoints, row.subscriptionName == name]
                  Left _ -> []
            if all (\member -> lookup member positions == Just (GlobalPosition 200)) members
              then pure True
              else threadDelay 10000 >> loop
      awaitLive handles = timeout 10000000 loop
        where
          loop = do
            states <- traverse (.currentState) handles
            if all (\case Just state -> stateName state == "live"; _ -> False) states
              then pure True
              else threadDelay 10000 >> loop
      withMembers [] action = action []
      withMembers ((member, ref) : rest) action = withSubscription store (config 3 member ref) \handle -> withMembers rest (\handles -> action (handle : handles))
  seeded <- forM [0 .. 199 :: Int] \index -> runStoreIO store (appendToStream (StreamName ("resize-" <> Text.pack (show index))) NoStream [event])
  firstRef <- newIORef []
  firstCaughtUp <- withSubscription store (config 2 0 firstRef) \_ -> awaitHead [0]
  firstRows <- readIORef firstRef
  refs <- forM [0 .. 2] \member -> (member,) <$> newIORef []
  resized <- try @SomeException (withMembers refs awaitLive)
  laterRows <- fmap concat (traverse (readIORef . snd) refs)
  let refused = case resized of Left _ -> True; _ -> False
      allSeen = Set.fromList (firstRows <> laterRows)
      cells =
        [ ("seeded-200-streams", length seeded == 200 && all isRight seeded),
          ("initial-member-checkpoint-head", firstCaughtUp == Just True),
          ("resized-members-live", refused || case resized of Right (Just True) -> True; _ -> False),
          ("coverage-or-topology-refusal", refused || allSeen == Set.fromList [GlobalPosition value | value <- [1 .. 200]])
        ]
  putSummary context Measurements "resize-leaves-gaps" (object ["firstMemberDeliveries" .= length firstRows, "totalDistinctDelivered" .= Set.size allSeen, "topologyRefused" .= refused])
  recordCells context "resize-leaves-gaps" [] cells
  where
    isRight (Right _) = True
    isRight _ = False

batchSizeValidation :: Scenario
batchSizeValidation =
  Scenario
    { id = either (error . show) id (parseScenarioId "kiroku/subscription/correctness/batch-size-validation"),
      revision = 1,
      summary = "Expects zero and negative subscription batch sizes to be rejected promptly.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = storeKnobs,
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| [Pg17]) Pg18)
          },
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku] [] False)},
      knownDefect = Just (KnownDefect "mori://shinzui/kiroku/plans/82-repair-live-reconnect-and-validate-subscription-identity-and-batch-size" "Subscription accepts invalid batch sizes" ["zero-refused", "negative-refused"] AllCohorts),
      run = runBatchSizeValidation
    }

runBatchSizeValidation :: RunContext -> IO ScenarioReport
runBatchSizeValidation context = withKirokuStore context \store -> do
  let event = EventData Nothing (EventType "InvalidBatch") (object []) Nothing Nothing Nothing
  seeded <- runStoreIO store (appendToStream (StreamName "invalid-batch-events") NoStream [event])
  (zeroRefused, zeroCalls) <- probe store (SubscriptionName "invalid-batch-zero") 0
  (negativeRefused, negativeCalls) <- probe store (SubscriptionName "invalid-batch-negative") (-1)
  putSummary context Measurements "batch-size-validation" (object ["zeroRefused" .= zeroRefused, "zeroHandlerCalls" .= zeroCalls, "negativeRefused" .= negativeRefused, "negativeHandlerCalls" .= negativeCalls])
  recordCells
    context
    "batch-size-validation"
    []
    [ ("seeded-event", case seeded of Right _ -> True; _ -> False),
      ("zero-refused", zeroRefused && zeroCalls == 0),
      ("negative-refused", negativeRefused && negativeCalls == 0)
    ]

probe :: KirokuStore -> SubscriptionName -> Int32 -> IO (Bool, Int)
probe store name size = do
  calls <- newIORef (0 :: Int)
  let handler _ = atomicModifyIORef' calls (\count -> (count + 1, ())) >> pure Continue
      config = (defaultSubscriptionConfig name AllStreams handler) {batchSize = size}
  started <- try @SomeException (subscribe store config)
  refused <- case started of
    Left _ -> pure True
    Right handle -> do
      outcome <- timeout 5000000 (wait handle)
      handle.cancel
      pure (case outcome of Just (Left _) -> True; _ -> False)
  delivered <- readIORef calls
  pure (refused, delivered)
