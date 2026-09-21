module Kenshou.Measure.Stats
  ( Interval (..),
    exactQuantile,
    arithmeticMean,
    geometricMean,
    coefficientOfVariation,
    bootstrapInterval,
    studentTInterval,
    intervalEnvelope,
  )
where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.List (sort)
import Data.Word (Word64)
import System.Random.SplitMix (mkSMGen, nextWord64)

data Interval = Interval {low :: Double, estimate :: Double, high :: Double}
  deriving stock (Eq, Show)

instance ToJSON Interval where
  toJSON value = object ["low" .= value.low, "estimate" .= value.estimate, "high" .= value.high]

exactQuantile :: Double -> [Double] -> Double
exactQuantile _ [] = 0
exactQuantile quantile values =
  let ordered = sort values
      position = max 0 (min 1 quantile) * fromIntegral (length ordered - 1)
      lower = floor position
      upper = ceiling position
      fraction = position - fromIntegral lower
   in ordered !! lower * (1 - fraction) + ordered !! upper * fraction

arithmeticMean :: [Double] -> Double
arithmeticMean [] = 0
arithmeticMean values = sum values / fromIntegral (length values)

geometricMean :: [Double] -> Double
geometricMean [] = 0
geometricMean values = exp (arithmeticMean (fmap log values))

coefficientOfVariation :: [Double] -> Double
coefficientOfVariation values =
  let mean = arithmeticMean values
      variance = if length values < 2 then 0 else sum [square (value - mean) | value <- values] / fromIntegral (length values - 1)
   in if mean == 0 then 0 else sqrt variance / abs mean
  where
    square value = value * value

bootstrapInterval :: Word64 -> Int -> Double -> ([Double] -> Double) -> [Double] -> Interval
bootstrapInterval _ _ _ _ [] = Interval 0 0 0
bootstrapInterval seed iterations confidence statistic values =
  let estimates = take (max 1 iterations) (resamples (mkSMGen seed))
      alpha = (1 - confidence) / 2
   in Interval (exactQuantile alpha estimates) (statistic values) (exactQuantile (1 - alpha) estimates)
  where
    count = length values
    resamples generator =
      let (sample, next) = draw count generator []
       in statistic sample : resamples next
    draw 0 generator accumulated = (accumulated, generator)
    draw remaining generator accumulated =
      let (word, next) = nextWord64 generator
          value = values !! fromIntegral (word `mod` fromIntegral count)
       in draw (remaining - 1) next (value : accumulated)

studentTInterval :: Double -> [Double] -> Interval
studentTInterval _ [] = Interval 0 0 0
studentTInterval _ values =
  let mean = arithmeticMean values
      count = length values
      variance = if count < 2 then 0 else sum [(value - mean) ^ (2 :: Int) | value <- values] / fromIntegral (count - 1)
      margin = critical (count - 1) * sqrt variance / sqrt (fromIntegral count)
   in Interval (mean - margin) mean (mean + margin)

intervalEnvelope :: Interval -> Interval -> Interval
intervalEnvelope left right = Interval (min left.low right.low) left.estimate (max left.high right.high)

critical :: Int -> Double
critical degrees
  | degrees <= 0 = 0
  | degrees <= length table = table !! (degrees - 1)
  | otherwise = 1.96
  where
    table = [12.706, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365, 2.306, 2.262, 2.228, 2.201, 2.179, 2.160, 2.145, 2.131, 2.120, 2.110, 2.101, 2.093, 2.086, 2.080, 2.074, 2.069, 2.064, 2.060, 2.056, 2.052, 2.048, 2.045]
