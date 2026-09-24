module Kenshou.Suite.Keiro.Workflow (scenarios, roles) where

import Kenshou.Core.Role (WorkerRole)
import Kenshou.Core.Scenario (Scenario)
import Kenshou.Suite.Keiro.Workflow.AwakeableSmoke qualified as AwakeableSmoke
import Kenshou.Suite.Keiro.Workflow.CrashSmoke qualified as CrashSmoke
import Kenshou.Suite.Keiro.Workflow.LinearSmoke qualified as LinearSmoke
import Kenshou.Suite.Keiro.Workflow.Roles qualified as Roles
import Kenshou.Suite.Keiro.Workflow.RotationSmoke qualified as RotationSmoke
import Kenshou.Suite.Keiro.Workflow.SleepSmoke qualified as SleepSmoke

scenarios :: [Scenario]
scenarios = LinearSmoke.scenarios <> CrashSmoke.scenarios <> SleepSmoke.scenarios <> AwakeableSmoke.scenarios <> RotationSmoke.scenarios

roles :: [WorkerRole]
roles = Roles.roles
