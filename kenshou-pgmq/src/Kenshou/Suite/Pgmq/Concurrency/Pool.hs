module Kenshou.Suite.Pgmq.Concurrency.Pool (scenarios) where

import Kenshou.Core.Scenario (Scenario, Tier (..))
import Kenshou.Suite.Pgmq.Catalog

scenarios :: [Scenario]
scenarios = [pgmqScenario (concurrency "pgmq/read/concurrency/pool-exhaustion-long-poll" "Shows long polls pin pool connections and verifies timeout recovery." TierStandard)]
