module Kenshou.Suite.Runtime.Concurrency.Network (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM)
import Data.Aeson (object, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Kenshou.Check.Fact (FactKind (..))
import Kenshou.Check.Fault.Network (ProxyMode (..), TcpProxy, resetConnections, setProxyMode)
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..))
import Kenshou.Core.Scenario (Placement (..), Scenario, Tier (..))
import Kenshou.Env.Kafka (laneProxy)
import Kenshou.Suite.Runtime.Concurrency (FaultEvidence (..), FaultPlan (..), faultInt, faultScenario, faultText)
import Kenshou.Suite.Runtime.Knobs (runtimeKnobName)
import Kenshou.Suite.Runtime.System.Broker (RuntimeBroker (..))
import Kenshou.Suite.Runtime.System.Schema (ContextName (..))
import Kenshou.Suite.Runtime.Topology (RunningSystem (..), recordWindow)

scenarios :: [Scenario]
scenarios = [partitionBroker, partitionDatabase]

-- | Partitions one context's role processes from their database through
-- the proxy in front of it. @blackhole@ exercises timeouts rather than
-- refused connections; the harness keeps its direct connection.
partitionDatabase :: Scenario
partitionDatabase =
  faultScenario
    FaultPlan
      { component = "network",
        name = "partition-database",
        summary = "Blackholes, resets or delays the link between one context's role processes and its database for an outage while orders flow, and judges I1 to I6.",
        tier = TierStandard,
        placement = PlaceEither,
        overrides = [("fault.count", VInt 3), ("fault.outage-seconds", VInt 15), ("fault.period-seconds", VInt 25)],
        extraKnobs = [contextKnob "database", modeKnob],
        inject = \context system -> do
          let name = if faultText context.knobs "fault.context" == "a" then Shop else Warehouse
          case lookup name system.databaseProxies of
            Nothing -> pure (FaultEvidence 0 (object ["reason" .= ("the database has no TCP endpoint to proxy" :: Text)]))
            Just proxy -> partitionThrough context system "fault/partition-database" proxy,
        knownDefect = Nothing,
        databaseProxies = True
      }

-- | Partitions one context's Kafka clients from the broker through the
-- proxy in front of that context's broker lane. Kafka clients reconnect to
-- the address the broker advertises, so each lane is its own listener; the
-- other context and the admin client stay connected.
partitionBroker :: Scenario
partitionBroker =
  faultScenario
    FaultPlan
      { component = "network",
        name = "partition-broker",
        summary = "Blackholes, resets or delays one context's broker lane for an outage while orders flow, and judges I1 to I6.",
        tier = TierStandard,
        placement = PlaceEither,
        overrides = [("fault.count", VInt 3), ("fault.outage-seconds", VInt 15), ("fault.period-seconds", VInt 25)],
        extraKnobs = [contextKnob "broker lane", modeKnob],
        inject = \context system -> do
          let lane = if faultText context.knobs "fault.context" == "a" then 0 else 1
          case laneProxy system.broker.environment lane of
            Left problem -> pure (FaultEvidence 0 (object ["reason" .= show problem]))
            Right proxy -> partitionThrough context system "fault/partition-broker" proxy,
        knownDefect = Nothing,
        databaseProxies = False
      }

-- | Every period, fail the proxied link for the outage and record the
-- window. @reset@ is instantaneous, so it is repeated each second through
-- the outage. The proxy's blackhole drops bytes inside established
-- streams, which TCP never does, so, as the kiroku partition scenario does,
-- @blackhole@ resets the connections before and after the outage: the
-- streams it corrupted are torn down as a peer's failure detection would.
-- The evidence counts connections reset (or one per latency outage).
partitionThrough :: RunContext -> RunningSystem -> Text -> TcpProxy -> IO FaultEvidence
partitionThrough context system label proxy = do
  let mode = faultText context.knobs "fault.mode"
      outage = faultInt context.knobs "fault.outage-seconds"
  effects <- forM [1 .. faultInt context.knobs "fault.count"] \_ -> do
    threadDelay (faultInt context.knobs "fault.period-seconds" * 1000000)
    recordWindow system label "*" DisturbanceStart
    effect <- case mode of
      "reset" -> sum <$> forM [1 .. outage] \_ -> resetConnections proxy <* threadDelay 1000000
      "latency" -> do
        setProxyMode proxy (Latency 500)
        threadDelay (outage * 1000000)
        setProxyMode proxy Forward
        pure 1
      _ -> do
        before <- resetConnections proxy
        setProxyMode proxy Blackhole
        threadDelay (outage * 1000000)
        setProxyMode proxy Forward
        after <- resetConnections proxy
        pure (before + after)
    recordWindow system label "*" DisturbanceEnd
    pure effect
  pure (FaultEvidence (length (filter (> 0) effects)) (object ["mode" .= mode, "effects" .= effects]))

contextKnob :: Text -> KnobSpec
contextKnob what = choice "fault.context" ("Whose " <> what <> " link is partitioned: the shop's (a) or the warehouse's (b).") "b" ["a"]

modeKnob :: KnobSpec
modeKnob = choice "fault.mode" "How the link fails: silently dropping traffic, resetting connections, or adding 500 ms of latency." "blackhole" ["reset", "latency"]

choice :: Text -> Text -> Text -> [Text] -> KnobSpec
choice name summary value others = KnobSpec (runtimeKnobName name) summary KnobText (VText value) (OneOf (VText value :| fmap VText others)) []
