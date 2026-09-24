module Kenshou.Suite.Keiro.Queue (scenarios) where

import Kenshou.Core.Scenario (Scenario)
import Kenshou.Suite.Keiro.Queue.Correctness qualified as Correctness

scenarios :: [Scenario]
scenarios = Correctness.scenarios
