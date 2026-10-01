module Kenshou.Suite.Keiro.Inbox.Oracle (receiptStatement, expectedReceipt, receiptsMatch, richEvent, expectedKey) where

import Data.Aeson (Value, object, (.=))
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.UUID qualified as UUID
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement qualified as Statement
import Keiro.Inbox (KafkaDeliveryRef (..))
import Keiro.Integration.Event (IntegrationEvent (..), SchemaReference (..), TraceContext (..), contentTypeText)
import Kiroku.Store.Types (EventId (..), GlobalPosition (..))
import Numeric (showHex)

-- Read physical columns, including SQL NULLs hidden by the runtime decoder.
receiptStatement :: Statement.Statement Text [Value]
receiptStatement =
  Statement.preparable
    "SELECT (to_jsonb(r) - 'payload_bytes' - 'occurred_at' - 'received_at' - 'completed_at' - 'failed_at' - 'last_error') || jsonb_build_object('payload_hex', encode(payload_bytes, 'hex'), 'occurred_micros', round(extract(epoch FROM occurred_at) * 1000000)::bigint, 'completed', completed_at IS NOT NULL, 'failed', failed_at IS NOT NULL, 'has_error', coalesce(length(last_error) > 0, false)) FROM keiro.keiro_inbox r WHERE source = $1 ORDER BY dedupe_key"
    (E.param (E.nonNullable E.text))
    (D.rowList (D.column (D.nonNullable D.jsonb)))

richEvent :: Int -> IntegrationEvent -> IntegrationEvent
richEvent index event =
  event
    { sourceEventId = if odd index then Just (EventId (UUID.fromWords 0 0 0 (fromIntegral index))) else Nothing,
      sourceGlobalPosition = Just (GlobalPosition (fromIntegral (1000 + index))),
      schemaVersion = 7,
      schemaReference = Just (SchemaReference (Just "kenshou-registry") (Just "inbox-probe") (Just 3) (Just 42) (Just "probe-fingerprint")),
      causationId = Just (EventId (UUID.fromWords 0 1 0 (fromIntegral index))),
      correlationId = Just (EventId (UUID.fromWords 0 2 0 (fromIntegral index))),
      traceContext = Just (TraceContext "00-12345678901234567890123456789012-1234567890123456-01" (Just "kenshou=probe"))
    }

-- The expected key is derived without calling the runtime's dedupe function.
expectedKey :: Text -> IntegrationEvent -> KafkaDeliveryRef -> Text
expectedKey policy event kafka = case policy of
  "message-id" -> event.messageId
  "source-event" -> case (event.sourceEventId, event.sourceGlobalPosition) of
    (Just (EventId uuid), _) -> UUID.toText uuid
    (_, Just (GlobalPosition position)) -> Text.pack (show position)
    _ -> error "source identity fixture is incomplete"
  "kafka-delivery" -> kafka.topic <> ":" <> Text.pack (show kafka.partition) <> ":" <> Text.pack (show kafka.offset)
  "custom" -> TextEncoding.decodeUtf8 event.payloadBytes
  _ -> error "unknown inbox matrix policy"

-- Failed receipts retain the full envelope even in dedupe-only mode.
expectedReceipt :: Bool -> Bool -> Text -> IntegrationEvent -> KafkaDeliveryRef -> Value
expectedReceipt dedupeOnly failed key event kafka =
  let retain = not dedupeOnly || failed
      envelope :: Maybe a -> Maybe a
      envelope value = if retain then value else Nothing
      ref = event.schemaReference
      trace = event.traceContext
      eventId (EventId uuid) = UUID.toText uuid
      position (GlobalPosition n) = n
      hexByte byte = let digits = showHex byte "" in if length digits == 1 then '0' : digits else digits
   in object
        [ "source" .= event.source,
          "dedupe_key" .= key,
          "message_id" .= event.messageId,
          "source_event_id" .= fmap eventId event.sourceEventId,
          "source_global_position" .= fmap position event.sourceGlobalPosition,
          "destination" .= event.destination,
          "event_type" .= event.eventType,
          "schema_version" .= envelope (Just event.schemaVersion),
          "content_type" .= contentTypeText event.contentType,
          "schema_registry" .= envelope (ref >>= (.registry)),
          "schema_subject" .= envelope (ref >>= (.subject)),
          "schema_version_ref" .= envelope (ref >>= (.version)),
          "schema_id" .= envelope (ref >>= (.schemaId)),
          "schema_fingerprint" .= envelope (ref >>= (.fingerprint)),
          "causation_id" .= fmap eventId event.causationId,
          "correlation_id" .= fmap eventId event.correlationId,
          "traceparent" .= envelope (fmap (.traceparent) trace),
          "tracestate" .= envelope (trace >>= (.tracestate)),
          "kafka_topic" .= kafka.topic,
          "kafka_partition" .= kafka.partition,
          "kafka_offset" .= kafka.offset,
          "payload_hex" .= (if retain then Text.pack (concatMap hexByte (ByteString.unpack event.payloadBytes)) else ""),
          "attributes" .= envelope event.attributes,
          "occurred_micros" .= (round (utcTimeToPOSIXSeconds event.occurredAt * 1000000) :: Integer),
          "status" .= (if failed then "failed" else "completed" :: Text),
          "attempt_count" .= (if failed then 1 else 0 :: Int),
          "completed" .= not failed,
          "failed" .= failed,
          "has_error" .= failed
        ]

-- Require exactly one physical row per expected receipt, never a vacuous pass.
receiptsMatch :: [Value] -> [Value] -> Bool
receiptsMatch expected observed =
  not (null expected)
    && length expected == length observed
    && all (\row -> length (filter (== row) observed) == 1 && length (filter (== row) expected) == 1) expected
