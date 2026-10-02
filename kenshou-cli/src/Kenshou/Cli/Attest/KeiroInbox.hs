module Kenshou.Cli.Attest.KeiroInbox (replayInboxCells, recomputeInbox) where

import Control.Exception (IOException, try)
import Control.Monad (unless)
import Data.Aeson (FromJSON, Object, Value (..), eitherDecodeFileStrict', object, toJSON, withObject, (.:), (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString qualified as ByteString
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Word (Word8)
import Kenshou.Core.Outcome (Outcome (..), outcomeExitCode)
import Kenshou.Evidence.Attest (Recomputation (..))
import Kenshou.Evidence.Source (RunResultView (..), RunSource (..))
import Numeric (showHex)
import System.FilePath ((</>))

-- This module deliberately imports neither the runtime nor the scenario oracle.
-- Expected receipts are reconstructed from captured arguments, never from the
-- diagnostic expectedSuccessRows/expectedFailedRow in the SQL observation file.
replayInboxCells :: Text -> Text -> Value -> Value -> Either Text [(Text, Bool)]
replayInboxCells policy persistence rawIntake rawSql = parse $ do
  unless (policy `elem` ["message-id", "source-event", "kafka-delivery", "custom"]) (fail "unsupported inbox policy")
  unless (persistence `elem` ["full-envelope", "dedupe-only"]) (fail "unsupported inbox persistence")
  intake <- asObject rawIntake
  sql <- asObject rawSql
  expectSchema intake "kenshou.inbox-matrix-intake/v1"
  expectSchema sql "kenshou.inbox-matrix-sql/v1"
  inputs <- intake .: "firstInputs"
  republished <- intake .: "republishInputs"
  failedInput <- intake .: "failedInput"
  malformed <- intake .: "missingInput"
  ids <- traverse (get "messageId") inputs :: Parser [Text]
  unless (sort ids == sort [Text.pack (show n) | n <- [1 .. 16 :: Int]]) (fail "inbox replay requires the complete sixteen-message workload")
  let coordinate :: Int -> Value
      coordinate n = object ["topic" .= ("kenshou.matrix" :: Text), "partition" .= (0 :: Int), "offset" .= n]
      replace key value (Object fields) = Object (KeyMap.insert key value fields)
      replace _ _ value = value
      republish index messageId value = replace "kafka" (coordinate (index + 16)) (replace "messageId" (String (messageId <> "-republished")) value)
  coordinates <- traverse (get "kafka") inputs :: Parser [Value]
  unless (coordinates == map coordinate [1 .. 16 :: Int] && republished == zipWith3 republish [1 .. 16] ids inputs) (fail "captured inbox delivery schedule differs from revision 3")
  firstInput <- case inputs of
    firstInput : _ -> pure firstInput
    [] -> fail "missing inbox inputs"
  source <- get "source" firstInput :: Parser Text
  sources <- traverse (get "source") inputs :: Parser [Text]
  let expectedMissing = case policy of
        "source-event" -> replace "messageId" (String "malformed") (replace "sourceEventId" Null (replace "sourceGlobalPosition" Null firstInput))
        "custom" -> replace "messageId" (String "malformed") (replace "payloadBytes" (toJSON ([] :: [Word8])) firstInput)
        _ -> replace "messageId" (String "") firstInput
      missingKafka = if policy == "kafka-delivery" then Null else coordinate (100 :: Int)
  unless (all (== source) sources && malformed == replace "kafka" missingKafka expectedMissing) (fail "malformed delivery input differs from the scheduled probe")
  unless (failedInput == replace "kafka" (coordinate (101 :: Int)) (replace "source" (String (source <> "-failed")) firstInput)) (fail "failed receipt input differs from the scheduled probe")
  let doubled = policy `elem` ["message-id", "kafka-delivery"]
      accepted = inputs <> if doubled then republished else []
  expected <- traverse (receipt policy (persistence == "dedupe-only") False) accepted
  expectedFailure <- receipt policy False True failedInput
  keys <- traverse (dedupeKey policy) accepted
  messageIds <- traverse (get "messageId") accepted :: Parser [Text]
  first <- intake .: "firstResults" :: Parser [Value]
  second <- intake .: "secondResults" :: Parser [Value]
  again <- intake .: "republishResults" :: Parser [Value]
  missing <- intake .: "missingResult"
  failures <- intake .: "failedResults" :: Parser [Value]
  decoded <- intake .: "decodedRows" :: Parser [Value]
  decodedKeys <- traverse (get "key") decoded :: Parser [Text]
  decodedStatuses <- traverse (get "status") decoded :: Parser [Text]
  observed <- sql .: "successRows"
  failedRows <- sql .: "failedRows"
  retained <- sql .: "retainedFailedRows"
  effects <- sql .: "effects" :: Parser [Text]
  afterFailure <- sql .: "effectsAfterFailure" :: Parser [Text]
  let tagged name = object ["tag" .= (name :: Text)]
      invalidIdentity = either (const True) (const False) (parseEither (dedupeKey policy) malformed)
      ceilingHeld = case failures of
        [one, two] -> field "tag" one == Just (String "handler-failed") && field "attempt" one == Just (Number 1) && field "tag" two == Just (String "previously-failed")
        _ -> False
  pure
    [ ("first-delivery-processed", first == replicate 16 (tagged "processed")),
      ("redelivery-duplicate", second == replicate 16 (tagged "duplicate")),
      ("republish-policy", again == replicate 16 (tagged (if doubled then "processed" else "duplicate"))),
      ("effect-count-by-policy", sort effects == sort messageIds),
      ("one-completed-row-per-key", sort decodedKeys == sort keys && all (== "InboxCompleted") decodedStatuses),
      ("missing-policy-field-fails-closed", invalidIdentity && missing == tagged "policy-unsatisfied"),
      ("persistence-shape", sameRows expected observed),
      ("failed-receipt-retains-envelope", sameRows [expectedFailure] failedRows),
      ("failed-handler-rolls-back-effect", sort effects == sort afterFailure),
      ("failed-receipt-ceiling", ceilingHeld),
      ("failed-receipt-survives-gc", sameRows [expectedFailure] retained)
    ]

receipt :: Text -> Bool -> Bool -> Value -> Parser Value
receipt policy dedupeOnly failed input = do
  event <- asObject input
  key <- dedupeKey policy input
  payload <- event .: "payloadBytes" :: Parser [Word8]
  occurred <- event .: "occurredAt" :: Parser UTCTime
  kafka <- event .: "kafka" >>= asObject
  schema <- event .: "schemaReference"
  trace <- event .: "traceContext"
  let envelope value = if dedupeOnly then Null else value
      schemaField name = nested name schema >>= pure . envelope
      traceField name = nested name trace >>= pure . envelope
      copy target name = (Key.fromText target,) <$> (event .: Key.fromText name :: Parser Value)
      hex byte = let digits = showHex byte "" in if length digits == 1 then '0' : digits else digits
  identities <-
    traverse
      (uncurry copy)
      [ ("source", "source"),
        ("message_id", "messageId"),
        ("source_event_id", "sourceEventId"),
        ("source_global_position", "sourceGlobalPosition"),
        ("destination", "destination"),
        ("event_type", "eventType"),
        ("content_type", "contentType"),
        ("causation_id", "causationId"),
        ("correlation_id", "correlationId")
      ]
  version <- envelope <$> (event .: "schemaVersion")
  attributes <- envelope <$> (event .: "attributes")
  registry <- schemaField "registry"
  subject <- schemaField "subject"
  schemaVersion <- schemaField "version"
  schemaId <- schemaField "id"
  fingerprint <- schemaField "fingerprint"
  parent <- traceField "parent"
  state <- traceField "state"
  topic <- kafka .: "topic" :: Parser Text
  partition <- kafka .: "partition" :: Parser Integer
  offset <- kafka .: "offset" :: Parser Integer
  pure $
    Object $
      KeyMap.fromList identities
        <> KeyMap.fromList
          [ "dedupe_key" .= key,
            "schema_version" .= version,
            "attributes" .= attributes,
            "schema_registry" .= registry,
            "schema_subject" .= subject,
            "schema_version_ref" .= schemaVersion,
            "schema_id" .= schemaId,
            "schema_fingerprint" .= fingerprint,
            "traceparent" .= parent,
            "tracestate" .= state,
            "kafka_topic" .= topic,
            "kafka_partition" .= partition,
            "kafka_offset" .= offset,
            "payload_hex" .= (if dedupeOnly then "" else Text.pack (concatMap hex payload)),
            "occurred_micros" .= (round (utcTimeToPOSIXSeconds occurred * 1000000) :: Integer),
            "status" .= (if failed then "failed" else "completed" :: Text),
            "attempt_count" .= (if failed then 1 else 0 :: Int),
            "completed" .= not failed,
            "failed" .= failed,
            "has_error" .= failed
          ]

dedupeKey :: Text -> Value -> Parser Text
dedupeKey policy input = do
  event <- asObject input
  key <- case policy of
    "message-id" -> event .: "messageId"
    "source-event" -> do
      uuid <- event .: "sourceEventId" :: Parser (Maybe Text)
      position <- event .: "sourceGlobalPosition" :: Parser (Maybe Integer)
      maybe (maybe (fail "missing source identity") (pure . Text.pack . show) position) pure uuid
    "kafka-delivery" -> do
      kafka <- event .: "kafka" >>= asObject
      topic <- kafka .: "topic"
      partition <- kafka .: "partition" :: Parser Integer
      offset <- kafka .: "offset" :: Parser Integer
      pure (topic <> ":" <> Text.pack (show partition) <> ":" <> Text.pack (show offset))
    "custom" -> do
      bytes <- event .: "payloadBytes" :: Parser [Word8]
      either (fail . show) pure (TextEncoding.decodeUtf8' (ByteString.pack bytes))
    _ -> fail "unsupported inbox policy"
  if Text.null key then fail "empty inbox key" else pure key

sameRows :: [Value] -> [Value] -> Bool
sameRows expected actual = not (null expected) && length expected == length actual && all (\row -> length (filter (== row) actual) == 1 && length (filter (== row) expected) == 1) expected

asObject :: Value -> Parser Object
asObject = withObject "observation" pure

get :: (FromJSON a) => Key.Key -> Value -> Parser a
get key = withObject "observation" (.: key)

nested :: Key.Key -> Value -> Parser Value
nested _ Null = pure Null
nested key value = get key value

expectSchema :: Object -> Text -> Parser ()
expectSchema value expected = do
  actual <- value .: "schema"
  unless (actual == expected) (fail "unsupported inbox observation schema")

parse :: Parser a -> Either Text a
parse parser = either (Left . Text.pack) Right (parseEither (const parser) Null)

field :: Text -> Value -> Maybe Value
field name (Object value) = KeyMap.lookup (Key.fromText name) value
field _ _ = Nothing

recomputeInbox :: FilePath -> RunSource -> IO (Either Text Recomputation)
recomputeInbox root source = do
  intake <- readDocument (root </> "logs/inbox-matrix-intake.json")
  sql <- readDocument (root </> "logs/inbox-matrix-sql.json")
  spec <- readDocument (root </> "run-spec.json")
  result <- readDocument (root </> "run-result.json")
  pure do
    captured <- intake
    observed <- sql
    specification <- spec
    document <- result
    -- Revision 4 strengthens only delegated intake; the table-backed workload
    -- and captured observations remain identical to revision 3.
    unless (field "scenarioRevision" document `elem` [Just (Number 3), Just (Number 4)]) (Left "inbox replay supports only scenario revisions 3 and 4")
    knobs <- maybe (Left "missing inbox knobs") Right (field "knobs" specification)
    mode <- either (Left . Text.pack) Right (parseEither (get "inbox.idempotence") knobs)
    unless (mode == ("inbox-table" :: Text)) (Left "delegated inbox replay is unavailable")
    policy <- either (Left . Text.pack) Right (parseEither (get "inbox.dedupe-policy") knobs)
    persistence <- either (Left . Text.pack) Right (parseEither (get "inbox.persistence") knobs)
    cells <- replayInboxCells policy persistence captured observed
    let failures = [label | (label, False) <- cells]
        outcome = if null failures then Passed else Failed
        summary = object ["checks" .= length cells, "failures" .= failures]
        agrees =
          field "failures" document == Just (toJSON failures)
            && field "blocking" document == Just (Bool (outcome == Failed))
            && field "exitCode" document == Just (toJSON (outcomeExitCode outcome))
            && source.result.resultKnownDefect == Nothing
            && (source.result.resultSummaries >>= field "verdicts" >>= field "keiro/inbox/correctness/effectively-once-matrix") == Just summary
    pure Recomputation {agreesWithDocuments = agrees, outcome = Just outcome, comparisonVerdict = Nothing, detail = "recomputed eleven inbox checks from captured intake arguments, result constructors, SQL receipts and durable effects"}

readDocument :: FilePath -> IO (Either Text Value)
readDocument path = do
  attempted <- try (eitherDecodeFileStrict' path) :: IO (Either IOException (Either String Value))
  pure $ case attempted of
    Left err -> Left (Text.pack (show err))
    Right value -> either (Left . Text.pack) Right value
