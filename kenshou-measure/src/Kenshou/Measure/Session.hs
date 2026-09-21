module Kenshou.Measure.Session
  ( MeasureEnv (..),
    MeasureConfig (..),
    Measurement,
    MeasurementReport (..),
    measureEnvFromRunContext,
    phasePlanFromCore,
    measureConfigFromKnobs,
    withMeasurement,
    measurementPhaseClock,
    measurementRecorder,
    measurementConfig,
    measurementEnv,
    appendLoadReport,
  )
where

import Control.Exception (SomeException, mask, throwIO, try)
import Control.Monad (when)
import Data.Aeson (Value)
import Data.IORef
import Data.Text (Text)
import Data.Word (Word64)
import Kenshou.Core.Context qualified as Core
import Kenshou.Core.Dimension (Dimensions (..), renderDurability)
import Kenshou.Core.Env.Postgres (PostgresEnv)
import Kenshou.Core.Id (Kind, ScenarioId (..), unSeed)
import Kenshou.Core.Knob (ResolvedKnobs)
import Kenshou.Core.Knob qualified as Knob
import Kenshou.Core.Log qualified as Log
import Kenshou.Core.Phase qualified as Core
import Kenshou.Measure.Clock
import Kenshou.Measure.Histogram (HistogramConfig (..), defaultHistogramConfig)
import Kenshou.Measure.Load.Types (LoadReport)
import Kenshou.Measure.Phase
import Kenshou.Measure.Recorder
import System.FilePath (makeRelative)

data MeasureEnv = MeasureEnv
  { runDir :: FilePath,
    seed :: Word64,
    origin :: Origin,
    processLabel :: Maybe Text,
    scenarioKind :: Kind,
    pgDurability :: Maybe Text,
    specPhases :: Maybe PhasePlan,
    knobs :: ResolvedKnobs,
    dimensions :: Dimensions,
    postgres :: Maybe PostgresEnv,
    onPhase :: Phase -> Origin -> IO (),
    registerSection :: Text -> Value -> IO (),
    declareArtifact :: FilePath -> Text -> IO (),
    logLine :: Text -> IO ()
  }

data MeasureConfig = MeasureConfig
  { defaultPhases :: PhasePlan,
    histogram :: HistogramConfig,
    rawSamples :: RawSamplePolicy,
    sampleIntervalMs :: Int,
    intervalHistogramSeconds :: Word64
  }
  deriving stock (Eq, Show)

data Measurement = Measurement MeasureEnv PhaseClock Recorder MeasureConfig (IORef [LoadReport])

data MeasurementReport = MeasurementReport
  { recorder :: RecorderReport,
    loads :: [LoadReport]
  }

measureEnvFromRunContext :: Core.RunContext -> IO MeasureEnv
measureEnvFromRunContext context = do
  origin <- captureOrigin
  let ScenarioId _ _ scenarioKind _ = context.scenario
      Dimensions _ _ durability _ = context.dimensions
  pure
    MeasureEnv
      { runDir = context.outDir,
        seed = unSeed context.seed,
        origin,
        processLabel = Nothing,
        scenarioKind,
        pgDurability = renderDurability <$> durability,
        specPhases = Just (phasePlanFromCore context.phases),
        knobs = context.knobs,
        dimensions = context.dimensions,
        postgres = context.env.postgres,
        onPhase = \phase _ -> Log.logAt context.logger Log.Debug ("measurement phase " <> renderPhase phase) [],
        registerSection = Core.putSummary context Core.Measurements,
        declareArtifact = \path mediaType -> Core.declareMediaType context (makeRelative context.outDir path) mediaType,
        logLine = \message -> Log.logAt context.logger Log.Info message []
      }

phasePlanFromCore :: Core.PhasePlan -> PhasePlan
phasePlanFromCore plan =
  PhasePlan
    { warmUp = seconds plan.warmUpSeconds,
      steady = SteadyFor (seconds plan.steadySeconds),
      drain = seconds plan.drainSeconds
    }
  where
    seconds value = Nanos (floor (value * 1_000_000_000))

measureConfigFromKnobs :: Core.RunContext -> PhasePlan -> Either Text MeasureConfig
measureConfigFromKnobs context defaultPhases = do
  rawSamples <- case Knob.knobText context.knobs (knobName "measure.raw-samples") of
    "full" -> Right RawFull
    "sampled" -> Right (RawSampled (fromIntegral (Knob.knobInt context.knobs (knobName "measure.raw-sample-one-in"))))
    "off" -> Right RawOff
    value -> Left ("unknown measure.raw-samples " <> value)
  pure
    MeasureConfig
      { defaultPhases,
        histogram = defaultHistogramConfig {significantDigits = fromIntegral (Knob.knobInt context.knobs (knobName "measure.histogram-digits"))},
        rawSamples,
        sampleIntervalMs = fromIntegral (Knob.knobInt context.knobs (knobName "measure.sample-interval-ms")),
        intervalHistogramSeconds = fromIntegral (Knob.knobInt context.knobs (knobName "measure.interval-histogram-seconds"))
      }

withMeasurement :: Core.RunContext -> MeasureConfig -> (Measurement -> IO value) -> IO (value, MeasurementReport)
withMeasurement context config action = mask \restore -> do
  env <- measureEnvFromRunContext context
  phaseClock <- newPhaseClock env.onPhase config.defaultPhases
  recorder <-
    newRecorder
      RecorderConfig
        { runDir = env.runDir,
          origin = env.origin,
          processLabel = env.processLabel,
          histogram = config.histogram,
          rawSamples = config.rawSamples,
          intervalHistogramSeconds = config.intervalHistogramSeconds,
          declareArtifact = env.declareArtifact
        }
      phaseClock
  loadReports <- newIORef []
  let measurement = Measurement env phaseClock recorder config loadReports
  result <- try (restore (action measurement))
  phase <- currentPhase phaseClock
  when (phase /= Done) (enterPhase phaseClock Done)
  recorderReport <- finishRecorder recorder
  loads <- readIORef loadReports
  case result of
    Left exception -> throwIO (exception :: SomeException)
    Right value -> pure (value, MeasurementReport recorderReport loads)

measurementPhaseClock :: Measurement -> PhaseClock
measurementPhaseClock (Measurement _ phaseClock _ _ _) = phaseClock

measurementRecorder :: Measurement -> Recorder
measurementRecorder (Measurement _ _ recorder _ _) = recorder

measurementConfig :: Measurement -> MeasureConfig
measurementConfig (Measurement _ _ _ config _) = config

measurementEnv :: Measurement -> MeasureEnv
measurementEnv (Measurement env _ _ _ _) = env

appendLoadReport :: Measurement -> LoadReport -> IO ()
appendLoadReport (Measurement _ _ _ _ loadReports) report = modifyIORef' loadReports (<> [report])

knobName :: Text -> Knob.KnobName
knobName = either (error . show) id . Knob.mkKnobName
