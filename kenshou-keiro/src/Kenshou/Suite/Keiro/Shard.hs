module Kenshou.Suite.Keiro.Shard (scenarios, roles) where

import Kenshou.Core.Role (WorkerRole)
import Kenshou.Core.Scenario (Scenario)
import Kenshou.Suite.Keiro.Shard.Correctness qualified as Correctness
import Kenshou.Suite.Keiro.Shard.LeaseSmoke qualified as LeaseSmoke
import Kenshou.Suite.Keiro.Shard.Mismatch qualified as Mismatch
import Kenshou.Suite.Keiro.Shard.Roles qualified as Roles

scenarios :: [Scenario]
scenarios = LeaseSmoke.scenarios <> Mismatch.scenarios <> Correctness.scenarios

roles :: [WorkerRole]
roles = Roles.roles
