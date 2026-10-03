module Kenshou.Cli.Attest.KeiroProducerIdentity (producerIdentityV1, replayProducerIdentityCells, recomputeProducerIdentity) where

import Control.Exception (IOException, try)
import Control.Monad (forM, unless)
import Data.Aeson (FromJSON, Value (..), eitherDecodeFileStrict', object, toJSON, withObject, (.:), (.=))
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.Bits ((.&.), (.|.))
import Data.ByteString qualified as ByteString
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as Lazy
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.UUID qualified as UUID
import Data.Word (Word32)
import Kenshou.Core.Canonical (sha256Hex)
import Kenshou.Core.Outcome (Outcome (..), outcomeExitCode)
import Kenshou.Evidence.Attest (Recomputation (..))
import Kenshou.Evidence.Source (RunResultView (..), RunSource (..))
import Numeric (readHex)

field :: Key -> Value -> Maybe Value
field key (Object fields) = KeyMap.lookup key fields
field _ _ = Nothing

get :: (FromJSON a) => Key -> Value -> Parser a
get key = withObject "producer identity observation" (.: key)

-- Reconstruct the frozen wire tuple without calling the producer implementation.
producerIdentityV1 :: Text -> Text -> Text -> UUID.UUID -> Word32 -> Value
producerIdentityV1 source producer namespace event index =
  let framed bytes = Builder.word64BE (fromIntegral (ByteString.length bytes)) <> Builder.byteString bytes
      (a, b, c, d) = UUID.toWords event
      bytes = Lazy.toStrict (Builder.toLazyByteString (framed "keiro.producer.outbox" <> Builder.word64BE 2 <> Builder.word16BE 1 <> framed (Text.encodeUtf8 source) <> framed (Text.encodeUtf8 producer) <> Builder.word64BE 16 <> foldMap Builder.word32BE [a, b, c, d] <> Builder.word64BE 4 <> Builder.word32BE index))
      digest = Text.drop 7 (sha256Hex bytes)
      word offset = case readHex (Text.unpack (Text.take 8 (Text.drop offset digest))) of [(value, "")] -> value; _ -> error "SHA-256 emitted invalid hex"
      uuid = UUID.fromWords (word 0) ((word 8 .&. 0xffff0fff) .|. 0x8000) ((word 16 .&. 0x3fffffff) .|. 0x80000000) (word 24)
   in object ["outboxId" .= UUID.toText uuid, "messageId" .= (namespace <> "_v1_" <> digest), "version" .= (1 :: Int)]

replayProducerIdentityCells :: Value -> Either Text [(Text, Bool)]
replayProducerIdentityCells = either (Left . Text.pack) Right . parseEither replay
  where
    replay raw = do
      schema <- get "schema" raw :: Parser Text
      source <- get "source" raw
      producer <- get "producerName" raw
      namespace <- get "namespace" raw
      event <- get "sourceEventId" raw :: Parser Text
      index <- get "emissionIndex" raw :: Parser Word32
      changedNamespace <- get "changedNamespace" raw
      unless (schema == "kenshou.outbox-producer-identity/v1" && not (Text.null source) && producer == "probe" && namespace == "kenshou" && event == UUID.toText UUID.nil && index == 0 && changedNamespace == "other") (fail "invalid producer identity fixture parameters")
      before <- get "before" raw :: Parser [Value]
      duplicate <- get "afterDuplicate" raw :: Parser [Value]
      afterConflicts <- get "afterConflicts" raw :: Parser [Value]
      finalRows <- get "finalRows" raw :: Parser [Value]
      conflicts <- get "conflicts" raw :: Parser [Value]
      observedConflicts <- traverse (\entry -> (,,) <$> get "field" entry <*> get "outcome" entry <*> get "rows" entry) conflicts :: Parser [(Text, Value, [Value])]
      let identity = producerIdentityV1 source producer namespace UUID.nil index
          changed = producerIdentityV1 source producer changedNamespace UUID.nil index
          outcome kind expected fields value = field "type" value == Just (String kind) && field "identity" value == Just expected && field "fields" value == Just (toJSON fields)
          check name kind expected fields = maybe False (outcome kind expected fields) (field name raw)
          same rows = length before == 1 && before == rows
          classes = ["RoutingField", "SchemaField", "PayloadField", "OccurredAtField", "CausalField", "TraceField", "AttributesField", "ProvenanceField"] :: [Text]
          stored = case before of [row] -> field "outbox_id" row == field "outboxId" identity && field "message_id" row == field "messageId" identity && field "source" row == Just (String source); _ -> False
          frozen = object ["outboxId" .= ("61dd62b4-bbfe-81ce-9634-6ce6afd48517" :: Text), "messageId" .= ("msg_v1_61dd62b4bbfef1ce56346ce6afd485172774bc060102e5cf455e39bd0edfa84b" :: Text), "version" .= (1 :: Int)]
      pure [("deterministic-identity", check "first" "inserted" identity ([] :: [Text]) && stored), ("adr-42-frozen-vector", field "frozenIdentity" raw == Just frozen), ("identical-replay-no-mutation", check "identical" "duplicate" identity ([] :: [Text]) && same duplicate), ("one-field-conflicts", sort [label | (label, _, _) <- observedConflicts] == sort classes && all (\(label, actual, _) -> outcome "conflict" identity [label] actual) observedConflicts), ("namespace-change-is-identity-conflict", check "identityConflict" "conflict" changed (["IdentityField"] :: [Text]) && field "outboxId" identity == field "outboxId" changed), ("conflicts-do-not-mutate", same afterConflicts && all (\(_, _, rows) -> same rows) observedConflicts), ("microsecond-equivalence", check "submicrosecond" "duplicate" identity ([] :: [Text])), ("attribute-key-order-equivalence", check "reordered" "duplicate" identity ([] :: [Text])), ("equivalent-replays-do-not-mutate", same finalRows)]

recomputeProducerIdentity :: FilePath -> RunSource -> IO (Either Text Recomputation)
recomputeProducerIdentity root source = do
  spec <- readDocument (root <> "/run-spec.json")
  result <- readDocument (root <> "/run-result.json")
  captured <- readDocument (root <> "/logs/outbox-producer-identity.json")
  checked <- case captured >>= replayProducerIdentityCells of
    Left err -> pure (Left err)
    Right cells -> do
      documents <- forM cells \(name, _) -> do
        value <- readDocument (root <> "/verdicts/keiro-fixture-" <> Text.unpack name <> ".json")
        pure ((name,) <$> value)
      pure ((cells,) <$> sequence documents)
  pure do
    specification <- spec
    document <- result
    raw <- captured
    unless (field "scenarioRevision" document == Just (Number 2) && field "scenarioRevision" specification == Just (Number 2)) (Left "producer identity replay requires revision 2")
    case field "runId" document of
      Just (String runId) -> unless (field "source" raw == Just (String ("kenshou-" <> Text.take 8 runId <> "-producer-id"))) (Left "producer source differs from run identity")
      _ -> Left "missing run identity"
    (cells, verdicts) <- checked
    let failures = [label | (label, False) <- cells]
        outcome = if null failures then Passed else Failed
        agreesCell (name, held) = case lookup name verdicts of Just saved -> field "status" saved == Just (String (if held then "held" else "violated")) && field "class" saved == Just (String "contract") && field "blocking" saved == Just (Bool True); Nothing -> False
        summary = object ["checks" .= length cells, "failures" .= failures]
        agrees = all agreesCell cells && field "failures" document == Just (toJSON failures) && field "blocking" document == Just (Bool (outcome == Failed)) && field "exitCode" document == Just (toJSON (outcomeExitCode outcome)) && source.result.resultKnownDefect == Nothing && (source.result.resultSummaries >>= field "verdicts" >>= field "keiro/outbox/correctness/producer-identity") == Just summary
    pure Recomputation {agreesWithDocuments = agrees, outcome = Just outcome, comparisonVerdict = Nothing, detail = "recomputed frozen producer identities, exact conflict classes and retained SQL row equality"}

readDocument :: FilePath -> IO (Either Text Value)
readDocument path = do
  attempted <- try (eitherDecodeFileStrict' path) :: IO (Either IOException (Either String Value))
  pure $ case attempted of Left err -> Left (Text.pack (show err)); Right value -> either (Left . Text.pack) Right value
