module Kenshou.Telemetry.Continuity
  ( SpanSelector (..),
    ContinuityResult (..),
    IsolationResult (..),
    checkContinuity,
    checkIsolation,
  )
where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Telemetry.Tracing.Probe (SpanView (..))
import OpenTelemetry.Attributes (Attribute, lookupAttribute)
import OpenTelemetry.Trace.Core (SpanKind)

data SpanSelector = SpanSelector
  { nameIs :: Maybe Text,
    kindIs :: Maybe SpanKind,
    hasAttr :: [(Text, Attribute)]
  }
  deriving stock (Eq, Show)

data ContinuityResult = ContinuityResult
  { producers :: Int,
    consumers :: Int,
    matched :: Int,
    violations :: Int,
    counterExamples :: [Text]
  }
  deriving stock (Eq, Show)

data IsolationResult = IsolationResult
  { checked :: Int,
    violations :: Int,
    counterExamples :: [Text]
  }
  deriving stock (Eq, Show)

instance ToJSON ContinuityResult where
  toJSON value = object ["producers" .= value.producers, "consumers" .= value.consumers, "matched" .= value.matched, "violations" .= value.violations, "counterExamples" .= value.counterExamples]

instance ToJSON IsolationResult where
  toJSON value = object ["checked" .= value.checked, "violations" .= value.violations, "counterExamples" .= value.counterExamples]

checkContinuity :: SpanSelector -> SpanSelector -> (SpanView -> Maybe Text) -> [SpanView] -> ContinuityResult
checkContinuity producerSelector consumerSelector correlation spans =
  let producerSpans = filter (matches producerSelector) spans
      consumerSpans = filter (matches consumerSelector) spans
      outcomes = fmap (checkConsumer producerSpans) consumerSpans
      failures = take 10 [message | Left message <- outcomes]
   in ContinuityResult (length producerSpans) (length consumerSpans) (length [() | Right () <- outcomes]) (length [() | Left _ <- outcomes]) failures
  where
    checkConsumer producerSpans consumer = case correlation consumer of
      Nothing -> Left (consumer.name <> ": missing correlation key")
      Just key -> case find ((== Just key) . correlation) producerSpans of
        Nothing -> Left (consumer.name <> ": no producer for " <> key)
        Just producer
          | consumer.traceId /= producer.traceId -> Left (consumer.name <> ": trace differs for " <> key)
          | consumer.parentSpanId /= Just producer.spanId -> Left (consumer.name <> ": parent differs for " <> key)
          | otherwise -> Right ()

checkIsolation :: SpanSelector -> (SpanView -> Bool) -> [SpanView] -> IsolationResult
checkIsolation selector expectedRoot spans =
  let checkedSpans = filter (\span -> matches selector span && expectedRoot span) spans
      failures = [span.name <> ": inherited parent " <> Text.pack (show parent) | span <- checkedSpans, Just parent <- [span.parentSpanId]]
   in IsolationResult (length checkedSpans) (length failures) (take 10 failures)

matches :: SpanSelector -> SpanView -> Bool
matches selector span =
  maybe True (== span.name) selector.nameIs
    && maybe True (== span.kind) selector.kindIs
    && all (\(key, expected) -> lookupAttribute span.attributes key == Just expected) selector.hasAttr
