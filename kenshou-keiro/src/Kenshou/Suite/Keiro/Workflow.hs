module Kenshou.Suite.Keiro.Workflow (scenarios, roles) where

import Kenshou.Core.Role (WorkerRole)
import Kenshou.Core.Scenario (Scenario)
import Kenshou.Suite.Keiro.Workflow.LinearSmoke qualified as LinearSmoke

scenarios :: [Scenario]
scenarios = LinearSmoke.scenarios

roles :: [WorkerRole]
roles = []
