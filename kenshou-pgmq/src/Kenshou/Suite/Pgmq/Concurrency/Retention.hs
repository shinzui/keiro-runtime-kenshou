module Kenshou.Suite.Pgmq.Concurrency.Retention (scenarios) where

import Kenshou.Core.Scenario (Scenario, Tier (..))
import Kenshou.Suite.Pgmq.Catalog

scenarios :: [Scenario]
scenarios =
  [ pgmqScenario (knownDefect "pgmq/queue/concurrency/partition-retention-drops-unread" "Partition retention can remove unread and in-flight messages." TierStandard "mori://shinzui/pgmq-hs/plans/21-state-the-fifo-ordering-and-partitioned-retention-contracts-truthfully")
  ]
