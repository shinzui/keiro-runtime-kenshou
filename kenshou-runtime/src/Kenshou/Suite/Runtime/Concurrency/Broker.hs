module Kenshou.Suite.Runtime.Concurrency.Broker (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM)
import Data.Aeson (object, (.=))
import Kenshou.Check.Fact (FactKind (..))
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Knob (KnobValue (..))
import Kenshou.Core.Scenario (Placement (..), Scenario, Tier (..))
import Kenshou.Env.Kafka (BrokerControl (..), requireControl)
import Kenshou.Suite.Runtime.Concurrency (FaultEvidence (..), FaultPlan (..), faultInt, faultScenario)
import Kenshou.Suite.Runtime.System.Broker (RuntimeBroker (..))
import Kenshou.Suite.Runtime.Topology (RunningSystem (..), recordWindow)

scenarios :: [Scenario]
scenarios = [brokerRestart]

-- | Kills the broker for the outage and starts it again. Outbox rows wait as
-- failed with backoff; none may become dead, which I4 checks.
brokerRestart :: Scenario
brokerRestart =
  faultScenario
    FaultPlan
      { component = "broker",
        name = "broker-restart",
        summary = "Kills the Kafka broker for an outage and restarts it while orders flow, and judges I1 to I6.",
        tier = TierStandard,
        placement = PlaceEither,
        overrides = [("fault.count", VInt 2), ("fault.outage-seconds", VInt 15), ("fault.period-seconds", VInt 30)],
        extraKnobs = [],
        inject = \context system -> case requireControl system.broker.environment of
          Left _ -> pure (FaultEvidence 0 (object ["reason" .= ("broker has no process control" :: String)]))
          Right control -> do
            restarts <- forM [1 .. faultInt context.knobs "fault.count"] \_ -> do
              threadDelay (faultInt context.knobs "fault.period-seconds" * 1000000)
              recordWindow system "fault/broker" "*" DisturbanceStart
              control.kill
              threadDelay (faultInt context.knobs "fault.outage-seconds" * 1000000)
              control.start
              recordWindow system "fault/broker" "*" DisturbanceEnd
              control.generation
            pure (FaultEvidence (length restarts) (object ["generations" .= restarts])),
        knownDefect = Nothing,
        databaseProxies = False
      }
