module Kenshou.Diagnose.Stall
  ( WatchdogConfig (..),
    defaultWatchdogConfig,
    Watchdog,
    StallDetected (..),
    withWatchdog,
    newProgress,
    registerPool,
    registerStateProbe,
    registerChildProcess,
    suspendDeadline,
    captureNow,
    module Kenshou.Diagnose.Progress,
    module Kenshou.Diagnose.Stall.Types,
  )
where

import Control.Concurrent (ThreadId, myThreadId, threadDelay, throwTo)
import Control.Concurrent.Async (withAsync)
import Control.Exception (Exception, bracket, bracket_)
import Data.Aeson (Value (Null), object, toJSON, (.=))
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (traverse_)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (diffUTCTime, getCurrentTime)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Kenshou.Core.Context qualified as Core
import Kenshou.Diagnose.Context qualified as Context
import Kenshou.Diagnose.Document
import Kenshou.Diagnose.LockGraph (buildGraph)
import Kenshou.Diagnose.Pool (PoolStats)
import Kenshou.Diagnose.Pool qualified as Pool
import Kenshou.Diagnose.Postgres
import Kenshou.Diagnose.Progress
import Kenshou.Diagnose.Stall.Classify (classify)
import Kenshou.Diagnose.Stall.Types
import Kenshou.Diagnose.Threads (dumpThreads, labelMe)
import System.CPUTime (getCPUTime)
import System.Posix.Signals (sigUSR2, signalProcess)
import System.Posix.Types (CPid)

data WatchdogConfig = WatchdogConfig
  { deadlineSeconds :: !Double,
    pollIntervalSeconds :: !Double,
    maxCaptures :: !Int,
    onStall :: !OnStall,
    postgres :: !(Maybe Text),
    advisoryLabels :: ![AdvisoryLabel],
    captureStacks :: !Bool,
    spinProbeSeconds :: !Double
  }
  deriving stock (Eq, Show)

defaultWatchdogConfig :: WatchdogConfig
defaultWatchdogConfig = WatchdogConfig 60 1 3 CaptureAndAbort Nothing [] True 2

data Watchdog = Watchdog
  { context :: !Core.RunContext,
    config :: !WatchdogConfig,
    scenarioThread :: !ThreadId,
    counters :: !(IORef [ProgressCounter]),
    poolProbes :: !(IORef [(Text, IO PoolStats)]),
    stateProbes :: !(IORef [(Text, IO Value)]),
    children :: !(IORef [(Text, CPid)]),
    suspensions :: !(IORef Int),
    captures :: !(IORef Int),
    database :: !(Maybe (Either Text Connection.Connection))
  }

newtype StallDetected = StallDetected StallReport deriving stock (Show)

instance Exception StallDetected

withWatchdog :: Core.RunContext -> WatchdogConfig -> (Watchdog -> IO value) -> IO value
withWatchdog context config action = do
  scenarioThread <- myThreadId
  bracket (openDatabase config) closeDatabase \database -> do
    watchdog <-
      Watchdog context config scenarioThread
        <$> newIORef []
        <*> newIORef []
        <*> newIORef []
        <*> newIORef []
        <*> newIORef 0
        <*> newIORef 0
        <*> pure database
    withAsync (monitor watchdog) \_ -> action watchdog

openDatabase :: WatchdogConfig -> IO (Maybe (Either Text Connection.Connection))
openDatabase config = traverse acquire config.postgres
  where
    acquire connectionString = do
      result <- Connection.acquire (Settings.connectionString connectionString <> Settings.applicationName "kenshou-diagnose-watchdog")
      pure case result of
        Left err -> Left (Text.pack (show err))
        Right connection -> Right connection

closeDatabase :: Maybe (Either Text Connection.Connection) -> IO ()
closeDatabase = maybe (pure ()) (either (const (pure ())) Connection.release)

newProgress :: Watchdog -> Text -> Bool -> IO ProgressCounter
newProgress watchdog name required = do
  counter <- newProgressCounter name required
  atomicModifyIORef' watchdog.counters (\values -> (counter : values, ()))
  pure counter

registerPool :: Watchdog -> Text -> IO PoolStats -> IO ()
registerPool watchdog name probe = atomicModifyIORef' watchdog.poolProbes (\values -> ((name, namedProbe) : values, ()))
  where
    namedProbe = do
      stats <- probe
      pure stats {Pool.name = name}

registerStateProbe :: Watchdog -> Text -> IO Value -> IO ()
registerStateProbe watchdog name probe = atomicModifyIORef' watchdog.stateProbes (\values -> ((name, probe) : values, ()))

registerChildProcess :: Watchdog -> Text -> CPid -> IO ()
registerChildProcess watchdog role pid = atomicModifyIORef' watchdog.children (\values -> ((role, pid) : values, ()))

suspendDeadline :: Watchdog -> Text -> IO value -> IO value
suspendDeadline watchdog _reason = bracket_ increment decrement
  where
    increment = atomicModifyIORef' watchdog.suspensions (\value -> (value + 1, ()))
    decrement = atomicModifyIORef' watchdog.suspensions (\value -> (max 0 (value - 1), ()))

monitor :: Watchdog -> IO ()
monitor watchdog = do
  labelMe "kenshou:diagnose:watchdog"
  loop
  where
    loop = do
      threadDelay (secondsToMicros watchdog.config.pollIntervalSeconds)
      suspended <- (> 0) <$> readIORef watchdog.suspensions
      count <- readIORef watchdog.captures
      snapshots <- readIORef watchdog.counters >>= traverse snapshotProgress
      now <- getCurrentTime
      let required = filter (.required) snapshots
          stalled = not (null required) && all (\counter -> realToFrac (diffUTCTime now counter.lastAdvancedAt) >= watchdog.config.deadlineSeconds) required
      if suspended || not stalled || count >= watchdog.config.maxCaptures
        then loop
        else do
          report <- captureNow watchdog "progress deadline exceeded"
          case watchdog.config.onStall of
            CaptureAndContinue -> threadDelay (secondsToMicros watchdog.config.deadlineSeconds) >> loop
            CaptureAndAbort -> throwTo watchdog.scenarioThread (StallDetected report)

captureNow :: Watchdog -> Text -> IO StallReport
captureNow watchdog reason = do
  captureNumber <- atomicModifyIORef' watchdog.captures (\value -> let next = value + 1 in (next, next))
  progress <- readIORef watchdog.counters >>= traverse snapshotProgress
  haskellThreads <- dumpThreads watchdog.config.captureStacks
  signalChildren watchdog
  pools <- readIORef watchdog.poolProbes >>= traverse (\(_, probe) -> probe)
  probes <- readIORef watchdog.stateProbes >>= traverse (\(name, probe) -> (name,) <$> probe)
  cpuStart <- getCPUTime
  postgres <- captureDatabase watchdog
  cpuEnd <- getCPUTime
  let elapsed = max 0.001 watchdog.config.spinProbeSeconds
      cpuCores = fromIntegral (cpuEnd - cpuStart) / 1.0e12 / elapsed
      statementCalls = maybe 0 (maybe 0 (.callsPerSecond) . (.statementRate)) postgres
      graph = maybe (buildGraph [] []) (\databaseSnapshot -> buildGraph databaseSnapshot.activity databaseSnapshot.locks) postgres
      snapshot = StallSnapshot watchdog.config.deadlineSeconds progress haskellThreads postgres graph pools (toJSON (Map.fromList probes)) (SpinEvidence cpuCores statementCalls)
      (classification, secondary, reasons) = classify snapshot
  detectedAt <- getCurrentTime
  let report = StallReport detectedAt captureNumber classification secondary (reason : reasons) snapshot
  writeReport watchdog report
  pure report

captureDatabase :: Watchdog -> IO (Maybe PostgresSnapshot)
captureDatabase watchdog = case watchdog.database of
  Nothing -> pure Nothing
  Just (Left err) -> pure (Just (PostgresSnapshot False (Just err) [] [] Nothing Null))
  Just (Right connection) -> Just <$> capturePostgres connection watchdog.config.spinProbeSeconds

signalChildren :: Watchdog -> IO ()
signalChildren watchdog = do
  registered <- readIORef watchdog.children
  traverse_ (signalProcess sigUSR2 . snd) registered
  if null registered then pure () else threadDelay 2_000_000

writeReport :: Watchdog -> StallReport -> IO ()
writeReport watchdog report = do
  let (runId, scenario) = Context.runIdentity watchdog.context
      diagnosis = Diagnosis StallDiagnosis runId scenario report.detectedAt (Generator "kenshou-diagnose" "0.1.0.0" "stall-watchdog-v1") (toJSON report)
  path <- Core.artifactPath watchdog.context Core.DiagnosisDir ("stall-" <> show report.captureNumber <> ".json")
  LazyByteString.writeFile path (encodeDiagnosis diagnosis)
  Core.declareMediaType watchdog.context path "application/json"
  Context.publishDiagnosis watchdog.context "stall" (object ["classification" .= report.classification, "path" .= path])

secondsToMicros :: Double -> Int
secondsToMicros = max 1 . floor . (* 1_000_000)
