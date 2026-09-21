module Kenshou.Diagnose.StatsSpec (spec) where

import Data.Vector qualified as Vector
import Kenshou.Diagnose.Stats
import Test.Hspec

spec :: Spec
spec = describe "Kenshou.Diagnose.Stats" do
  it "recovers an exact line" do
    fmap fst (theilSen (line 2 10)) `shouldBe` Just 2

  it "resists twenty percent large outliers" do
    let points = Vector.imap (\index point -> if index `mod` 5 == 0 then (fst point, snd point + 10_000) else point) (line 3 100)
    fmap fst (theilSen points) `shouldSatisfy` maybe False (\slope -> abs (slope - 3) < 0.01)

  it "returns a deterministic moving-block interval containing the exact slope" do
    let first = slopeWithInterval 42 200 0.95 (line 4 80)
        second = slopeWithInterval 42 200 0.95 (line 4 80)
    first `shouldBe` second
    first `shouldSatisfy` maybe False (\estimate -> estimate.low <= 4 && estimate.high >= 4)

  it "covers the known slope for at least ninety of one hundred bootstrap seeds" do
    let points = Vector.fromList [(fromIntegral index, 5 * fromIntegral index + correlatedNoise index) | index <- [0 .. 39 :: Int]]
        contains seed = maybe False (\estimate -> estimate.low <= 5 && estimate.high >= 5) (slopeWithInterval seed 80 0.95 points)
    length (filter contains [1 .. 100]) `shouldSatisfy` (>= 90)

  it "reduces sawtooth windows by their minima" do
    let points = Vector.fromList [(0, 10), (1, 20), (2, 11), (3, 30)]
    windowMinima 2 points `shouldBe` Vector.fromList [(0, 10), (2, 11)]
  where
    line :: Double -> Int -> Vector.Vector (Double, Double)
    line slope count = Vector.fromList [(fromIntegral index, slope * fromIntegral index + 7) | index <- [0 .. count - 1]]
    correlatedNoise index = if index >= 10 && index < 18 then 10 else 0
