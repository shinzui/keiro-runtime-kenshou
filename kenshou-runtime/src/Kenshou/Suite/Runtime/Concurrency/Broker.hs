module Kenshou.Suite.Runtime.Concurrency.Broker (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM)
import Data.Aeson (object, (.=))
import Kenshou.Check.Fact (FactKind (..))
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Env.Postgres (PostgresEnv (..), ServerControl (..), StopMode (..))
import Kenshou.Core.Knob (KnobValue (..))
import Kenshou.Core.Scenario (CohortScope (..), KnownDefect (..), Placement (..), Scenario, Tier (..))
import Kenshou.Env.Kafka (BrokerControl (..), requireControl)
import Kenshou.Suite.Runtime.Concurrency (FaultEvidence (..), FaultPlan (..), faultInt, faultScenario)
import Kenshou.Suite.Runtime.System.Broker (RuntimeBroker (..))
import Kenshou.Suite.Runtime.Topology (RunningSystem (..), recordWindow)

scenarios :: [Scenario]
scenarios = [brokerRestart, ackRetryUnderDatabaseOutage, batchEnqueuePublishUnderBrokerRestart]

-- | Kills the broker for the outage and starts it again. Outbox rows wait as
-- failed with backoff; none may become dead, which I4 checks.
brokerRestart :: Scenario
brokerRestart = faultScenario brokerRestart'

brokerRestart' :: FaultPlan
brokerRestart' =
  FaultPlan
    { component = "broker",
      name = "broker-restart",
      summary = "Kills the Kafka broker for an outage and restarts it while orders flow, and judges I1 to I6.",
      tier = TierStandard,
      placement = PlaceLocal,
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

-- | Known defect: with the house-pattern @AckRetry@ transient policy, a
-- warehouse database outage with a full consumer backlog lets the adapter
-- seek past unprocessed records (KFK-1) and run buffered successors out of
-- order (KFK-2), so some orders never reach the warehouse.
ackRetryUnderDatabaseOutage :: Scenario
ackRetryUnderDatabaseOutage =
  faultScenario
    FaultPlan
      { component = "broker",
        name = "ack-retry-under-database-outage",
        summary = "Takes the warehouse database away for twenty seconds under the AckRetry consumer policy; known defect KFK-1/KFK-2.",
        tier = TierStandard,
        placement = PlaceLocal,
        overrides = [("runtime.kafka-transient-policy", VText "ack-retry"), ("fault.count", VInt 1), ("fault.outage-seconds", VInt 20)],
        extraKnobs = [],
        inject = \context system -> case system.warehousePostgres.control of
          Nothing -> pure (FaultEvidence 0 (object ["reason" .= ("warehouse PostgreSQL has no server control" :: String)]))
          Just control -> do
            outages <- forM [1 .. faultInt context.knobs "fault.count"] \_ -> do
              threadDelay (faultInt context.knobs "fault.period-seconds" * 1000000)
              recordWindow system "fault/postmaster" "*" DisturbanceStart
              control.stopServer StopImmediate
              threadDelay (faultInt context.knobs "fault.outage-seconds" * 1000000)
              control.startServer
              recordWindow system "fault/postmaster" "*" DisturbanceEnd
            pure (FaultEvidence (length outages) (object ["outages" .= length outages])),
        knownDefect =
          Just
            KnownDefect
              { reference = "mori://shinzui/keiro/plans/119-fix-the-seek-barrier-ordering-and-stale-successor-execution-in-shibuya-kafka-adapter",
                summary = "Consecutive fast AckRetry decisions in shibuya-kafka-adapter 0.9.0.1 can seek past an unprocessed record and run buffered successors out of order.",
                expectedFailures = ["quiescence-reached", "terminal-exactly-once", "effects-exactly-once", "conservation", "duplicates-bounded"],
                appliesTo = AllCohorts
              },
        databaseProxies = False
      }

-- | Known defect: the obvious batch outbox wiring reports enqueued records
-- as published without a broker acknowledgement (KFK-3), so a broker restart
-- loses rows already marked sent.
batchEnqueuePublishUnderBrokerRestart :: Scenario
batchEnqueuePublishUnderBrokerRestart =
  faultScenario
    FaultPlan
      { component = "broker",
        name = "batch-enqueue-publish-under-broker-restart",
        summary = "Publishes with batch enqueue and restarts the broker; known defect KFK-3, rows marked sent that the broker never stored.",
        tier = TierStandard,
        placement = PlaceLocal,
        overrides = [("runtime.publish-mode", VText "batch-enqueue"), ("fault.count", VInt 2), ("fault.outage-seconds", VInt 15), ("fault.period-seconds", VInt 30)],
        extraKnobs = [],
        inject = brokerRestart'.inject,
        knownDefect =
          Just
            KnownDefect
              { reference = "mori://shinzui/keiro/plans/120-add-an-acked-batch-publish-api-to-kafka-effectful-and-a-reference-outbox-bridge",
                summary = "No shipped API reports broker acknowledgements for a batch, so the batch wiring marks rows sent that the broker never acknowledged.",
                expectedFailures = ["quiescence-reached", "terminal-exactly-once", "effects-exactly-once", "conservation"],
                appliesTo = AllCohorts
              },
        databaseProxies = False
      }
