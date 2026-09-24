module Kenshou.Suite.Keiro.Outbox (scenarios) where

import Kenshou.Core.Scenario (Scenario)
import Kenshou.Suite.Keiro.Outbox.Correctness qualified as Correctness
import Kenshou.Suite.Keiro.Outbox.ProducerIdentity qualified as ProducerIdentity

scenarios :: [Scenario]
scenarios = Correctness.scenarios <> ProducerIdentity.scenarios
