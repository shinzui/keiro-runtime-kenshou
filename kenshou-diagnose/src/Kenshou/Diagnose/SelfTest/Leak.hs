module Kenshou.Diagnose.SelfTest.Leak
  ( leakingWorkerScenario,
    stableWorkerScenario,
  )
where

import Control.Concurrent (MVar, ThreadId, killThread, newEmptyMVar, takeMVar, threadDelay)
import Control.Exception (bracket, evaluate, finally)
import Control.Monad (forM, forM_, replicateM, void)
import Data.ByteString qualified as ByteString
import Data.ByteString.Short (ShortByteString)
import Data.ByteString.Short qualified as Short
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Dimension
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (Kind (Soak), ScenarioId, parseScenarioId)
import Kenshou.Core.Knob
import Kenshou.Core.Phase qualified as Core
import Kenshou.Core.Scenario
import Kenshou.Diagnose.Leak
import Kenshou.Diagnose.Leak.MajorGcProbe (withMajorGcProbe)
import Kenshou.Diagnose.Series (SeriesBinding (..))
import Kenshou.Diagnose.Threads (forkLabelled)
import Kenshou.Measure.Clock (Nanos (..))
import Kenshou.Measure.Knobs (measureKnobs)
import Kenshou.Measure.Phase qualified as Measure
import Kenshou.Measure.Sampler
import Kenshou.Measure.Session (MeasureEnv (..), measureEnvFromRunContext)
import System.IO (Handle, IOMode (ReadMode), hClose, openFile)

leakingWorkerScenario :: Scenario
leakingWorkerScenario =
  Scenario
    { id = scenarioId "selftest/diagnose/soak/leaking-worker",
      revision = 1,
      summary = "Proves that bounded heap, thread, and descriptor growth is detected.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = leakKnobs <> samplingKnobs,
      dimensions = telemetryOff,
      phases = Core.PhasePlan 5 40 0,
      requires = noEnvironment,
      knownDefect = Nothing,
      run = runLeakingWorker
    }

stableWorkerScenario :: Scenario
stableWorkerScenario =
  Scenario
    { id = scenarioId "selftest/diagnose/soak/stable-worker",
      revision = 1,
      summary = "Proves that high allocation into a bounded retained ring remains stable.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = stableKnobs <> samplingKnobs,
      dimensions = telemetryOff,
      phases = Core.PhasePlan 10 35 0,
      requires = noEnvironment,
      knownDefect = Nothing,
      run = runStableWorker
    }

data LeakResources
  = HeapResources (IORef [ShortByteString])
  | ThreadResources (MVar ()) (IORef [ThreadId])
  | DescriptorResources (IORef [Handle])

runLeakingWorker :: RunContext -> IO ScenarioReport
runLeakingWorker context = do
  let kind = knobText context.knobs (name "leak.kind")
      duration = fromIntegral (knobInt context.knobs (name "run.duration-s"))
      warmup = min duration (fromIntegral (knobInt context.knobs (name "run.warmup-s")))
      majorGcMs = fromIntegral (knobInt context.knobs (name "diagnose.major-gc-interval-ms"))
      bytesPerSecond = fromIntegral (knobInt context.knobs (name "leak.bytes-per-second"))
      unitsPerSecond = fromIntegral (knobInt context.knobs (name "leak.units-per-second"))
      chunkBytes = fromIntegral (knobInt context.knobs (name "leak.chunk-bytes"))
      targetRate = if kind == "heap" then fromIntegral bytesPerSecond else fromIntegral unitsPerSecond
  bracket (newResources kind) cleanupResources $ \resources -> do
    _ <- withMajorGcProbe context majorGcMs $ withSelfTestSampling context \clock -> do
      Measure.enterPhase clock Measure.WarmUp
      produceFor warmup (produce kind resources bytesPerSecond unitsPerSecond chunkBytes)
      Measure.enterPhase clock Measure.Steady
      produceFor (duration - warmup) (produce kind resources bytesPerSecond unitsPerSecond chunkBytes)
    report <- judgeLeaks context (leakingSpec kind majorGcMs duration warmup targetRate)
    pure (assessLeak kind targetRate report)

runStableWorker :: RunContext -> IO ScenarioReport
runStableWorker context = do
  let duration = fromIntegral (knobInt context.knobs (name "run.duration-s"))
      warmup = min duration (fromIntegral (knobInt context.knobs (name "run.warmup-s")))
      majorGcMs = fromIntegral (knobInt context.knobs (name "diagnose.major-gc-interval-ms"))
      bytesPerSecond = fromIntegral (knobInt context.knobs (name "alloc.bytes-per-second"))
      ringBytes = fromIntegral (knobInt context.knobs (name "retain.ring-bytes"))
      chunkBytes = 4096
  retained <- newIORef []
  allocated <- newIORef (0 :: Int)
  _ <- withMajorGcProbe context majorGcMs $ withSelfTestSampling context \clock -> do
    Measure.enterPhase clock Measure.WarmUp
    stableFor warmup retained allocated bytesPerSecond ringBytes chunkBytes
    Measure.enterPhase clock Measure.Steady
    stableFor (duration - warmup) retained allocated bytesPerSecond ringBytes chunkBytes
  report <- judgeLeaks context (stableSpec majorGcMs duration warmup)
  total <- readIORef allocated
  let heap = findProbe "heap.live-bytes" report
      enoughAllocation = total > 5 * ringBytes
  pure case heap of
    Nothing -> inconclusiveBecause "heap.live-bytes was not reported"
    Just probe
      | probe.verdict == InsufficientData -> inconclusiveBecause ("heap evidence is insufficient: " <> probe.reason)
      | probe.verdict == Stable && enoughAllocation -> passed
      | otherwise -> failedWith ["stable-worker-verdict"] ("heap verdict=" <> showText probe.verdict <> ", allocated=" <> showText total)

withSelfTestSampling :: RunContext -> (Measure.PhaseClock -> IO value) -> IO value
withSelfTestSampling context action = do
  environment <- measureEnvFromRunContext context
  clock <- Measure.newPhaseClock environment.onPhase (Measure.PhasePlan (Nanos 0) (Measure.SteadyCount 0) (Nanos 0))
  sampling <-
    startSampling
      SamplerConfig
        { runDir = environment.runDir,
          origin = environment.origin,
          intervalMs = 500,
          postgres = Nothing,
          extraSamplers = [],
          phaseClock = clock,
          declareArtifact = environment.declareArtifact,
          logLine = environment.logLine
        }
  action clock `finally` void (stopSampling sampling)

newResources :: Text -> IO LeakResources
newResources "heap" = HeapResources <$> newIORef []
newResources "threads" = ThreadResources <$> newEmptyMVar <*> newIORef []
newResources "fds" = DescriptorResources <$> newIORef []
newResources other = ioError (userError ("unknown leak.kind " <> Text.unpack other))

cleanupResources :: LeakResources -> IO ()
cleanupResources (HeapResources retained) = writeIORef retained []
cleanupResources (ThreadResources _ threads) = readIORef threads >>= mapM_ killThread
cleanupResources (DescriptorResources handles) = readIORef handles >>= mapM_ hClose

produce :: Text -> LeakResources -> Int -> Int -> Int -> Int -> IO ()
produce "heap" (HeapResources retained) bytesPerSecond _ chunkBytes step = do
  chunks <- freshChunks bytesPerSecond chunkBytes step
  modifyIORef' retained (chunks <>)
produce "threads" (ThreadResources blocker threads) _ unitsPerSecond _ _ = do
  spawned <- replicateM unitsPerSecond (forkLabelled "kenshou:selftest:leaked-thread" (waitForever blocker))
  modifyIORef' threads (spawned <>)
produce "fds" (DescriptorResources handles) _ unitsPerSecond _ _ = do
  opened <- replicateM unitsPerSecond (openFile "/dev/null" ReadMode)
  modifyIORef' handles (opened <>)
produce _ _ _ _ _ _ = ioError (userError "leak resource does not match leak.kind")

waitForever :: MVar () -> IO ()
waitForever blocker = do
  _ <- takeMVar blocker
  pure ()

produceFor :: Int -> (Int -> IO ()) -> IO ()
produceFor seconds action = forM_ [0 .. seconds - 1] \step -> action step >> threadDelay 1_000_000

stableFor :: Int -> IORef [ShortByteString] -> IORef Int -> Int -> Int -> Int -> IO ()
stableFor seconds retained allocated bytesPerSecond ringBytes chunkBytes =
  forM_ [0 .. seconds - 1] \step -> do
    chunks <- freshChunks bytesPerSecond chunkBytes step
    previous <- readIORef retained
    let bounded = take (max 1 (ringBytes `div` chunkBytes)) (chunks <> previous)
    _ <- evaluate (sum (fmap Short.length bounded))
    writeIORef retained bounded
    modifyIORef' allocated (+ sum (fmap Short.length chunks))
    threadDelay 1_000_000

freshChunks :: Int -> Int -> Int -> IO [ShortByteString]
freshChunks bytesPerSecond chunkBytes step = do
  let count = max 1 ((bytesPerSecond + chunkBytes - 1) `div` chunkBytes)
      byte = fromIntegral (step `mod` 251)
  forM [1 .. count] \index -> do
    let remaining = bytesPerSecond - (index - 1) * chunkBytes
        size = max 1 (min chunkBytes remaining)
        chunk = Short.toShort (ByteString.replicate size byte)
    Short.length chunk `seq` pure chunk

leakingSpec :: Text -> Double -> Int -> Int -> Double -> LeakSpec
leakingSpec kind majorGcMs duration warmup targetRate =
  defaultLeakSpec
    { probes = fmap tune defaultLeakSpec.probes,
      warmupCutSeconds = if majorGcMs > 0 then 0 else fromIntegral warmup,
      minPoints = max 5 (min 20 (duration - warmup - 2)),
      minDurationSeconds = max 5 (fromIntegral (duration - warmup) * 0.7),
      envelopeWindowSeconds = 1,
      resamples = 300
    }
  where
    target = targetProbe kind
    tune probe
      | probe.name == target =
          probe
            { binding = if kind == "heap" && majorGcMs > 0 then SeriesBinding "rts-major.csv" "t_mono_ns" "live_bytes" Map.empty else probe.binding,
              floorPerHour = targetRate * 1800,
              minGrowth = targetRate * fromIntegral (duration - warmup) * 0.25,
              minRelativeGrowth = 0
            }
      | otherwise = probe {floorPerHour = 1.0e30, minGrowth = 1.0e30, minRelativeGrowth = 0}

stableSpec :: Double -> Int -> Int -> LeakSpec
stableSpec majorGcMs duration warmup =
  defaultLeakSpec
    { probes = fmap tune defaultLeakSpec.probes,
      warmupCutSeconds = if majorGcMs > 0 then 0 else fromIntegral warmup,
      minPoints = max 5 (min 20 (duration - warmup - 2)),
      minDurationSeconds = max 5 (fromIntegral (duration - warmup) * 0.7),
      envelopeWindowSeconds = 1,
      resamples = 300
    }
  where
    tune :: ProbeSpec -> ProbeSpec
    tune probe
      | probe.name == "heap.live-bytes" = probe {binding = if majorGcMs > 0 then SeriesBinding "rts-major.csv" "t_mono_ns" "live_bytes" Map.empty else probe.binding}
      | otherwise = ProbeSpec probe.name probe.unit probe.binding probe.aggregation Informational probe.floorPerHour probe.minGrowth probe.minRelativeGrowth probe.limit

assessLeak :: Text -> Double -> LeakReport -> ScenarioReport
assessLeak kind expectedRate report = case findProbe (targetProbe kind) report of
  Nothing -> inconclusiveBecause ("target probe was not reported: " <> targetProbe kind)
  Just probe
    | probe.verdict == InsufficientData -> inconclusiveBecause ("target probe evidence is insufficient: " <> probe.reason)
    | otherwise ->
        let actualRate = (/ 3600) <$> probe.slopePerHour
            tolerance = if kind == "heap" then 0.15 else 0.20
            rateOk = maybe False (\actual -> abs (actual - expectedRate) <= expectedRate * tolerance) actualRate
            intervalOk = case (probe.slopePerHour, probe.intervalPerHour) of
              (Just slope, Just (low, high)) -> low <= slope && slope <= high
              _ -> False
            unrelated = [candidate.probe | candidate <- report.probes, candidate.probe /= probe.probe, candidate.expectation == Bounded, candidate.verdict == LeakSuspected]
            failures = ["target-verdict" | probe.verdict /= LeakSuspected] <> ["target-rate" | not rateOk] <> ["target-interval" | not intervalOk] <> ["unrelated-probe" | not (null unrelated)]
         in if null failures
              then passed
              else failedWith failures ("expected " <> targetProbe kind <> " at " <> showText expectedRate <> "/s; actual=" <> showText actualRate <> "; unrelated=" <> showText unrelated)

findProbe :: Text -> LeakReport -> Maybe ProbeReport
findProbe wanted report = case filter ((== wanted) . (.probe)) report.probes of
  value : _ -> Just value
  [] -> Nothing

targetProbe :: Text -> Text
targetProbe "heap" = "heap.live-bytes"
targetProbe "threads" = "haskell.threads"
targetProbe "fds" = "os.fds"
targetProbe other = error ("unknown leak kind " <> Text.unpack other)

leakKnobs :: [KnobSpec]
leakKnobs =
  [ textKnob "leak.kind" "Resource retained by the worker" "heap" ["heap", "threads", "fds"],
    intKnob "leak.bytes-per-second" "Heap bytes retained each second" 1_048_576 65_536 67_108_864,
    intKnob "leak.units-per-second" "Threads or descriptors retained each second" 5 1 1_000,
    intKnob "leak.chunk-bytes" "Size of each retained heap chunk" 4_096 256 1_048_576,
    intKnob "run.duration-s" "Run duration" 45 20 3_600,
    intKnob "run.warmup-s" "Warm-up duration" 5 0 600,
    intKnob "diagnose.major-gc-interval-ms" "Forced major-GC interval, or zero to disable" 1_000 0 60_000
  ]

stableKnobs :: [KnobSpec]
stableKnobs =
  [ intKnob "alloc.bytes-per-second" "Bytes allocated each second" 8_388_608 65_536 67_108_864,
    intKnob "retain.ring-bytes" "Maximum bytes retained in the ring" 33_554_432 65_536 536_870_912,
    intKnob "run.duration-s" "Run duration" 45 20 3_600,
    intKnob "run.warmup-s" "Warm-up duration" 10 0 600,
    intKnob "diagnose.major-gc-interval-ms" "Forced major-GC interval, or zero to disable" 1_000 0 60_000
  ]

samplingKnobs :: [KnobSpec]
samplingKnobs = fmap setInterval (measureKnobs Soak)
  where
    setInterval :: KnobSpec -> KnobSpec
    setInterval spec
      | renderKnobName spec.name == "measure.sample-interval-ms" = KnobSpec spec.name spec.summary spec.knobType (VInt 500) spec.allowed spec.variants
      | otherwise = spec

telemetryOff :: DimensionSupport
telemetryOff =
  DimensionSupport
    (Supported (Support (TracingOff :| []) TracingOff))
    (Supported (Support (MetricsOff :| []) MetricsOff))
    NotApplicable
    NotApplicable

intKnob :: Text -> Text -> Int -> Int -> Int -> KnobSpec
intKnob knobName summary def low high = KnobSpec (name knobName) summary KnobInt (VInt (fromIntegral def)) (IntRange (fromIntegral low) (fromIntegral high)) []

textKnob :: Text -> Text -> Text -> [Text] -> KnobSpec
textKnob knobName summary def (first : rest) = KnobSpec (name knobName) summary KnobText (VText def) (OneOf (VText first :| fmap VText rest)) []
textKnob knobName _ _ [] = error ("no values for " <> Text.unpack knobName)

name :: Text -> KnobName
name = either (error . show) id . mkKnobName

scenarioId :: Text -> ScenarioId
scenarioId = either (error . show) id . parseScenarioId

showText :: (Show value) => value -> Text
showText = Text.pack . show
