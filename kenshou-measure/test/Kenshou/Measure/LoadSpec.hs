module Kenshou.Measure.LoadSpec (spec) where

import Kenshou.Measure.Load.Arrival
import System.Random.SplitMix (mkSMGen)
import Test.Hspec

spec :: Spec
spec = describe "Kenshou.Measure.Load.Arrival" do
  it "uses exact constant-rate spacing" do
    constantSchedule 100 1_000 5 `shouldBe` [1_000, 10_001_000, 20_001_000, 30_001_000, 40_001_000]

  it "replays Poisson schedules from the same seed" do
    let first = poissonSchedule 100 (mkSMGen 42) 0 1_000
        second = poissonSchedule 100 (mkSMGen 42) 0 1_000
    first `shouldBe` second

  it "keeps the Poisson mean near the requested rate" do
    let arrivals = poissonSchedule 100 (mkSMGen 42) 0 20_000
        gaps = zipWith (-) arrivals (0 : arrivals)
        meanGap = fromIntegral (sum gaps) / fromIntegral (length gaps) :: Double
    meanGap `shouldSatisfy` \value -> value > 9_700_000 && value < 10_300_000
