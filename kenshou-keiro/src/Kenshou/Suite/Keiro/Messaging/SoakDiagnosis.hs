module Kenshou.Suite.Keiro.Messaging.SoakDiagnosis
  ( majorGcKnob,
    majorGcIntervalMs,
    withSoakMajorGc,
    soakLeakSpec,
  )
where

import Data.Map.Strict qualified as Map
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobInt, mkKnobName)
import Kenshou.Diagnose.Leak (LeakSpec (..), ProbeSpec (..), defaultLeakSpec)
import Kenshou.Diagnose.Leak.MajorGcProbe (withMajorGcProbe)
import Kenshou.Diagnose.Series (SeriesBinding (..))

majorGcKnob :: KnobSpec
majorGcKnob = KnobSpec knob "Forced major-GC interval for leak diagnosis; zero disables it" KnobInt (VInt 0) (IntRange 0 60000) []
  where
    knob = either (error . show) id (mkKnobName "diagnose.major-gc-interval-ms")

majorGcIntervalMs :: RunContext -> Double
majorGcIntervalMs context = fromIntegral (knobInt context.knobs name)
  where
    name :: KnobName
    name = either (error . show) id (mkKnobName "diagnose.major-gc-interval-ms")

withSoakMajorGc :: RunContext -> IO value -> IO value
withSoakMajorGc context = withMajorGcProbe context (majorGcIntervalMs context)

soakLeakSpec :: RunContext -> Double -> LeakSpec
soakLeakSpec context duration =
  defaultLeakSpec
    { probes =
        [ if probe.name == "heap.live-bytes" && majorGcIntervalMs context > 0
            then probe {binding = SeriesBinding "rts-major.csv" "t_mono_ns" "live_bytes" Map.empty}
            else probe
        | probe <- defaultLeakSpec.probes
        ],
      warmupCutSeconds = 0,
      minDurationSeconds = max 30 (duration * 0.7),
      minPoints = 10,
      envelopeWindowSeconds = max 2 (min 30 (duration / 40))
    }
