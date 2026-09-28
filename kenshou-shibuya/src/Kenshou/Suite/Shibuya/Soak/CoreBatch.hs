{-# LANGUAGE BlockArguments #-}

module Kenshou.Suite.Shibuya.Soak.CoreBatch (scenarios, role) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (cancel, poll, withAsync)
import Control.Concurrent.STM (atomically, newTBQueueIO, readTBQueue, writeTBQueue)
import Control.Exception (bracket)
import Control.Monad (forever, when)
import Data.Aeson (object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.ByteString.Char8 qualified as ByteString
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Word (Word64)
import Effectful (liftIO, runEff)
import GHC.Clock (getMonotonicTimeNSec)
import Kenshou.Check.Process (awaitReady, readChildMessages, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), declareMediaType, putSummary)
import Kenshou.Core.Dimension (noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobInt, mkKnobName)
import Kenshou.Core.Outcome (Outcome (..))
import Kenshou.Core.Phase (PhasePlan (..))
import Kenshou.Core.Role (ControlMessage (..), RoleContext (..), WorkerInit (..), WorkerMessage (..), WorkerRole (..), mkRoleName)
import Kenshou.Core.Scenario (CohortScope (..), KnownDefect (..), Placement (..), Scenario (..), ScenarioReport (..), Tier (..), failedWith, passed)
import Kenshou.Diagnose.Leak (LeakReport (..), LeakSpec (..), LeakVerdict (..), ProbeSpec (..), defaultLeakSpec, judgeLeaks)
import Kenshou.Diagnose.Series (SeriesBinding (..))
import Kenshou.Measure.Sampler.Process (ProcessSampler, closeProcessSampler, openProcessSampler, sampleProcess)
import Kenshou.Measure.Sampler.Rts (RtsSampler, closeRtsSampler, openRtsSampler, sampleRts)
import Shibuya.Adapter (Adapter (..))
import Shibuya.App (AppConfig (..), defaultAppConfig, mkBatchProcessor, runApp, waitApp)
import Shibuya.Batch (BatchConfig (..), BatchKey (..), ackAllOk, defaultBatchConfig)
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (mkIngested)
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Core.Types (Envelope (..), MessageId (..), mkEnvelope)
import Shibuya.Telemetry.Effect (runTracingNoop)
import Streamly.Data.Stream qualified as Stream
import System.Directory (copyFile, createDirectoryIfMissing)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Mem (performMajorGC)

data SoakProfile = FullSoak | ReducedSoak deriving stock (Eq, Show)

data Arm = ShortTimeout | LongTimeout deriving stock (Eq, Show)

scenarios :: [Scenario]
scenarios = fmap scenario [FullSoak, ReducedSoak]

scenario :: SoakProfile -> Scenario
scenario profile =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId ("shibuya/core-batch/soak/high-cardinality-batch-keys" <> if profile == FullSoak then "" else "-reduced")),
      revision = 1,
      summary = "Measures bounded one-second and unbounded one-hour high-cardinality batch-key state in separate Shibuya workers.",
      tier = if profile == FullSoak then TierSoak else TierExtended,
      placement = if profile == FullSoak then PlaceCell else PlaceEither,
      knobs = [intKnob "soak.duration-seconds" (if profile == FullSoak then 14400 else 1200) 5 20000, intKnob "soak.rate-per-second" 200 1 1000],
      dimensions = noDimensions,
      phases = PhasePlan 0 (if profile == FullSoak then 14400 else 1200) 0,
      requires = noEnvironment,
      knownDefect = Just (KnownDefect "mori://shinzui/shibuya/okf/reviews/concepts/REV-15" "REV-15-L1: pending high-cardinality batch keys can grow without the configured inbox bound" ["long-arm-batch-state-unbounded", "long-arm-backpressure-lost"] AllCohorts),
      run = runSoak profile
    }
  where
    intKnob key value low high = KnobSpec (either (error . Text.unpack) id (mkKnobName key)) key KnobInt (VInt value) (IntRange low high) []

role :: WorkerRole
role = WorkerRole (either (error . Text.unpack) id (mkRoleName "shibuya/batch-key-soak")) "Runs a bounded-memory producer against the real Shibuya batch processor and samples its own resources." runWorker

runSoak :: SoakProfile -> RunContext -> IO ScenarioReport
runSoak profile context = withCheck context \check -> withSupervisor check \supervisor -> do
  let duration = fromIntegral (knobInt context.knobs (knob "soak.duration-seconds")) :: Int
      rate = fromIntegral (knobInt context.knobs (knob "soak.rate-per-second")) :: Int
      armName :: Arm -> Text
      armName ShortTimeout = "batch-short"
      armName LongTimeout = "batch-long"
  children <-
    mapM
      ( \(index, arm) -> do
          spec <- roleProcess check "shibuya/batch-key-soak" index (object ["arm" .= armName arm, "rate" .= rate])
          child <- spawn supervisor spec
          awaitReady child 10000
          pure (arm, child)
      )
      [(0, ShortTimeout), (1, LongTimeout)]
  mapM_ (\(_, child) -> sendCommand child CtlStart) children
  threadDelay (duration * 1000000)
  results <-
    mapM
      ( \(arm, child) -> do
          exitCode <- stopGracefully supervisor child 15000
          messages <- readChildMessages child
          pure (arm, exitCode, listToMaybe (mapMaybe decodeResult messages))
      )
      children
  shortLeak <- judgeLeaks context (leakSpec profile "batch-short")
  copyDiagnosis context "leak-short.json"
  longLeak <- judgeLeaks context (leakSpec profile "batch-long")
  copyDiagnosis context "leak-long.json"
  let shortResult = lookupArm ShortTimeout results
      longResult = lookupArm LongTimeout results
      shortFailed = maybe True (\(exitCode, counts) -> exitCode /= ExitSuccess || not counts.running) shortResult
      longFailed = maybe True (\(exitCode, counts) -> exitCode /= ExitSuccess || not counts.running) longResult
      shortCounts = snd <$> shortResult
      longCounts = snd <$> longResult
      shortOutstanding = maybe 0 (\value -> value.produced - value.finalized) shortCounts
      longOutstanding = maybe 0 (\value -> value.produced - value.finalized) longCounts
      baselineFailures =
        ["short-arm-worker-failed" | shortFailed]
          <> ["long-arm-worker-failed" | longFailed]
          <> ["short-arm-no-progress" | maybe True ((<= 0) . (.produced)) shortCounts]
          <> ["long-arm-no-progress" | maybe True ((<= 0) . (.produced)) longCounts]
          <> ["short-arm-backpressure-lost" | shortOutstanding > 1000]
          <> ["short-arm-leak" | shortLeak.verdict == LeakSuspected]
      knownFailures =
        ["long-arm-batch-state-unbounded" | longLeak.verdict == LeakSuspected]
          <> ["long-arm-backpressure-lost" | longOutstanding > 1000]
      failures = baselineFailures <> knownFailures
      report
        | not (null failures) = failedWith failures (Text.intercalate "; " failures)
        | shortLeak.verdict == InsufficientData || longLeak.verdict == InsufficientData = ScenarioReport Inconclusive (Just "leak samples are insufficient") []
        | otherwise = passed
  putSummary context Verdicts "batch-key-soak" (object ["durationSeconds" .= duration, "ratePerSecond" .= rate, "short" .= summaryResult shortResult shortLeak, "long" .= summaryResult longResult longLeak, "shortOutstanding" .= shortOutstanding, "longOutstanding" .= longOutstanding])
  pure report
  where
    lookupArm arm = listToMaybe . mapMaybe (\(candidate, exitCode, result) -> if arm == candidate then (exitCode,) <$> result else Nothing)
    summaryResult result leak = object ["exit" .= fmap (show . fst) result, "produced" .= fmap ((.produced) . snd) result, "finalized" .= fmap ((.finalized) . snd) result, "leakVerdict" .= show leak.verdict]

data ArmResult = ArmResult {produced :: !Int, finalized :: !Int, running :: !Bool}

decodeResult :: WorkerMessage -> Maybe ArmResult
decodeResult (WrkCustom "batch-soak-result" value) = parseMaybe (withObject "batch-soak-result" (\item -> ArmResult <$> item .: "produced" <*> item .: "finalized" <*> item .: "running")) value
decodeResult _ = Nothing

copyDiagnosis :: RunContext -> FilePath -> IO ()
copyDiagnosis context name = do
  copyFile (context.outDir </> "diagnosis" </> "leak.json") (context.outDir </> "diagnosis" </> name)
  declareMediaType context ("diagnosis/" <> name) "application/json"

leakSpec :: SoakProfile -> FilePath -> LeakSpec
leakSpec profile arm =
  defaultLeakSpec
    { probes = fmap relocate (take 5 defaultLeakSpec.probes),
      warmupCutSeconds = if profile == FullSoak then 300 else 60,
      minPoints = if profile == FullSoak then 30 else 10,
      minDurationSeconds = if profile == FullSoak then 1200 else 600
    }
  where
    relocate probe =
      let original = probe.binding
       in probe {binding = original {file = "children" </> arm </> original.file}}

knob :: Text -> KnobName
knob = either (error . Text.unpack) id . mkKnobName

runWorker :: RoleContext -> IO ()
runWorker context = do
  let arm = parseMaybe (withObject "batch-key-soak" (.: "arm")) context.init.args :: Maybe Text
      rate = parseMaybe (withObject "batch-key-soak" (.: "rate")) context.init.args :: Maybe Int
  case (arm, rate) of
    (Just label, Just perSecond) | perSecond > 0 -> workerBody context label perSecond
    _ -> context.send (WrkError "invalid batch-key soak worker arguments")

workerBody :: RoleContext -> Text -> Int -> IO ()
workerBody context label rate = do
  queue <- newTBQueueIO 256
  produced <- newIORef (0 :: Int)
  finalized <- newIORef (0 :: Int)
  let directory = context.init.outDir </> "series" </> "children" </> Text.unpack label
      long = label == "batch-long"
      delay = if long then 3600 else 1 :: Double
      producer = forever do
        next <- atomicModifyIORef' produced (\old -> let value = old + 1 in (value, value))
        atomically $ writeTBQueue queue next
        threadDelay (max 1 (1000000 `div` rate))
      source =
        Stream.unfoldrM
          ( \() -> do
              number <- liftIO $ atomically $ readTBQueue queue
              let identifier = MessageId ("batch-soak-" <> Text.pack (show number))
                  envelope = (mkEnvelope identifier (ByteString.pack "payload")) {partition = Just (Text.pack (show number))}
                  acknowledgement = AckHandle (\_ -> liftIO $ atomicModifyIORef' finalized (\old -> (old + 1, ())))
              pure (Just (mkIngested envelope acknowledgement, ()))
          )
          ()
      adapter = Adapter "batch-key-soak" source (pure ())
      config = defaultBatchConfig {batchSize = 100, batchTimeout = realToFrac delay, batchKey = \envelope -> BatchKey (maybe "missing" id envelope.partition)}
      application = runEff $ runTracingNoop $ do
        started <- runApp defaultAppConfig {inboxSize = 100} [(ProcessorId label, mkBatchProcessor adapter (\_ _ -> pure ackAllOk) config)]
        case started of
          Left err -> liftIO $ ioError (userError (show err))
          Right handle -> waitApp handle
      sample = bracket (openSamplers directory) closeSamplers (\(rts, process, start) -> sampleLoop rts process start 0)
  createDirectoryIfMissing True directory
  context.send WrkReady
  awaitStart
  withAsync sample \sampler -> withAsync producer \producerThread -> withAsync application \appThread -> do
    awaitStop
    producedCount <- readIORef produced
    finalizedCount <- readIORef finalized
    applicationState <- poll appThread
    context.send (WrkCustom "batch-soak-result" (object ["produced" .= producedCount, "finalized" .= finalizedCount, "running" .= maybe True (const False) applicationState, "applicationState" .= fmap (either show (const "completed")) applicationState]))
    cancel producerThread
    cancel appThread
    cancel sampler
  where
    awaitStart = context.receive >>= \case Just CtlStart -> pure (); Nothing -> ioError (userError "batch soak controller disconnected"); _ -> awaitStart
    awaitStop = context.receive >>= \case Just (CtlStop _) -> pure (); Nothing -> ioError (userError "batch soak controller disconnected"); _ -> awaitStop

openSamplers :: FilePath -> IO (Maybe RtsSampler, ProcessSampler, Word64)
openSamplers directory = do
  rts <- openRtsSampler (directory </> "rts.csv")
  process <- openProcessSampler (directory </> "proc.csv")
  start <- getMonotonicTimeNSec
  pure (rts, process, start)

closeSamplers :: (Maybe RtsSampler, ProcessSampler, Word64) -> IO ()
closeSamplers (rts, process, _) = do
  maybe (pure ()) closeRtsSampler rts
  closeProcessSampler process

sampleLoop :: Maybe RtsSampler -> ProcessSampler -> Word64 -> Int -> IO ()
sampleLoop rts process start count = do
  when (count `mod` (10 :: Int) == 0) performMajorGC
  now <- getMonotonicTimeNSec
  wall <- getPOSIXTime
  let prefix = [Text.pack (show (now - start)), Text.pack (show (round (wall * 1000) :: Integer)), "steady"]
  maybe (pure ()) (\sampler -> sampleRts sampler prefix) rts
  sampleProcess process prefix
  threadDelay 1000000
  sampleLoop rts process start (count + 1)
