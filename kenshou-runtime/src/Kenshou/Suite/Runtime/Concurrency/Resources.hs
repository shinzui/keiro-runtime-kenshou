module Kenshou.Suite.Runtime.Concurrency.Resources (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Control.Monad (forM)
import Data.Aeson (Value (Number), object, (.=))
import Data.Maybe (mapMaybe)
import Kenshou.Check.Fact (FactKind (..))
import Kenshou.Check.Fault (Duration (..), Fault (..), FaultHandle (..), holding)
import Kenshou.Check.Fault.Postgres (LockTarget (..), holdLock)
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Knob (KnobValue (..))
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Core.Scenario (Placement (..), Scenario, Tier (..))
import Kenshou.Env.Kafka (describeGroup, groupLag)
import Kenshou.Suite.Runtime.Concurrency (FaultEvidence (..), FaultPlan (..), faultInt, faultKnob, faultScenario)
import Kenshou.Suite.Runtime.System.Broker (RuntimeBroker (..))
import Kenshou.Suite.Runtime.Topology (RunningSystem (..), recordWindow, sendRole)

scenarios :: [Scenario]
scenarios = [poolStarvation, slowConsumerBackpressure]

-- | Two connections per pool, sixteen concurrent workflow advances, and a
-- lock holder blocking a shop ledger row for the outage every period. The
-- system must keep making progress and drain afterwards.
poolStarvation :: Scenario
poolStarvation =
  faultScenario
    FaultPlan
      { component = "resources",
        name = "pool-starvation",
        summary = "Runs every role with a two-connection pool while a lock holder blocks a ledger row every period, and judges I1 to I6.",
        tier = TierStandard,
        placement = PlaceEither,
        overrides = [("kiroku.pool-size", VInt 2), ("workflow.max-concurrent-advances", VInt 16), ("fault.outage-seconds", VInt 10)],
        extraKnobs = [],
        inject = \context system -> do
          let outage = faultInt context.knobs "fault.outage-seconds"
          held <- forM [1 .. faultInt context.knobs "fault.count"] \_ -> do
            threadDelay (faultInt context.knobs "fault.period-seconds" * 1000000)
            recordWindow system "fault/lock" "*" DisturbanceStart
            handle <- (holding (Duration (outage * 1000000)) (holdLock system.shopPostgres (RowLock "kenshou_keiro" "account_balance"))).inject
            recordWindow system "fault/lock" "*" DisturbanceEnd
            pure handle.details
          pure (FaultEvidence (length held) (object ["locks" .= held])),
        knownDefect = Nothing,
        databaseProxies = False
      }

-- | The warehouse consumer and pick handler gain latency for the outage
-- while the driver keeps its rate. The backlog must accumulate as consumer
-- lag and then drain.
slowConsumerBackpressure :: Scenario
slowConsumerBackpressure =
  faultScenario
    FaultPlan
      { component = "resources",
        name = "slow-consumer-backpressure",
        summary = "Slows the warehouse consumer and pick handler for five minutes while orders keep arriving, then lets the system drain, and judges I1 to I6.",
        tier = TierExtended,
        placement = PlaceEither,
        overrides = [("runtime.duration-seconds", VInt 420), ("fault.count", VInt 1), ("fault.outage-seconds", VInt 300), ("fault.period-seconds", VInt 1), ("runtime.quiescence-deadline-seconds", VInt 900)],
        extraKnobs = [faultKnob "fault.latency-ms" "Latency added to each warehouse delivery and pick." 250 0 60000],
        inject = \context system -> do
          let latency = Number (fromIntegral (faultInt context.knobs "fault.latency-ms"))
              outage = faultInt context.knobs "fault.outage-seconds"
          threadDelay (faultInt context.knobs "fault.period-seconds" * 1000000)
          recordWindow system "fault/slow-consumer" "*" DisturbanceStart
          mapM_ (\role -> sendRole system role (CtlCustom "latency" latency)) ["b-consumer", "b-jobs"]
          -- Sample the warehouse group's lag through the outage; a backlog
          -- that never builds means the fault took no effect.
          lags <- forM [1 .. max 1 (outage `div` 10)] \_ -> do
            threadDelay 10000000
            described <- try @SomeException (describeGroup system.broker.environment system.broker.warehouseConsumerGroup)
            pure (either (const Nothing) groupLag described)
          mapM_ (\role -> sendRole system role (CtlCustom "latency" (Number 0))) ["b-consumer", "b-jobs"]
          recordWindow system "fault/slow-consumer" "*" DisturbanceEnd
          let observed = mapMaybe id lags
          pure (FaultEvidence (if any (> 0) observed then 1 else 0) (object ["latencyMs" .= latency, "lagSamples" .= lags])),
        knownDefect = Nothing,
        databaseProxies = False
      }
