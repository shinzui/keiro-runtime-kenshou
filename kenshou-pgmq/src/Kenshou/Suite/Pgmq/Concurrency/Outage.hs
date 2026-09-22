module Kenshou.Suite.Pgmq.Concurrency.Outage (scenarios) where

import Kenshou.Core.Scenario (Scenario, Tier (..))
import Kenshou.Suite.Pgmq.Catalog

scenarios :: [Scenario]
scenarios =
  fmap
    pgmqScenario
    [ concurrency "pgmq/effectful/concurrency/backend-termination-recovery" "Checks transient classification and pool recovery after backend termination." TierStandard,
      concurrency "pgmq/effectful/concurrency/postgres-restart-recovery" "Checks durable messages and pool recovery across PostgreSQL restart." TierStandard,
      concurrency "pgmq/queue/concurrency/unlogged-queue-crash-loss" "Demonstrates unlogged queue loss while standard queues remain durable." TierSmoke,
      concurrency "pgmq/effectful/concurrency/network-partition" "Checks reset, latency, blackhole bounds, and healed-proxy recovery." TierStandard
    ]
