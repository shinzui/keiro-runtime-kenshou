module Kenshou.Measure.Summary
  ( SummaryError (..),
    SummaryWindow (..),
    MeasurementSummary (..),
    summarizeRunDir,
    summarizeRunDirWithHealth,
  )
where

import Control.Exception (SomeException, try)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as ByteString
import Data.List (isSuffixOf)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Data.Word (Word64)
import Kenshou.Measure.Health
import Kenshou.Measure.Histogram qualified as Histogram
import Kenshou.Measure.Histogram.Codec (decodeHistogram)
import Kenshou.Measure.Metrics
import Kenshou.Measure.Samples
import Kenshou.Measure.Stats (arithmeticMean)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath ((</>))
import Text.Read (readMaybe)

newtype SummaryError = SummaryError Text deriving stock (Eq, Show)

data SummaryWindow = SummaryWindow
  { steadyStartMonoNs :: Word64,
    steadyEndMonoNs :: Word64,
    steadySeconds :: Double
  }
  deriving stock (Eq, Show)

data MeasurementSummary = MeasurementSummary
  { grade :: Text,
    gradeReasons :: [Text],
    window :: SummaryWindow,
    ops :: Map Text Value,
    metrics :: Map Text Metric,
    health :: [HealthObservation]
  }
  deriving stock (Eq, Show)

instance ToJSON SummaryWindow where
  toJSON value = object ["steadyStartMonoNs" .= value.steadyStartMonoNs, "steadyEndMonoNs" .= value.steadyEndMonoNs, "steadySeconds" .= value.steadySeconds]

instance FromJSON SummaryWindow where
  parseJSON = withObject "SummaryWindow" \value -> SummaryWindow <$> value .: "steadyStartMonoNs" <*> value .: "steadyEndMonoNs" <*> value .: "steadySeconds"

instance ToJSON MeasurementSummary where
  toJSON summary =
    object
      [ "schema" .= ("kenshou.measurements/v1" :: Text),
        "algorithm" .= object ["name" .= ("kenshou-summary" :: Text), "version" .= (1 :: Int)],
        "grade" .= summary.grade,
        "gradeReasons" .= summary.gradeReasons,
        "window" .= summary.window,
        "ops" .= summary.ops,
        "metrics" .= summary.metrics,
        "health" .= summary.health
      ]

instance FromJSON MeasurementSummary where
  parseJSON = withObject "MeasurementSummary" \value -> do
    schema <- value .: "schema"
    if schema /= ("kenshou.measurements/v1" :: Text) then fail "unsupported measurement summary" else pure ()
    MeasurementSummary <$> value .: "grade" <*> value .:? "gradeReasons" .!= [] <*> value .: "window" <*> value .: "ops" <*> value .: "metrics" <*> value .:? "health" .!= []

data Counts = Counts {successes :: Word64, failures :: Word64, units :: Word64}

data SampleMeta = SampleMeta {operation :: Text, latencyBasis :: Text, rawFull :: Bool, steadyCounts :: Counts, errorCauses :: Map Text Word64}

instance FromJSON Counts where
  parseJSON = withObject "Counts" \value -> Counts <$> value .:? "successes" .!= 0 <*> value .:? "failures" .!= 0 <*> value .:? "units" .!= 0

instance FromJSON SampleMeta where
  parseJSON = withObject "SampleMeta" \value -> do
    phaseCounts <- value .: "phaseCounts"
    steady <- withObject "phaseCounts" (\counts -> counts .:? "steady" .!= Counts 0 0 0) phaseCounts
    raw <- value .: "rawSamples"
    SampleMeta <$> value .: "operation" <*> value .:? "latencyBasis" .!= "intended-start" <*> pure (raw == String "full") <*> pure steady <*> value .:? "errorCauses" .!= Map.empty

summarizeRunDir :: FilePath -> IO (Either SummaryError MeasurementSummary)
summarizeRunDir = summarizeRunDirWithHealth defaultHealthConfig

summarizeRunDirWithHealth :: HealthConfig -> FilePath -> IO (Either SummaryError MeasurementSummary)
summarizeRunDirWithHealth healthConfig runDir = do
  exists <- doesDirectoryExist runDir
  if not exists
    then pure (Left (SummaryError "run directory does not exist"))
    else do
      result <- try (summarize healthConfig runDir)
      pure (either (Left . SummaryError . Text.pack . show) id (result :: Either SomeException (Either SummaryError MeasurementSummary)))

summarize :: HealthConfig -> FilePath -> IO (Either SummaryError MeasurementSummary)
summarize healthConfig runDir = do
  windowResult <- readWindow (runDir </> "series" </> "load.csv")
  case windowResult of
    Left err -> pure (Left err)
    Right window -> do
      files <- listDirectory (runDir </> "samples")
      operationResults <- traverse (summarizeOperation runDir window) [file | file <- files, ".meta.json" `isSuffixOf` file]
      case sequence operationResults of
        Left err -> pure (Left err)
        Right operations -> do
          let operationMap = Map.fromList [(name, value) | (name, value, _, _) <- operations]
              operationMetrics = Map.unions [values | (_, _, values, _) <- operations]
              totalOps = sum [metric.value | (name, metric) <- Map.toList operationMetrics, ".throughput" `Text.isSuffixOf` name] * window.steadySeconds
          runtimeMetrics <- summarizeSeries runDir window totalOps
          reasons <- gradeReasonsFromRun runDir (all (\(_, _, _, full) -> full) operations)
          health <- evaluateHealth healthConfig runDir
          let healthReasons = ["health:" <> item.gate | item <- health, item.severity /= Info]
              allReasons = reasons <> healthReasons
          pure (Right (MeasurementSummary (if null allReasons then "benchmark" else "exploratory") allReasons window operationMap (operationMetrics <> runtimeMetrics) health))

summarizeOperation :: FilePath -> SummaryWindow -> FilePath -> IO (Either SummaryError (Text, Value, Map Text Metric, Bool))
summarizeOperation runDir window metaFile = do
  decoded <- eitherDecodeFileStrict' (runDir </> "samples" </> metaFile) :: IO (Either String SampleMeta)
  case decoded of
    Left message -> pure (Left (SummaryError (Text.pack message)))
    Right meta -> do
      let base = Text.unpack meta.operation
          histogramPath = runDir </> "samples" </> base <> ".hist"
          servicePath = runDir </> "samples" </> base <> ".service.hist"
          rawPath = runDir </> "samples" </> base <> ".raw"
      latency <- decodeHistogram <$> ByteString.readFile histogramPath
      service <- decodeHistogram <$> ByteString.readFile servicePath
      rawOk <-
        if meta.rawFull
          then do
            rawExists <- doesFileExist rawPath
            if not rawExists then pure False else (== 0) . (.ignoredBytes) <$> readSamples rawPath (const (pure ()))
          else pure True
      case (latency, service, rawOk) of
        (_, _, False) -> pure (Left (SummaryError ("raw sample file is missing or truncated for " <> meta.operation)))
        (Left message, _, _) -> pure (Left (SummaryError message))
        (_, Left message, _) -> pure (Left (SummaryError message))
        (Right latencyHistogram, Right serviceHistogram, _) -> do
          let count = Histogram.totalCount latencyHistogram
              failures = meta.steadyCounts.failures
              throughput = fromIntegral count / window.steadySeconds
              unitsPerSecond = fromIntegral meta.steadyCounts.units / window.steadySeconds
              errorRate = if count + failures == 0 then 0 else fromIntegral failures / fromIntegral (count + failures)
              quantile histogram q = fromIntegral (Histogram.valueAtQuantile histogram q) :: Double
              latencyValues = metricSet ("op." <> meta.operation <> ".latency") latencyHistogram
              serviceP99 = quantile serviceHistogram 0.99
              metrics =
                Map.fromList
                  [ ("op." <> meta.operation <> ".throughput", Metric throughput "ops/s"),
                    ("op." <> meta.operation <> ".units-throughput", Metric unitsPerSecond "units/s"),
                    ("op." <> meta.operation <> ".service.p99", Metric serviceP99 "ns"),
                    ("op." <> meta.operation <> ".error-rate", Metric errorRate "ratio")
                  ]
                  <> latencyValues
              value =
                object
                  [ "latencyBasis" .= meta.latencyBasis,
                    "coordinatedOmissionRisk" .= (meta.latencyBasis == "actual-start"),
                    "count" .= count,
                    "reportedSuccesses" .= meta.steadyCounts.successes,
                    "failures" .= failures,
                    "errors" .= meta.errorCauses,
                    "throughput" .= throughput,
                    "unitsPerSecond" .= unitsPerSecond,
                    "latencyNs" .= distribution latencyHistogram,
                    "serviceNs" .= distribution serviceHistogram
                  ]
          pure (Right (meta.operation, value, metrics, meta.rawFull))
  where
    distribution histogram =
      object
        [ "p50" .= Histogram.valueAtQuantile histogram 0.50,
          "p90" .= Histogram.valueAtQuantile histogram 0.90,
          "p99" .= Histogram.valueAtQuantile histogram 0.99,
          "p999" .= Histogram.valueAtQuantile histogram 0.999,
          "max" .= Histogram.maxValue histogram,
          "mean" .= Histogram.meanValue histogram
        ]
    metricSet prefix histogram =
      Map.fromList
        [ (prefix <> ".p50", Metric (fromIntegral (Histogram.valueAtQuantile histogram 0.50)) "ns"),
          (prefix <> ".p90", Metric (fromIntegral (Histogram.valueAtQuantile histogram 0.90)) "ns"),
          (prefix <> ".p99", Metric (fromIntegral (Histogram.valueAtQuantile histogram 0.99)) "ns"),
          (prefix <> ".p999", Metric (fromIntegral (Histogram.valueAtQuantile histogram 0.999)) "ns"),
          (prefix <> ".max", Metric (fromIntegral (Histogram.maxValue histogram)) "ns"),
          (prefix <> ".mean", Metric (Histogram.meanValue histogram) "ns")
        ]

readWindow :: FilePath -> IO (Either SummaryError SummaryWindow)
readWindow path = do
  rows <- readCsv path
  let steady = [readWord (row !! 0) | row <- rows, length row > 2, row !! 2 == "steady"]
      drain = [readWord (row !! 0) | row <- rows, length row > 2, row !! 2 == "drain"]
  pure case (catMaybes steady, catMaybes drain) of
    (start : _, end : _) | end > start -> Right (SummaryWindow start end (fromIntegral (end - start) / 1e9))
    _ -> Left (SummaryError "load.csv has no complete steady window")

summarizeSeries :: FilePath -> SummaryWindow -> Double -> IO (Map Text Metric)
summarizeSeries runDir window totalOps = do
  rts <- numericRows (runDir </> "series" </> "rts.csv") "phase" "steady"
  proc <- numericRows (runDir </> "series" </> "proc.csv") "phase" "steady"
  wal <- numericRows (runDir </> "series" </> "pg-wal.csv") "phase" "steady"
  checkpointer <- numericRows (runDir </> "series" </> "pg-checkpointer.csv") "phase" "steady"
  let delta column rows = (-) <$> (Map.lookup column =<< lastMay rows) <*> (Map.lookup column =<< headMay rows)
      maximumOf column rows = maximumMaybe (mapMaybe (Map.lookup column) rows)
      meanOf column rows = case mapMaybe (Map.lookup column) rows of [] -> Nothing; values -> Just (arithmeticMean values)
      elapsed = fromIntegral (window.steadyEndMonoNs - window.steadyStartMonoNs)
      capabilities = max 1 (maybe 1 id (Map.lookup "capabilities" =<< lastMay rts))
      metrics =
        [ metric "rts.alloc-rate" "bytes/s" ((/ window.steadySeconds) <$> delta "allocated_bytes" rts),
          metric "rts.alloc-bytes-per-op" "bytes/op" ((/ max 1 totalOps) <$> delta "allocated_bytes" rts),
          metric "rts.gc-productivity" "ratio" ((\gc total -> 1 - gc / max 1 total) <$> delta "gc_elapsed_ns" rts <*> delta "elapsed_ns" rts),
          metric "rts.max-live-bytes" "bytes" (maximumOf "max_live_bytes" rts),
          metric "rts.live-bytes-major-mean" "bytes" (meanOf "live_bytes_major_mean" rts),
          metric "proc.cpu-utilisation" "ratio" ((/ (max 1 elapsed * capabilities)) <$> delta "cpu_total_ns" proc),
          metric "proc.rss-max" "bytes" (maximumOf "rss_bytes" proc),
          metric "pg.wal-bytes-per-op" "bytes/op" ((/ max 1 totalOps) <$> delta "wal_bytes" wal),
          metric "pg.checkpoints-in-window" "count" ((+) <$> delta "num_timed" checkpointer <*> delta "num_requested" checkpointer)
        ]
  pure (Map.fromList (catMaybes metrics))
  where
    metric name unit value = (name,) . (`Metric` unit) <$> value

gradeReasonsFromRun :: FilePath -> Bool -> IO [Text]
gradeReasonsFromRun runDir rawFull = do
  decoded <- eitherDecodeFileStrict' (runDir </> "run-spec.json") :: IO (Either String Value)
  let durability = case decoded of
        Right (Object root) -> do
          Object dimensions <- KeyMap.lookup "dimensions" root
          String value <- KeyMap.lookup "pg.durability" dimensions
          pure value
        _ -> Nothing
  pure (["raw samples are not retained in full" | not rawFull] <> ["pg.durability=fsync-off" | durability == Just "fsync-off"])

readCsv :: FilePath -> IO [[Text]]
readCsv path = do
  exists <- doesFileExist path
  if not exists then pure [] else fmap (Text.splitOn ",") . drop 1 . Text.lines <$> Text.readFile path

numericRows :: FilePath -> Text -> Text -> IO [Map Text Double]
numericRows path filterColumn filterValue = do
  exists <- doesFileExist path
  if not exists
    then pure []
    else do
      linesValue <- Text.lines <$> Text.readFile path
      case linesValue of
        [] -> pure []
        header : rows -> do
          let columns = Text.splitOn "," header
              decoded = fmap (Map.fromList . zip columns . fmap readDouble . Text.splitOn ",") rows
          pure [Map.mapMaybe id row | (raw, row) <- zip rows decoded, field columns filterColumn raw == Just filterValue]

field :: [Text] -> Text -> Text -> Maybe Text
field columns wanted row = do
  index <- lookupIndex wanted columns
  atMay (Text.splitOn "," row) index

lookupIndex :: (Eq value) => value -> [value] -> Maybe Int
lookupIndex wanted = go 0
  where
    go _ [] = Nothing; go index (value : rest) = if value == wanted then Just index else go (index + 1) rest

readDouble :: Text -> Maybe Double
readDouble value | Text.null value = Nothing
readDouble value = readMaybe (Text.unpack value)

readWord :: Text -> Maybe Word64
readWord = readMaybe . Text.unpack

headMay, lastMay :: [value] -> Maybe value
headMay [] = Nothing; headMay (value : _) = Just value
lastMay [] = Nothing; lastMay values = Just (last values)

maximumMaybe :: (Ord value) => [value] -> Maybe value
maximumMaybe [] = Nothing; maximumMaybe values = Just (maximum values)

atMay :: [value] -> Int -> Maybe value
atMay values index = case drop index values of value : _ -> Just value; [] -> Nothing
