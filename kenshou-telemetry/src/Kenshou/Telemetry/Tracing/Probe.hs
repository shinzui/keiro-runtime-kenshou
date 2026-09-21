module Kenshou.Telemetry.Tracing.Probe
  ( SpanView (..),
    SpanProbe,
    newSpanProbe,
    readSpans,
    spansSeen,
  )
where

import Data.Foldable qualified as Foldable
import Data.IORef
import Data.Sequence (Seq (..), (|>))
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Word (Word64)
import OpenTelemetry.Attributes (Attributes)
import OpenTelemetry.Common (optionalTimestampToMaybe, timestampToNanoseconds)
import OpenTelemetry.Internal.Common.Types (FlushResult (FlushSuccess), ShutdownResult (ShutdownSuccess))
import OpenTelemetry.Processor.Span (SpanProcessor (..))
import OpenTelemetry.Trace.Core (ImmutableSpan (..), SpanContext (..), SpanHot (..), SpanKind, SpanStatus, getSpanContext)
import OpenTelemetry.Trace.Id (SpanId, TraceId)

data SpanView = SpanView
  { name :: Text,
    kind :: SpanKind,
    traceId :: TraceId,
    spanId :: SpanId,
    parentSpanId :: Maybe SpanId,
    attributes :: Attributes,
    startNs :: Word64,
    endNs :: Word64,
    status :: SpanStatus
  }
  deriving stock (Eq, Show)

data ProbeState = ProbeState {seen :: Int, retained :: Seq SpanView}

data SpanProbe = SpanProbe {capacity :: Int, state :: IORef ProbeState}

newSpanProbe :: Int -> IO (SpanProbe, SpanProcessor)
newSpanProbe capacity = do
  state <- newIORef (ProbeState 0 Seq.empty)
  let probe = SpanProbe (max 0 capacity) state
      processor =
        SpanProcessor
          { spanProcessorOnStart = \_ _ -> pure (),
            spanProcessorOnEnd = capture probe,
            spanProcessorShutdown = pure ShutdownSuccess,
            spanProcessorForceFlush = pure FlushSuccess
          }
  pure (probe, processor)

readSpans :: SpanProbe -> IO [SpanView]
readSpans probe = toList . (.retained) <$> readIORef probe.state
  where
    toList = Foldable.toList

spansSeen :: SpanProbe -> IO Int
spansSeen probe = (.seen) <$> readIORef probe.state

capture :: SpanProbe -> ImmutableSpan -> IO ()
capture probe spanValue = do
  hot <- readIORef spanValue.spanHot
  parent <- traverse getSpanContext spanValue.spanParent
  let view =
        SpanView
          { name = hot.hotName,
            kind = spanValue.spanKind,
            traceId = spanValue.spanContext.traceId,
            spanId = spanValue.spanContext.spanId,
            parentSpanId = (.spanId) <$> parent,
            attributes = hot.hotAttributes,
            startNs = timestampToNanoseconds spanValue.spanStart,
            endNs = maybe (timestampToNanoseconds spanValue.spanStart) timestampToNanoseconds (optionalTimestampToMaybe hot.hotEnd),
            status = hot.hotStatus
          }
  atomicModifyIORef' probe.state \current ->
    let appended = current.retained |> view
        trimmed = if Seq.length appended > probe.capacity then Seq.drop 1 appended else appended
     in (ProbeState (current.seen + 1) trimmed, ())
