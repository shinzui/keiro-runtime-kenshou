{-# LANGUAGE FieldSelectors #-}

module Kenshou.Plan.Summary
  ( EntryStatus (..),
    Attempt (..),
    SummaryEntry (..),
    PlanSummary (..),
    emptySummary,
    worstOutcome,
    summaryExitCode,
    finalizeSummary,
    writeSummary,
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (UTCTime)
import Kenshou.Core.Id (RunId, ScenarioId)
import Kenshou.Core.Outcome (Outcome (..), outcomeExitCode, renderOutcome)
import System.Directory (renameFile)
import System.Exit (ExitCode (..))

data EntryStatus = Pending | Running | Completed deriving stock (Eq, Show)

data Attempt = Attempt
  { runId :: RunId,
    startedAt :: UTCTime,
    finishedAt :: Maybe UTCTime,
    outcome :: Maybe Outcome,
    knownDefect :: Bool,
    childExitCode :: Maybe Int
  }
  deriving stock (Eq, Show)

data SummaryEntry = SummaryEntry
  { ordinal :: Int,
    scenario :: ScenarioId,
    status :: EntryStatus,
    attempts :: [Attempt]
  }
  deriving stock (Eq, Show)

data PlanSummary = PlanSummary
  { planId :: RunId,
    entries :: [SummaryEntry],
    counts :: Map Text Int,
    worst :: Outcome,
    exitCode :: Int
  }
  deriving stock (Eq, Show)

emptySummary :: RunId -> [(Int, ScenarioId)] -> PlanSummary
emptySummary planId entries = finalizeSummary (PlanSummary planId [SummaryEntry ordinal scenario Pending [] | (ordinal, scenario) <- entries] Map.empty Passed 0)

worstOutcome :: PlanSummary -> Outcome
worstOutcome summary = case blocking of
  [] -> Passed
  values -> foldl1 worse values
  where
    blocking = concatMap entryOutcome summary.entries
    entryOutcome entry
      | entry.status /= Completed = [Errored]
      | otherwise = case reverse entry.attempts of
          attempt : _ | attempt.knownDefect -> []
          attempt : _ -> maybe [Errored] pure attempt.outcome
          [] -> [Errored]
    worse left right = if rank left >= rank right then left else right
    rank Passed = (0 :: Int)
    rank Inconclusive = 1
    rank InfrastructureFailure = 2
    rank Errored = 3
    rank Failed = 4

summaryExitCode :: PlanSummary -> ExitCode
summaryExitCode summary = case outcomeExitCode (worstOutcome summary) of 0 -> ExitSuccess; value -> ExitFailure value

finalizeSummary :: PlanSummary -> PlanSummary
finalizeSummary summary = summary {counts = outcomeCounts, worst, exitCode = outcomeExitCode worst}
  where
    worst = worstOutcome summary
    latest = [attempt | entry <- summary.entries, attempt <- take 1 (reverse entry.attempts)]
    outcomes = [outcome | attempt <- latest, not attempt.knownDefect, Just outcome <- [attempt.outcome]]
    defectCount = length (filter (.knownDefect) latest)
    outcomeCounts = Map.fromListWith (+) ([(renderOutcome outcome, 1) | outcome <- outcomes] <> [("known-defect", defectCount) | defectCount > 0])

writeSummary :: FilePath -> PlanSummary -> IO ()
writeSummary path summary = do
  let temporary = path <> ".tmp"
  LazyByteString.writeFile temporary (encode (finalizeSummary summary))
  renameFile temporary path

instance ToJSON PlanSummary where
  toJSON summary = object ["schema" .= ("kenshou.plan-summary/v1" :: Text), "planId" .= summary.planId, "entries" .= summary.entries, "counts" .= summary.counts, "worstOutcome" .= summary.worst, "exitCode" .= summary.exitCode]

instance FromJSON PlanSummary where
  parseJSON = withObject "PlanSummary" \value -> do
    schema <- value .: "schema"
    if schema /= ("kenshou.plan-summary/v1" :: Text) then fail "unsupported plan summary schema" else pure ()
    PlanSummary <$> value .: "planId" <*> value .: "entries" <*> value .:? "counts" .!= Map.empty <*> value .:? "worstOutcome" .!= Passed <*> value .:? "exitCode" .!= 0

instance ToJSON SummaryEntry where
  toJSON entry = object ["ordinal" .= entry.ordinal, "scenario" .= entry.scenario, "status" .= renderStatus entry.status, "attempts" .= entry.attempts]

instance FromJSON SummaryEntry where
  parseJSON = withObject "SummaryEntry" \value -> SummaryEntry <$> value .: "ordinal" <*> value .: "scenario" <*> (value .: "status" >>= parseStatus) <*> value .:? "attempts" .!= []

instance ToJSON Attempt where
  toJSON attempt = object ["runId" .= attempt.runId, "startedAt" .= attempt.startedAt, "finishedAt" .= attempt.finishedAt, "outcome" .= attempt.outcome, "knownDefect" .= attempt.knownDefect, "childExitCode" .= attempt.childExitCode]

instance FromJSON Attempt where
  parseJSON = withObject "Attempt" \value -> Attempt <$> value .: "runId" <*> value .: "startedAt" <*> value .:? "finishedAt" <*> value .:? "outcome" <*> value .:? "knownDefect" .!= False <*> value .:? "childExitCode"

renderStatus :: EntryStatus -> Text
renderStatus Pending = "pending"
renderStatus Running = "running"
renderStatus Completed = "completed"

parseStatus :: Text -> Parser EntryStatus
parseStatus "pending" = pure Pending
parseStatus "running" = pure Running
parseStatus "completed" = pure Completed
parseStatus other = fail ("unknown entry status " <> show other)
