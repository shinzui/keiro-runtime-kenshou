module Kenshou.Suite.Pgmq.Correctness.Queue (scenarios) where

import Kenshou.Core.Scenario (Scenario, Tier (..))
import Kenshou.Suite.Pgmq.Catalog

scenarios :: [Scenario]
scenarios =
  [ pgmqScenario (correctness "pgmq/queue/correctness/lifecycle-by-kind" "Creates, inspects, clears, and drops every supported queue kind." TierSmoke)
  ]
