module Kenshou.Suite.Kiroku.Soak.Growth (Growth (..), Drift (..), relationGrowth, appendLatencyDrift) where

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Measure.Clock (Origin (..))
import Kenshou.Measure.Samples (SampleFileReport (..), SampleHeader (..), SampleRecord (..), readSamples)
import Kenshou.Measure.Session (MeasurementReport (..))
import Kenshou.Measure.Summary (MeasurementSummary (..), SummaryWindow (..))
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import Text.Read (readMaybe)

data Growth = Growth
  { firstBytesPerRow :: !Double,
    lastBytesPerRow :: !Double,
    insertedRows :: !Integer,
    linear :: !Bool
  }
  deriving stock (Eq, Show)

data Drift = Drift
  { firstP99Ns :: !Integer,
    lastP99Ns :: !Integer,
    firstSamples :: !Int,
    lastSamples :: !Int,
    withinFactorTwo :: !Bool
  }
  deriving stock (Eq, Show)

-- The PostgreSQL sampler records relation size and cumulative inserted tuples
-- together. Compare equal halves of the steady window after enough tuples have
-- been inserted to dominate relation-page granularity.
relationGrowth :: RunContext -> Text -> IO (Maybe Growth)
relationGrowth context relation = do
  contents <- TextIO.readFile (context.outDir </> "series" </> "pg-relations.csv")
  let samples =
        [ (bytes, inserts)
        | line <- drop 1 (Text.lines contents),
          let columns = Text.splitOn "," line,
          length columns >= 10,
          columns !! 2 == "steady",
          columns !! 3 == relation,
          Just bytes <- [readMaybe (Text.unpack (columns !! 6)) :: Maybe Integer],
          Just inserts <- [readMaybe (Text.unpack (columns !! 9)) :: Maybe Integer]
        ]
      count = length samples
  pure $ do
    if count < 3 then Nothing else Just ()
    first <- listToMaybe samples
    middle <- listToMaybe (drop (count `div` 2) samples)
    lastSample <- listToMaybe (reverse samples)
    let insertedFirst = snd middle - snd first
        insertedLast = snd lastSample - snd middle
        inserted = snd lastSample - snd first
    if min insertedFirst insertedLast < 1000
      then Nothing
      else do
        let firstRate = fromIntegral (fst middle - fst first) / fromIntegral insertedFirst
            lastRate = fromIntegral (fst lastSample - fst middle) / fromIntegral insertedLast
            ratio = if firstRate <= 0 then 1 / 0 else lastRate / firstRate
        pure (Growth firstRate lastRate inserted (firstRate > 0 && lastRate > 0 && ratio >= 0.5 && ratio <= 2))

appendLatencyDrift :: RunContext -> MeasurementReport -> IO (Maybe Drift)
appendLatencyDrift context measurement = do
  let path = context.outDir </> "samples" </> "append.raw"
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      records <- newIORef []
      report <- readSamples path (\record -> modifyIORef' records (record :))
      observed <- readIORef records
      let origin = report.header.origin.monoNs
          window = measurement.summary.window
          start = window.steadyStartMonoNs
          end = window.steadyEndMonoNs
          tenth = (end - start) `div` 10
          latency record = fromIntegral (record.endNs - min record.endNs record.intendedStartNs)
          relative record = record.intendedStartNs - min record.intendedStartNs origin
          successes = filter ((== 0) . (.outcomeCode)) observed
          first = [latency record | record <- successes, relative record >= start, relative record < start + tenth]
          lastValues = [latency record | record <- successes, relative record >= end - tenth, relative record < end]
      pure $ do
        if min (length first) (length lastValues) < 100 then Nothing else Just ()
        early <- percentile99 first
        late <- percentile99 lastValues
        pure (Drift early late (length first) (length lastValues) (late <= 2 * early))

percentile99 :: [Integer] -> Maybe Integer
percentile99 values = listToMaybe (drop index ordered)
  where
    ordered = sort values
    index = max 0 (ceiling (0.99 * fromIntegral (length values) :: Double) - 1)
