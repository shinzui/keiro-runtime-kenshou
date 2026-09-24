module Kenshou.Suite.Keiro.Shard (scenarios, roles) where

import Kenshou.Core.Role (WorkerRole)
import Kenshou.Core.Scenario (Scenario)
import Kenshou.Suite.Keiro.Shard.LeaseSmoke qualified as LeaseSmoke
import Kenshou.Suite.Keiro.Shard.Mismatch qualified as Mismatch

scenarios :: [Scenario]
scenarios = LeaseSmoke.scenarios <> Mismatch.scenarios

roles :: [WorkerRole]
roles = []
