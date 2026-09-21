module Kenshou.Diagnose.Leak.MajorGcProbe
  ( withMajorGcProbe,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync)
import Control.Monad (forever, when)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Stats
import Kenshou.Core.Context qualified as Core
import Kenshou.Core.Id (Kind (Benchmark))
import Kenshou.Diagnose.Context qualified as Context
import System.IO (BufferMode (LineBuffering), IOMode (AppendMode), hSetBuffering, withFile)
import System.Mem (performMajorGC)

-- Forced major collections perturb latency and heap ageing. Scenario authors
-- must never enable this probe in benchmark evidence.
withMajorGcProbe :: Core.RunContext -> Double -> IO value -> IO value
withMajorGcProbe context intervalMilliseconds action
  | intervalMilliseconds <= 0 = action
  | Context.scenarioKind context == Benchmark = ioError (userError "withMajorGcProbe: benchmark scenarios cannot force major garbage collections")
  | otherwise = do
      path <- Core.artifactPath context Core.SeriesDir "rts-major.csv"
      Core.declareMediaType context "series/rts-major.csv" "text/csv"
      Text.writeFile path "t_mono_ns,live_bytes,major_gcs,gc_gen,pause_ns\n"
      withAsync (sampleLoop path) (const action)
  where
    delay = max 1 (floor (intervalMilliseconds * 1000))
    sampleLoop path = withFile path AppendMode \handle -> do
      hSetBuffering handle LineBuffering
      forever do
        threadDelay delay
        started <- getMonotonicTimeNSec
        performMajorGC
        stats <- getRTSStats
        ended <- getMonotonicTimeNSec
        let details = stats.gc
        when (details.gcdetails_gen > 0) $
          Text.hPutStrLn handle $
            Text.intercalate "," (fmap (Text.pack . show) [ended, details.gcdetails_live_bytes, fromIntegral stats.major_gcs, fromIntegral details.gcdetails_gen, ended - started])
