module Kenshou.Suite.Pgmq.Correctness.Effectful (scenarios) where

import Kenshou.Core.Scenario (Scenario, Tier (..))
import Kenshou.Suite.Pgmq.Catalog

scenarios :: [Scenario]
scenarios =
  fmap
    pgmqScenario
    [ correctness "pgmq/effectful/correctness/interpreter-parity-and-errors" "Checks session and effect interpreters agree and classify real failures." TierStandard,
      correctness "pgmq/effectful/correctness/traced-span-contract" "Checks traced operation span names, kinds, errors, and propagated context." TierSmoke
    ]
