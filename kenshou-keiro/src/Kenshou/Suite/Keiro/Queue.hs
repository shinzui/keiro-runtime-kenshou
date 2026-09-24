module Kenshou.Suite.Keiro.Queue (scenarios, roles) where

import Kenshou.Core.Role (WorkerRole)
import Kenshou.Core.Scenario (Scenario)
import Kenshou.Suite.Keiro.Queue.Concurrency qualified as Concurrency
import Kenshou.Suite.Keiro.Queue.Correctness qualified as Correctness
import Kenshou.Suite.Keiro.Queue.Roles qualified as Roles

scenarios :: [Scenario]
scenarios = Correctness.scenarios <> Concurrency.scenarios

roles :: [WorkerRole]
roles = Roles.roles
