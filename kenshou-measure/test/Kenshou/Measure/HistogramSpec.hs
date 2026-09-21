module Kenshou.Measure.HistogramSpec (spec) where

import Control.Monad (replicateM_)
import Data.ByteString qualified as ByteString
import Data.Char (digitToInt, isHexDigit)
import Data.Either (isLeft)
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Data.Word (Word64)
import Hedgehog
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Kenshou.Measure.Histogram
import Kenshou.Measure.Histogram.Codec
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "Kenshou.Measure.Histogram" do
  it "keeps exact aggregates and bounded quantiles" do
    histogram <- build [1_000, 2_048, 2_000_000, 3_600_000_000_000]
    totalCount histogram `shouldBe` 4
    minValue histogram `shouldBe` 1_000
    maxValue histogram `shouldBe` 3_600_000_000_000
    valueAtQuantile histogram 0.5 `shouldSatisfy` \value -> value >= 2_048 && value <= 2_050
    valueAtQuantile histogram 1 `shouldBe` 3_600_000_000_000

  it "stays within the configured 0.1 percent equivalent range" $ hedgehog do
    value <- forAll (Gen.word64 (Range.linear 1 3_600_000_000_000))
    (low, high) <- evalEither (equivalentRange defaultHistogramConfig value)
    assert (low <= value && high >= value)
    assert (high - low <= max 1 (value `div` 1_000))

  it "merges without changing the recorded distribution" do
    left <- build [1, 2, 3]
    right <- build [4, 5, 6]
    together <- build [1, 2, 3, 4, 5, 6]
    merge left right `shouldBe` Right together
    merge right left `shouldBe` Right together

  it "round-trips the KHST version 1 codec" do
    histogram <- build ([0 .. 10_000] <> [2_000_000, 3_600_000_000_001])
    decodeHistogram (encodeHistogram histogram) `shouldBe` Right histogram

  it "keeps the KHST version 1 golden bytes stable" do
    histogram <- build [1, 1_000, 2_000_000]
    golden <- decodeHex . filter isHexDigit <$> readFile "test/golden/histogram-v1.hex"
    encodeHistogram histogram `shouldBe` golden

  it "records ten million samples inside the cost budget" do
    mutable <- newHistogram defaultHistogramConfig
    started <- getCurrentTime
    replicateM_ 10_000_000 (recordValue mutable 1_000)
    finished <- getCurrentTime
    total <- totalCount <$> freeze mutable
    total `shouldBe` 10_000_000
    realToFrac (diffUTCTime finished started) `shouldSatisfy` (< (2.5 :: Double))

  it "rejects a mismatched merge configuration" do
    left <- build [1]
    mutable <- newHistogram (HistogramConfig 1 10_000 2)
    recordValue mutable 1
    right <- freeze mutable
    merge left right `shouldSatisfy` isLeft

build :: [Word64] -> IO Histogram
build values = do
  mutable <- newHistogram defaultHistogramConfig
  mapM_ (recordValue mutable) values
  freeze mutable

decodeHex :: String -> ByteString.ByteString
decodeHex [] = ByteString.empty
decodeHex (high : low : rest) = ByteString.cons (fromIntegral (digitToInt high * 16 + digitToInt low)) (decodeHex rest)
decodeHex _ = error "golden hex has an odd number of digits"
