module Kenshou.Suite.Keiro.Outbox (scenarios, roles) where

import Kenshou.Core.Role (WorkerRole)
import Kenshou.Core.Scenario (Scenario)
import Kenshou.Suite.Keiro.Outbox.Concurrency qualified as Concurrency
import Kenshou.Suite.Keiro.Outbox.Correctness qualified as Correctness
import Kenshou.Suite.Keiro.Outbox.IdentityRace qualified as IdentityRace
import Kenshou.Suite.Keiro.Outbox.ProducerIdentity qualified as ProducerIdentity
import Kenshou.Suite.Keiro.Outbox.ProducerReplay qualified as ProducerReplay
import Kenshou.Suite.Keiro.Outbox.Roles qualified as Roles
import Kenshou.Suite.Keiro.Outbox.Telemetry qualified as Telemetry

scenarios :: [Scenario]
scenarios = Correctness.scenarios <> ProducerIdentity.scenarios <> Concurrency.scenarios <> IdentityRace.scenarios <> ProducerReplay.scenarios <> Telemetry.scenarios

roles :: [WorkerRole]
roles = Roles.roles
