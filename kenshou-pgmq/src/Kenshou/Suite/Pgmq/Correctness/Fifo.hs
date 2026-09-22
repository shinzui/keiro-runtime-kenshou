module Kenshou.Suite.Pgmq.Correctness.Fifo (scenarios) where

import Kenshou.Core.Scenario (Scenario, Tier (..))
import Kenshou.Suite.Pgmq.Catalog

scenarios :: [Scenario]
scenarios =
  [ pgmqScenario (correctness "pgmq/fifo/correctness/grouped-read-semantics" "Checks grouped, round-robin, and grouped-head FIFO read boundaries." TierSmoke),
    pgmqScenario (knownDefect "pgmq/fifo/correctness/grouped-result-order" "Grouped read vectors are not guaranteed to return in message identifier order." TierStandard "mori://shinzui/pgmq-hs/plans/19-give-the-grouped-reads-a-deterministic-return-order")
  ]
