module Kenshou.Suite.Keiro.Inbox.Observation (delivery, result, decodedReceipt) where

import Data.Aeson (Value, object, (.=))
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.UUID qualified as UUID
import Keiro.Inbox (InboxError (..), InboxResult (..), InboxRow (..), KafkaDeliveryRef (..))
import Keiro.Integration.Event (IntegrationEvent (..), SchemaReference (..), TraceContext (..), contentTypeText)
import Kiroku.Store.Types (EventId (..), GlobalPosition (..))

-- Capture arguments and constructors, without computing an expected verdict.
delivery :: IntegrationEvent -> Maybe KafkaDeliveryRef -> Value
delivery event kafka =
  object
    [ "messageId" .= event.messageId,
      "source" .= event.source,
      "destination" .= event.destination,
      "eventType" .= event.eventType,
      "schemaVersion" .= event.schemaVersion,
      "contentType" .= contentTypeText event.contentType,
      "schemaReference" .= fmap schema event.schemaReference,
      "sourceEventId" .= fmap eventId event.sourceEventId,
      "sourceGlobalPosition" .= fmap (\(GlobalPosition position) -> position) event.sourceGlobalPosition,
      "payloadBytes" .= ByteString.unpack event.payloadBytes,
      "occurredAt" .= event.occurredAt,
      "causationId" .= fmap eventId event.causationId,
      "correlationId" .= fmap eventId event.correlationId,
      "traceContext" .= fmap trace event.traceContext,
      "attributes" .= event.attributes,
      "kafka" .= fmap coordinate kafka
    ]
  where
    eventId (EventId uuid) = UUID.toText uuid
    schema ref = object ["registry" .= ref.registry, "subject" .= ref.subject, "version" .= ref.version, "id" .= ref.schemaId, "fingerprint" .= ref.fingerprint]
    trace context = object ["parent" .= context.traceparent, "state" .= context.tracestate]
    coordinate ref = object ["topic" .= ref.topic, "partition" .= ref.partition, "offset" .= ref.offset]

result :: Either InboxError (InboxResult a) -> Value
result = \case
  Left (DedupePolicyUnsatisfied _) -> tagged "policy-unsatisfied" []
  Right (InboxProcessed _) -> tagged "processed" []
  Right InboxDuplicate -> tagged "duplicate" []
  Right InboxInProgress -> tagged "in-progress" []
  Right (InboxPreviouslyFailed message) -> tagged "previously-failed" ["error" .= message]
  Right (InboxHandlerFailed message attempt) -> tagged "handler-failed" ["error" .= message, "attempt" .= attempt]
  where
    tagged tag fields = object (("tag" .= (tag :: Text)) : fields)

decodedReceipt :: InboxRow -> Value
decodedReceipt row = object ["key" .= row.dedupeKey, "status" .= show row.status]
