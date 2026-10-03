module Kenshou.Suite.Keiro.Queue (scenarios, roles) where

import Kenshou.Core.Role (WorkerRole)
import Kenshou.Core.Scenario (Scenario)
import Kenshou.Suite.Keiro.Queue.Bench qualified as Bench
import Kenshou.Suite.Keiro.Queue.Concurrency qualified as Concurrency
import Kenshou.Suite.Keiro.Queue.Correctness qualified as Correctness
import Kenshou.Suite.Keiro.Queue.PollingFaults qualified as PollingFaults
import Kenshou.Suite.Keiro.Queue.Roles qualified as Roles
import Kenshou.Suite.Keiro.Queue.Soak qualified as Soak
import Kenshou.Suite.Keiro.Queue.SoakWorker qualified as SoakWorker
import Kenshou.Suite.Keiro.Queue.Telemetry qualified as Telemetry

scenarios :: [Scenario]
scenarios = Correctness.scenarios <> Concurrency.scenarios <> Telemetry.scenarios <> Bench.scenarios <> Soak.scenarios

roles :: [WorkerRole]
roles = Roles.roles <> PollingFaults.roles <> [SoakWorker.role]
