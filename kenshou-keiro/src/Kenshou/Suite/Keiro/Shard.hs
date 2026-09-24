module Kenshou.Suite.Keiro.Shard (scenarios, roles) where

import Kenshou.Core.Role (WorkerRole)
import Kenshou.Core.Scenario (Scenario)
import Kenshou.Suite.Keiro.Shard.Concurrency qualified as Concurrency
import Kenshou.Suite.Keiro.Shard.Correctness qualified as Correctness
import Kenshou.Suite.Keiro.Shard.DatabaseFaults qualified as DatabaseFaults
import Kenshou.Suite.Keiro.Shard.LeaseSmoke qualified as LeaseSmoke
import Kenshou.Suite.Keiro.Shard.Mismatch qualified as Mismatch
import Kenshou.Suite.Keiro.Shard.Roles qualified as Roles
import Kenshou.Suite.Keiro.Shard.Variants qualified as Variants

scenarios :: [Scenario]
scenarios = LeaseSmoke.scenarios <> Mismatch.scenarios <> Correctness.scenarios <> Concurrency.scenarios <> Variants.scenarios <> DatabaseFaults.scenarios

roles :: [WorkerRole]
roles = Roles.roles
