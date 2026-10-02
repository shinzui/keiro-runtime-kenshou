module Kenshou.Cli.Attest.KeiroQueueOutcomes (replayQueueOutcomeCells, recomputeQueueOutcomes) where

import Control.Exception (IOException, try)
import Control.Monad (unless)
import Data.Aeson (FromJSON (..), Value (..), eitherDecodeFileStrict', object, toJSON, withObject, (.:), (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither, parseMaybe)
import Data.Int (Int64)
import Data.List (nub, sortOn)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Kenshou.Cli.Attest.KeiroQueueWorkers (replayWorkerOutcomes)
import Kenshou.Core.Outcome (Outcome (..), outcomeExitCode)
import Kenshou.Evidence.Attest (Recomputation (..))
import Kenshou.Evidence.Source (RunResultView (..), RunSource (..))
import System.FilePath ((</>))

field :: Key.Key -> Value -> Maybe Value
field key (Object fields) = KeyMap.lookup key fields
field _ _ = Nothing

get :: (FromJSON a) => Key.Key -> Value -> Parser a
get key = withObject "queue observation" (.: key)

require :: [Key.Key] -> Value -> Parser ()
require keys = withObject "complete queue observations" \fields -> unless (all (`KeyMap.member` fields) keys) (fail "missing queue observation")

expectedHeaders :: Value
expectedHeaders = object ["probe" .= ("preserved" :: Text), "nested" .= object ["value" .= (1 :: Int)]]

timestamp :: Key.Key -> Value -> Maybe UTCTime
timestamp key value = field key value >>= parseMaybe parseJSON

dlqPreserves :: Text -> Int64 -> [Value] -> [Value] -> Bool
dlqPreserves payload identifier raw decoded = case (raw, decoded) of
  ([body], [entry]) ->
    field "original_message" body == Just (String payload)
      && field "original_message_id" body == Just (toJSON identifier)
      && field "original_headers" body == Just expectedHeaders
      && field "read_count" body == Just (Number 1)
      && timestamp "original_enqueued_at" body /= Nothing
      && timestamp "original_enqueued_at" body == timestamp "enqueuedAt" entry
      && field "payload" entry == Just (String payload)
      && field "messageId" entry == Just (toJSON identifier)
      && field "headers" entry == Just expectedHeaders
      && field "readCount" entry == Just (Number 1)
      && field "reason" entry == field "dead_letter_reason" body
      && case field "dead_letter_reason" body of Just (String reason) -> Text.isPrefixOf "poison_pill" reason; _ -> False
  _ -> False

-- Reconstruct the contract from observations without importing the scenario,
-- its oracles, or Keiro. Expected inputs and labels are fixed by revision 4.
replayQueueOutcomeCells :: Value -> Value -> Value -> Either Text [(Text, Bool)]
replayQueueOutcomeCells raw physical workers = do
  primary <- either (Left . Text.pack) Right (parseEither (const replay) Null)
  boundary <- replayWorkerOutcomes workers
  pure (primary <> boundary)
  where
    replay = do
      schema <- get "schema" raw
      physicalSchema <- get "schema" physical
      unless (schema == ("kenshou.queue-job-observations/v1" :: Text) && physicalSchema == ("kenshou.queue-physical-outcomes/v1" :: Text)) (fail "unsupported queue outcome observations")
      require ["done", "retryHandled", "retryAttempts", "delayHandled", "dead", "defaultHandled", "defaultAttempts", "archive", "batchDepth", "groupHeaderCount", "thrownHandled", "thrownDepth", "malformed", "futureHandled", "futureDepth", "futureReadCounts", "workerDoneCompleted", "workerDoneRows", "workerRetryRows", "workerDeadRows", "workerThrowRows"] raw
      require ["batchPayloads", "archivePayload", "archiveRows", "deadPayload", "deadContextHeaders", "workerDeadPayload", "workerContext", "malformedHandlerCalls", "futureHandlerCalls"] physical
      headers <- get "sentHeaders" physical
      unless (headers == expectedHeaders && field "batchPayloads" physical == Just (toJSON (["one", "two", "three"] :: [Text])) && field "archivePayload" physical == Just (String "archive") && field "deadPayload" physical == Just (String "dead") && field "workerDeadPayload" physical == Just (String "worker-dead")) (fail "altered queue fixture inputs")
      batchIds <- get "batchReturnedIds" physical :: Parser [Int64]
      batchRows <- get "batchRows" physical :: Parser [(Int64, Value, Maybe Value, Int64)]
      archiveId <- get "archiveReturnedId" physical :: Parser Int64
      deadId <- get "deadReturnedId" physical :: Parser Int64
      workerDeadId <- get "workerDeadReturnedId" physical :: Parser (Maybe Int64)
      deadEntries <- get "drainDeadEntries" physical
      workerDeadEntries <- get "workerDeadEntries" physical
      drainDecoded <- get "drainDecodedDlq" raw
      workerDecoded <- get "workerDecodedDlq" raw
      deadLetter <- get "deadLetter" raw :: Parser (Int64, Text)
      malformedDead <- get "malformedDead" raw :: Parser (Int64, Text)
      groupRows <- get "groupRows" raw :: Parser [(Int64, Value, Maybe Value, Int64)]
      [doneEffects, retryEffects, deadEffects, throwEffects] <- get "workerEffects" raw :: Parser [Int64]
      retryTerminal <- get "workerRetry" raw >>= get "terminal" :: Parser (Maybe (Int64, (Int64, Text)))
      deadTerminal <- get "workerDead" raw >>= get "terminal" :: Parser (Maybe (Int64, (Int64, Text)))
      throwTerminal <- get "workerThrow" raw >>= get "terminal" :: Parser (Maybe (Int64, (Int64, Text)))
      let equals key value = field key raw == Just value
          physicalEquals key value = field key physical == Just value
          numbers = toJSON :: [Int64] -> Value
          empty = toJSON ([] :: [Value])
          sorted = sortOn (\(identifier, _, _, _) -> identifier)
          expectedBatch = [(identifier, String payload, Nothing, 0) | (identifier, payload) <- zip batchIds ["one", "two", "three"]]
          archive = toJSON [(archiveId, String "archive", Just expectedHeaders, 1 :: Int64)]
          poison (count, reason) = count == 1 && Text.isPrefixOf "poison_pill" reason
      pure
        [ ("done-deletes", equals "done" (numbers [1, 0])),
          ("retry-delay-and-attempt", equals "retryHandled" (numbers [1, 0, 1]) && equals "retryAttempts" (numbers [0, 1])),
          ("enqueue-delay", equals "delayHandled" (numbers [0, 1])),
          ("dead-letter", equals "dead" (numbers [1, 0]) && poison deadLetter),
          ("default-retry-delay", equals "defaultHandled" (numbers [1, 0, 1]) && equals "defaultAttempts" (numbers [0, 1])),
          ("archive-when-dlq-disabled", equals "archive" (numbers [1, 0, 1])),
          ("batch-ids-and-rows", length batchIds == 3 && length (nub batchIds) == 3 && equals "batchDepth" (Number 3)),
          ("batch-id-order-and-payloads", length batchIds == 3 && length (nub batchIds) == 3 && sorted batchRows == sorted expectedBatch),
          ("drain-context-preserves-headers", physicalEquals "deadContextHeaders" (toJSON [expectedHeaders])),
          ("drain-dead-wrapper", dlqPreserves "dead" deadId deadEntries drainDecoded),
          ("archive-preserves-message", physicalEquals "archiveRows" archive),
          ("malformed-skips-handler", physicalEquals "malformedHandlerCalls" (Number 0)),
          ("future-skips-handler", physicalEquals "futureHandlerCalls" (Number 0)),
          ("group-header", equals "groupHeaderCount" (Number 1) && length [() | (_, _, Just header, _) <- groupRows, field "x-pgmq-group" header == Just (String "alpha")] == 1),
          ("drain-handler-exception", equals "thrownHandled" (numbers [0, 0, 1]) && equals "thrownDepth" (Number 1)),
          ("malformed-payload", equals "malformed" (numbers [1, 0]) && fst malformedDead == 1 && Text.isPrefixOf "invalid_payload" (snd malformedDead)),
          ("future-payload-retries", equals "futureHandled" (numbers [1, 0, 1]) && equals "futureDepth" (Number 1) && equals "futureReadCounts" (numbers [1, 2])),
          ("worker-done-and-context", equals "workerDoneCompleted" (Bool True) && physicalEquals "workerContext" (object ["attempt" .= (0 :: Int), "headers" .= Null]) && equals "workerDoneRows" empty && doneEffects == 1),
          ("worker-retry", equals "workerRetryRows" empty && retryEffects == 2 && maybe False ((== 2) . fst) retryTerminal),
          ("worker-dead-letter", equals "workerDeadRows" empty && deadEffects == 1 && maybe False (\(effects, placement) -> effects == 1 && poison placement) deadTerminal),
          ("worker-dead-wrapper", maybe False (\identifier -> dlqPreserves "worker-dead" identifier workerDeadEntries workerDecoded) workerDeadId),
          ("worker-handler-exception-redelivery", equals "workerThrowRows" empty && throwEffects == 2 && maybe False ((== 2) . fst) throwTerminal)
        ]

recomputeQueueOutcomes :: FilePath -> RunSource -> IO (Either Text Recomputation)
recomputeQueueOutcomes root source = do
  spec <- readDocument (root </> "run-spec.json")
  result <- readDocument (root </> "run-result.json")
  job <- readDocument (root </> "logs/queue-job-observations.json")
  physical <- readDocument (root </> "logs/queue-physical-outcomes.json")
  workers <- readDocument (root </> "logs/queue-worker-outcomes.json")
  pure do
    specification <- spec
    document <- result
    unless (field "scenarioRevision" document == Just (Number 4) && field "scenarioRevision" specification == Just (Number 4)) (Left "queue outcome replay requires scenario revision 4")
    observed <- job
    placed <- physical
    boundaries <- workers
    cells <- replayQueueOutcomeCells observed placed boundaries
    let failures = [label | (label, False) <- cells]
        outcome = if null failures then Passed else Failed
        summary = object ["checks" .= length cells, "failures" .= failures]
        agrees = field "failures" document == Just (toJSON failures) && field "blocking" document == Just (Bool (outcome == Failed)) && field "exitCode" document == Just (toJSON (outcomeExitCode outcome)) && source.result.resultKnownDefect == Nothing && (source.result.resultSummaries >>= field "verdicts" >>= field "keiro/queue/correctness/job-outcome-semantics") == Just summary
    pure Recomputation {agreesWithDocuments = agrees, outcome = Just outcome, comparisonVerdict = Nothing, detail = "recomputed all forty-three queue outcome checks from API observations, handler facts, SQL rows, decoded/raw DLQ entries and worker boundaries"}

readDocument :: FilePath -> IO (Either Text Value)
readDocument path = do
  attempted <- try (eitherDecodeFileStrict' path) :: IO (Either IOException (Either String Value))
  pure $ case attempted of Left err -> Left (Text.pack (show err)); Right value -> either (Left . Text.pack) Right value
