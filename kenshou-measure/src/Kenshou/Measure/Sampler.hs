module Kenshou.Measure.Sampler
  ( Sampler (..),
    SamplerConfig (..),
    SamplerReport (..),
    SamplingHandle,
    startSampling,
    stopSampling,
  )
where

import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Exception (finally)
import Control.Monad (forM_)
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64)
import Kenshou.Measure.Clock
import Kenshou.Measure.Phase
import Kenshou.Measure.Sampler.Csv
import Kenshou.Measure.Sampler.Host
import Kenshou.Measure.Sampler.Postgres
import Kenshou.Measure.Sampler.Process
import Kenshou.Measure.Sampler.Rts
import System.FilePath ((</>))

data Sampler = Sampler
  { name :: Text,
    sample :: [Text] -> IO ()
  }

data SamplerConfig = SamplerConfig
  { runDir :: FilePath,
    origin :: Origin,
    intervalMs :: Int,
    postgres :: Maybe PgSamplerConfig,
    extraSamplers :: [Sampler],
    phaseClock :: PhaseClock,
    declareArtifact :: FilePath -> Text -> IO (),
    logLine :: Text -> IO ()
  }

data SamplerReport = SamplerReport
  { rtsAvailable :: Bool,
    processAvailable :: Bool,
    hostAvailable :: Bool,
    postgresAvailable :: Bool,
    pgStatementsAvailable :: Bool,
    ticks :: Word64
  }
  deriving stock (Eq, Show)

data Event = Boundary | Scheduled | Stop

data SamplingHandle = SamplingHandle
  { threads :: [Async ()],
    events :: TChan Event,
    closeResources :: IO (),
    report :: IO SamplerReport
  }

startSampling :: SamplerConfig -> IO SamplingHandle
startSampling config = do
  let seriesDir = config.runDir </> "series"
      path name = seriesDir </> name
      declare name = config.declareArtifact (path name) "text/csv"
  events <- newBroadcastTChanIO
  phaseEvents <- atomically (dupTChan events)
  postgresEvents <- atomically (dupTChan events)
  addBoundaryListener config.phaseClock (atomically (writeTChan events Boundary))
  samplerWriter <- openCsv (path "sampler.csv") ["t_mono_ns", "t_wall_ms", "phase", "scheduled_mono_ns", "late_ns", "cost_ns", "wall_minus_mono_ns"]
  declare "sampler.csv"
  rts <- openRtsSampler (path "rts.csv")
  forM_ rts (const (declare "rts.csv"))
  process <- openProcessSampler (path "proc.csv")
  declare "proc.csv"
  host <- openHostSampler (path "host.csv")
  forM_ host (const (declare "host.csv"))
  previousClockDelta <- newIORef Nothing
  tickCount <- newIORef 0
  mainThread <- async (mainLoop config phaseEvents samplerWriter rts process host previousClockDelta tickCount 1)
  postgresResult <- case config.postgres of
    Nothing -> pure Nothing
    Just pgConfig -> do
      opened <- openPostgresSampler seriesDir pgConfig config.logLine
      case opened of
        Left err -> config.logLine ("PostgreSQL sampler unavailable: " <> err) >> pure Nothing
        Right sampler -> do
          mapM_ declare (postgresArtifactNames (postgresHasStatements sampler))
          thread <- async (postgresLoop config postgresEvents sampler 1 `finally` closePostgresSampler sampler)
          pure (Just (thread, postgresHasStatements sampler))
  let closeResources = do
        closeCsv samplerWriter
        forM_ rts closeRtsSampler
        closeProcessSampler process
        forM_ host closeHostSampler
      readReport = do
        count <- readIORef tickCount
        pure
          SamplerReport
            { rtsAvailable = maybe False (const True) rts,
              processAvailable = True,
              hostAvailable = maybe False (const True) host,
              postgresAvailable = maybe False (const True) postgresResult,
              pgStatementsAvailable = maybe False snd postgresResult,
              ticks = count
            }
  pure
    SamplingHandle
      { threads = mainThread : maybe [] (pure . fst) postgresResult,
        events,
        closeResources,
        report = readReport
      }

stopSampling :: SamplingHandle -> IO SamplerReport
stopSampling handle = do
  atomically (writeTChan handle.events Stop)
  mapM_ wait handle.threads `finally` handle.closeResources
  handle.report

mainLoop :: SamplerConfig -> TChan Event -> CsvWriter -> Maybe RtsSampler -> ProcessSampler -> Maybe HostSampler -> IORef (Maybe Integer) -> IORef Word64 -> Word64 -> IO ()
mainLoop config events samplerWriter rts process host previousClockDelta tickCount tickNumber = do
  let intervalNs = fromIntegral config.intervalMs * 1_000_000
      scheduled = config.origin.monoNs + tickNumber * intervalNs
  event <- waitForEvent events scheduled
  case event of
    Stop -> pure ()
    Boundary -> nowNs >>= sampleAll >> mainLoop config events samplerWriter rts process host previousClockDelta tickCount tickNumber
    Scheduled -> sampleAll scheduled >> mainLoop config events samplerWriter rts process host previousClockDelta tickCount (tickNumber + 1)
  where
    sampleAll scheduled = do
      started <- nowNs
      (_, prefix) <- timestampColumns config.origin config.phaseClock
      forM_ rts (`sampleRts` prefix)
      sampleProcess process prefix
      forM_ host (`sampleHost` prefix)
      forM_ config.extraSamplers (\sampler -> sampler.sample prefix)
      ended <- nowNs
      wallOrigin <- captureOrigin
      let delta = fromIntegral wallOrigin.wallUnixNs - fromIntegral wallOrigin.monoNs
      previous <- readIORef previousClockDelta
      writeIORef previousClockDelta (Just delta)
      let clockChange = maybe 0 (delta -) previous
          value = Text.pack . show
      appendCsv samplerWriter (prefix <> fmap value [scheduled - min scheduled config.origin.monoNs, started - min started scheduled, ended - started] <> [Text.pack (show clockChange)])
      atomicModifyIORef' tickCount (\count -> (count + 1, ()))

postgresLoop :: SamplerConfig -> TChan Event -> PostgresSampler -> Word64 -> IO ()
postgresLoop config events sampler tickNumber = do
  let intervalNs = fromIntegral config.intervalMs * 1_000_000
      scheduled = config.origin.monoNs + tickNumber * intervalNs
  event <- waitForEvent events scheduled
  case event of
    Stop -> pure ()
    Boundary -> sampleNow True >> postgresLoop config events sampler tickNumber
    Scheduled -> sampleNow (postgresPeriodic sampler && tickNumber `mod` 10 == 0) >> postgresLoop config events sampler (tickNumber + 1)
  where
    sampleNow includeStatements = do
      (_, prefix) <- timestampColumns config.origin config.phaseClock
      samplePostgres sampler prefix includeStatements

waitForEvent :: TChan Event -> Word64 -> IO Event
waitForEvent events deadline = do
  result <- race (sleepUntilNs deadline >> pure Scheduled) (atomically (readTChan events))
  pure (either id id result)
