module Kenshou.Suite.Keiro.Messaging.Verdict (recordMessagingCells, recordMessagingCellsClassified) where

import Data.Aeson (Value, object, (.=))
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Time (getCurrentTime)
import Kenshou.Check.Verdict (InvariantClass (..), RunInfo (..), Verdict (..), VerdictStatus (..), writeVerdict)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Id (renderScenarioId)
import Kenshou.Core.Scenario (ScenarioReport, failedWith, passed)
import System.FilePath ((</>))

recordMessagingCells :: RunContext -> Map Text Int64 -> Value -> [(Text, Bool)] -> IO ScenarioReport
recordMessagingCells context counts parameters cells =
  recordMessagingCellsClassified context counts parameters [(label, Contract, held) | (label, held) <- cells]

recordMessagingCellsClassified :: RunContext -> Map Text Int64 -> Value -> [(Text, InvariantClass, Bool)] -> IO ScenarioReport
recordMessagingCellsClassified context counts parameters cells = do
  checkedAt <- getCurrentTime
  mapM_ (writeCell checkedAt) cells
  let failed = [label | (label, _, False) <- cells]
  putSummary context Verdicts (renderScenarioId context.scenario) (object ["checks" .= length cells, "failures" .= failed])
  pure $ if null failed then passed else failedWith failed "messaging scenario checks failed"
  where
    writeCell checkedAt (label, classification, held) = do
      _ <-
        writeVerdict
          (context.outDir </> "verdicts")
          (RunInfo context.runId context.scenario)
          Verdict
            { checker = label,
              invariant = label,
              cls = classification,
              status = if held then Held else Violated,
              reason = Nothing,
              summary = if held then "Expected result observed" else "Expected result did not match",
              counts,
              parameters,
              counterExamples = [],
              counterExamplesTruncated = False,
              inputs = [],
              replay = Nothing,
              checkedAt,
              durationMillis = 0
            }
      pure ()
