module Kenshou.Suite.Pgmq.Bench.Backlog (scenarios) where

import Kenshou.Core.Scenario (Scenario)
import Kenshou.Suite.Pgmq.Catalog

scenarios :: [Scenario]
scenarios = [pgmqScenario (benchmark "pgmq/read/benchmark/invisible-backlog-read-cost" "Measures visible read cost behind a large invisible backlog.")]
