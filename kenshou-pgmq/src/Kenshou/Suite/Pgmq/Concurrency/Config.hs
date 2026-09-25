module Kenshou.Suite.Pgmq.Concurrency.Config (scenarios) where

import Kenshou.Core.Scenario (Scenario, Tier (..))
import Kenshou.Suite.Pgmq.Catalog

scenarios :: [Scenario]
scenarios =
  fmap
    pgmqScenario
    [ knownDefectWithFailures "pgmq/config/concurrency/concurrent-reconcile" "Concurrent reconcilers can race on FIFO index creation and can each report themselves as a resource creator." TierStandard "mori://shinzui/pgmq-hs/okf/bug-reports/concepts/BUG-2" ["no-worker-errors", "one-creator-report-per-resource"],
      concurrency "pgmq/ack/concurrency/overlapping-batch-ack-deadlock" "Checks overlapping batch acknowledgements retry classified deadlocks exactly." TierStandard
    ]
