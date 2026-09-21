module Kenshou.Check.Selftest.ModelReplay (modelReplayScenario) where

import Data.Aeson (object, (.=))
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Hedgehog (PropertyT, assert, forAll)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Kenshou.Check.Model
import Kenshou.Check.Model.Linearizability
import Kenshou.Check.Scenario
import Kenshou.Check.Verdict
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Dimension
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario

modelReplayScenario :: Scenario
modelReplayScenario =
  Scenario
    { id = either (error . show) id (parseScenarioId "selftest/check/correctness/model-replays-counterexample"),
      revision = 1,
      summary = "Proves model counter-examples replay from the run seed and linearizability checking is non-vacuous.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [intKnob "model.tests" "Generated model cases" 200 1 10000],
      dimensions = telemetryOff,
      phases = zeroPhases,
      requires = noEnvironment,
      knownDefect = Nothing,
      run = runModelReplay
    }

runModelReplay :: RunContext -> IO ScenarioReport
runModelReplay context = withCheck context \environment -> do
  let testCount = fromIntegral (knobInt context.knobs (knobName "model.tests"))
      broken = ModelRun "deliberately-broken-register" Implementation testCount 50 brokenProperty
      correct = ModelRun "correct-register" Contract testCount 50 correctProperty
  first <- runModel environment broken
  second <- runModel environment broken
  good <- runModel environment correct
  now <- getCurrentTime
  let sameCounterExample = first.counterExamples == second.counterExamples && first.replay == second.replay
      replayHeld = first.status == Violated && second.status == Violated && sameCounterExample && good.status == Held
      valid = [Operation "p1" "register" (WriteRegister 1) 0 (Just 1) (Returned Written), Operation "p2" "register" ReadRegister 2 (Just 3) (Returned (ReadValue (Just 1)))]
      invalid = [Operation "p1" "register" (WriteRegister 1) 0 (Just 1) (Returned Written), Operation "p2" "register" ReadRegister 2 (Just 3) (Returned (ReadValue Nothing))]
      linearHeld = checkLinearizable defaultLinConfig registerModel valid == Linearizable && isRejected (checkLinearizable defaultLinConfig registerModel invalid)
      verdict name invariant held parameters = Verdict name invariant Contract (if held then Held else Violated) Nothing "Model self-test result." (Map.fromList [("examined", 2), ("violations", if held then 0 else 1)]) parameters [] False [] Nothing now 0
  finishWithVerdicts environment [verdict "model-replay" "replayable-model-counterexample" replayHeld (object ["sameCounterExample" .= sameCounterExample]), verdict "linearizability-non-vacuity" "linearizability" linearHeld (object [])]

brokenProperty :: PropertyT IO ()
brokenProperty = do
  value <- forAll (Gen.int (Range.linear 0 100))
  assert (value < 0)

correctProperty :: PropertyT IO ()
correctProperty = do
  value <- forAll (Gen.int (Range.linear 0 100))
  assert (value >= 0)

isRejected :: LinResult -> Bool
isRejected (NotLinearizable _) = True
isRejected _ = False

intKnob :: Text -> Text -> Int64 -> Int64 -> Int64 -> KnobSpec
intKnob raw summary def low high = KnobSpec (knobName raw) summary KnobInt (VInt def) (IntRange low high) []

knobName :: Text -> KnobName
knobName value = either (error . Text.unpack) id (mkKnobName value)

telemetryOff :: DimensionSupport
telemetryOff = DimensionSupport (Supported (Support (TracingOff :| []) TracingOff)) (Supported (Support (MetricsOff :| []) MetricsOff)) NotApplicable NotApplicable
