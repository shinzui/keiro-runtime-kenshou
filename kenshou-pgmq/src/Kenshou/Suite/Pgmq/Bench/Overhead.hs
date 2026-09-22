module Kenshou.Suite.Pgmq.Bench.Overhead (scenarios) where

import Kenshou.Core.Scenario (Scenario)
import Kenshou.Suite.Pgmq.Catalog

scenarios :: [Scenario]
scenarios =
  fmap
    pgmqScenario
    [ benchmark "pgmq/effectful/benchmark/interpreter-tracing-overhead" "Measures plain and traced effect interpreter overhead across tracing arms.",
      benchmark "pgmq/queue/benchmark/metrics-poll-overhead" "Measures SQL metrics polling overhead across queue depths and intervals."
    ]
