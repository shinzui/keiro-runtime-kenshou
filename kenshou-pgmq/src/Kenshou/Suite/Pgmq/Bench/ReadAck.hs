module Kenshou.Suite.Pgmq.Bench.ReadAck (scenarios) where

import Kenshou.Core.Scenario (Scenario)
import Kenshou.Suite.Pgmq.Catalog

scenarios :: [Scenario]
scenarios = [pgmqScenario (benchmark "pgmq/read/benchmark/read-ack-throughput" "Measures read and acknowledgement throughput across strategies.")]
