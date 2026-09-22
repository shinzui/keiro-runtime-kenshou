module Kenshou.Suite.Pgmq.Bench.Notify (scenarios) where

import Kenshou.Core.Scenario (Scenario)
import Kenshou.Suite.Pgmq.Catalog

scenarios :: [Scenario]
scenarios = [pgmqScenario (benchmark "pgmq/notify/benchmark/notify-insert-overhead" "Measures insert-trigger and notification-lock overhead.")]
