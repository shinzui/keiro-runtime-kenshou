module Kenshou.Telemetry.SelfTest.Problems
  ( traceContinuityScenario,
    slowExporterScenario,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (forM_, replicateM_, void)
import Data.Aeson (object, (.=))
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Context (RunContext (..), SummarySection (Verdicts), putSummary)
import Kenshou.Core.Dimension
import Kenshou.Core.Dimension qualified as Dimension
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (ScenarioId, parseScenarioId)
import Kenshou.Core.Knob
import Kenshou.Core.Phase (PhasePlan (..))
import Kenshou.Core.Scenario
import Kenshou.Telemetry
import Kenshou.Telemetry.Compose
import Kenshou.Telemetry.Continuity
import Kenshou.Telemetry.Detect
import Kenshou.Telemetry.Tracing.Pipeline (PipelineSnapshot (..), snapshotPipeline)
import Kenshou.Telemetry.Tracing.Probe (SpanView (..), readSpans)
import OpenTelemetry.Attributes (Attribute (AttributeValue), PrimitiveAttribute (TextAttribute), lookupAttribute)
import OpenTelemetry.Trace.Core (Span, addAttribute, defaultSpanArguments, inSpan, inSpan')
import System.Timeout (timeout)

traceContinuityScenario :: Scenario
traceContinuityScenario =
  Scenario
    { id = scenarioId "selftest/telemetry/correctness/trace-continuity",
      revision = 1,
      summary = "Proves trace discontinuity and context-leak checks are non-vacuous.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [intKnob "continuity.messages" "Synthetic messages in each continuity case" 1000 10 100000] <> telemetryKnobs,
      dimensions = onlyArms TracingSdkInMemory MetricsOff,
      phases = PhasePlan 0 0 0,
      requires = noEnvironment,
      knownDefect = Nothing,
      run = runTraceContinuity
    }

slowExporterScenario :: Scenario
slowExporterScenario =
  Scenario
    { id = scenarioId "selftest/telemetry/concurrency/slow-exporter-backpressure",
      revision = 1,
      summary = "Proves slow exporters and handlers are detected without blocking the emitter.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs =
        [ intKnob "backpressure.phase-seconds" "Maximum synthetic phase duration" 8 2 600,
          intKnob "handler.delay-micros" "Injected handler delay" 5000 0 1000000
        ]
          <> telemetryKnobs,
      dimensions = onlyArms TracingSdkOtlp MetricsOff,
      phases = PhasePlan 0 0 0,
      requires = noEnvironment,
      knownDefect = Nothing,
      run = runSlowExporter
    }

runTraceContinuity :: RunContext -> IO ScenarioReport
runTraceContinuity context = case telemetrySpecFromContext context of
  Left message -> pure (failedWith ["invalid-telemetry-config"] message)
  Right spec -> withTelemetry spec \telemetry -> case telemetry.tracer of
    Nothing -> pure (failedWith ["missing-tracer"] "sdk-inmemory did not provide a tracer")
    Just tracer -> do
      let messages = fromIntegral (knobInt context.knobs (name "continuity.messages"))
      forM_ [1 .. messages] \index ->
        inSpan' tracer "intact.producer" defaultSpanArguments \producer -> do
          addMessageId producer ("intact-" <> tshow index)
          inSpan' tracer "intact.consumer" defaultSpanArguments \consumer -> addMessageId consumer ("intact-" <> tshow index)
      forM_ [10, 20 .. messages] \index -> do
        inSpan' tracer "broken.producer" defaultSpanArguments \producer -> addMessageId producer ("broken-" <> tshow index)
        inSpan' tracer "broken.consumer" defaultSpanArguments \consumer -> addMessageId consumer ("broken-" <> tshow index)
      inSpan tracer "leak.carrier" defaultSpanArguments do
        forM_ [10, 20 .. messages] \index ->
          inSpan' tracer "leaky.consumer" defaultSpanArguments \consumer -> addMessageId consumer ("leaky-" <> tshow index)
      void telemetry.flushTelemetry
      spans <- maybe (pure []) readSpans telemetry.spans
      let correlate spanValue = case lookupAttribute spanValue.attributes "message.id" of Just (AttributeValue (TextAttribute value)) -> Just value; _ -> Nothing
          intact = checkContinuity (named "intact.producer") (named "intact.consumer") correlate spans
          broken = checkContinuity (named "broken.producer") (named "broken.consumer") correlate spans
          isolated = checkIsolation (named "leaky.consumer") (const True) spans
          expected = messages `div` 10
          ok = intact.violations == 0 && intact.consumers == messages && broken.violations == expected && isolated.violations == expected
      telemetry.recordContinuity intact (IsolationResult 0 0 [])
      telemetry.recordContinuity broken isolated
      putSummary context Verdicts "trace-continuity" (object ["intact" .= intact, "broken" .= broken, "leaky" .= isolated, "expectedInjected" .= expected])
      pure (if ok then passed else failedWith ["trace-detector-non-vacuity"] "continuity detectors did not identify exactly the injected defects")

runSlowExporter :: RunContext -> IO ScenarioReport
runSlowExporter context = case telemetrySpecFromContext context of
  Left message -> pure (failedWith ["invalid-telemetry-config"] message)
  Right spec -> withTelemetry (spec {processor = BatchProcessor 256 200 128 2000, shutdownMs = 1000}) \telemetry -> case (telemetry.tracer, telemetry.pipeline) of
    (Just tracer, Just pipeline) -> do
      let delayMicros = fromIntegral (knobInt context.knobs (name "handler.delay-micros"))
          phaseMicros = fromIntegral (knobInt context.knobs (name "backpressure.phase-seconds")) * 1_000_000
      synchronousStats <- newHandlerStats
      replicateM_ 20 (timedHandler synchronousStats "synchronous" (slowHandler delayMicros) ())
      synchronous <- snapshotHandlerStats "synchronous" synchronousStats
      asyncStats <- newHandlerStats
      (submit, asyncSnapshot) <- asyncHandler 64 (slowHandler delayMicros)
      completed <- timeout phaseMicros (replicateM_ 10000 (timedHandler asyncStats "async-submit" submit ()))
      threadDelay (min 250_000 phaseMicros)
      asynchronous <- snapshotHandlerStats "async-submit" asyncStats
      asyncQueue <- asyncSnapshot
      telemetry.recordHandlerStats synchronous
      telemetry.recordHandlerStats asynchronous
      telemetry.setSinkFault SinkHang
      emitted <- timeout phaseMicros (replicateM_ 10000 (inSpan tracer "backpressure" defaultSpanArguments (pure ())))
      snapshot <- snapshotPipeline pipeline
      let syncFired = (handlerFinding synchronous).status == Fired
          asyncQuiet = (handlerFinding asynchronous).status == Quiet
          ok = completed /= Nothing && emitted /= Nothing && syncFired && asyncQuiet && asyncQueue.dropped > 0 && snapshot.spansDropped > 0
      putSummary context Verdicts "slow-exporter-backpressure" (object ["synchronous" .= synchronous, "asynchronous" .= asynchronous, "asyncQueue" .= asyncQueue, "pipeline" .= snapshot, "emitterCompleted" .= (emitted /= Nothing)])
      pure (if ok then passed else failedWith ["backpressure-detector-non-vacuity"] "slow exporter or handler detector did not fire as expected")
    _ -> pure (failedWith ["missing-sdk"] "sdk-otlp did not provide a tracer and pipeline")

onlyArms :: TracingArm -> MetricsArm -> DimensionSupport
onlyArms tracing metrics =
  DimensionSupport (Supported (Support (tracing :| []) tracing)) (Supported (Support (metrics :| []) metrics)) Dimension.NotApplicable Dimension.NotApplicable

named :: Text -> SpanSelector
named spanName = SpanSelector (Just spanName) Nothing []

addMessageId :: Span -> Text -> IO ()
addMessageId spanValue value = addAttribute spanValue "message.id" value

scenarioId :: Text -> ScenarioId
scenarioId text = either (error . Text.unpack) id (parseScenarioId text)

intKnob :: Text -> Text -> Int64 -> Int64 -> Int64 -> KnobSpec
intKnob key summary def low high = KnobSpec (name key) summary KnobInt (VInt def) (IntRange low high) []

name :: Text -> KnobName
name = either (error . Text.unpack) id . mkKnobName

tshow :: (Show value) => value -> Text
tshow = Text.pack . show
