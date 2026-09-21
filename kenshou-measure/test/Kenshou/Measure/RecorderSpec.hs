module Kenshou.Measure.RecorderSpec (spec) where

import Data.ByteString qualified as ByteString
import Data.IORef
import Kenshou.Measure.Clock
import Kenshou.Measure.Histogram qualified as Histogram
import Kenshou.Measure.Histogram.Codec (decodeHistogram)
import Kenshou.Measure.Phase
import Kenshou.Measure.Recorder
import Kenshou.Measure.Samples (SampleFileReport (..), SampleRecord (..), readSamples)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "Kenshou.Measure.Recorder" do
  it "retains warm-up raw samples while excluding them from steady histograms" $ withSystemTempDirectory "kenshou-recorder" \directory -> do
    origin <- captureOrigin
    clock <- newPhaseClock (\_ _ -> pure ()) (PhasePlan (Nanos 1) (SteadyFor (Nanos 1)) (Nanos 1))
    recorder <-
      newRecorder
        RecorderConfig
          { runDir = directory,
            origin,
            processLabel = Nothing,
            histogram = Histogram.defaultHistogramConfig,
            rawSamples = RawFull,
            intervalHistogramSeconds = 10,
            declareArtifact = \_ _ -> pure ()
          }
        clock
    operation <- registerOp recorder (OpName "request")
    worker <- newWorkerRecorder operation 1
    enterPhase clock WarmUp
    warm <- nowNs
    recordOp worker warm warm (warm + 10) (OpOk 1)
    enterPhase clock Steady
    steady <- nowNs
    recordOp worker steady steady (steady + 20) (OpOk 1)
    recordOp worker (steady + 30) (steady + 35) (steady + 60) (OpFailed (ErrorCause "store"))
    report <- finishRecorder recorder
    case report.operations of
      [operationReport] -> do
        Histogram.totalCount operationReport.latency `shouldBe` 2
        Histogram.valueAtQuantile operationReport.latency 1 `shouldBe` 30
        doesFileExist (directory </> "samples/request.hist") `shouldReturn` True
        encoded <- ByteString.readFile (directory </> "samples/request.hist")
        fmap Histogram.totalCount (decodeHistogram encoded) `shouldBe` Right 2
        rawCount <- newIORef (0 :: Int)
        recomputedMutable <- Histogram.newHistogram Histogram.defaultHistogramConfig
        rawReport <- readSamples (directory </> "samples/request.raw") \(SampleRecord intended _ end _ _) -> do
          modifyIORef' rawCount (+ 1)
          if intended >= steady then Histogram.recordValue recomputedMutable (end - intended) else pure ()
        readIORef rawCount `shouldReturn` 3
        recomputed <- Histogram.freeze recomputedMutable
        recomputed `shouldBe` operationReport.latency
        let SampleFileReport _ _ ignored = rawReport
        ignored `shouldBe` 0
      unexpected -> expectationFailure ("expected one operation report, got " <> show (length unexpected))

  it "writes interval histograms when full raw retention is disabled" $ withSystemTempDirectory "kenshou-intervals" \directory -> do
    origin <- captureOrigin
    clock <- newPhaseClock (\_ _ -> pure ()) (PhasePlan (Nanos 1) (SteadyFor (Nanos 1)) (Nanos 1))
    recorder <-
      newRecorder
        RecorderConfig
          { runDir = directory,
            origin,
            processLabel = Nothing,
            histogram = Histogram.defaultHistogramConfig,
            rawSamples = RawOff,
            intervalHistogramSeconds = 10,
            declareArtifact = \_ _ -> pure ()
          }
        clock
    operation <- registerOp recorder (OpName "request")
    worker <- newWorkerRecorder operation 1
    enterPhase clock Steady
    started <- nowNs
    recordOp worker started started (started + 50) (OpOk 1)
    report <- finishRecorder recorder
    case report.operations of
      [operationReport] -> do
        operationReport.rawFile `shouldBe` Nothing
        operationReport.intervalHistogramFile `shouldBe` Just (directory </> "samples/request.ihist")
        doesFileExist (directory </> "samples/request.ihist") `shouldReturn` True
      unexpected -> expectationFailure ("expected one operation report, got " <> show (length unexpected))
