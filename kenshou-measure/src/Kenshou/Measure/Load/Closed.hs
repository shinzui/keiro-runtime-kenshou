module Kenshou.Measure.Load.Closed (runClosed) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async
import Control.Exception (SomeException, try)
import Control.Monad (forM, when)
import Data.IORef
import Data.Word (Word64)
import Kenshou.Measure.Clock
import Kenshou.Measure.Load.Series
import Kenshou.Measure.Load.Types
import Kenshou.Measure.Phase
import Kenshou.Measure.Recorder
import Kenshou.Measure.Session
import System.Timeout (timeout)

runClosed :: Measurement -> ClosedConfig -> Operation -> IO LoadReport
runClosed measurement config operation = do
  opHandle <- registerOp (measurementRecorder measurement) operation.name
  offered <- newIORef 0
  completed <- newIORef 0
  failed <- newIORef 0
  steadyCompleted <- newIORef 0
  maxLag <- newIORef 0
  loadSeries <- openLoadSeries measurement
  let phaseClock = measurementPhaseClock measurement
      plan = (measurementConfig measurement).defaultPhases
  enterPhase phaseClock WarmUp
  sampleLoadSeries loadSeries measurement offered offered completed failed maxLag
  workers <- forM [0 .. config.workers - 1] \workerId -> do
    workerRecorder <- newWorkerRecorder opHandle workerId
    async do
      when (config.staggerNs > 0) (sleepNanos (fromIntegral workerId * config.staggerNs `div` fromIntegral (max 1 config.workers)))
      workerLoop phaseClock workerRecorder workerId 0 offered completed failed steadyCompleted
  sleepNanos (unNanos plan.warmUp)
  enterPhase phaseClock Steady
  sampleLoadSeries loadSeries measurement offered offered completed failed maxLag
  case plan.steady of
    SteadyFor duration -> sleepNanos (unNanos duration)
    SteadyCount target -> waitForCount steadyCompleted target
  enterPhase phaseClock Drain
  sampleLoadSeries loadSeries measurement offered offered completed failed maxLag
  let drainMicros = fromIntegral (min (unNanos plan.drain `div` 1_000) (fromIntegral (maxBound :: Int)))
  drained <- timeout drainMicros (mapM_ wait workers)
  case drained of
    Just () -> pure ()
    Nothing -> mapM_ cancel workers
  enterPhase phaseClock Done
  sampleLoadSeries loadSeries measurement offered offered completed failed maxLag
  closeLoadSeries loadSeries
  offeredValue <- readIORef offered
  completedValue <- readIORef completed
  failedValue <- readIORef failed
  let report = (emptyLoadReport (ClosedLoop config)) {offered = offeredValue, started = offeredValue, completed = completedValue, failed = failedValue}
  appendLoadReport measurement report
  pure report
  where
    workerLoop phaseClock workerRecorder workerId sequenceNumber offered completed failed steadyCompleted = do
      phase <- currentPhase phaseClock
      case phase of
        Drain -> pure ()
        Done -> pure ()
        _ -> do
          intended <- nowNs
          atomicModifyIORef' offered (\value -> (value + 1, ()))
          result <- try (operation.run workerId sequenceNumber)
          ended <- nowNs
          let opResult = case result of
                Left (_ :: SomeException) -> OpFailed (ErrorCause "exception")
                Right value -> value
          recordOp workerRecorder intended intended ended opResult
          atomicModifyIORef' completed (\value -> (value + 1, ()))
          case opResult of OpFailed _ -> atomicModifyIORef' failed (\value -> (value + 1, ())); OpOk _ -> pure ()
          when (phase == Steady) (atomicModifyIORef' steadyCompleted (\value -> (value + 1, ())))
          when (config.thinkTimeNs > 0) (sleepNanos config.thinkTimeNs)
          workerLoop phaseClock workerRecorder workerId (sequenceNumber + 1) offered completed failed steadyCompleted

waitForCount :: IORef Word64 -> Word64 -> IO ()
waitForCount counter target = do
  current <- readIORef counter
  if current >= target then pure () else threadDelay 1_000 >> waitForCount counter target

sleepNanos :: Word64 -> IO ()
sleepNanos duration = nowNs >>= sleepUntilNs . (+ duration)

unNanos :: Nanos -> Word64
unNanos (Nanos value) = value
