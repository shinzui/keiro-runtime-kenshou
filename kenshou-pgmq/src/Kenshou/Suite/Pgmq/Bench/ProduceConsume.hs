module Kenshou.Suite.Pgmq.Bench.ProduceConsume (scenarios) where

import Kenshou.Core.Scenario (Scenario)
import Kenshou.Suite.Pgmq.Catalog

scenarios :: [Scenario]
scenarios = [pgmqScenario (benchmark "pgmq/read/benchmark/produce-consume-latency" "Measures intended-start produce-to-consume latency across wake modes.")]
