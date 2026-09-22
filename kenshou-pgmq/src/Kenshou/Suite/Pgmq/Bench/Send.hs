module Kenshou.Suite.Pgmq.Bench.Send (scenarios) where

import Kenshou.Core.Scenario (Scenario)
import Kenshou.Suite.Pgmq.Catalog

scenarios :: [Scenario]
scenarios = [pgmqScenario (benchmark "pgmq/send/benchmark/send-throughput" "Measures single and batch send throughput, latency, and WAL cost.")]
