module Kenshou.Suite.Kiroku.Concurrency.Telemetry (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM_)
import Data.Aeson (object, (.=))
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Vector qualified as Vector
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobInt, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario
import Kenshou.Suite.Kiroku.Correctness.Append (recordCells)
import Kenshou.Suite.Kiroku.Fixture.Oracle qualified as Oracle
import Kenshou.Suite.Kiroku.Fixture.Store (withKirokuStoreWithTap)
import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Kiroku.Store hiding (id, withKirokuStore)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [slowEventHandlerStallsDelivery]

slowEventHandlerStallsDelivery :: Scenario
slowEventHandlerStallsDelivery =
  Scenario
    { id = either (error . show) id (parseScenarioId "kiroku/otel/concurrency/slow-event-handler-stalls-delivery"),
      revision = 1,
      summary = "Checks that a slow event callback throttles subscription batches and that delivery recovers when delay is removed.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = storeKnobs <> [intKnob "kiroku.handler.delay-ms" 50 1 500, intKnob "kiroku.handler.events" 20000 10000 100000],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| [Pg17]) Pg18)
          },
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku] [] False)},
      knownDefect = Nothing,
      run = runSlowHandler
    }
  where
    name = either (error . show) id . mkKnobName
    intKnob key value low high = KnobSpec (name key) key KnobInt (VInt value) (IntRange low high) []

runSlowHandler :: RunContext -> IO ScenarioReport
runSlowHandler context = do
  let name = either (error . show) id . mkKnobName
      delayMs = fromIntegral (knobInt context.knobs (name "kiroku.handler.delay-ms")) :: Int
      events = fromIntegral (knobInt context.knobs (name "kiroku.handler.events")) :: Int
      subscription = SubscriptionName "slow-event-handler"
  delayOn <- newIORef True
  callbackCount <- newIORef (0 :: Int)
  delivered <- newIORef (0 :: Int)
  let tap event = case event of
        KirokuEventSubscriptionDelivered observed _ _ _ | observed == subscription -> do
          atomicModifyIORef' callbackCount (\count -> (count + 1, ()))
          active <- readIORef delayOn
          if active then threadDelay (delayMs * 1000) else pure ()
        _ -> pure ()
  withKirokuStoreWithTap context (Just tap) \store -> do
    let stream = StreamName "handler-stall"
        event = EventData Nothing (EventType "HandlerStall") (object []) Nothing Nothing Nothing
        batches = [min 1000 (events - offset) | offset <- [0, 1000 .. events - 1]]
    forM_ batches \batch -> do
      result <- runStoreIO store (appendToStream stream AnyVersion (replicate batch event))
      case result of
        Right _ -> pure ()
        Left err -> fail ("slow handler prepopulation failed: " <> show err)
    let handler _ = atomicModifyIORef' delivered (\count -> (count + 1, ())) >> pure Continue
        config = (defaultSubscriptionConfig subscription AllStreams handler) {batchSize = 100}
        waitFor target = do
          current <- readIORef delivered
          if current >= target then pure () else threadDelay 10000 >> waitFor target
        waitForCheckpoint = do
          snapshot <- runStoreIO store subscriptionCheckpointInventory
          case snapshot of
            Right value | [position | row <- Vector.toList value.checkpoints, row.subscriptionName == subscription, let { GlobalPosition position = row.checkpointPosition }] == [fromIntegral events] -> pure True
            _ -> threadDelay 10000 >> waitForCheckpoint
    withSubscription store config \_ -> do
      threadDelay 2000000
      slowCount <- readIORef delivered
      slowCallbacks <- readIORef callbackCount
      writeIORef delayOn False
      threadDelay 1000000
      fastCount <- readIORef delivered
      completed <- timeout 30000000 (waitFor events)
      finalCount <- readIORef delivered
      counts <- Oracle.threeCounts store.pool
      checkpointReached <- timeout 10000000 waitForCheckpoint
      let slowRate = slowCount `div` 2
          fastGain = fastCount - slowCount
          cells =
            [ ("prepopulation-durable", counts == (fromIntegral events, fromIntegral events, fromIntegral events)),
              ("slow-callback-invoked", slowCallbacks > 0),
              ("slow-phase-throttled", slowCount > 0 && slowCount < events `div` 2),
              ("throughput-recovers", fastGain >= 2 * slowRate),
              ("delivery-completes", completed == Just () && finalCount == events),
              ("checkpoint-reaches-head", checkpointReached == Just True)
            ]
      putSummary context Measurements "slow-event-handler" (object ["delayMs" .= delayMs, "events" .= events, "slowWindowSeconds" .= (2 :: Int), "slowDelivered" .= slowCount, "fastWindowSeconds" .= (1 :: Int), "fastDelivered" .= fastGain, "callbackCountBeforeRelease" .= slowCallbacks])
      recordCells context "slow-event-handler-stalls-delivery" [] cells
