module Kenshou.Suite.Keiro.Shard (scenarios, roles) where

import Kenshou.Core.Role (WorkerRole)
import Kenshou.Core.Scenario (Scenario)
import Kenshou.Suite.Keiro.Shard.LeaseSmoke qualified as LeaseSmoke

scenarios :: [Scenario]
scenarios = LeaseSmoke.scenarios

roles :: [WorkerRole]
roles = []
