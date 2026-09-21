module Kenshou.Measure.Load.Series
  ( LoadSeries,
    openLoadSeries,
    sampleLoadSeries,
    closeLoadSeries,
  )
where

import Data.IORef
import Data.Text qualified as Text
import Data.Word (Word64)
import Kenshou.Measure.Sampler.Csv
import Kenshou.Measure.Session
import System.FilePath ((</>))

newtype LoadSeries = LoadSeries CsvWriter

openLoadSeries :: Measurement -> IO LoadSeries
openLoadSeries measurement = do
  let path = (measurementEnv measurement).runDir </> "series" </> "load.csv"
  writer <- openCsv path ["t_mono_ns", "t_wall_ms", "phase", "offered", "started", "completed", "failed", "max_lag_ns"]
  (measurementEnv measurement).declareArtifact path "text/csv"
  pure (LoadSeries writer)

sampleLoadSeries :: LoadSeries -> Measurement -> IORef Word64 -> IORef Word64 -> IORef Word64 -> IORef Word64 -> IORef Word64 -> IO ()
sampleLoadSeries (LoadSeries writer) measurement offered started completed failed maxLag = do
  (_, prefix) <- timestampColumns (measurementEnv measurement).origin (measurementPhaseClock measurement)
  values <- traverse readIORef [offered, started, completed, failed, maxLag]
  appendCsv writer (prefix <> fmap (Text.pack . show) values)

closeLoadSeries :: LoadSeries -> IO ()
closeLoadSeries (LoadSeries writer) = closeCsv writer
