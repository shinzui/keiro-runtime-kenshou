module Kenshou.Suite.Pgmq.Correctness.Send (scenarios) where

import Kenshou.Core.Scenario (Scenario, Tier (..))
import Kenshou.Suite.Pgmq.Catalog

scenarios :: [Scenario]
scenarios =
  fmap
    pgmqScenario
    [ correctness "pgmq/send/correctness/send-variants-round-trip" "Round-trips every single, batch, delayed, scheduled, and headers send variant." TierSmoke,
      correctness "pgmq/send/correctness/delayed-and-scheduled-visibility" "Proves delayed and scheduled messages are never visible before their due time." TierStandard,
      correctness "pgmq/send/correctness/large-payload-round-trip" "Round-trips payloads through queue and archive storage up to the configured size." TierStandard,
      correctness "pgmq/send/correctness/transactional-send-rollback" "Proves caller-owned transactions commit and roll back sends atomically." TierSmoke
    ]
