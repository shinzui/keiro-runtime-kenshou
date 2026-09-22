module Kenshou.Suite.Pgmq.Bench.Ladder (scenarios) where

import Kenshou.Core.Scenario (Scenario)
import Kenshou.Suite.Pgmq.Catalog

scenarios :: [Scenario]
scenarios = [pgmqScenario (benchmark "pgmq/effectful/benchmark/layer-ladder" "Measures raw SQL, pgmq-hasql, and pgmq-effectful operation overhead.")]
