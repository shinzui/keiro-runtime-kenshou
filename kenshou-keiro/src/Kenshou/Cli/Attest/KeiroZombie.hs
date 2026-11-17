module Kenshou.Cli.Attest.KeiroZombie (replayZombieCells, recomputeZombie) where

import Control.Exception (IOException, try)
import Control.Monad (forM, unless)
import Data.Aeson (FromJSON (..), Value (..), eitherDecodeFileStrict', object, toJSON, withObject, (.:), (.=))
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Kenshou.Core.Outcome (Outcome (..))
import Kenshou.Evidence.Attest (Recomputation (..))
import Kenshou.Evidence.Source (RunResultView (..), RunSource (..))

-- Row observations are inputs, not saved scenario verdicts. No Keiro or
-- scenario oracle is imported by this independent interpreter.
data Row = Row {outboxId :: Text, messageId :: Text, source :: Text, status :: Text, attempts :: Int, observedAt :: UTCTime}

instance FromJSON Row where
  parseJSON = withObject "outbox row snapshot" \o -> do
    row <- Row <$> o .: "outboxId" <*> o .: "messageId" <*> o .: "source" <*> o .: "status" <*> o .: "attemptCount" <*> o .: "observedAt"
    unless (row.status `elem` ["OutboxPending", "OutboxPublishing", "OutboxSent", "OutboxFailed", "OutboxRejected", "OutboxDead"] && row.attempts >= 0 && all (not . Text.null) [row.outboxId, row.messageId, row.source]) (fail "invalid outbox snapshot")
    pure row

replayZombieCells :: Value -> Either Text [(Text, Bool)]
replayZombieCells =
  either (Left . Text.pack) Right
    . parseEither
      ( withObject "zombie publisher observations" \o -> do
          schema <- o .: "schema"
          unless (schema == ("kenshou.outbox-zombie-observations/v1" :: Text)) (fail "unsupported zombie observations")
          mode <- o .: "outcome" :: Parser Text
          unless (mode `elem` ["failed", "succeeded", "dead"]) (fail "unknown stale publisher outcome")
          first <- o .: "firstClaim"
          reclaimed <- o .: "reclaimed"
          second <- o .: "secondClaim"
          stale <- o .: "afterStale"
          final <- o .: "finalRow"
          requeued <- o .: "maintenanceRequeued" :: Parser [Int]
          headers <- o .: "brokerHeaders" :: Parser [[(Text, Text)]]
          let rows = [first, reclaimed, second, stale, final] :: [Row]
          unless (all (\row -> (row.outboxId, row.messageId, row.source) == (first.outboxId, first.messageId, first.source)) rows && and (zipWith (<=) (map (.observedAt) rows) (map (.observedAt) (drop 1 rows)))) (fail "inconsistent row identity or snapshot chronology")
          unless (all (\items -> [value | ("keiro-message-id", value) <- items] == [first.messageId]) headers) (fail "broker record identity differs from the fixture row")
          pure
            [ ("schedule-realised", first.status == "OutboxPublishing" && requeued == [1] && reclaimed.status == "OutboxFailed" && second.status == "OutboxPublishing" && second.attempts == 2),
              ("stale-finalization-no-effect", stale.status == "OutboxPublishing" && stale.attempts == 2),
              ("terminal-consistent-with-success", final.status == "OutboxSent" && length headers == (if mode == "succeeded" then 2 else 1))
            ]
      )

field :: Key -> Value -> Maybe Value
field key (Object fields) = KeyMap.lookup key fields
field _ _ = Nothing

recomputeZombie :: FilePath -> RunSource -> IO (Either Text Recomputation)
recomputeZombie root source = do
  spec <- readDocument (root <> "/run-spec.json")
  result <- readDocument (root <> "/run-result.json")
  captured <- readDocument (root <> "/logs/outbox-zombie-observations.json")
  let names = ["schedule-realised", "stale-finalization-no-effect", "terminal-consistent-with-success"]
      covered = drop 1 names
  verdicts <- forM names \name -> (name,) <$> readDocument (root <> "/verdicts/" <> Text.unpack name <> ".json")
  pure do
    specification <- spec
    document <- result
    raw <- captured
    unless (field "scenarioRevision" specification == Just (Number 2) && field "scenarioRevision" document == Just (Number 2)) (Left "zombie replay requires revision 2 raw row captures")
    unless (field "outcome" raw == (field "knobs" specification >>= field "outbox.zombie-outcome")) (Left "stale outcome differs from resolved specification")
    case field "runId" document of
      Just (String runId) -> unless ((field "firstClaim" raw >>= field "source") == Just (String ("kenshou-" <> Text.take 8 runId <> "-zombie"))) (Left "row source differs from run identity")
      _ -> Left "missing run identity"
    cells <- replayZombieCells raw
    documents <- traverse (\(name, value) -> (name,) <$> value) verdicts
    arguments <- either (Left . Text.pack) Right (parseEither (withObject "invocation" (.: "argv")) =<< maybe (Left "missing invocation") Right (field "invocation" document)) :: Either Text [Text]
    let failures = [label | (label, False) <- cells]
        outcome = if null failures then Passed else Failed
        reproduced = not (null failures) && all (`elem` covered) failures
        knownStatus = if reproduced then "reproduced" else if null failures then "not-reproduced" else "different-failure"
        expectedExit = if null failures || (reproduced && "--strict-known-defects" `notElem` arguments) then 0 else 1 :: Int
        agreesCell (name, held) = case lookup name documents of
          Just saved -> field "status" saved == Just (String (if held then "held" else "violated")) && field "class" saved == Just (String (if name == "stale-finalization-no-effect" then "implementation" else "contract")) && field "blocking" saved == Just (Bool (name /= "stale-finalization-no-effect"))
          Nothing -> False
        knownAgrees = case source.result.resultKnownDefect of
          Just known -> field "reference" known == Just (String "mori://shinzui/keiro/okf/bug-reports/concepts/BUG-5") && field "expectedFailures" known == Just (toJSON covered) && field "status" known == Just (String knownStatus)
          Nothing -> False
        summary = object ["checks" .= length cells, "failures" .= failures]
        agrees = all agreesCell cells && knownAgrees && field "failures" document == Just (toJSON failures) && field "blocking" document == Just (Bool (not (null failures) && not reproduced)) && field "exitCode" document == Just (toJSON expectedExit) && (source.result.resultSummaries >>= field "verdicts" >>= field "keiro/outbox/concurrency/zombie-publisher-finalization") == Just summary
    pure Recomputation {agreesWithDocuments = agrees, outcome = Just outcome, comparisonVerdict = Nothing, detail = "recomputed the stale-publisher schedule, claim preservation and final state from ordered row snapshots, maintenance returns and broker headers"}

readDocument :: FilePath -> IO (Either Text Value)
readDocument path = do
  attempted <- try (eitherDecodeFileStrict' path) :: IO (Either IOException (Either String Value))
  pure $ case attempted of Left err -> Left (Text.pack (show err)); Right value -> either (Left . Text.pack) Right value
