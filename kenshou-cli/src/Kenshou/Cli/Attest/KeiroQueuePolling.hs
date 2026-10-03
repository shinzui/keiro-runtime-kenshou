module Kenshou.Cli.Attest.KeiroQueuePolling (replayPollingCells, recomputeQueuePolling) where

import Control.Exception (IOException, try)
import Control.Monad (forM, unless)
import Data.Aeson (FromJSON, Value (..), eitherDecodeFileStrict', object, toJSON, withObject, (.:), (.=))
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, diffUTCTime)
import Kenshou.Core.Outcome (Outcome (..), outcomeExitCode)
import Kenshou.Evidence.Attest (Recomputation (..))
import Kenshou.Evidence.Source (RunResultView (..), RunSource (..))

field :: Key -> Value -> Maybe Value
field key (Object fields) = KeyMap.lookup key fields
field _ _ = Nothing

get :: (FromJSON a) => Key -> Value -> Parser a
get key = withObject "polling observation" (.: key)

replayPollingCells :: Value -> Either Text [(Text, Bool)]
replayPollingCells = either (Left . Text.pack) Right . parseEither replay
  where
    replay raw = do
      schema <- get "schema" raw :: Parser Text
      fault <- get "fault" raw :: Parser Text
      outage <- get "outageSeconds" raw :: Parser Double
      count <- get "faultCount" raw :: Parser Int
      polling <- get "polling" raw :: Parser Text
      supervision <- get "supervision" raw :: Parser Text
      warmup <- get "warmupCompletedAt" raw :: Parser (Maybe UTCTime)
      phases <- get "faults" raw :: Parser [Value]
      effects <- get "effects" raw :: Parser [Text]
      depth <- get "queueDepth" raw :: Parser Int
      ended <- get "appExitedAtEnd" raw :: Parser Bool
      unless (schema == "kenshou.queue-polling-observations/v1" && fault `elem` ["backend-kill", "proxy-reset", "postmaster-restart"] && count >= 1 && count <= 5 && length phases <= count && outage `elem` [0, 10] && (fault == "postmaster-restart" || outage == 0) && polling `elem` ["poll-every", "long-poll"] && supervision `elem` ["stop-all-on-failure", "ignore-failures"]) (fail "invalid polling capture parameters")
      starts <- traverse (get "startedAt") phases :: Parser [UTCTime]
      facts <- traverse (uncurry (phase (outage >= 10))) (zip [1 ..] phases)
      let expected = expectedPayloads (length phases)
          injected = length [() | (True, _) <- facts]
      pure [("faults-injected", length facts == count && injected == count), ("processing-resumed", maybe False (\stamp -> all (>= stamp) starts) warmup && length facts == count && all snd facts && not ended), ("no-loss", Set.fromList effects == Set.fromList expected && depth == 0), ("bounded-duplicates", length effects - Set.size (Set.fromList effects) <= injected)]
    expectedPayloads batch = [Text.pack (show index) | index <- [1 .. (batch + 1) * 20 :: Int]]
    phase expectExit index raw = do
      batch <- get "batch" raw :: Parser Int
      victim <- get "victimPid" raw :: Parser (Maybe Int)
      query <- get "victimQuery" raw :: Parser (Maybe Text)
      wait <- get "victimWait" raw :: Parser (Maybe Text)
      injected <- get "injected" raw :: Parser Bool
      started <- get "startedAt" raw :: Parser UTCTime
      healed <- get "healedAt" raw :: Parser UTCTime
      recovered <- get "recoveredAt" raw :: Parser (Maybe UTCTime)
      effects <- get "effectsAfter" raw :: Parser [Text]
      ended <- get "appExited" raw :: Parser Bool
      restarted <- get "restarted" raw :: Parser Bool
      running <- get "stillRunning" raw :: Parser Bool
      let schedule = batch == index && injected && maybe False (> 0) victim && maybe False (Text.isInfixOf "pgmq.read") query && wait == Just "Lock"
          timely = healed >= started && maybe False (\stamp -> stamp >= healed && diffUTCTime stamp healed <= 5) recovered
          coverage = Set.fromList (expectedPayloads index) == Set.fromList effects
          lifecycle = if expectExit then ended && restarted else not ended && not restarted
      pure (schedule, batch == index && timely && coverage && lifecycle && running)

recomputeQueuePolling :: FilePath -> RunSource -> IO (Either Text Recomputation)
recomputeQueuePolling root source = do
  spec <- readDocument (root <> "/run-spec.json")
  result <- readDocument (root <> "/run-result.json")
  captured <- readDocument (root <> "/logs/queue-polling-observations.json")
  verdicts <- forM ["faults-injected", "processing-resumed", "no-loss", "bounded-duplicates"] \name -> do
    value <- readDocument (root <> "/verdicts/" <> Text.unpack name <> ".json")
    pure (name, value)
  pure do
    specification <- spec
    document <- result
    raw <- captured
    unless (field "scenarioRevision" specification == Just (Number 3) && field "scenarioRevision" document == Just (Number 3)) (Left "polling replay requires scenario revision 3")
    knobs <- maybe (Left "missing polling knobs") Right (field "knobs" specification)
    unless (all (\(key, knob) -> field key raw == field knob knobs) [("fault", "queue.fault"), ("outageSeconds", "queue.outage-seconds"), ("faultCount", "queue.fault-count"), ("polling", "queue.polling"), ("supervision", "queue.supervision")]) (Left "polling capture differs from resolved specification")
    cells <- replayPollingCells raw
    documents <- traverse (\(name, value) -> (name,) <$> value) verdicts
    let verdictAgrees (name, held) = case lookup name documents of
          Just saved -> field "status" saved == Just (String (if held then "held" else "violated")) && field "class" saved == Just (String "contract") && field "blocking" saved == Just (Bool True)
          Nothing -> False
        failures = [label | (label, False) <- cells]
        outcome = if null failures then Passed else Failed
        summary = object ["checks" .= length cells, "failures" .= failures]
        agrees = all verdictAgrees cells && field "failures" document == Just (toJSON failures) && field "blocking" document == Just (Bool (outcome == Failed)) && field "exitCode" document == Just (toJSON (outcomeExitCode outcome)) && source.result.resultKnownDefect == Nothing && (source.result.resultSummaries >>= field "verdicts" >>= field "keiro/queue/concurrency/workers-survive-transient-polling-error") == Just summary
    pure Recomputation {agreesWithDocuments = agrees, outcome = Just outcome, comparisonVerdict = Nothing, detail = "recomputed post-fault batch coverage, bounded recovery, app lifecycle and final queue coverage from polling observations"}

readDocument :: FilePath -> IO (Either Text Value)
readDocument path = do
  attempted <- try (eitherDecodeFileStrict' path) :: IO (Either IOException (Either String Value))
  pure $ case attempted of Left err -> Left (Text.pack (show err)); Right value -> either (Left . Text.pack) Right value
