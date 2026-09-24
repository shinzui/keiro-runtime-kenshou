module Kenshou.Suite.Keiro.Timer.Oracle (recordTimerCells) where

import Data.Aeson (object)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (getCurrentTime)
import Kenshou.Check.Scenario (CheckEnv (..), finishWithVerdicts)
import Kenshou.Check.Verdict (InvariantClass (..), Verdict (..), VerdictStatus (..))
import Kenshou.Core.Scenario (ScenarioReport)

recordTimerCells :: CheckEnv -> [(Text, Bool)] -> IO ScenarioReport
recordTimerCells check cells = do
  now <- getCurrentTime
  let verdict (name, held) =
        Verdict
          { checker = "timer-" <> name,
            invariant = name,
            cls = Contract,
            status = if held then Held else Violated,
            reason = Nothing,
            summary = if held then "Timer lifecycle invariant held" else "Timer lifecycle invariant failed",
            counts = Map.singleton "timers" 1,
            parameters = object [],
            counterExamples = [],
            counterExamplesTruncated = False,
            inputs = [],
            replay = Nothing,
            checkedAt = now,
            durationMillis = 0
          }
  finishWithVerdicts check (map verdict cells)
