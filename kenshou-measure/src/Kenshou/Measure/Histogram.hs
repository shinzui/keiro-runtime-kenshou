module Kenshou.Measure.Histogram
  ( HistogramConfig (..),
    defaultHistogramConfig,
    MutableHistogram,
    Histogram,
    newHistogram,
    recordValue,
    freeze,
    merge,
    valueAtQuantile,
    totalCount,
    minValue,
    maxValue,
    overflowCount,
    meanValue,
    equivalentRange,
    histogramConfig,
    histogramCounts,
    histogramSum,
    histogramArrayLength,
    histogramFromCounts,
  )
where

import Control.Monad (forM_)
import Control.Monad.ST (runST)
import Data.Bits
import Data.IORef
import Data.Primitive.PrimArray
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64)
import GHC.Exts (RealWorld)

data HistogramConfig = HistogramConfig
  { lowestDiscernible :: !Word64,
    highestTrackable :: !Word64,
    significantDigits :: !Int
  }
  deriving stock (Eq, Show)

defaultHistogramConfig :: HistogramConfig
defaultHistogramConfig = HistogramConfig 1 3_600_000_000_000 3

data Layout = Layout
  { unitMagnitude :: !Int,
    subBucketCountMagnitude :: !Int,
    subBucketCount :: !Int,
    subBucketHalfCount :: !Int,
    subBucketHalfCountMagnitude :: !Int,
    subBucketMask :: !Word64,
    arrayLength :: !Int
  }

data MutableHistogram = MutableHistogram
  { config :: !HistogramConfig,
    layout :: !Layout,
    counts :: !(MutablePrimArray RealWorld Word64),
    count :: !(IORef Word64),
    minimum :: !(IORef Word64),
    maximum :: !(IORef Word64),
    total :: !(IORef Word64),
    overflow :: !(IORef Word64)
  }

data Histogram = Histogram
  { config :: !HistogramConfig,
    layout :: !Layout,
    counts :: !(PrimArray Word64),
    count :: !Word64,
    minimum :: !Word64,
    maximum :: !Word64,
    total :: !Word64,
    overflow :: !Word64
  }

instance Eq Histogram where
  left == right =
    left.config == right.config
      && left.count == right.count
      && left.minimum == right.minimum
      && left.maximum == right.maximum
      && left.total == right.total
      && left.overflow == right.overflow
      && histogramCounts left == histogramCounts right

instance Show Histogram where
  show value =
    "Histogram {config="
      <> show value.config
      <> ", count="
      <> show value.count
      <> ", min="
      <> show value.minimum
      <> ", max="
      <> show value.maximum
      <> ", overflow="
      <> show value.overflow
      <> "}"

newHistogram :: HistogramConfig -> IO MutableHistogram
newHistogram config = case makeLayout config of
  Left message -> ioError (userError (Text.unpack message))
  Right layout -> do
    counts <- newPrimArray layout.arrayLength
    setPrimArray counts 0 layout.arrayLength 0
    MutableHistogram config layout counts
      <$> newIORef 0
      <*> newIORef maxBound
      <*> newIORef 0
      <*> newIORef 0
      <*> newIORef 0

recordValue :: MutableHistogram -> Word64 -> IO ()
recordValue histogram value = do
  modifyIORef' histogram.count (+ 1)
  modifyIORef' histogram.minimum (min value)
  modifyIORef' histogram.maximum (max value)
  modifyIORef' histogram.total (+ value)
  if value > histogram.config.highestTrackable
    then modifyIORef' histogram.overflow (+ 1)
    else do
      let index = countsIndex histogram.layout value
      previous <- readPrimArray histogram.counts index
      writePrimArray histogram.counts index (previous + 1)

freeze :: MutableHistogram -> IO Histogram
freeze mutable = do
  immutable <- freezePrimArray mutable.counts 0 mutable.layout.arrayLength
  count <- readIORef mutable.count
  observedMinimum <- readIORef mutable.minimum
  observedMaximum <- readIORef mutable.maximum
  total <- readIORef mutable.total
  overflow <- readIORef mutable.overflow
  pure $ Histogram mutable.config mutable.layout immutable count (if count == 0 then 0 else observedMinimum) observedMaximum total overflow

merge :: Histogram -> Histogram -> Either Text Histogram
merge left right
  | left.config /= right.config = Left "histogram configurations differ"
  | otherwise =
      Right
        Histogram
          { config = left.config,
            layout = left.layout,
            counts = runST do
              mutable <- newPrimArray left.layout.arrayLength
              forM_ [0 .. left.layout.arrayLength - 1] \index ->
                writePrimArray mutable index (indexPrimArray left.counts index + indexPrimArray right.counts index)
              unsafeFreezePrimArray mutable,
            count = left.count + right.count,
            minimum = case (left.count, right.count) of
              (0, _) -> right.minimum
              (_, 0) -> left.minimum
              _ -> min left.minimum right.minimum,
            maximum = max left.maximum right.maximum,
            total = left.total + right.total,
            overflow = left.overflow + right.overflow
          }

valueAtQuantile :: Histogram -> Double -> Word64
valueAtQuantile histogram quantile
  | histogram.count == 0 = 0
  | quantile >= 1 = histogram.maximum
  | target > histogram.count - histogram.overflow = histogram.maximum
  | otherwise = findIndex 0 0
  where
    bounded = max 0 (min 1 quantile)
    target = max 1 (ceiling (bounded * fromIntegral histogram.count))
    findIndex index cumulative
      | index >= histogram.layout.arrayLength = histogram.maximum
      | next >= target =
          let (_, highest) = equivalentRangeAtIndex histogram.layout index
           in max histogram.minimum (min histogram.maximum highest)
      | otherwise = findIndex (index + 1) next
      where
        next = cumulative + indexPrimArray histogram.counts index

totalCount :: Histogram -> Word64
totalCount = (.count)

minValue :: Histogram -> Word64
minValue = (.minimum)

maxValue :: Histogram -> Word64
maxValue = (.maximum)

overflowCount :: Histogram -> Word64
overflowCount = (.overflow)

meanValue :: Histogram -> Double
meanValue histogram
  | histogram.count == 0 = 0
  | otherwise = fromIntegral histogram.total / fromIntegral histogram.count

equivalentRange :: HistogramConfig -> Word64 -> Either Text (Word64, Word64)
equivalentRange config value = do
  layout <- makeLayout config
  pure (equivalentRangeAtIndex layout (countsIndex layout (min value config.highestTrackable)))

histogramConfig :: Histogram -> HistogramConfig
histogramConfig = (.config)

histogramCounts :: Histogram -> [Word64]
histogramCounts histogram = [indexPrimArray histogram.counts index | index <- [0 .. histogram.layout.arrayLength - 1]]

histogramSum :: Histogram -> Word64
histogramSum = (.total)

histogramArrayLength :: HistogramConfig -> Either Text Int
histogramArrayLength config = (.arrayLength) <$> makeLayout config

histogramFromCounts :: HistogramConfig -> [Word64] -> Word64 -> Word64 -> Word64 -> Word64 -> Word64 -> Either Text Histogram
histogramFromCounts config values count observedMinimum observedMaximum total overflow = do
  layout <- makeLayout config
  if length values /= layout.arrayLength
    then Left "histogram count array has the wrong length"
    else
      pure
        Histogram
          { config,
            layout,
            counts = primArrayFromList values,
            count,
            minimum = if count == 0 then 0 else observedMinimum,
            maximum = observedMaximum,
            total,
            overflow
          }

makeLayout :: HistogramConfig -> Either Text Layout
makeLayout config
  | config.lowestDiscernible == 0 = Left "lowestDiscernible must be positive"
  | config.highestTrackable < config.lowestDiscernible = Left "highestTrackable must not be below lowestDiscernible"
  | config.significantDigits < 1 || config.significantDigits > 5 = Left "significantDigits must be between 1 and 5"
  | otherwise = Right Layout {unitMagnitude, subBucketCountMagnitude, subBucketCount, subBucketHalfCount, subBucketHalfCountMagnitude, subBucketMask, arrayLength}
  where
    unitMagnitude = integerLog2 config.lowestDiscernible
    required = 2 * (10 ^ config.significantDigits)
    subBucketCountMagnitude = ceilingLog2 required
    subBucketCount = 1 `shiftL` subBucketCountMagnitude
    subBucketHalfCount = subBucketCount `div` 2
    subBucketHalfCountMagnitude = subBucketCountMagnitude - 1
    subBucketMask = fromIntegral (subBucketCount - 1) `shiftL` unitMagnitude
    initial = fromIntegral subBucketCount `shiftL` unitMagnitude :: Word64
    bucketCount = length (takeWhile (<= config.highestTrackable) (iterate (`shiftL` 1) initial)) + 1
    arrayLength = (bucketCount + 1) * subBucketHalfCount

countsIndex :: Layout -> Word64 -> Int
countsIndex layout value =
  ((bucketIndex + 1) `shiftL` layout.subBucketHalfCountMagnitude)
    + (subBucketIndex - layout.subBucketHalfCount)
  where
    bucketIndex = (64 - layout.unitMagnitude - layout.subBucketCountMagnitude) - countLeadingZeros (value .|. layout.subBucketMask)
    subBucketIndex = fromIntegral (value `shiftR` (bucketIndex + layout.unitMagnitude))

equivalentRangeAtIndex :: Layout -> Int -> (Word64, Word64)
equivalentRangeAtIndex layout index = (lowest, lowest + rangeSize - 1)
  where
    initialBucket = (index `shiftR` layout.subBucketHalfCountMagnitude) - 1
    initialSub = (index .&. (layout.subBucketHalfCount - 1)) + layout.subBucketHalfCount
    (bucket, subBucket) = if initialBucket < 0 then (0, initialSub - layout.subBucketHalfCount) else (initialBucket, initialSub)
    lowest = fromIntegral subBucket `shiftL` (bucket + layout.unitMagnitude)
    rangeSize = 1 `shiftL` (bucket + layout.unitMagnitude)

integerLog2 :: Word64 -> Int
integerLog2 value = finiteBitSize value - 1 - countLeadingZeros value

ceilingLog2 :: Int -> Int
ceilingLog2 value = go 0 1
  where
    go magnitude power | power >= value = magnitude | otherwise = go (magnitude + 1) (power * 2)
