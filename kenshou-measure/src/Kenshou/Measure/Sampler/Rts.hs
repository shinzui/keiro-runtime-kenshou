module Kenshou.Measure.Sampler.Rts
  ( RtsSampler,
    openRtsSampler,
    sampleRts,
    closeRtsSampler,
  )
where

import Data.IORef
import Data.Text qualified as Text
import Data.Word (Word32, Word64)
import GHC.Conc (getNumCapabilities, listThreads)
import GHC.Stats
import Kenshou.Measure.Sampler.Csv

data RtsSampler = RtsSampler CsvWriter (IORef (Maybe (Word32, Word64)))

openRtsSampler :: FilePath -> IO (Maybe RtsSampler)
openRtsSampler path = do
  enabled <- getRTSStatsEnabled
  if not enabled
    then pure Nothing
    else do
      writer <- openCsv path (baseColumns <> columns)
      previous <- newIORef Nothing
      pure (Just (RtsSampler writer previous))
  where
    baseColumns = ["t_mono_ns", "t_wall_ms", "phase"]
    columns =
      [ "gcs",
        "major_gcs",
        "allocated_bytes",
        "max_live_bytes",
        "cumulative_live_bytes",
        "live_bytes_major_mean",
        "live_bytes_last_gc",
        "last_gc_gen",
        "mem_in_use_bytes",
        "max_mem_in_use_bytes",
        "large_objects_bytes",
        "compact_bytes",
        "slop_bytes",
        "block_fragmentation_bytes",
        "copied_bytes",
        "gc_cpu_ns",
        "gc_elapsed_ns",
        "mutator_cpu_ns",
        "mutator_elapsed_ns",
        "cpu_ns",
        "elapsed_ns",
        "haskell_threads",
        "capabilities"
      ]

sampleRts :: RtsSampler -> [Text.Text] -> IO ()
sampleRts (RtsSampler writer previousRef) prefix = do
  stats <- getRTSStats
  previous <- readIORef previousRef
  threads <- length <$> listThreads
  capabilities <- getNumCapabilities
  let details = stats.gc
      majorMean = case previous of
        Just (oldMajor, oldCumulative) | stats.major_gcs > oldMajor -> Just ((stats.cumulative_live_bytes - oldCumulative) `div` fromIntegral (stats.major_gcs - oldMajor))
        _ -> Nothing
      value = Text.pack . show
      maybeValue = maybe "" (value . toInteger)
  appendCsv writer $
    prefix
      <> fmap
        value
        [ toInteger stats.gcs,
          toInteger stats.major_gcs,
          toInteger stats.allocated_bytes,
          toInteger stats.max_live_bytes,
          toInteger stats.cumulative_live_bytes
        ]
      <> [maybeValue majorMean]
      <> fmap
        value
        [ toInteger details.gcdetails_live_bytes,
          toInteger details.gcdetails_gen,
          toInteger details.gcdetails_mem_in_use_bytes,
          toInteger stats.max_mem_in_use_bytes,
          toInteger details.gcdetails_large_objects_bytes,
          toInteger details.gcdetails_compact_bytes,
          toInteger details.gcdetails_slop_bytes,
          toInteger details.gcdetails_block_fragmentation_bytes,
          toInteger stats.copied_bytes,
          toInteger stats.gc_cpu_ns,
          toInteger stats.gc_elapsed_ns,
          toInteger stats.mutator_cpu_ns,
          toInteger stats.mutator_elapsed_ns,
          toInteger stats.cpu_ns,
          toInteger stats.elapsed_ns,
          toInteger threads,
          toInteger capabilities
        ]
  writeIORef previousRef (Just (stats.major_gcs, stats.cumulative_live_bytes))

closeRtsSampler :: RtsSampler -> IO ()
closeRtsSampler (RtsSampler writer _) = closeCsv writer
