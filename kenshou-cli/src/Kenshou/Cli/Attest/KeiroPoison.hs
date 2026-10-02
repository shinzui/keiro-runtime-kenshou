module Kenshou.Cli.Attest.KeiroPoison (replayPoisonCells, recomputePoison) where

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

-- Raw handler checkpoints, constructors and durable receipt/effect observations
-- are separate from the scenario's verdicts. No runtime or scenario oracle is
-- imported into this verifier.
replayPoisonCells :: Text -> Text -> Value -> Either Text [(Text, Bool)]
replayPoisonCells mode failure raw = either (Left . Text.pack) Right $ parseEither (const replay) Null
  where
    replay = do
      unless (mode `elem` ["inbox-table", "delegated"] && failure `elem` ["pure-exception", "condemn", "sql-error"]) (fail "unsupported poison workload")
      schema <- get "schema" raw
      actualMode <- get "idempotence" raw
      actualFailure <- get "failureMode" raw
      unless (schema == ("kenshou.inbox-poison-observations/v1" :: Text) && actualMode == mode && actualFailure == failure) (fail "poison observation schema or workload differs")
      inputs <- get "inputs" raw :: Parser [Value]
      ids <- traverse (get "messageId") inputs :: Parser [Text]
      sources <- traverse (get "source") inputs :: Parser [Text]
      let expectedInputs = if mode == "inbox-table" && failure == "pure-exception" then ["poison", "recovery"] else ["poison"]
      unless (sort ids == expectedInputs) (fail "poison replay requires the complete scheduled workload")
      case sources of
        source : rest -> unless (not (Text.null source) && all (== source) rest) (fail "poison inputs have inconsistent sources")
        [] -> fail "missing poison source"
      rows <- get "rows" raw :: Parser [Value]
      observed <- get "observations" raw
      -- Read every receipt field needed by the checks; a malformed observation
      -- must not masquerade as an absent matching receipt.
      rowIds <- traverse (get "messageId") rows :: Parser [Text]
      statuses <- traverse (get "status") rows :: Parser [Text]
      attempts <- traverse (get "attemptCount") rows :: Parser [Integer]
      rowSources <- traverse (get "source") rows :: Parser [Text]
      unless (all (`elem` sources) rowSources) (fail "poison receipt source differs from the workload")
      let receipts = zip3 rowIds statuses attempts
          poisonRows = [(status, attempt) | (message, status, attempt) <- receipts, message == "poison"]
          recoveryRows = [() | (message, _, _) <- receipts, message == "recovery"]
          tagged tag = object ["tag" .= (tag :: Text)]
          count key = get key observed :: Parser Integer
      if mode == "delegated"
        then do
          scheduled <- get "attempts" observed :: Parser [Integer]
          unless (scheduled == [4, 3]) (fail "delegated retry schedule differs from revision 3")
          above <- get "aboveCeiling" observed
          within <- get "withinCeiling" observed
          afterCeiling <- count "callsAfterCeiling"
          afterAttempt <- count "callsAfterAttempt"
          pure
            [ ("delegated-ceiling-stops-handler", above == object ["tag" .= ("previously-failed" :: Text), "error" .= Null] && afterCeiling == 0),
              ("delegated-within-ceiling-runs-handler", within == tagged "processed" && afterAttempt == 1),
              ("delegated-retry-has-no-inbox-row", null rows)
            ]
        else do
          initial <- count "initialCalls"
          let initialCell = ("handler-count-starts-at-zero", initial == 0)
          if failure == "pure-exception"
            then do
              poisonCalls <- count "poisonCalls"
              failedCalls <- count "failedRecoveryCalls"
              recoveredCalls <- count "recoveredCalls"
              duplicateCalls <- count "duplicateCalls"
              poisonEffects <- get "poisonEffects" observed :: Parser [Text]
              failedEffects <- get "failedRecoveryEffects" observed :: Parser [Text]
              recoveredEffects <- get "recoveredEffects" observed :: Parser [Text]
              duplicateEffects <- get "duplicateEffects" observed :: Parser [Text]
              poisonResults <- get "poisonResults" observed :: Parser [Value]
              recoveryFailures <- get "recoveryFailures" observed :: Parser [Value]
              recovered <- get "recovered" observed
              duplicate <- get "duplicate" observed
              let failed attempt value = field "tag" value == Just (String "handler-failed") && field "attempt" value == Just (toJSON (attempt :: Int))
                  ceilingHeld = case drop 3 poisonResults of
                    [value] -> field "tag" value == Just (String "previously-failed")
                    _ -> False
              pure
                [ initialCell,
                  ("failure-attempts", length poisonResults == 4 && and (zipWith failed [1 .. 3] (take 3 poisonResults))),
                  ("ceiling-stops-retry", ceilingHeld),
                  ("ceiling-stops-handler", poisonCalls == 3),
                  ("failed-effects-roll-back", null poisonEffects && null failedEffects),
                  ("failed-row-survives-gc", poisonRows == [("InboxFailed", 3)]),
                  ("recovery-after-two-failures", length recoveryFailures == 2 && and (zipWith failed [1, 2] recoveryFailures) && recovered == tagged "processed" && duplicate == tagged "duplicate" && null recoveryRows),
                  ("recovery-effect-once", failedCalls == 5 && recoveredCalls == 6 && duplicateCalls == 6 && recoveredEffects == ["recovery"] && duplicateEffects == ["recovery"])
                ]
            else do
              calls <- count "handlerCalls"
              effects <- get "effects" observed :: Parser [Text]
              first <- get "first" observed
              second <- get "second" observed
              let noCompletion = null effects && all (/= "InboxCompleted") statuses
              if failure == "condemn"
                then
                  pure
                    [ initialCell,
                      ("condemned-call-reports-processed", first == tagged "processed" && second == tagged "processed"),
                      ("condemned-call-rolls-back", noCompletion && null rows),
                      ("redelivery-runs-handler-again", calls == 2)
                    ]
                else do
                  unless (second == Null) (fail "SQL-error workload has an unexpected second call")
                  pure [initialCell, ("sql-error-has-no-completed-effect", noCompletion), ("sql-error-handler-attempted", calls == 1)]

get :: (FromJSON a) => Key.Key -> Value -> Parser a
get key = withObject "poison observation" (.: key)

field :: Text -> Value -> Maybe Value
field key (Object fields) = KeyMap.lookup (Key.fromText key) fields
field _ _ = Nothing

recomputePoison :: FilePath -> RunSource -> IO (Either Text Recomputation)
recomputePoison root source = do
  spec <- readDocument (root </> "run-spec.json")
  result <- readDocument (root </> "run-result.json")
  captured <- readDocument (root </> "logs/inbox-poison-observations.json")
  pure do
    specification <- spec
    document <- result
    observed <- captured
    unless (field "scenarioRevision" document == Just (Number 3)) (Left "poison replay requires scenario revision 3")
    knobs <- maybe (Left "missing poison knobs") Right (field "knobs" specification)
    mode <- either (Left . Text.pack) Right (parseEither (get "inbox.idempotence") knobs)
    failure <- either (Left . Text.pack) Right (parseEither (get "inbox.failure-mode") knobs)
    cells <- replayPoisonCells mode failure observed
    let failures = [label | (label, False) <- cells]
        outcome = if null failures then Passed else Failed
        summary = object ["checks" .= length cells, "failures" .= failures]
        agrees =
          field "failures" document == Just (toJSON failures)
            && field "blocking" document == Just (Bool (outcome == Failed))
            && field "exitCode" document == Just (toJSON (outcomeExitCode outcome))
            && source.result.resultKnownDefect == Nothing
            && (source.result.resultSummaries >>= field "verdicts" >>= field "keiro/inbox/correctness/poison-accounting") == Just summary
    pure Recomputation {agreesWithDocuments = agrees, outcome = Just outcome, comparisonVerdict = Nothing, detail = "recomputed poison checks from captured constructors, handler invocation checkpoints and durable effects/receipts"}

readDocument :: FilePath -> IO (Either Text Value)
readDocument path = do
  attempted <- try (eitherDecodeFileStrict' path) :: IO (Either IOException (Either String Value))
  pure $ case attempted of
    Left err -> Left (Text.pack (show err))
    Right value -> either (Left . Text.pack) Right value
