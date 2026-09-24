module Kenshou.Suite.Keiro.Inbox (scenarios) where

import Kenshou.Core.Scenario (Scenario)
import Kenshou.Suite.Keiro.Inbox.Correctness qualified as Correctness

scenarios :: [Scenario]
scenarios = Correctness.scenarios
