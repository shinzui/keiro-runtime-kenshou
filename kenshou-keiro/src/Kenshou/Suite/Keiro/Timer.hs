module Kenshou.Suite.Keiro.Timer (scenarios, roles) where

import Kenshou.Core.Role (WorkerRole)
import Kenshou.Core.Scenario (Scenario)
import Kenshou.Suite.Keiro.Timer.Concurrency qualified as Concurrency
import Kenshou.Suite.Keiro.Timer.Correctness qualified as Correctness
import Kenshou.Suite.Keiro.Timer.Roles qualified as Roles

scenarios :: [Scenario]
scenarios = Correctness.scenarios <> Concurrency.scenarios

roles :: [WorkerRole]
roles = Roles.roles
