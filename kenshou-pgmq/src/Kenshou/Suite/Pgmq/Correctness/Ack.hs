module Kenshou.Suite.Pgmq.Correctness.Ack (scenarios) where

import Kenshou.Core.Scenario (Scenario, Tier (..))
import Kenshou.Suite.Pgmq.Catalog

scenarios :: [Scenario]
scenarios = [pgmqScenario (correctness "pgmq/ack/correctness/delete-archive-semantics" "Checks single and batch delete and archive acknowledgement semantics." TierSmoke)]
