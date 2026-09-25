module Kenshou.Suite.Shibuya.Concurrency.CoreOrdering (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, throwIO, try)
import Data.Aeson (object, (.=))
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Text qualified as Text
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension (noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (KnownDefect (..), Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Suite.Shibuya.Cohort (knownOnReleasedCore, rev)
import Shibuya.Internal.Runner.KeyedScheduler (runKeyedScheduler)
import Streamly.Data.Stream qualified as Stream
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [keyedWorkerFailure]

keyedWorkerFailure :: Scenario
keyedWorkerFailure =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/core-ordering/concurrency/keyed-worker-failure-stops-intake"),
      revision = 1,
      summary = "A keyed worker exception stops the scheduler and bounds successor starts.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions = noDimensions,
      phases = zeroPhases,
      requires = noEnvironment,
      knownDefect = knownOnReleasedCore ((rev 5 "REV-5-F1") {expectedFailures = ["REV-5-F1", "successor-start-bound-exceeded"]}),
      run = runKeyedWorkerFailure
    }

runKeyedWorkerFailure :: RunContext -> IO ScenarioReport
runKeyedWorkerFailure context = do
  started <- newIORef (0 :: Int)
  let source = Stream.unfoldrM (\number -> pure (Just (number, number + 1))) (0 :: Int)
      action number = do
        atomicModifyIORef' started (\count -> (count + 1, ()))
        if number == 0
          then throwIO (userError "scripted keyed worker fault")
          else threadDelay 100000
  observed <- try @SomeException (timeout 1000000 (runKeyedScheduler 4 8 (const (Nothing :: Maybe Int)) action source))
  totalStarted <- readIORef started
  let threwScripted = case observed of
        Left err -> "scripted keyed worker fault" `Text.isInfixOf` Text.pack (show err)
        _ -> False
      successors = max 0 (totalStarted - 1)
      failures =
        ["REV-5-F1" | not threwScripted]
          <> ["successor-start-bound-exceeded" | successors > 12]
  putSummary context Verdicts "keyed-worker-failure" $
    object
      [ "returnedWithinOneSecond" .= either (const True) (maybe False (const True)) observed,
        "rethrewScriptedFailure" .= threwScripted,
        "successorsStarted" .= successors,
        "successorStartBound" .= (12 :: Int)
      ]
  pure $ if null failures then passed else failedWith failures (Text.intercalate "; " failures)
