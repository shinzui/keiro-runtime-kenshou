module Kenshou.Suite.Pgmq.Concurrency.Config (scenarios) where

import Kenshou.Core.Scenario (Scenario, Tier (..))
import Kenshou.Suite.Pgmq.Catalog

scenarios :: [Scenario]
scenarios =
  fmap
    pgmqScenario
    [ concurrency "pgmq/config/concurrency/concurrent-reconcile" "Checks simultaneous reconcilers converge without catalog races." TierStandard,
      concurrency "pgmq/ack/concurrency/overlapping-batch-ack-deadlock" "Checks overlapping batch acknowledgements retry classified deadlocks exactly." TierStandard
    ]
