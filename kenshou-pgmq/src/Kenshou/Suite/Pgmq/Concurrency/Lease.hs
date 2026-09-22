module Kenshou.Suite.Pgmq.Concurrency.Lease (scenarios) where

import Kenshou.Core.Scenario (Scenario, Tier (..))
import Kenshou.Suite.Pgmq.Catalog

scenarios :: [Scenario]
scenarios =
  fmap
    pgmqScenario
    [ concurrency "pgmq/read/concurrency/no-double-lease-threads" "Proves concurrent threads never own overlapping leases." TierStandard,
      concurrency "pgmq/read/concurrency/no-double-lease-processes" "Proves concurrent processes never own overlapping leases." TierStandard,
      concurrency "pgmq/vt/concurrency/crash-redelivery-read-count" "Kills consumers after reads and checks expiry and read-count accounting." TierStandard,
      concurrency "pgmq/ack/concurrency/stale-ack-after-expiry" "Demonstrates the documented unfenced stale-acknowledgement boundary." TierSmoke
    ]
