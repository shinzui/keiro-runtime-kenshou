module Kenshou.Suite.Pgmq.Concurrency.Notify (scenarios) where

import Kenshou.Core.Scenario (Scenario, Tier (..))
import Kenshou.Suite.Pgmq.Catalog

scenarios :: [Scenario]
scenarios =
  [ pgmqScenario (knownDefect "pgmq/notify/concurrency/partitioned-notify-storm" "Partition triggers bypass the configured notification throttle." TierStandard "mori://shinzui/pgmq-hs/plans/23-gate-the-notification-fail-open-on-a-real-queue-row-and-state-the-partitioned-queue-contract"),
    pgmqScenario (concurrency "pgmq/notify/concurrency/throttle-lost-after-crash" "Checks fail-open notification delivery and reconciler recovery after crash." TierStandard),
    pgmqScenario (concurrency "pgmq/notify/concurrency/listener-loss-poll-fallback" "Checks polling bounds delivery while LISTEN is disconnected." TierStandard)
  ]
