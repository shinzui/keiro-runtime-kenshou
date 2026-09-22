module Kenshou.Suite.Pgmq.Correctness.Vt (scenarios) where

import Kenshou.Core.Scenario (Scenario, Tier (..))
import Kenshou.Suite.Pgmq.Catalog

scenarios :: [Scenario]
scenarios =
  fmap
    pgmqScenario
    [ correctness "pgmq/vt/correctness/wall-clock-expiry" "Waits for a real visibility timeout and checks database-clock redelivery." TierSmoke,
      correctness "pgmq/vt/correctness/set-vt-semantics" "Checks relative and absolute visibility-time updates and lease extension." TierSmoke
    ]
