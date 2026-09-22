module Kenshou.Suite.Pgmq.Concurrency.Fifo (scenarios) where

import Kenshou.Core.Scenario (Scenario, Tier (..))
import Kenshou.Suite.Pgmq.Catalog

scenarios :: [Scenario]
scenarios =
  fmap
    pgmqScenario
    [ concurrency "pgmq/fifo/concurrency/head-per-group-barrier" "Checks grouped-head maintains one live lease and ordered handling per group." TierExtended,
      concurrency "pgmq/fifo/concurrency/grouped-batch-successor-hazard" "Demonstrates successors can run before a failed predecessor in grouped batches." TierStandard,
      concurrency "pgmq/fifo/concurrency/producer-commit-order-inversion" "Demonstrates message identifiers follow insert order rather than commit order." TierSmoke
    ]
