module Kenshou.Suite.Pgmq.Concurrency.Crash (scenarios) where

import Kenshou.Core.Scenario (Scenario, Tier (..))
import Kenshou.Suite.Pgmq.Catalog

scenarios :: [Scenario]
scenarios =
  fmap
    pgmqScenario
    [ concurrency "pgmq/ack/concurrency/random-sigkill-at-least-once" "Checks at-least-once handling during repeated random process kills." TierExtended,
      concurrency "pgmq/send/concurrency/producer-sigkill-batch-atomicity" "Checks batch sends are all-or-nothing across producer kills." TierStandard
    ]
