module Kenshou.Suite.Keiro.Workflow.Oracle
  ( journalStepIdentity,
    effectCoverage,
    backoffLadder,
    recordWorkflowCells,
    recordWorkflowCellsAs,
  )
where

import Data.Aeson (object)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (NominalDiffTime, UTCTime, diffUTCTime, getCurrentTime)
import Keiro.Workflow (WorkflowId, WorkflowName, deterministicJournalId)
import Kenshou.Check.Scenario (CheckEnv, finishWithVerdicts)
import Kenshou.Check.Verdict (InvariantClass (..), Verdict (..), VerdictStatus (..))
import Kenshou.Core.Scenario (ScenarioReport)
import Kiroku.Store.Types (EventId)

-- | Require one journal row per expected step in order, with Keiro's stable
-- identifier. A duplicated or renamed row fails even if the final result is
-- unchanged.
journalStepIdentity :: WorkflowName -> WorkflowId -> Int -> [Text] -> [(Text, EventId)] -> Bool
journalStepIdentity name wid generation expected observed =
  map fst observed == expected
    && all (\(stepName, eventId) -> eventId == deterministicJournalId name wid generation stepName) observed

-- | Every expected step must have an effect. An extra execution is allowed
-- only when the crash-window ledger grants that exact step another attempt.
-- Unknown effect keys fail, so a lost or mislabelled effect cannot be hidden.
effectCoverage :: [Text] -> Map Text Int -> Map Text Int -> Bool
effectCoverage expected effects crashWindows =
  Map.keysSet effects == Map.keysSet (Map.fromList [(key, ()) | key <- expected])
    && all
      ( \key ->
          let count = Map.findWithDefault 0 key effects
              windows = Map.findWithDefault 0 key crashWindows
           in count >= 1 && count <= 1 + max 0 windows
      )
      expected

-- | Check the actual spacing of consecutive executions against the
-- exponential retry gate. The first retry waits @initialDelay@, subsequent
-- waits double up to 64 seconds. @slack@ covers poll and clock skew, and is
-- applied on both sides of each expected interval.
backoffLadder :: NominalDiffTime -> NominalDiffTime -> [UTCTime] -> Either Text ()
backoffLadder initialDelay slack observations
  | initialDelay <= 0 = Left "initial backoff delay must be positive"
  | slack < 0 = Left "backoff slack must be non-negative"
  | otherwise = go (0 :: Int) observations
  where
    go _ [] = Right ()
    go _ [_] = Right ()
    go attempt (earlier : later : rest) =
      let expected = min 64 (initialDelay * (2 ^ attempt))
          actual = diffUTCTime later earlier
       in if actual >= max 0 (expected - slack) && actual <= expected + slack
            then go (attempt + 1) (later : rest)
            else Left ("backoff interval " <> Text.pack (show attempt) <> " was " <> Text.pack (show actual) <> "; expected " <> Text.pack (show expected) <> " +/- " <> Text.pack (show slack))

recordWorkflowCells :: CheckEnv -> [(Text, Bool)] -> IO ScenarioReport
recordWorkflowCells = recordWorkflowCellsAs Contract

recordWorkflowCellsAs :: InvariantClass -> CheckEnv -> [(Text, Bool)] -> IO ScenarioReport
recordWorkflowCellsAs invariantClass check cells = do
  now <- getCurrentTime
  let verdict (name, held) =
        Verdict
          { checker = "workflow-" <> name,
            invariant = name,
            cls = invariantClass,
            status = if held then Held else Violated,
            reason = Nothing,
            summary = if held then "Workflow invariant held" else "Workflow invariant failed",
            counts = Map.singleton "instances" 1,
            parameters = object [],
            counterExamples = [],
            counterExamplesTruncated = False,
            inputs = [],
            replay = Nothing,
            checkedAt = now,
            durationMillis = 0
          }
  finishWithVerdicts check (map verdict cells)
