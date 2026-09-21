module Kenshou.Diagnose.Stats
  ( SlopeEstimate (..),
    theilSen,
    slopeWithInterval,
    windowMinima,
    windowMedians,
  )
where

import Data.List (sort)
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import Data.Word (Word64)
import System.Random.SplitMix (SMGen, mkSMGen, nextWord64)

data SlopeEstimate = SlopeEstimate
  { slope :: !Double,
    intercept :: !Double,
    low :: !Double,
    high :: !Double,
    points :: !Int,
    resamples :: !Int,
    blockLength :: !Int
  }
  deriving stock (Eq, Show)

theilSen :: Vector (Double, Double) -> Maybe (Double, Double)
theilSen original
  | Vector.length samples < 2 = Nothing
  | null slopes = Nothing
  | otherwise = Just (estimate, median [y - estimate * x | (x, y) <- Vector.toList samples])
  where
    samples = capPoints original
    indexed = Vector.toList (Vector.indexed samples)
    slopes =
      [ (y2 - y1) / (x2 - x1)
      | (index, (x1, y1)) <- indexed,
        (_, (x2, y2)) <- drop (index + 1) indexed,
        x2 /= x1
      ]
    estimate = median slopes

slopeWithInterval :: Word64 -> Int -> Double -> Vector (Double, Double) -> Maybe SlopeEstimate
slopeWithInterval seed requested confidence values = do
  (estimate, intercept) <- theilSen values
  let count = Vector.length values
      block = max 1 (ceiling (sqrt (fromIntegral count :: Double)))
      iterations = max 1 requested
      residuals = Vector.map (\(x, y) -> (x, y - (estimate * x + intercept))) values
      estimates = take iterations (bootstrapSlopes block estimate intercept residuals (mkSMGen seed))
      alpha = max 0 (min 0.5 ((1 - confidence) / 2))
  pure
    SlopeEstimate
      { slope = estimate,
        intercept,
        low = quantile alpha estimates,
        high = quantile (1 - alpha) estimates,
        points = count,
        resamples = iterations,
        blockLength = block
      }

windowMinima :: Double -> Vector (Double, Double) -> Vector (Double, Double)
windowMinima width = windowBy width minimumPoint
  where
    minimumPoint values = minimumByValue values

windowMedians :: Double -> Vector (Double, Double) -> Vector (Double, Double)
windowMedians width = windowBy width medianPoint
  where
    medianPoint values =
      let ordered = sortOnValue values
       in ordered !! ((length ordered - 1) `div` 2)

windowBy :: Double -> ([(Double, Double)] -> (Double, Double)) -> Vector (Double, Double) -> Vector (Double, Double)
windowBy width choose values
  | width <= 0 = values
  | Vector.null values = Vector.empty
  | otherwise = Vector.fromList (fmap choose (groups (Vector.toList values)))
  where
    origin = fst (Vector.head values)
    bucket (time, _) = floor ((time - origin) / width) :: Int
    groups [] = []
    groups (first : rest) =
      let key = bucket first
          (same, remaining) = span ((== key) . bucket) rest
       in (first : same) : groups remaining

capPoints :: Vector (Double, Double) -> Vector (Double, Double)
capPoints values
  | Vector.length values <= 2000 = values
  | otherwise =
      let width = fromIntegral (Vector.length values) / 2000 :: Double
          groups = chunk (ceiling width) (Vector.toList values)
       in Vector.fromList (fmap medianPoint groups)
  where
    medianPoint group = sortOnValue group !! ((length group - 1) `div` 2)

bootstrapSlopes :: Int -> Double -> Double -> Vector (Double, Double) -> SMGen -> [Double]
bootstrapSlopes _ _ _ values _ | Vector.length values < 2 = []
bootstrapSlopes block baseEstimate intercept values generator =
  let (sampledResiduals, next) = movingBlockSample block values generator
      sample = Vector.map (\(x, residual) -> (x, baseEstimate * x + intercept + residual)) sampledResiduals
      bootstrapEstimate = maybe 0 fst (theilSen sample)
   in bootstrapEstimate : bootstrapSlopes block baseEstimate intercept values next

movingBlockSample :: Int -> Vector (Double, Double) -> SMGen -> (Vector (Double, Double), SMGen)
movingBlockSample block values initial =
  let count = Vector.length values
      blockCount = ceiling (fromIntegral count / fromIntegral block :: Double)
      (starts, final) = drawStarts blockCount count initial []
      sampledY = take count [snd (values Vector.! ((start + offset) `mod` count)) | start <- starts, offset <- [0 .. block - 1]]
      sampledX = fmap fst (Vector.toList values)
   in (Vector.fromList (zip sampledX sampledY), final)

drawStarts :: Int -> Int -> SMGen -> [Int] -> ([Int], SMGen)
drawStarts 0 _ generator accumulated = (reverse accumulated, generator)
drawStarts remaining count generator accumulated =
  let (word, next) = nextWord64 generator
      start = fromIntegral (word `mod` fromIntegral count)
   in drawStarts (remaining - 1) count next (start : accumulated)

quantile :: Double -> [Double] -> Double
quantile _ [] = 0
quantile fraction values =
  let ordered = sort values
      position = max 0 (min 1 fraction) * fromIntegral (length ordered - 1)
      lowerIndex = floor position
      upperIndex = ceiling position
      weight = position - fromIntegral lowerIndex
   in ordered !! lowerIndex * (1 - weight) + ordered !! upperIndex * weight

median :: [Double] -> Double
median = quantile 0.5

minimumByValue :: [(Double, Double)] -> (Double, Double)
minimumByValue = foldl1 \left@(_, leftValue) right@(_, rightValue) -> if rightValue < leftValue then right else left

sortOnValue :: [(Double, Double)] -> [(Double, Double)]
sortOnValue = sortByValue

sortByValue :: [(Double, Double)] -> [(Double, Double)]
sortByValue [] = []
sortByValue (pivot@(_, pivotValue) : rest) =
  sortByValue [value | value@(_, item) <- rest, item <= pivotValue]
    <> [pivot]
    <> sortByValue [value | value@(_, item) <- rest, item > pivotValue]

chunk :: Int -> [value] -> [[value]]
chunk _ [] = []
chunk size values = let (prefix, suffix) = splitAt (max 1 size) values in prefix : chunk size suffix
