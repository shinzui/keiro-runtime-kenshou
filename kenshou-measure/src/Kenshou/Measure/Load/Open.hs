module Kenshou.Measure.Load.Open (runOpen) where

import Control.Concurrent.Async
import Control.Exception (SomeException, try)
import Control.Monad (forM, when)
import Data.IORef
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Data.Word (Word64)
import Kenshou.Measure.Clock
import Kenshou.Measure.Load.Arrival
import Kenshou.Measure.Load.Types
import Kenshou.Measure.Phase
import Kenshou.Measure.Recorder
import Kenshou.Measure.Session
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.Random.SplitMix (SMGen, mkSMGen)
import System.Timeout (timeout)

data TicketState = TicketState !Word64 !Word64 !SMGen

runOpen :: Measurement -> OpenConfig -> Operation -> IO LoadReport
runOpen measurement config operation = do
  opHandle <- registerOp (measurementRecorder measurement) operation.name
  offered <- newIORef 0
  started <- newIORef 0
  completed <- newIORef 0
  failed <- newIORef 0
  maxLag <- newIORef 0
  aborted <- newIORef False
  start <- nowNs
  tickets <- newIORef (TicketState 0 start (mkSMGen (measurementEnv measurement).seed))
  let phaseClock = measurementPhaseClock measurement
      plan = (measurementConfig measurement).defaultPhases
  enterPhase phaseClock WarmUp
  executors <- forM [0 .. config.executors - 1] \executorId -> do
    workerRecorder <- newWorkerRecorder opHandle executorId
    async (executorLoop phaseClock workerRecorder executorId tickets offered started completed failed maxLag aborted)
  sleepNanos (unNanos plan.warmUp)
  enterPhase phaseClock Steady
  case plan.steady of
    SteadyFor duration -> sleepNanos (unNanos duration)
    SteadyCount target -> waitForCount completed target
  enterPhase phaseClock Drain
  let drainMicros = fromIntegral (min (unNanos plan.drain `div` 1_000) (fromIntegral (maxBound :: Int)))
  drained <- timeout drainMicros (mapM_ wait executors)
  case drained of Just () -> pure (); Nothing -> mapM_ cancel executors
  enterPhase phaseClock Done
  offeredValue <- readIORef offered
  startedValue <- readIORef started
  completedValue <- readIORef completed
  failedValue <- readIORef failed
  maxLagValue <- readIORef maxLag
  abortedValue <- readIORef aborted
  let overload = if maxLagValue > config.overload.maxLagNs then Just (OverloadEvidence config.overload.maxLagNs maxLagValue) else Nothing
      report = LoadReport (OpenLoop config) offeredValue startedValue completedValue failedValue maxLagValue overload abortedValue
  writeLoadSeries measurement report
  appendLoadReport measurement report
  pure report
  where
    executorLoop phaseClock workerRecorder executorId tickets offered started completed failed maxLag aborted = do
      phase <- currentPhase phaseClock
      abortNow <- readIORef aborted
      case phase of
        Drain -> pure ()
        Done -> pure ()
        _ | abortNow -> pure ()
        _ -> do
          (sequenceNumber, intended) <- atomicModifyIORef' tickets \(TicketState index next generator) ->
            let (gap, nextGenerator) = nextGapNs config.arrival generator
             in (TicketState (index + 1) (next + gap) nextGenerator, (index, next))
          atomicModifyIORef' offered (\value -> (value + 1, ()))
          sleepUntilNs intended
          actual <- nowNs
          let lag = actual - min actual intended
          atomicModifyIORef' maxLag (\value -> (max value lag, ()))
          when (lag > config.overload.abortLagNs) (writeIORef aborted True)
          atomicModifyIORef' started (\value -> (value + 1, ()))
          result <- try (operation.run executorId sequenceNumber)
          ended <- nowNs
          let opResult = case result of
                Left (_ :: SomeException) -> OpFailed (ErrorCause "exception")
                Right value -> value
          recordOp workerRecorder intended actual ended opResult
          atomicModifyIORef' completed (\value -> (value + 1, ()))
          case opResult of OpFailed _ -> atomicModifyIORef' failed (\value -> (value + 1, ())); OpOk _ -> pure ()
          executorLoop phaseClock workerRecorder executorId tickets offered started completed failed maxLag aborted

writeLoadSeries :: Measurement -> LoadReport -> IO ()
writeLoadSeries measurement report = do
  let directory = (measurementEnv measurement).runDir </> "series"
      path = directory </> "load.csv"
      row = Text.intercalate "," (fmap (Text.pack . show) [report.offered, report.started, report.completed, report.failed, report.maxLagNs])
  createDirectoryIfMissing True directory
  Text.IO.writeFile path ("offered,started,completed,failed,max_lag_ns\n" <> row <> "\n")
  (measurementEnv measurement).declareArtifact path "text/csv"

waitForCount :: IORef Word64 -> Word64 -> IO ()
waitForCount counter target = do
  current <- readIORef counter
  if current >= target then pure () else sleepNanos 1_000_000 >> waitForCount counter target

sleepNanos :: Word64 -> IO ()
sleepNanos duration = nowNs >>= sleepUntilNs . (+ duration)

unNanos :: Nanos -> Word64
unNanos (Nanos value) = value
