module Kenshou.Cli.Attest.KeiroQueueConfig (replayQueueConfigCells, recomputeQueueConfig) where

import Control.Exception (IOException, try)
import Control.Monad (unless)
import Data.Aeson (FromJSON (..), Value (..), eitherDecodeFileStrict', object, toJSON, withObject, (.:), (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Outcome (Outcome (..), outcomeExitCode)
import Kenshou.Evidence.Attest (Recomputation (..))
import Kenshou.Evidence.Source (RunResultView (..), RunSource (..))
import System.FilePath ((</>))

data Attempt = Attempt {status :: Text, detail :: Text}

instance FromJSON Attempt where
  parseJSON = withObject "configuration attempt" \o -> do
    status <- o .: "status"
    unless (status `elem` ["accepted", "rejected"]) (fail "unknown configuration attempt status")
    Attempt status <$> o .: "detail"

data Case = Case
  { label :: Text,
    expected :: Text,
    drain :: Attempt,
    worker :: Attempt,
    afterDrain :: (Int64, Int64),
    afterWorker :: (Int64, Int64)
  }

instance FromJSON Case where
  parseJSON = withObject "configuration case" \o -> Case <$> o .: "case" <*> o .: "expectedError" <*> o .: "drain" <*> o .: "worker" <*> o .: "afterDrain" <*> o .: "afterWorker"

-- Independent contract expectations: neither the runtime nor its scenario
-- validator is imported, and recorded expected-error strings are not trusted.
expectedErrors :: [(Text, Text)]
expectedErrors =
  [ ("invalid-visibility", "InvalidJobTuning (NonPositiveVisibilityTimeout 0)"),
    ("invalid-batch", "InvalidJobTuning (NonPositiveBatchSize 0)"),
    ("invalid-polling", "InvalidJobTuning NonPositivePollInterval"),
    ("invalid-long-poll-limit", "InvalidJobTuning NonPositivePollInterval"),
    ("invalid-long-poll-interval", "InvalidJobTuning NonPositivePollInterval"),
    ("ordering-mismatch", "JobOrderingMismatch {jobOrderingDeclared = Unordered, tuningOrderingGiven = FifoHeads}"),
    ("unsafe-legacy-batch", "UnsafeLegacyFifoBatch {unsafeOrdering = FifoThroughput, unsafeBatchSize = 2}"),
    ("unsafe-round-robin-batch", "UnsafeLegacyFifoBatch {unsafeOrdering = FifoRoundRobin, unsafeBatchSize = 2}"),
    ("validation-precedence", "InvalidJobTuning (NonPositiveVisibilityTimeout 0)"),
    ("mismatch-before-unsafe-batch", "JobOrderingMismatch {jobOrderingDeclared = Unordered, tuningOrderingGiven = FifoThroughput}")
  ]

replayQueueConfigCells :: Value -> Either Text [(Text, Bool)]
replayQueueConfigCells raw = either (Left . Text.pack) Right $ parseEither replay raw
  where
    replay = withObject "queue configuration observations" \o -> do
      schema <- o .: "schema"
      unless (schema == ("kenshou.queue-config-rejections/v1" :: Text)) (fail "unsupported queue configuration observations")
      cases <- o .: "cases" :: Parser [Case]
      before <- o .: "beforeValidDrain"
      drained <- o .: "validDrain" :: Parser (Maybe Int)
      empty <- o .: "emptyDrain" :: Parser (Maybe Int)
      let byLabel = Map.fromList [(item.label, item) | item <- cases]
          expected = Map.fromList expectedErrors
      unless (length cases == Map.size byLabel && Map.keysSet byLabel == Map.keysSet expected) (fail "missing, duplicate or unknown configuration case")
      unless (all (\item -> Map.lookup item.label expected == Just item.expected) cases) (fail "recorded configuration expectation differs from contract")
      let held err attempt state = attempt.status == "rejected" && attempt.detail == err && state == (1, 0)
          cells (label, err) = case Map.lookup label byLabel of
            Just item -> [(label, held err item.drain item.afterDrain), ("worker-" <> label, held err item.worker item.afterWorker)]
            Nothing -> []
      pure $ concatMap cells expectedErrors <> [("read-count-untouched", before == (1 :: Int64, 0 :: Int64)), ("rejections-did-not-consume-job", drained == Just 1 && empty == Just 0)]

field :: Text -> Value -> Maybe Value
field key (Object fields) = KeyMap.lookup (Key.fromText key) fields
field _ _ = Nothing

recomputeQueueConfig :: FilePath -> RunSource -> IO (Either Text Recomputation)
recomputeQueueConfig root source = do
  spec <- readDocument (root </> "run-spec.json")
  result <- readDocument (root </> "run-result.json")
  captured <- readDocument (root </> "logs/queue-config-rejections.json")
  pure do
    specification <- spec
    document <- result
    observed <- captured
    unless (field "scenarioRevision" document == Just (Number 2) && field "scenarioRevision" specification == Just (Number 2)) (Left "queue configuration replay requires scenario revision 2")
    cells <- replayQueueConfigCells observed
    let failures = [label | (label, False) <- cells]
        outcome = if null failures then Passed else Failed
        summary = object ["checks" .= length cells, "failures" .= failures]
        agrees =
          field "failures" document == Just (toJSON failures)
            && field "blocking" document == Just (Bool (outcome == Failed))
            && field "exitCode" document == Just (toJSON (outcomeExitCode outcome))
            && source.result.resultKnownDefect == Nothing
            && (source.result.resultSummaries >>= field "verdicts" >>= field "keiro/queue/correctness/consumption-config-rejections") == Just summary
    pure Recomputation {agreesWithDocuments = agrees, outcome = Just outcome, comparisonVerdict = Nothing, detail = "recomputed twenty-two drain/worker configuration checks from observed errors and physical queue states"}

readDocument :: FilePath -> IO (Either Text Value)
readDocument path = do
  attempted <- try (eitherDecodeFileStrict' path) :: IO (Either IOException (Either String Value))
  pure $ case attempted of
    Left err -> Left (Text.pack (show err))
    Right value -> either (Left . Text.pack) Right value
