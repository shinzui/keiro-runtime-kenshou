module Kenshou.Suite.Pgmq.Concurrency.Outage (scenarios) where

import Kenshou.Core.Scenario (Scenario, Tier (..))
import Kenshou.Suite.Pgmq.Catalog

scenarios :: [Scenario]
scenarios =
  fmap
    pgmqScenario
    [ knownDefectWithFailures "pgmq/effectful/concurrency/backend-termination-recovery" "Backend termination can surface a disconnect as a permanent row-count error." TierStandard "mori://shinzui/pgmq-hs/okf/improvement-requests/concepts/IR-4" ["transient-error"],
      knownDefectWithFailures "pgmq/effectful/concurrency/postgres-restart-recovery" "Immediate PostgreSQL shutdown can surface a transient disconnect with no SQLSTATE." TierStandard "mori://shinzui/pgmq-hs/okf/improvement-requests/concepts/IR-4" ["outage-error-transient"],
      concurrency "pgmq/queue/concurrency/unlogged-queue-crash-loss" "Demonstrates unlogged queue loss while standard queues remain durable." TierSmoke,
      knownDefectWithFailures "pgmq/effectful/concurrency/network-partition" "A TCP reset can surface a transient disconnect with no SQLSTATE." TierStandard "mori://shinzui/pgmq-hs/okf/improvement-requests/concepts/IR-4" ["reset-transient"],
      knownDefectWithFailures "pgmq/effectful/concurrency/network-blackhole" "A blackholed PostgreSQL response can leave a PGMQ call blocked past the configured bound." TierStandard "mori://shinzui/pgmq-hs/okf/improvement-requests/concepts/IR-6" ["client-returned-within-bound"]
    ]
