module Kenshou.Cli.Attest.KeiroQueueOrdering (replayOrderingCells, recomputeQueueOrdering) where

import Control.Exception (IOException, try)
import Control.Monad (forM, unless)
import Data.Aeson (FromJSON, Value (..), eitherDecodeFileStrict', object, toJSON, withObject, (.:), (.=))
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.List (sortOn)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Kenshou.Core.Outcome (Outcome (..), outcomeExitCode)
import Kenshou.Evidence.Attest (Recomputation (..))
import Kenshou.Evidence.Source (RunResultView (..), RunSource (..))

field :: Key -> Value -> Maybe Value
field key (Object fields) = KeyMap.lookup key fields
field _ _ = Nothing

get :: (FromJSON a) => Key -> Value -> Parser a
get key = withObject "ordering observation" (.: key)

-- Return deciding contract checks and separate implementation observations.
replayOrderingCells :: Value -> Either Text ([(Text, Bool)], [(Text, Bool)])
replayOrderingCells = either (Left . Text.pack) Right . parseEither replay
  where
    replay raw = do
      schema <- get "schema" raw :: Parser Text
      mode <- get "ordering" raw :: Parser Text
      groups <- get "groups" raw :: Parser Int
      count <- get "jobsPerGroup" raw :: Parser Int
      workers <- get "workers" raw :: Parser Int
      batch <- get "batchSize" raw :: Parser Int
      killed <- get "killWorker" raw :: Parser Bool
      scheduled <- get "blockedAtKill" raw :: Parser Bool
      depth <- get "queueDepth" raw :: Parser Int
      spans <- get "spans" raw :: Parser [(Text, UTCTime, Maybe UTCTime)]
      unless (schema == "kenshou.queue-ordering-observations/v1" && mode `elem` ["fifo-heads", "unordered", "fifo-throughput", "fifo-round-robin"] && groups >= 2 && groups <= 32 && count >= 2 && count <= 50 && workers >= 2 && workers <= 8 && batch >= 1 && batch <= 32 && (mode `notElem` ["fifo-throughput", "fifo-round-robin"] || batch == 1)) (fail "invalid ordering capture parameters")
      let payload groupIndex sequenceIndex = Text.pack (show groupIndex <> ":" <> show sequenceIndex)
          finished = [(item, started, ended) | (item, started, Just ended) <- spans]
          expected = [payload groupIndex sequenceIndex | groupIndex <- [0 .. groups - 1], sequenceIndex <- [0 .. count - 1]]
          complete = sortOn id [item | (item, _, _) <- finished] == sortOn id expected && depth == 0
          groupOrdered groupIndex =
            let ordered = [rows | sequenceIndex <- [0 .. count - 1], let rows = [(started, ended) | (item, started, ended) <- finished, item == payload groupIndex sequenceIndex]]
             in case traverse singleton ordered of
                  Just ranges -> and (zipWith (\(_, earlierEnd) (laterStart, _) -> earlierEnd <= laterStart) ranges (drop 1 ranges))
                  Nothing -> False
          strict = all groupOrdered [0 .. groups - 1]
          abandoned = length [() | (item, _, Nothing) <- spans, item == "0:0"]
          otherProgress = case [ended | (item, _, ended) <- finished, item == "0:0"] of
            [headEnd] -> any (\(item, _, ended) -> item `elem` expected && not ("0:" `Text.isPrefixOf` item) && ended < headEnd) finished
            _ -> False
          contracts =
            [("schedule-realised", scheduled && (not killed || abandoned == 1)), ("all-jobs-completed", complete), ("other-groups-progress", otherProgress)]
              <> [("strict-group-order", strict) | mode == "fifo-heads"]
              <> [("unordered-control-reorders", not strict) | mode == "unordered"]
      pure (contracts, [("strict-group-order", strict) | mode /= "fifo-heads"])
    singleton [item] = Just item
    singleton _ = Nothing

recomputeQueueOrdering :: FilePath -> RunSource -> IO (Either Text Recomputation)
recomputeQueueOrdering root source = do
  spec <- readDocument (root <> "/run-spec.json")
  result <- readDocument (root <> "/run-result.json")
  captured <- readDocument (root <> "/logs/queue-ordering-observations.json")
  let names = ["schedule-realised", "all-jobs-completed", "other-groups-progress", "strict-group-order"] <> ["unordered-control-reorders" | either (const False) ((== Just (String "unordered")) . field "ordering") captured]
  verdicts <- forM names \name -> do
    value <- readDocument (root <> "/verdicts/" <> Text.unpack name <> ".json")
    pure (name, value)
  pure do
    specification <- spec
    document <- result
    raw <- captured
    unless (field "scenarioRevision" specification == Just (Number 3) && field "scenarioRevision" document == Just (Number 3)) (Left "ordering replay requires scenario revision 3")
    knobs <- maybe (Left "missing ordering knobs") Right (field "knobs" specification)
    let matches (key, knob) = field key raw == field knob knobs
        mode = field "ordering" raw
        requestedBatch = if mode `elem` [Just (String "fifo-throughput"), Just (String "fifo-round-robin")] then Just (Number 1) else field "queue.batch-size" knobs
    unless (all matches [("ordering", "queue.ordering"), ("groups", "queue.groups"), ("jobsPerGroup", "queue.jobs-per-group"), ("workers", "queue.workers"), ("killWorker", "queue.kill-worker")] && field "batchSize" raw == requestedBatch) (Left "ordering capture differs from the resolved specification")
    (contracts, observations) <- replayOrderingCells raw
    documents <- traverse (\(name, value) -> (name,) <$> value) verdicts
    let expected = [(name, held, True) | (name, held) <- contracts] <> [(name, held, False) | (name, held) <- observations]
        verdictAgrees (name, held, deciding) = case lookup name documents of
          Just saved -> field "status" saved == Just (String (if held then "held" else "violated")) && field "class" saved == Just (String (if deciding then "contract" else "implementation")) && field "blocking" saved == Just (Bool deciding)
          Nothing -> False
        failures = [label | (label, False) <- contracts]
        outcome = if null failures then Passed else Failed
        summary = object ["checks" .= (length contracts + length observations), "failures" .= failures]
        agrees = all verdictAgrees expected && field "failures" document == Just (toJSON failures) && field "blocking" document == Just (Bool (outcome == Failed)) && field "exitCode" document == Just (toJSON (outcomeExitCode outcome)) && source.result.resultKnownDefect == Nothing && (source.result.resultSummaries >>= field "verdicts" >>= field "keiro/queue/concurrency/fifo-heads-strict-order") == Just summary
    pure Recomputation {agreesWithDocuments = agrees, outcome = Just outcome, comparisonVerdict = Nothing, detail = "recomputed exact job coverage, FIFO order, competing-group progress and negative-control disposition from SQL handler spans"}

readDocument :: FilePath -> IO (Either Text Value)
readDocument path = do
  attempted <- try (eitherDecodeFileStrict' path) :: IO (Either IOException (Either String Value))
  pure $ case attempted of Left err -> Left (Text.pack (show err)); Right value -> either (Left . Text.pack) Right value
