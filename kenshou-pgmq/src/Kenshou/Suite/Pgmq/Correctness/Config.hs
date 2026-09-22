module Kenshou.Suite.Pgmq.Correctness.Config (scenarios) where

import Kenshou.Core.Scenario (Scenario, Tier (..))
import Kenshou.Suite.Pgmq.Catalog

scenarios :: [Scenario]
scenarios =
  [ pgmqScenario (correctness "pgmq/config/correctness/reconcile-convergence" "Checks that declarative queue reconciliation converges and reports drift." TierSmoke),
    pgmqScenario (knownDefect "pgmq/config/correctness/mixed-case-alias-collision" "Reconciliation must report mixed-case physical table alias collisions." TierSmoke "mori://shinzui/pgmq-hs/plans/24-report-name-collisions-and-unsupported-notifications-instead-of-acting-on-them")
  ]
