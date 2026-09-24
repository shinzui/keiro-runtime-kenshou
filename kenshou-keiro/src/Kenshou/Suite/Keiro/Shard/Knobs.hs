module Kenshou.Suite.Keiro.Shard.Knobs
  ( shardKnobs,
    shardKnobName,
    shardOptionsFrom,
  )
where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Keiro.Subscription.Shard.Worker (RetryDelay (..), ShardedWorkerConfigError, ShardedWorkerOptions (..), defaultShardedWorkerOptions, mkShardedWorkerOptions)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), ResolvedKnobs, knobDouble, knobInt, mkKnobName)
import Kiroku.Store.Subscription.Types (RetryPolicy (..), SubscriptionTarget)

shardKnobName :: Text -> KnobName
shardKnobName = either (error . Text.unpack) id . mkKnobName

shardKnobs :: [KnobSpec]
shardKnobs =
  [ integer "shard.shard-count" 8 1 100000,
    decimal "shard.lease-ttl-seconds" 3 0.01 3600,
    decimal "shard.renew-interval-seconds" 0.5 0.01 3600,
    integer "shard.batch-size" 100 1 100000,
    integer "shard.buffer-size" 256 1 100000,
    integer "shard.handler-retry-delay-ms" 100 0 60000,
    integer "shard.retry-max-attempts" 5 1 100,
    integer "shard.worker-processes" 3 1 64,
    KnobSpec (shardKnobName "shard.handler") "Shard handler kind" KnobText (VText "ack") (OneOf (VText "ack" :| [VText "plain"])) [],
    integer "shard.events" 20000 1 10000000,
    integer "shard.streams" 500 1 1000000
  ]
  where
    integer key def low high = KnobSpec (shardKnobName key) key KnobInt (VInt def) (IntRange low high) []
    decimal key def low high = KnobSpec (shardKnobName key) key KnobDouble (VDouble def) (DoubleRange low high) []

shardOptionsFrom :: SubscriptionTarget -> ResolvedKnobs -> Either ShardedWorkerConfigError ShardedWorkerOptions
shardOptionsFrom target knobs =
  mkShardedWorkerOptions
    (defaultShardedWorkerOptions target (fromIntegral (knobInt knobs (shardKnobName "shard.shard-count"))))
      { leaseTtl = realToFrac (knobDouble knobs (shardKnobName "shard.lease-ttl-seconds")),
        renewInterval = realToFrac (knobDouble knobs (shardKnobName "shard.renew-interval-seconds")),
        batchSize = fromIntegral (knobInt knobs (shardKnobName "shard.batch-size")),
        bufferSize = fromIntegral (knobInt knobs (shardKnobName "shard.buffer-size")),
        handlerRetryDelay = RetryDelay (realToFrac (knobInt knobs (shardKnobName "shard.handler-retry-delay-ms")) / 1000),
        retryPolicy = RetryPolicy (fromIntegral (knobInt knobs (shardKnobName "shard.retry-max-attempts")))
      }
