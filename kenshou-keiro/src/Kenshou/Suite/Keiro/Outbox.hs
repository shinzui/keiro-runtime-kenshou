module Kenshou.Suite.Keiro.Outbox (scenarios) where

import Kenshou.Core.Scenario (Scenario)
import Kenshou.Suite.Keiro.Outbox.Correctness qualified as Correctness

scenarios :: [Scenario]
scenarios = Correctness.scenarios
