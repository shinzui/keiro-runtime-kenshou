{-# LANGUAGE BangPatterns #-}

module Kenshou.Measure.Recorder
  ( OpName (..),
    ErrorCause (..),
    OpResult (..),
    RawSamplePolicy (..),
    RecorderConfig (..),
    Recorder,
    OpHandle,
    WorkerRecorder,
    OpReport (..),
    RecorderReport (..),
    newRecorder,
    registerOp,
    newWorkerRecorder,
    recordOp,
    recordDuration,
    timeOp,
    finishRecorder,
  )
where

import Control.Monad (forM, forM_, when)
import Data.Aeson (ToJSON (..), encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.ByteString qualified as ByteString
import Data.ByteString.Builder (byteString, toLazyByteString, word16LE, word32LE, word64LE, word8)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word
import Kenshou.Measure.Clock
import Kenshou.Measure.Histogram (Histogram, HistogramConfig)
import Kenshou.Measure.Histogram qualified as Histogram
import Kenshou.Measure.Histogram.Codec (encodeHistogram)
import Kenshou.Measure.Phase
import Kenshou.Measure.Samples
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

newtype OpName = OpName Text
  deriving stock (Eq, Ord, Show)

newtype ErrorCause = ErrorCause Text
  deriving stock (Eq, Ord, Show)

data OpResult = OpOk !Int | OpFailed !ErrorCause
  deriving stock (Eq, Show)

data RawSamplePolicy = RawFull | RawSampled !Word64 | RawOff
  deriving stock (Eq, Show)

instance ToJSON RawSamplePolicy where
  toJSON RawFull = toJSON ("full" :: Text)
  toJSON (RawSampled oneIn) = object ["mode" .= ("sampled" :: Text), "oneIn" .= oneIn]
  toJSON RawOff = toJSON ("off" :: Text)

data RecorderConfig = RecorderConfig
  { runDir :: FilePath,
    origin :: Origin,
    processLabel :: Maybe Text,
    histogram :: HistogramConfig,
    rawSamples :: RawSamplePolicy,
    intervalHistogramSeconds :: Word64,
    declareArtifact :: FilePath -> Text -> IO ()
  }

data Recorder = Recorder
  { config :: RecorderConfig,
    phaseClock :: PhaseClock,
    operations :: IORef [OpHandle]
  }

data OpHandle = OpHandle
  { recorder :: Recorder,
    name :: OpName,
    writer :: Maybe SampleWriter,
    workers :: IORef [WorkerRecorder]
  }

data WorkerRecorder = WorkerRecorder
  { operation :: OpHandle,
    workerId :: Word16,
    latency :: Histogram.MutableHistogram,
    service :: Histogram.MutableHistogram,
    phaseCounts :: IORef (Map Phase (Word64, Word64, Word64)),
    errors :: IORef (Map ErrorCause Word64),
    intervals :: IORef (Map Word64 Histogram.MutableHistogram),
    pending :: IORef [SampleRecord],
    pendingCount :: IORef Int,
    seen :: IORef Word64
  }

data OpReport = OpReport
  { name :: OpName,
    latency :: Histogram,
    service :: Histogram,
    phaseCounts :: Map Phase (Word64, Word64, Word64),
    errors :: Map ErrorCause Word64,
    backpressureCount :: Word64,
    histogramFile :: FilePath,
    serviceHistogramFile :: FilePath,
    rawFile :: Maybe FilePath,
    intervalHistogramFile :: Maybe FilePath,
    metadataFile :: FilePath
  }

data RecorderReport = RecorderReport
  { operations :: [OpReport],
    backpressureCount :: Word64
  }

newRecorder :: RecorderConfig -> PhaseClock -> IO Recorder
newRecorder config phaseClock = do
  createDirectoryIfMissing True (config.runDir </> "samples")
  Recorder config phaseClock <$> newIORef []

registerOp :: Recorder -> OpName -> IO OpHandle
registerOp recorder name@(OpName nameText) = do
  let rawPath = samplePath recorder.config nameText "raw"
      label = maybe "harness" id recorder.config.processLabel
  writer <- case recorder.config.rawSamples of
    RawOff -> pure Nothing
    _ -> Just <$> openSampleWriter rawPath (SampleHeader recorder.config.origin MonotonicClock nameText label)
  handle <- OpHandle recorder name writer <$> newIORef []
  modifyIORef' recorder.operations (<> [handle])
  pure handle

newWorkerRecorder :: OpHandle -> Int -> IO WorkerRecorder
newWorkerRecorder operation workerNumber = do
  latency <- Histogram.newHistogram operation.recorder.config.histogram
  service <- Histogram.newHistogram operation.recorder.config.histogram
  worker <-
    WorkerRecorder operation (fromIntegral workerNumber) latency service
      <$> newIORef Map.empty
      <*> newIORef Map.empty
      <*> newIORef Map.empty
      <*> newIORef []
      <*> newIORef 0
      <*> newIORef 0
  modifyIORef' operation.workers (<> [worker])
  pure worker

recordOp :: WorkerRecorder -> Word64 -> Word64 -> Word64 -> OpResult -> IO ()
recordOp worker intended actual end result = do
  phase <- phaseOf worker.operation.recorder.phaseClock intended
  let serviceNs = end - min end actual
      latencyNs = end - min end intended
      (successes, failures, units) = case result of
        OpOk completed -> (1, 0, fromIntegral (max 0 completed))
        OpFailed _ -> (0, 1, 0)
  when (phase == Steady) do
    Histogram.recordValue worker.latency latencyNs
    Histogram.recordValue worker.service serviceNs
    when (worker.operation.recorder.config.rawSamples /= RawFull) (recordInterval worker intended latencyNs)
  modifyIORef' worker.phaseCounts (Map.insertWith addCounts phase (successes, failures, units))
  case result of
    OpFailed cause -> modifyIORef' worker.errors (Map.insertWith (+) cause 1)
    OpOk _ -> pure ()
  sequenceNumber <- atomicModifyIORef' worker.seen (\value -> (value + 1, value))
  when (retain worker.operation.recorder.config.rawSamples sequenceNumber) do
    let outcomeCode = case result of OpOk _ -> 0; OpFailed _ -> 1
    modifyIORef' worker.pending (SampleRecord intended actual end outcomeCode units :)
    count <- atomicModifyIORef' worker.pendingCount (\value -> let next = value + 1 in (next, next))
    when (count >= 512) (flushWorker worker)

recordDuration :: WorkerRecorder -> Word64 -> Word64 -> OpResult -> IO ()
recordDuration worker end duration = recordOp worker (end - min end duration) (end - min end duration) end

timeOp :: WorkerRecorder -> IO OpResult -> IO OpResult
timeOp worker action = do
  start <- nowNs
  result <- action
  end <- nowNs
  recordOp worker start start end result
  pure result

finishRecorder :: Recorder -> IO RecorderReport
finishRecorder recorder = do
  operations <- readIORef recorder.operations >>= mapM finishOperation
  pure RecorderReport {operations, backpressureCount = sum (fmap (.backpressureCount) operations)}

finishOperation :: OpHandle -> IO OpReport
finishOperation operation = do
  workers <- readIORef operation.workers
  mapM_ flushWorker workers
  forM_ operation.writer closeSampleWriter
  latency <- mergeWorkerHistograms operation.recorder.config.histogram workers (.latency)
  service <- mergeWorkerHistograms operation.recorder.config.histogram workers (.service)
  phaseCounts <- fmap (Map.unionsWith addCounts) (mapM (readIORef . (.phaseCounts)) workers)
  errors <- fmap (Map.unionsWith (+)) (mapM (readIORef . (.errors)) workers)
  backpressureCount <- maybe (pure 0) sampleWriterBackpressure operation.writer
  intervalHistograms <- finishIntervals operation.recorder.config workers
  let OpName nameText = operation.name
      histogramFile = samplePath operation.recorder.config nameText "hist"
      serviceHistogramFile = samplePath operation.recorder.config nameText "service.hist"
      metadataFile = samplePath operation.recorder.config nameText "meta.json"
      rawFile = case operation.writer of Nothing -> Nothing; Just _ -> Just (samplePath operation.recorder.config nameText "raw")
      intervalHistogramFile = if null intervalHistograms then Nothing else Just (samplePath operation.recorder.config nameText "ihist")
  writeBytes histogramFile (encodeHistogram latency)
  writeBytes serviceHistogramFile (encodeHistogram service)
  forM_ intervalHistogramFile \path -> writeIntervalHistograms operation.recorder.config path intervalHistograms
  LazyByteString.writeFile metadataFile $
    encode
      ( object
          [ "schema" .= ("kenshou.sample-meta/v1" :: Text),
            "operation" .= nameText,
            "latencyBasis" .= ("intended-start" :: Text),
            "clock" .= ("monotonic" :: Text),
            "rawSamples" .= operation.recorder.config.rawSamples,
            "phaseCounts" .= object [Key.fromText (renderPhase phase) .= object ["successes" .= successes, "failures" .= failures, "units" .= units] | (phase, (successes, failures, units)) <- Map.toAscList phaseCounts],
            "errorCauses" .= object [Key.fromText cause .= count | (ErrorCause cause, count) <- Map.toAscList errors],
            "files" .= object ["histogram" .= histogramFile, "serviceHistogram" .= serviceHistogramFile, "raw" .= rawFile, "intervalHistogram" .= intervalHistogramFile],
            "backpressureCount" .= backpressureCount
          ]
      )
  let artifacts = [(histogramFile, "application/vnd.kenshou.histogram"), (serviceHistogramFile, "application/vnd.kenshou.histogram"), (metadataFile, "application/json")] <> maybe [] (\path -> [(path, "application/vnd.kenshou.samples")]) rawFile <> maybe [] (\path -> [(path, "application/vnd.kenshou.interval-histograms")]) intervalHistogramFile
  mapM_ (uncurry operation.recorder.config.declareArtifact) artifacts
  pure OpReport {name = operation.name, latency, service, phaseCounts, errors, backpressureCount, histogramFile, serviceHistogramFile, rawFile, intervalHistogramFile, metadataFile}

flushWorker :: WorkerRecorder -> IO ()
flushWorker worker = case worker.operation.writer of
  Nothing -> writeIORef worker.pending [] >> writeIORef worker.pendingCount 0
  Just writer -> do
    records <- atomicModifyIORef' worker.pending (\pending -> ([], reverse pending))
    writeIORef worker.pendingCount 0
    writeSampleBlock writer worker.workerId records

mergeWorkerHistograms :: HistogramConfig -> [WorkerRecorder] -> (WorkerRecorder -> Histogram.MutableHistogram) -> IO Histogram
mergeWorkerHistograms config workers project = do
  histograms <- mapM (Histogram.freeze . project) workers
  case histograms of
    [] -> Histogram.newHistogram config >>= Histogram.freeze
    first : rest -> case foldl' combine (Right first) rest of
      Left message -> ioError (userError (Text.unpack message))
      Right value -> pure value
  where
    combine accumulated next = accumulated >>= (`Histogram.merge` next)

samplePath :: RecorderConfig -> Text -> FilePath -> FilePath
samplePath config operation extension = config.runDir </> "samples" </> Text.unpack operation <> maybe "" (("." <>) . Text.unpack) config.processLabel <> "." <> extension

writeBytes :: FilePath -> ByteString.ByteString -> IO ()
writeBytes = ByteString.writeFile

retain :: RawSamplePolicy -> Word64 -> Bool
retain RawFull _ = True
retain (RawSampled oneIn) sequenceNumber = oneIn > 0 && sequenceNumber `mod` oneIn == 0
retain RawOff _ = False

recordInterval :: WorkerRecorder -> Word64 -> Word64 -> IO ()
recordInterval worker intended latencyNs = do
  let seconds = max 1 worker.operation.recorder.config.intervalHistogramSeconds
      intervalNs = seconds * 1_000_000_000
      epoch = intended `div` intervalNs
  existing <- Map.lookup epoch <$> readIORef worker.intervals
  histogram <- case existing of
    Just value -> pure value
    Nothing -> do
      value <- Histogram.newHistogram worker.operation.recorder.config.histogram
      modifyIORef' worker.intervals (Map.insert epoch value)
      pure value
  Histogram.recordValue histogram latencyNs

finishIntervals :: RecorderConfig -> [WorkerRecorder] -> IO [(Word64, Histogram)]
finishIntervals config workers = do
  workerMaps <- mapM (readIORef . (.intervals)) workers
  let epochs = Set.toAscList (Set.unions (fmap Map.keysSet workerMaps))
  forM epochs \epoch -> do
    histograms <- forM workerMaps \intervals -> traverse Histogram.freeze (Map.lookup epoch intervals)
    empty <- Histogram.newHistogram config.histogram >>= Histogram.freeze
    let mergeOne accumulated Nothing = accumulated
        mergeOne (Left message) _ = Left message
        mergeOne (Right accumulated) (Just next) = Histogram.merge accumulated next
    case foldl mergeOne (Right empty) histograms of
      Left message -> ioError (userError (Text.unpack message))
      Right histogram -> pure (epoch, histogram)

writeIntervalHistograms :: RecorderConfig -> FilePath -> [(Word64, Histogram)] -> IO ()
writeIntervalHistograms config path histograms =
  ByteString.writeFile path . LazyByteString.toStrict . toLazyByteString $
    byteString "KIHS" <> word16LE 1 <> word16LE 0 <> foldMap frame histograms
  where
    intervalNs = max 1 config.intervalHistogramSeconds * 1_000_000_000
    frame (epoch, histogram) =
      let encoded = encodeHistogram histogram
          absoluteStart = epoch * intervalNs
          start = absoluteStart - min absoluteStart config.origin.monoNs
       in word64LE start <> word64LE (start + intervalNs) <> word8 2 <> word32LE (fromIntegral (ByteString.length encoded)) <> byteString encoded

addCounts :: (Word64, Word64, Word64) -> (Word64, Word64, Word64) -> (Word64, Word64, Word64)
addCounts (a, b, c) (x, y, z) =
  let !successes = a + x
      !failures = b + y
      !units = c + z
   in (successes, failures, units)
