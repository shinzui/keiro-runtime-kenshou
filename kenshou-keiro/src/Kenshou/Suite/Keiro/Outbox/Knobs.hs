module Kenshou.Suite.Keiro.Outbox.Knobs
  ( outboxKnobs,
    decodePublishOptions,
  )
where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Keiro.Outbox (BackoffSchedule (..), ExponentialBackoffOptions (..), OrderingPolicy (..), OutboxPublishConfigError, OutboxPublishOptions (..), defaultPublishOptions, mkOutboxPublishOptions)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), ResolvedKnobs, knobDouble, knobInt, knobText, mkKnobName)
import OpenTelemetry.Trace.Core (Tracer)

outboxKnobs :: [KnobSpec]
outboxKnobs =
  [ textKnob "outbox.ordering-policy" "Publisher ordering policy" "per-key-head-of-line" ["per-source-stream", "stop-the-line", "best-effort"],
    intKnob "outbox.batch-size" "Rows claimed per publisher pass" 32 0 10000,
    intKnob "outbox.max-attempts" "Maximum consumed publish attempts" 10 0 100,
    textKnob "outbox.backoff" "Publish retry schedule" "constant" ["exponential"],
    doubleKnob "outbox.backoff-seconds" "Initial or constant retry delay in seconds" 2 0 3600,
    doubleKnob "outbox.backoff-max-seconds" "Maximum exponential retry delay in seconds" 60 0 3600,
    doubleKnob "outbox.backoff-multiplier" "Exponential retry multiplier" 2 0 100,
    doubleKnob "outbox.publishing-timeout-seconds" "Age at which maintenance may reclaim a claim" 300 0 3600,
    intKnob "outbox.publishers" "Publisher process count" 1 1 32,
    intKnob "outbox.enqueuers" "Enqueuer process count" 1 1 32,
    textKnob "outbox.enqueue-path" "Inline or canonical producer enqueue path" "producer" ["inline"],
    intKnob "outbox.rows" "Number of enqueued integration events" 2000 1 1000000,
    intKnob "outbox.key-cardinality" "Number of partition keys; zero means no key" 50 0 1000000,
    intKnob "outbox.sources" "Number of event sources" 1 1 10000,
    intKnob "outbox.payload-bytes" "Payload size in bytes" 1024 0 10000000,
    intKnob "outbox.maintenance-interval-ms" "Maintenance pass interval in milliseconds" 500 1 60000,
    textKnob "outbox.gc" "Sent-row garbage collection" "off" ["on"],
    doubleKnob "outbox.retention-seconds" "Sent-row retention in seconds" 3600 0 86400,
    intKnob "broker.invocation-micros" "Synthetic broker service time per call" 1000 0 10000000,
    intKnob "broker.per-record-micros" "Synthetic broker service time per record" 10 0 10000000,
    intKnob "broker.partitions" "Synthetic broker partition count" 4 1 10000,
    doubleKnob "broker.fail-ratio" "Transient publish failure fraction" 0 0 1,
    doubleKnob "broker.reject-ratio" "Terminal publish rejection fraction" 0 0 1,
    doubleKnob "broker.poison-ratio" "Permanent publish failure fraction" 0 0 1,
    doubleKnob "broker.throw-ratio" "Callback exception fraction" 0 0 1,
    doubleKnob "broker.drop-outcome-ratio" "Missing publish outcome fraction" 0 0 1
  ]

decodePublishOptions :: ResolvedKnobs -> Maybe Tracer -> Either OutboxPublishConfigError OutboxPublishOptions
decodePublishOptions knobs tracer =
  mkOutboxPublishOptions
    defaultPublishOptions
      { batchSize = fromIntegral (knobInt knobs (name "outbox.batch-size")),
        maxAttempts = fromIntegral (knobInt knobs (name "outbox.max-attempts")),
        backoff = case knobText knobs (name "outbox.backoff") of
          "constant" -> ConstantBackoff (realToFrac (knobDouble knobs (name "outbox.backoff-seconds")))
          "exponential" ->
            ExponentialBackoff
              ( ExponentialBackoffOptions
                  (realToFrac (knobDouble knobs (name "outbox.backoff-seconds")))
                  (realToFrac (knobDouble knobs (name "outbox.backoff-max-seconds")))
                  (knobDouble knobs (name "outbox.backoff-multiplier"))
              )
          other -> error ("unknown resolved outbox backoff: " <> show other),
        orderingPolicy = case knobText knobs (name "outbox.ordering-policy") of
          "per-key-head-of-line" -> PerKeyHeadOfLine
          "per-source-stream" -> PerSourceStream
          "stop-the-line" -> StopTheLine
          "best-effort" -> BestEffort
          other -> error ("unknown resolved outbox ordering policy: " <> show other),
        publishingTimeout = realToFrac (knobDouble knobs (name "outbox.publishing-timeout-seconds")),
        tracer
      }

name :: Text -> KnobName
name = either (error . show) id . mkKnobName

textKnob :: Text -> Text -> Text -> [Text] -> KnobSpec
textKnob key summary def alternatives = KnobSpec (name key) summary KnobText (VText def) (OneOf (VText def :| map VText alternatives)) (map VText alternatives)

intKnob :: Text -> Text -> Int -> Int -> Int -> KnobSpec
intKnob key summary def low high = KnobSpec (name key) summary KnobInt (VInt (fromIntegral def)) (IntRange (fromIntegral low) (fromIntegral high)) []

doubleKnob :: Text -> Text -> Double -> Double -> Double -> KnobSpec
doubleKnob key summary def low high = KnobSpec (name key) summary KnobDouble (VDouble def) (DoubleRange low high) []
