module Kenshou.Suite.Pgmq.Bench.Fifo (scenarios) where

import Kenshou.Core.Scenario (Scenario)
import Kenshou.Suite.Pgmq.Catalog

scenarios :: [Scenario]
scenarios = [pgmqScenario (benchmark "pgmq/fifo/benchmark/grouped-read-cost" "Measures grouped read strategies across group counts and FIFO indexing.")]
