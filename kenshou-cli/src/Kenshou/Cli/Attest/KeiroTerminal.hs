module Kenshou.Cli.Attest.KeiroTerminal (replayTerminalCells, recomputeTerminal) where

import Control.Exception (IOException, try)
import Control.Monad (unless)
import Data.Aeson (FromJSON (..), Value (..), eitherDecodeFileStrict', object, toJSON, withObject, (.:), (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.Bits (xor)
import Data.List (sort, sortOn)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, diffUTCTime)
import Data.Word (Word64)
import Kenshou.Core.Outcome (Outcome (..), outcomeExitCode)
import Kenshou.Evidence.Attest (Recomputation (..))
import Kenshou.Evidence.Source (RunResultView (..), RunSource (..))
import System.FilePath ((</>))

data Row = Row
  { ident :: Text,
    message :: Text,
    source :: Text,
    key :: Maybe Text,
    status :: Text,
    attempts :: Int,
    rejectedAt :: Maybe UTCTime,
    rejectionCode :: Maybe Text,
    lastError :: Maybe Text
  }

instance FromJSON Row where
  parseJSON = withObject "outbox row" \o -> Row <$> o .: "outboxId" <*> o .: "messageId" <*> o .: "source" <*> o .: "key" <*> o .: "status" <*> o .: "attemptCount" <*> o .: "rejectedAt" <*> o .: "rejectionCode" <*> o .: "lastError"

data Callback = Callback
  { started :: UTCTime,
    ended :: UTCTime,
    rows :: [Row],
    outcomes :: Map.Map Text Text
  }

instance FromJSON Callback where
  parseJSON = withObject "outbox callback" \o -> do
    started <- o .: "started"
    ended <- o .: "ended"
    rows <- o .: "claimed"
    values <- o .: "outcomes" :: Parser [Value]
    pairs <- traverse (\value -> (,) <$> get "outboxId" value <*> (get "outcome" value >>= get "tag")) values
    unless (ended >= started && length pairs == Map.size (Map.fromList pairs)) (fail "invalid callback interval or duplicate outcome")
    unless (all ((`elem` ["succeeded", "failed", "rejected"]) . snd) pairs) (fail "unknown callback outcome")
    pure Callback {started, ended, rows, outcomes = Map.fromList pairs}

data Summary = Summary {claimed :: Int, published :: Int, rejected :: Int, retried :: Int, dead :: Int}

instance FromJSON Summary where
  parseJSON = withObject "publisher summary" \o -> Summary <$> o .: "claimed" <*> o .: "published" <*> o .: "rejected" <*> o .: "retried" <*> o .: "dead"

-- This module deliberately imports neither Keiro nor the scenario/broker oracle.
-- The fault-plan hash is reconstructed from the sealed seed and workload knobs.
replayTerminalCells :: Word64 -> Value -> Value -> Either Text [(Text, Bool)]
replayTerminalCells seed knobs raw = either (Left . Text.pack) Right $ parseEither (const replay) Null
  where
    replay = do
      schema <- get "schema" raw
      unless (schema == ("kenshou.outbox-terminal-observations/v1" :: Text)) (fail "unsupported terminal observations")
      count <- get "outbox.rows" knobs
      keys <- get "outbox.key-cardinality" knobs
      maxAttempts <- get "outbox.max-attempts" knobs
      policy <- get "outbox.ordering-policy" knobs
      backoff <- get "outbox.backoff" knobs :: Parser Text
      base <- get "outbox.backoff-seconds" knobs :: Parser Double
      cap <- get "outbox.backoff-max-seconds" knobs :: Parser Double
      multiplier <- get "outbox.backoff-multiplier" knobs :: Parser Double
      poison <- get "broker.poison-ratio" knobs :: Parser Double
      reject <- get "broker.reject-ratio" knobs :: Parser Double
      transient <- get "broker.fail-ratio" knobs :: Parser Double
      throws <- get "broker.throw-ratio" knobs :: Parser Double
      drops <- get "broker.drop-outcome-ratio" knobs :: Parser Double
      unless (policy `elem` ["best-effort", "per-source-stream", "stop-the-line", "per-key-head-of-line"] && backoff `elem` ["constant", "exponential"] && throws == 0 && drops == 0) (fail "unsupported terminal policy or fault plan")
      inputs <- get "inputs" raw :: Parser [Row]
      rows <- get "rows" raw :: Parser [Row]
      callbacks <- get "callbacks" raw :: Parser [Callback]
      headers <- get "brokerHeaders" raw :: Parser [[(Text, Text)]]
      summaries <- get "summaries" raw :: Parser (Maybe [Summary])
      let byId = Map.fromList [(row.ident, row) | row <- inputs]
          sameIdentity row = maybe False (\input -> (input.message, input.source, input.key) == (row.message, row.source, row.key)) (Map.lookup row.ident byId)
          expectedInputs = [(Text.pack (show i), if keys == 0 then Nothing else Just ("key-" <> Text.pack (show (i `mod` keys)))) | i <- [1 .. count :: Int]]
      unless (count > 0 && keys >= 0 && maxAttempts > 0 && length inputs == Map.size byId && sort [(row.message, row.key) | row <- inputs] == sort expectedInputs) (fail "incomplete or altered terminal input workload")
      unless (all (\row -> row.status == "OutboxPending" && row.attempts == 0) inputs && Set.size (Set.fromList (map (.source) inputs)) == 1) (fail "terminal input rows are not fresh from one source")
      unless (all sameIdentity (rows <> concatMap (.rows) callbacks)) (fail "observed row identity differs from terminal inputs")
      let brokerCounts = Map.fromListWith (+) [(value, 1 :: Int) | record <- headers, (name, value) <- record, name == "keiro-message-id"]
          statusMatches row
            | draw row.message "1" < poison = row.status == "OutboxDead" && row.attempts == maxAttempts
            | draw row.message "4" < reject = row.status == "OutboxRejected"
            | maxAttempts == 1 && draw row.message "(1,2)" < transient = row.status == "OutboxDead" && row.attempts == 1
            | otherwise = row.status == "OutboxSent"
          wireMatches row = case row.status of
            "OutboxSent" -> Map.member row.message brokerCounts
            "OutboxRejected" -> Map.notMember row.message brokerCounts
            "OutboxDead" -> Map.notMember row.message brokerCounts
            _ -> False
          rejectionMatches row = if row.status == "OutboxRejected" then row.rejectedAt /= Nothing && row.rejectionCode == Just "synthetic_rejection" else row.rejectedAt == Nothing && row.rejectionCode == Nothing
          deadMatches row =
            let expectedError = if draw row.message "1" >= poison && maxAttempts == 1 && draw row.message "(1,2)" < transient then "synthetic transient failure" else "synthetic permanent failure"
             in row.status /= "OutboxDead" || (row.attempts == maxAttempts && row.lastError == Just expectedError)
          effective = concatMap (effectiveRows policy) callbacks
          effectiveCounts = Map.fromListWith (+) [(row.ident, 1 :: Int) | (row, _, _, _) <- effective]
          attemptGroups = Map.fromListWith (<>) [(row.ident, [(row.attempts, started, ended, outcome)]) | (row, started, ended, outcome) <- effective]
          delay number = realToFrac (if backoff == "constant" then base else min cap (base * multiplier ** fromIntegral (max 0 (number - 1))))
          waits attempts = let ordered = sortOn (\(number, _, _, _) -> number) attempts in and (zipWith (\(number, _, ended, outcome) (_, nextStarted, _, _) -> outcome == "failed" && diffUTCTime nextStarted ended >= delay number) ordered (drop 1 ordered))
          statusCount status = length [() | row <- rows, row.status == status]
          total accessor = fmap (sum . map accessor) summaries
      pure
        [ ("drained-before-deadline", maybe False (const True) summaries),
          ("every-row-terminal", length rows == count && Set.fromList (map (.ident) rows) == Map.keysSet byId && all statusMatches rows),
          ("broker-matches-terminal-status", all wireMatches rows),
          ("one-broker-record-per-sent-row", length headers == statusCount "OutboxSent" && all (== 1) (Map.elems brokerCounts)),
          ("rejection-metadata", all rejectionMatches rows),
          ("poison-attempt-ceiling", all deadMatches rows),
          ("attempt-count-matches-callbacks", all (\row -> row.attempts == Map.findWithDefault 0 row.ident effectiveCounts) rows),
          ("backoff-respected", all waits (Map.elems attemptGroups)),
          ("retried-count-matches-attempts-and-skips", case (total (.retried), total (.claimed)) of (Just retried, Just claimed) -> retried == sum [row.attempts - 1 | row <- rows] + claimed - length effective; _ -> False),
          ("published-count-matches-summaries", total (.published) == Just (statusCount "OutboxSent")),
          ("rejected-count-matches-summaries", total (.rejected) == Just (statusCount "OutboxRejected")),
          ("dead-count-matches-summaries", total (.dead) == Just (statusCount "OutboxDead"))
        ]
    draw message salt = fromIntegral (foldl' mix seed (Text.unpack message <> salt) `mod` 1000000) / 1000000
    mix value char = (value `xor` fromIntegral (fromEnum char)) * 1099511628211

effectiveRows :: Text -> Callback -> [(Row, UTCTime, UTCTime, Text)]
effectiveRows policy callback = reverse accepted
  where
    (_, accepted) = foldl' step (Set.empty, []) callback.rows
    step (blocked, prior) row =
      let group = case policy of
            "best-effort" -> Left row.ident
            "per-source-stream" -> Right (row.source, Nothing)
            "stop-the-line" -> Right ("", Nothing)
            _ -> maybe (Left row.ident) (\key -> Right (row.source, Just key)) row.key
          outcome = Map.findWithDefault "failed" row.ident callback.outcomes
       in if Set.member group blocked then (blocked, prior) else (if outcome == "failed" then Set.insert group blocked else blocked, (row, callback.started, callback.ended, outcome) : prior)

get :: (FromJSON a) => Key.Key -> Value -> Parser a
get key = withObject "terminal observation" (.: key)

field :: Text -> Value -> Maybe Value
field key (Object fields) = KeyMap.lookup (Key.fromText key) fields
field _ _ = Nothing

recomputeTerminal :: FilePath -> RunSource -> IO (Either Text Recomputation)
recomputeTerminal root source = do
  spec <- readDocument (root </> "run-spec.json")
  result <- readDocument (root </> "run-result.json")
  captured <- readDocument (root </> "logs/outbox-terminal-observations.json")
  pure do
    specification <- spec
    document <- result
    observed <- captured
    unless (field "scenarioRevision" document == Just (Number 3) && field "scenarioRevision" specification == Just (Number 3)) (Left "terminal replay requires scenario revision 3")
    knobs <- maybe (Left "missing terminal knobs") Right (field "knobs" specification)
    seed <- either (Left . Text.pack) Right (parseEither (get "seed") specification)
    cells <- replayTerminalCells seed knobs observed
    let failures = [label | (label, False) <- cells]
        outcome = if null failures then Passed else Failed
        summary = object ["checks" .= length cells, "failures" .= failures]
        agrees =
          field "failures" document == Just (toJSON failures)
            && field "blocking" document == Just (Bool (outcome == Failed))
            && field "exitCode" document == Just (toJSON (outcomeExitCode outcome))
            && source.result.resultKnownDefect == Nothing
            && (source.result.resultSummaries >>= field "verdicts" >>= field "keiro/outbox/correctness/terminal-state-matrix") == Just summary
    pure Recomputation {agreesWithDocuments = agrees, outcome = Just outcome, comparisonVerdict = Nothing, detail = "recomputed twelve terminal checks from raw inputs, callback attempts/times, broker headers, final rows and publisher summaries"}

readDocument :: FilePath -> IO (Either Text Value)
readDocument path = do
  attempted <- try (eitherDecodeFileStrict' path) :: IO (Either IOException (Either String Value))
  pure $ case attempted of
    Left err -> Left (Text.pack (show err))
    Right value -> either (Left . Text.pack) Right value
