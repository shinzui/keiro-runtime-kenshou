module Kenshou.Suite.Keiro.Timer (scenarios, roles) where

import Kenshou.Core.Role (WorkerRole)
import Kenshou.Core.Scenario (Scenario)
import Kenshou.Suite.Keiro.Timer.Correctness qualified as Correctness

scenarios :: [Scenario]
scenarios = Correctness.scenarios

roles :: [WorkerRole]
roles = []
