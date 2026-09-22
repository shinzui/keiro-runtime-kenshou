module Kenshou.Suite.Pgmq.Correctness.Topics (scenarios) where

import Kenshou.Core.Scenario (Scenario, Tier (..))
import Kenshou.Suite.Pgmq.Catalog

scenarios :: [Scenario]
scenarios = [pgmqScenario (correctness "pgmq/topics/correctness/routing-model" "Compares topic binding and sending with a pure wildcard routing model." TierStandard)]
