module Kenshou.Suite.Keiro.Workflow (scenarios, roles) where

import Kenshou.Core.Role (WorkerRole)
import Kenshou.Core.Scenario (Scenario)
import Kenshou.Suite.Keiro.Workflow.CrashSmoke qualified as CrashSmoke
import Kenshou.Suite.Keiro.Workflow.LinearSmoke qualified as LinearSmoke
import Kenshou.Suite.Keiro.Workflow.Roles qualified as Roles

scenarios :: [Scenario]
scenarios = LinearSmoke.scenarios <> CrashSmoke.scenarios

roles :: [WorkerRole]
roles = Roles.roles
