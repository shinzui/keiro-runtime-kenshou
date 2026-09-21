module Kenshou.Measure.SamplesSpec (spec) where

import Data.IORef
import Kenshou.Measure.Clock
import Kenshou.Measure.Samples
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "Kenshou.Measure.Samples" do
  it "round-trips worker blocks through KSMP version 1" $ withSystemTempDirectory "kenshou-samples" \directory -> do
    origin <- captureOrigin
    let path = directory </> "request.raw"
        records =
          [ SampleRecord (origin.monoNs + 10) (origin.monoNs + 12) (origin.monoNs + 22) 0 1,
            SampleRecord (origin.monoNs + 30) (origin.monoNs + 35) (origin.monoNs + 50) 1 0
          ]
    writer <- openSampleWriter path (SampleHeader origin MonotonicClock "request" "harness")
    writeSampleBlock writer 3 records
    closeSampleWriter writer
    observed <- newIORef []
    report <- readSamples path (\record -> modifyIORef' observed (<> [record]))
    readIORef observed `shouldReturn` records
    let SampleFileReport _ recordsRead ignoredBytes = report
    recordsRead `shouldBe` 2
    ignoredBytes `shouldBe` 0
