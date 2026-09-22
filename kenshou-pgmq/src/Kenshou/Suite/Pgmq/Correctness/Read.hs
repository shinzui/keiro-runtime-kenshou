module Kenshou.Suite.Pgmq.Correctness.Read (scenarios) where

import Kenshou.Core.Scenario (Scenario, Tier (..))
import Kenshou.Suite.Pgmq.Catalog

scenarios :: [Scenario]
scenarios =
  fmap
    pgmqScenario
    [ correctness "pgmq/read/correctness/read-semantics" "Checks batch, conditional, pop, and polling read semantics." TierSmoke,
      correctness "pgmq/read/correctness/plain-read-return-order" "Checks whether plain reads retain ascending message identifier order after heap churn." TierStandard
    ]
