{-# LANGUAGE RankNTypes #-}

module Kenshou.Check.Model
  ( ModelRun (..),
    runModel,
    sequentialProperty,
    parallelProperty,
  )
where

import Data.Aeson (object, (.=))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (diffUTCTime, getCurrentTime)
import Hedgehog (Gen, PropertyT, Range, forAll)
import Hedgehog qualified
import Hedgehog.Internal.Property (Property (..), ShrinkPath (..), defaultConfig, withTests)
import Hedgehog.Internal.Report (FailedAnnotation (..), FailureReport (..), Report (..), Result (..))
import Hedgehog.Internal.Runner (checkReport)
import Hedgehog.Internal.Seed qualified as HedgehogSeed
import Hedgehog.Internal.State (Command)
import Hedgehog.Internal.State qualified as State
import Kenshou.Check.Scenario
import Kenshou.Check.Verdict
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Id (renderScenarioId, unSeed)

data ModelRun = ModelRun
  { name :: !Text,
    cls :: !InvariantClass,
    tests :: !Int,
    size :: !Int,
    property :: !(PropertyT IO ())
  }

runModel :: CheckEnv -> ModelRun -> IO Verdict
runModel environment model = do
  started <- getCurrentTime
  let runSeed = unSeed environment.context.seed
      derived = deriveSeed runSeed model.name
      configured = withTests (fromIntegral model.tests) (Property defaultConfig model.property)
  report <- checkReport configured.propertyConfig (fromIntegral model.size) (HedgehogSeed.from derived) configured.propertyTest (const (pure ()))
  ended <- getCurrentTime
  let duration = floor (diffUTCTime ended started * 1000)
      replayCommand = "kenshou run " <> renderScenarioId environment.context.scenario <> " --seed " <> Text.pack (show runSeed)
      base status reason summary counterExamples replay =
        Verdict
          model.name
          "model-property"
          model.cls
          status
          reason
          summary
          (Map.fromList [("tests", fromIntegral report.reportTests), ("violations", if status == Violated then 1 else 0)])
          (object ["derivedSeed" .= derived, "size" .= model.size])
          counterExamples
          False
          []
          replay
          ended
          duration
  pure case report.reportStatus of
    OK -> base Held Nothing "The model property held." [] Nothing
    GaveUp -> base NotEvaluated (Just "gave-up") "The model property exhausted its discard limit." [] Nothing
    Failed failure ->
      let ShrinkPath shrinkPath = failure.failureShrinkPath
          counterExample =
            object
              [ "message" .= failure.failureMessage,
                "annotations" .= fmap (.failedValue) failure.failureAnnotations,
                "footnotes" .= failure.failureFootnotes,
                "shrinks" .= show failure.failureShrinks,
                "shrinkPath" .= shrinkPath
              ]
          replay = Replay (fromIntegral runSeed) model.size shrinkPath replayCommand
       in base Violated Nothing "The model property found a reproducible counter-example." [counterExample] (Just replay)

sequentialProperty :: (forall variable. state variable) -> Range Int -> [Command Gen (PropertyT IO) state] -> PropertyT IO ()
sequentialProperty initial range commands = do
  actions <- forAll (State.sequential range initial commands)
  Hedgehog.executeSequential initial actions

parallelProperty :: (forall variable. state variable) -> Range Int -> Range Int -> [Command Gen (PropertyT IO) state] -> PropertyT IO ()
parallelProperty initial prefixRange branchRange commands = do
  actions <- forAll (State.parallel prefixRange branchRange initial commands)
  Hedgehog.executeParallel initial actions
