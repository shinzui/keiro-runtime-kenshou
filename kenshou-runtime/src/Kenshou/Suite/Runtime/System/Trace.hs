module Kenshou.Suite.Runtime.System.Trace
  ( Signals (..),
    TraceSabotage (..),
    noSignals,
    draftTraceContext,
    commandOptions,
    workflowRunOptions,
    currentTraceContext,
    withEventTrace,
    withStoredTrace,
    withRootSpan,
  )
where

import Control.Exception (bracket)
import Control.Monad.IO.Unlift (MonadIO, MonadUnliftIO, withRunInIO)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding
import Keiro.Command (RunCommandOptions, defaultRunCommandOptions)
import Keiro.Command qualified as Command
import Keiro.Integration.Event (TraceContext (..))
import Keiro.Telemetry (KeiroMetrics, traceContextFromCurrentSpan)
import Keiro.Workflow (WorkflowRunOptions, defaultWorkflowRunOptions)
import Keiro.Workflow qualified as Workflow
import Kiroku.Otel.TraceContext (extractTraceContext)
import Kiroku.Store.Types (RecordedEvent (..))
import OpenTelemetry.Context (insertSpan)
import OpenTelemetry.Context.ThreadLocal (attachContext, detachContext, getContext)
import OpenTelemetry.Propagator.W3CTraceContext (decodeSpanContext)
import OpenTelemetry.Trace.Core (SpanContext, Tracer, TracerProvider, defaultSpanArguments, inSpan, wrapSpanContext)

-- The released runtime carries a trace across Kafka (record headers into
-- the shibuya consumer span) and across PGMQ (enqueueTraced headers into the
-- worker span), but not across the event store, the outbox row, or a
-- workflow resume. The reference system carries it the way an application
-- must: the current span's W3C context goes into the metadata of every event
-- it appends (the shape kiroku-otel reads back), into the outbox draft, and
-- into a journaled workflow step.

-- | The telemetry a role passes to the runtime components it runs. Every
-- field is empty when both telemetry dimensions are @off@.
data Signals = Signals
  { tracer :: !(Maybe Tracer),
    provider :: !(Maybe TracerProvider),
    metrics :: !(Maybe KeiroMetrics),
    sabotage :: !TraceSabotage,
    -- | Record that a delivery on a hop was handled: the hop name and the
    -- delivery's identity. Invariant I5 counts repeated identities.
    observe :: Text -> Text -> IO ()
  }

-- | Sabotage controls for trace continuity only: each removes one link that
-- an application must provide, so I7 must fail.
data TraceSabotage
  = NoTraceSabotage
  | -- | Outbox drafts carry no trace context.
    UntracedOutbox
  | -- | The publisher sends the stored trace headers through an untraced
    -- producer, so no @send <topic>@ span parents the consumer.
    UntracedProducer
  deriving stock (Eq, Show)

noSignals :: Signals
noSignals = Signals Nothing Nothing Nothing NoTraceSabotage (\_ _ -> pure ())

-- | The trace context an outbox draft carries: the one recorded with the
-- source event. Keiro's producer identity includes the trace class
-- (keiro ADR-42), so a redelivered handler must enqueue exactly the same
-- context; the span of the current delivery attempt would differ on every
-- redelivery and turn a replay into an identity conflict.
draftTraceContext :: Signals -> RecordedEvent -> Maybe TraceContext
draftTraceContext signals event
  | signals.sabotage == UntracedOutbox = Nothing
  | otherwise = case event.metadata of
      Just (Object fields) -> case (KeyMap.lookup "traceparent" fields, KeyMap.lookup "tracestate" fields) of
        (Just (String parent), state) -> Just (TraceContext parent (case state of Just (String value) -> Just value; _ -> Nothing))
        _ -> Nothing
      _ -> Nothing

-- | Command options with the role's tracer and metrics. With a tracer, the
-- current span's context is stored in the metadata of every appended event,
-- so the subscriber that handles the event can continue the trace.
commandOptions :: (MonadIO m) => Signals -> m RunCommandOptions
commandOptions signals = case signals.tracer of
  Nothing -> pure defaultRunCommandOptions {Command.metrics = signals.metrics}
  Just active -> do
    context <- currentTraceContext
    pure defaultRunCommandOptions {Command.tracer = Just active, Command.metrics = signals.metrics, Command.metadata = fmap traceMetadata context}

workflowRunOptions :: Signals -> WorkflowRunOptions
workflowRunOptions signals = defaultWorkflowRunOptions {Workflow.tracer = signals.tracer}

-- | The active span's context, or nothing outside a span.
currentTraceContext :: (MonadIO m) => m (Maybe TraceContext)
currentTraceContext = traceContextFromCurrentSpan

traceMetadata :: TraceContext -> Value
traceMetadata context = object (["traceparent" .= context.traceparent] <> maybe [] (\state -> ["tracestate" .= state]) context.tracestate)

-- | Run an action in a span that continues the trace recorded in an event's
-- metadata; a root span when the event carries none.
withEventTrace :: (MonadUnliftIO m) => Signals -> Text -> RecordedEvent -> m a -> m a
withEventTrace signals name event action = case signals.tracer of
  Nothing -> action
  Just active -> withParent (extractTraceContext event) (inSpan active name defaultSpanArguments action)

-- | Run an action with a stored trace context as its parent, so spans it
-- opens join that trace.
withStoredTrace :: (MonadUnliftIO m) => Signals -> Maybe TraceContext -> m a -> m a
withStoredTrace signals stored action = case signals.tracer of
  Nothing -> action
  Just _ -> withParent (stored >>= decode) action
  where
    decode context = decodeSpanContext (Just (TextEncoding.encodeUtf8 context.traceparent)) (TextEncoding.encodeUtf8 <$> context.tracestate)

-- | A span with no parent, such as one business request.
withRootSpan :: (MonadUnliftIO m) => Signals -> Text -> m a -> m a
withRootSpan signals name action = maybe action (\active -> inSpan active name defaultSpanArguments action) signals.tracer

withParent :: (MonadUnliftIO m) => Maybe SpanContext -> m a -> m a
withParent Nothing action = action
withParent (Just parent) action = withRunInIO \run -> do
  context <- getContext
  bracket (attachContext (insertSpan (wrapSpanContext parent) context)) detachContext (const (run action))
