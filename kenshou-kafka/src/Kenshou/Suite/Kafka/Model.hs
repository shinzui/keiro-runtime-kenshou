module Kenshou.Suite.Kafka.Model (scenarios) where

import Data.Aeson (object, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Hedgehog (annotateShow, assert, evalIO, forAll)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Kenshou.Check.Model (ModelRun (..), runModel)
import Kenshou.Check.Scenario (finishWithVerdicts, withCheck)
import Kenshou.Check.Verdict (InvariantClass (..))
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension (DimensionSupport (..), MetricsArm (..), Support (..), Supported (..), TracingArm (..))
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (KnobName, knobInt, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (CohortScope (..), KnownDefect (..), PackageCondition (..), Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Kafka.Fixture (intKnob)
import Kenshou.Suite.Kafka.Model.Simulator

scenarios :: [Scenario]
scenarios =
  [ Scenario
      { id = either (error . Text.unpack) id (parseScenarioId "kafka/adapter/correctness/ack-state-machine-model"),
        revision = 1,
        summary = "Runs generated retry schedules through the released adapter's real ack and seek code without a broker.",
        tier = TierStandard,
        placement = PlaceEither,
        knobs =
          [ intKnob "model.tests" "Generated schedules per property" 2000 1 20000,
            intKnob "model.max-offsets" "Maximum simulated partition length" 30 5 100
          ],
        dimensions = DimensionSupport (Supported (Support (TracingOff :| []) TracingOff)) (Supported (Support (MetricsOff :| []) MetricsOff)) NotApplicable NotApplicable,
        phases = zeroPhases,
        requires = noEnvironment,
        knownDefect =
          Just
            KnownDefect
              { reference = "mori://shinzui/keiro/masterplans/18-make-the-kafka-transport-edge-production-safe-surfaced-by-the-2026-07-transport-review",
                summary = "The released adapter can overwrite an earlier retry barrier and execute buffered successors first.",
                expectedFailures = ["model-no-commit-past-unacked", "model-first-success-order", "model-terminates-at-log-end"],
                appliesTo = OnlyWhen (ResolvedFromHackage "shibuya-kafka-adapter" :| [VersionBelow "shibuya-kafka-adapter" "0.9.0.2"])
              },
        run = runAckModel
      }
  ]

runAckModel :: RunContext -> IO ScenarioReport
runAckModel context = withCheck context \check -> do
  let tests = fromIntegral (knobInt context.knobs (key "model.tests"))
      offsets = fromIntegral (knobInt context.knobs (key "model.max-offsets"))
      propertyFor predicate scriptFor = do
        retryAt <- forAll (Gen.int (Range.linear 1 (offsets - 3)))
        depth <- forAll (Gen.int (Range.linear 2 (min 10 offsets)))
        let schedule = Schedule depth depth offsets (scriptFor retryAt)
        result <- evalIO (runSchedule schedule)
        annotateShow schedule
        annotateShow result
        case result of
          Left problem -> fail (show problem)
          Right trace -> assert (predicate trace)
      doubleRetry offset = Map.fromList [(offset, [DecideRetry, DecideOk]), (offset + 1, [DecideRetry, DecideOk])]
      singleRetry offset = Map.singleton offset [DecideRetry, DecideOk]
  fixed <- runSchedule (Schedule 10 10 10 (doubleRetry 3))
  putSummary context Verdicts "modelFixedSchedule" (object ["schedule" .= ("offsets 3 and 4 each retry once, depth 10" :: Text), "trace" .= show fixed])
  verdicts <-
    sequence
      [ runModel check (ModelRun "model-no-commit-past-unacked" Contract tests offsets (propertyFor propNoCommitPastUnacked doubleRetry)),
        runModel check (ModelRun "model-first-success-order" Contract tests offsets (propertyFor propFirstSuccessInOrder singleRetry)),
        runModel check (ModelRun "model-terminates-at-log-end" Contract tests offsets (propertyFor propTerminates doubleRetry))
      ]
  finishWithVerdicts check verdicts

key :: Text -> KnobName
key = either (error . Text.unpack) id . mkKnobName
