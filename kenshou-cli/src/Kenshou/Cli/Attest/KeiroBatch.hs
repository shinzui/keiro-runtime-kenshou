module Kenshou.Cli.Attest.KeiroBatch (replayBatchCells, recomputeBatch) where

import Control.Exception (IOException, try)
import Control.Monad (unless)
import Data.Aeson (FromJSON, Value (..), eitherDecodeFileStrict', object, toJSON, withObject, (.:), (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Outcome (Outcome (..), outcomeExitCode)
import Kenshou.Evidence.Attest (Recomputation (..))
import Kenshou.Evidence.Source (RunResultView (..), RunSource (..))
import System.FilePath ((</>))

-- Replay only raw batch arguments, returned constructors, invocation traces
-- and database observations. No scenario or runtime oracle is imported.
replayBatchCells :: Text -> Text -> Value -> Either Text [(Text, Bool)]
replayBatchCells mode failure raw = either (Left . Text.pack) Right $ parseEither (const replay) Null
  where
    replay = do
      unless (mode `elem` ["inbox-table", "delegated"] && failure `elem` ["pure-exception", "condemn"]) (fail "unsupported batch workload")
      schema <- get "schema" raw
      actualMode <- get "idempotence" raw
      actualFailure <- get "failureMode" raw
      unless (schema == ("kenshou.inbox-batch-observations/v1" :: Text) && actualMode == mode && actualFailure == failure) (fail "batch observation schema or workload differs")
      batches <- get "batches" raw :: Parser [[Value]]
      ids <- traverse (traverse (get "messageId")) batches :: Parser [[Text]]
      sources <- traverse (get "source") (concat batches) :: Parser [Text]
      let expected = if mode == "delegated" then [["clean", "clean", "poison", "poison", "tail"], ["clean"]] else [["clean-a", "clean-b", "clean-a"], ["good-c", "poison", "good-d"]]
      unless (ids == expected) (fail "batch replay requires the complete positional workload")
      case sources of
        source : rest -> unless (not (Text.null source) && all (== source) rest) (fail "batch inputs have inconsistent sources")
        [] -> fail "missing batch source"
      rows <- get "rows" raw :: Parser [Value]
      rowIds <- traverse (get "messageId") rows :: Parser [Text]
      statuses <- traverse (get "status") rows :: Parser [Text]
      attempts <- traverse (get "attemptCount") rows :: Parser [Integer]
      rowSources <- traverse (get "source") rows :: Parser [Text]
      unless (all (`elem` sources) rowSources) (fail "batch receipt source differs from the workload")
      observed <- get "observations" raw
      first <- get "firstResults" observed :: Parser [Value]
      second <- get "secondResults" observed :: Parser [Value]
      let tagged tag = object ["tag" .= (tag :: Text)]
          processed = tagged "processed"
          duplicate = tagged "duplicate"
          failed value = field "tag" value == Just (String "handler-failed") && field "attempt" value == Just (Number 1)
      if mode == "delegated"
        then do
          afterBatch <- get "callsAfterBatch" observed :: Parser [Text]
          afterNext <- get "callsAfterNext" observed :: Parser [Text]
          pure
            [ ("delegated-batch-positional", case first of [a, b, c, d, e] -> [a, b, d, e] == [processed, duplicate, processed, processed] && failed c; _ -> False),
              ("delegated-batch-retries-failed-key", afterBatch == ["clean", "poison", "poison", "tail"]),
              ("delegated-batch-memory-is-call-local", second == [processed] && afterNext == ["clean", "poison", "poison", "tail", "clean"]),
              ("delegated-batch-skips-inbox-table", null rows)
            ]
        else do
          initial <- get "initialCalls" observed :: Parser Integer
          initialHandlers <- get "initialHandlerCalls" observed :: Parser Integer
          cleanHandlers <- get "cleanHandlerCalls" observed :: Parser Integer
          transactions <- get "cleanTransactionCount" observed :: Parser Integer
          calls <- get "poisonCalls" observed :: Parser Integer
          effects <- get "effects" observed :: Parser [Text]
          let poison = [(status, attempt) | (message, status, attempt) <- zip3 rowIds statuses attempts, message == "poison"]
              condemning = failure == "condemn"
              fallback = if condemning then second == replicate 3 processed else case second of [a, b, c] -> a == processed && failed b && c == processed; _ -> False
          pure
            [ ("handler-count-starts-at-zero", initial == 0 && initialHandlers == 0),
              ("clean-batch-skips-duplicate-handler", cleanHandlers == 2),
              ("clean-batch-positional", first == [processed, processed, duplicate]),
              ("clean-batch-one-transaction", transactions == 1),
              ("fallback-isolates-poison", fallback),
              ("effects-once", sort effects == ["clean-a", "clean-b", "good-c", "good-d"]),
              ("poison-receipt", if condemning then null poison && calls == 2 else poison == [("InboxFailed", 1)])
            ]

get :: (FromJSON a) => Key.Key -> Value -> Parser a
get key = withObject "batch observation" (.: key)

field :: Text -> Value -> Maybe Value
field key (Object fields) = KeyMap.lookup (Key.fromText key) fields
field _ _ = Nothing

recomputeBatch :: FilePath -> RunSource -> IO (Either Text Recomputation)
recomputeBatch root source = do
  spec <- readDocument (root </> "run-spec.json")
  result <- readDocument (root </> "run-result.json")
  captured <- readDocument (root </> "logs/inbox-batch-observations.json")
  pure do
    specification <- spec
    document <- result
    observed <- captured
    unless (field "scenarioRevision" document == Just (Number 3)) (Left "batch replay requires scenario revision 3")
    knobs <- maybe (Left "missing batch knobs") Right (field "knobs" specification)
    mode <- either (Left . Text.pack) Right (parseEither (get "inbox.idempotence") knobs)
    failure <- either (Left . Text.pack) Right (parseEither (get "inbox.failure-mode") knobs)
    cells <- replayBatchCells mode failure observed
    let failures = [label | (label, False) <- cells]
        outcome = if null failures then Passed else Failed
        summary = object ["checks" .= length cells, "failures" .= failures]
        agrees =
          field "failures" document == Just (toJSON failures)
            && field "blocking" document == Just (Bool (outcome == Failed))
            && field "exitCode" document == Just (toJSON (outcomeExitCode outcome))
            && source.result.resultKnownDefect == Nothing
            && (source.result.resultSummaries >>= field "verdicts" >>= field "keiro/inbox/correctness/batch-fast-path-and-fallback") == Just summary
    pure Recomputation {agreesWithDocuments = agrees, outcome = Just outcome, comparisonVerdict = Nothing, detail = "recomputed batch checks from positional intake constructors, handler traces and durable effects/receipts"}

readDocument :: FilePath -> IO (Either Text Value)
readDocument path = do
  attempted <- try (eitherDecodeFileStrict' path) :: IO (Either IOException (Either String Value))
  pure $ case attempted of
    Left err -> Left (Text.pack (show err))
    Right value -> either (Left . Text.pack) Right value
