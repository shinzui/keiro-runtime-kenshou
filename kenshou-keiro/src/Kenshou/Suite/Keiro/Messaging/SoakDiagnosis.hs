module Kenshou.Suite.Keiro.Messaging.SoakDiagnosis
  ( majorGcKnob,
    majorGcIntervalMs,
    withSoakMajorGc,
    soakLeakSpec,
    processLeakSpec,
    withRoleSamples,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (link, withAsync)
import Control.Exception (bracket)
import Control.Monad (forever, when)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import GHC.Clock (getMonotonicTimeNSec)
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobInt, mkKnobName)
import Kenshou.Core.Role (RoleContext (..), WorkerInit (..))
import Kenshou.Diagnose.Leak (LeakSpec (..), ProbeSpec (..), defaultLeakSpec)
import Kenshou.Diagnose.Leak.MajorGcProbe (withMajorGcProbe)
import Kenshou.Diagnose.Series (SeriesBinding (..))
import Kenshou.Measure.Sampler.Process qualified as ProcessSample
import Kenshou.Measure.Sampler.Rts (closeRtsSampler, openRtsSampler, sampleRts)
import System.FilePath ((</>))
import System.Mem (performMajorGC)

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

processLeakSpec :: FilePath -> LeakSpec -> LeakSpec
processLeakSpec prefix (LeakSpec probes warmup points duration envelope resamples confidence) =
  LeakSpec
    [ probe {binding = if probe.name == "heap.live-bytes" then probe.binding {file = prefix </> "rts.csv", valueColumn = "live_bytes_last_gc"} else probe.binding {file = prefix </> probe.binding.file}}
    | probe <- probes,
      probe.name `elem` ["heap.live-bytes", "process.native-bytes", "haskell.threads", "os.threads", "os.fds"]
    ]
    warmup
    points
    duration
    envelope
    resamples
    confidence

withRoleSamples :: RoleContext -> IO value -> IO value
withRoleSamples context action = bracket open close \(rts, process, start) -> withAsync (sampleLoop rts process start) \sampler -> link sampler >> action
  where
    directory = context.init.outDir </> "series" </> "children" </> Text.unpack (Text.replace "/" "-" context.init.instanceName)
    open = do
      rts <- openRtsSampler (directory </> "rts.csv")
      process <- ProcessSample.openProcessSampler (directory </> "proc.csv")
      start <- getMonotonicTimeNSec
      pure (rts, process, start)
    close (rts, process, _) = maybe (pure ()) closeRtsSampler rts >> ProcessSample.closeProcessSampler process
    sampleLoop rts process start = do
      lastMajor <- newIORef start
      forever do
        now <- getMonotonicTimeNSec
        previous <- readIORef lastMajor
        let interval = fromIntegral (knobInt context.init.knobs (either (error . show) id (mkKnobName "diagnose.major-gc-interval-ms"))) * 1000000
        when (interval > 0 && now - previous >= interval) (performMajorGC >> writeIORef lastMajor now)
        wall <- getPOSIXTime
        let prefix = [Text.pack (show (now - start)), Text.pack (show (round (wall * 1000) :: Integer)), "steady"]
        maybe (pure ()) (\sampler -> sampleRts sampler prefix) rts
        ProcessSample.sampleProcess process prefix
        threadDelay 1000000
