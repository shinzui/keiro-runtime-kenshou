module Kenshou.Suite.Keiro.Inbox (scenarios, roles) where

import Kenshou.Core.Role (WorkerRole)
import Kenshou.Core.Scenario (Scenario)
import Kenshou.Suite.Keiro.Inbox.Bench qualified as Bench
import Kenshou.Suite.Keiro.Inbox.Concurrency qualified as Concurrency
import Kenshou.Suite.Keiro.Inbox.Correctness qualified as Correctness
import Kenshou.Suite.Keiro.Inbox.Roles qualified as Roles

scenarios :: [Scenario]
scenarios = Correctness.scenarios <> Concurrency.scenarios <> Bench.scenarios

roles :: [WorkerRole]
roles = Roles.roles
