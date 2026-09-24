module Kenshou.Suite.Keiro.Outbox (scenarios, roles) where

import Kenshou.Core.Role (WorkerRole)
import Kenshou.Core.Scenario (Scenario)
import Kenshou.Suite.Keiro.Outbox.Concurrency qualified as Concurrency
import Kenshou.Suite.Keiro.Outbox.Correctness qualified as Correctness
import Kenshou.Suite.Keiro.Outbox.ProducerIdentity qualified as ProducerIdentity
import Kenshou.Suite.Keiro.Outbox.Roles qualified as Roles

scenarios :: [Scenario]
scenarios = Correctness.scenarios <> ProducerIdentity.scenarios <> Concurrency.scenarios

roles :: [WorkerRole]
roles = Roles.roles
