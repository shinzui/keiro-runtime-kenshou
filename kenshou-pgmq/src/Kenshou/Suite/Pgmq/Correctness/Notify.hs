module Kenshou.Suite.Pgmq.Correctness.Notify (scenarios) where

import Kenshou.Core.Scenario (Scenario, Tier (..))
import Kenshou.Suite.Pgmq.Catalog

scenarios :: [Scenario]
scenarios = [pgmqScenario (correctness "pgmq/notify/correctness/channel-and-throttle" "Checks notification channel naming, throttling, updates, and disablement." TierSmoke)]
