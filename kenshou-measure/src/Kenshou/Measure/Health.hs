module Kenshou.Measure.Health
  ( Severity (..),
    HealthObservation (..),
    HealthConfig (..),
    defaultHealthConfig,
    captureHealthNotices,
    evaluateHealth,
    healthOutcome,
  )
where

import Control.Applicative ((<|>))
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.List (isSuffixOf)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Text.IO qualified as Text
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Data.Word (Word64)
import Kenshou.Core.Outcome (Outcome (..))
import System.Directory (copyFile, doesFileExist, listDirectory)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import Text.Read (readMaybe)

data Severity = Info | Soft | Hard deriving stock (Eq, Ord, Show)

data HealthObservation = HealthObservation
  { gate :: Text,
    severity :: Severity,
    fromMonoNs :: Word64,
    toMonoNs :: Word64,
    detail :: Text,
    evidence :: Value
  }
  deriving stock (Eq, Show)

data HealthConfig = HealthConfig
  { cpuSoft :: Double,
    cpuHard :: Double,
    stealSoft :: Double,
    clockStepNs :: Word64,
    pauseNs :: Word64,
    minSteadySamples :: Word64
  }
  deriving stock (Eq, Show)

defaultHealthConfig :: HealthConfig
defaultHealthConfig = HealthConfig 0.70 0.90 0.02 50_000_000 2_000_000_000 1_000

instance ToJSON Severity where
  toJSON Info = String "info"
  toJSON Soft = String "soft"
  toJSON Hard = String "hard"

instance FromJSON Severity where
  parseJSON = withText "Severity" \case
    "info" -> pure Info
    "soft" -> pure Soft
    "hard" -> pure Hard
    _ -> fail "severity must be info, soft, or hard"

instance ToJSON HealthObservation where
  toJSON value =
    object
      [ "gate" .= value.gate,
        "severity" .= value.severity,
        "fromMonoNs" .= value.fromMonoNs,
        "toMonoNs" .= value.toMonoNs,
        "detail" .= value.detail,
        "evidence" .= value.evidence
      ]

instance FromJSON HealthObservation where
  parseJSON = withObject "HealthObservation" \value -> HealthObservation <$> value .: "gate" <*> value .: "severity" <*> value .: "fromMonoNs" <*> value .: "toMonoNs" <*> value .: "detail" <*> value .: "evidence"

data HealthNotice = HealthNotice Text Severity UTCTime Text

instance FromJSON HealthNotice where
  parseJSON = withObject "HealthNotice" \value -> do
    schema <- value .: "schema"
    if schema /= ("kenshou.health-notice/v1" :: Text) then fail "unsupported health notice" else pure ()
    HealthNotice <$> value .: "source" <*> value .: "severity" <*> value .: "at" <*> value .: "detail"

type CsvRow = Map Text Text

captureHealthNotices :: FilePath -> IO (Maybe FilePath)
captureHealthNotices runDir = do
  let captured = runDir </> "health-notices.jsonl"
  source <- lookupEnv "KENSHOU_HEALTH_NOTICES"
  case source of
    Just path | path /= captured -> do
      exists <- doesFileExist path
      if exists then copyFile path captured >> pure (Just captured) else existing captured
    _ -> existing captured
  where
    existing path = do
      exists <- doesFileExist path
      pure (if exists then Just path else Nothing)

evaluateHealth :: HealthConfig -> FilePath -> IO [HealthObservation]
evaluateHealth config runDir = do
  samplerRows <- steadyRows (runDir </> "series" </> "sampler.csv")
  loadRows <- readCsvRows (runDir </> "series" </> "load.csv")
  hostRows <- steadyRows (runDir </> "series" </> "host.csv")
  processRows <- steadyRows (runDir </> "series" </> "proc.csv")
  rtsRows <- steadyRows (runDir </> "series" </> "rts.csv")
  checkpointRows <- steadyRows (runDir </> "series" </> "pg-checkpointer.csv")
  spec <- decodeValue (runDir </> "run-spec.json")
  sampleObservations <- sampleFileObservations config runDir
  noticeObservations <- noticeFileObservations runDir samplerRows
  let bounds = steadyWindow loadRows samplerRows
      intervalNs = round (numberAt ["knobs", "measure.sample-interval-ms"] spec * 1_000_000)
      effectivePauseNs = max config.pauseNs (5 * intervalNs)
      cpu = driverCpu config bounds hostRows processRows rtsRows
      driverHard = any (\item -> item.gate == "driver-cpu-saturation" && item.severity == Hard) cpu
      overload = backlogObservations bounds driverHard spec loadRows
      clocks = samplerObservations config effectivePauseNs bounds samplerRows
      checkpoint = checkpointObservations bounds checkpointRows
      rts = [observation bounds "rts-stats-unavailable" Info "GHC RTS statistics were unavailable" Null | null rtsRows]
  pure (cpu <> overload <> clocks <> checkpoint <> sampleObservations bounds <> rts <> noticeObservations bounds)

healthOutcome :: [HealthObservation] -> Maybe Outcome
healthOutcome observations
  | any ((== Hard) . (.severity)) observations = Just InfrastructureFailure
  | any ((== Soft) . (.severity)) observations = Just Inconclusive
  | otherwise = Nothing

driverCpu :: HealthConfig -> (Word64, Word64) -> [CsvRow] -> [CsvRow] -> [CsvRow] -> [HealthObservation]
driverCpu config bounds hostRows processRows rtsRows = saturation <> steal
  where
    hostDeltas = fmap (\fieldName -> max 0 (delta fieldName hostRows)) ["cpu_user", "cpu_nice", "cpu_system", "cpu_idle", "cpu_iowait", "cpu_irq", "cpu_softirq", "cpu_steal"]
    hostTotal = sum hostDeltas
    hostBusy = if hostTotal <= 0 then Nothing else Just ((hostTotal - hostDeltas !! 3 - hostDeltas !! 4) / hostTotal)
    capabilities = max 1 (fromMaybe 1 (lastNumber "capabilities" rtsRows))
    elapsed = max 1 (delta "t_mono_ns" processRows)
    processBusy = if length processRows < 2 then Nothing else Just (delta "cpu_total_ns" processRows / elapsed / capabilities)
    busy = if length hostRows >= 2 then hostBusy else processBusy
    saturation = case busy of
      Just value | value > config.cpuHard -> [cpuObservation Hard value]
      Just value | value > config.cpuSoft -> [cpuObservation Soft value]
      _ -> []
    stealFraction = if hostTotal <= 0 then 0 else hostDeltas !! 7 / hostTotal
    steal = [observation bounds "cpu-steal" Soft "host CPU steal exceeded the health threshold" (object ["fraction" .= stealFraction, "threshold" .= config.stealSoft]) | stealFraction > config.stealSoft]
    cpuObservation level value = observation bounds "driver-cpu-saturation" level "load driver CPU use exceeded the health threshold" (object ["utilisation" .= value, "softThreshold" .= config.cpuSoft, "hardThreshold" .= config.cpuHard])

backlogObservations :: (Word64, Word64) -> Bool -> Value -> [CsvRow] -> [HealthObservation]
backlogObservations bounds driverHard spec rows =
  case maximumMaybe (mapMaybe (fieldNumber "max_lag_ns") rows) of
    Just maximumLag
      | modelName `elem` [Just "open-constant", Just "open-poisson"] && maximumLag > maximumThreshold ->
          let aborted = maximumLag > abortThreshold
              level = if driverHard || aborted then Hard else Soft
           in [observation bounds "open-loop-backlog" level "open-loop arrivals accumulated sustained lag" (object ["maximumLagNs" .= maximumLag, "thresholdNs" .= maximumThreshold, "abortedEarly" .= aborted])]
    _ -> []
  where
    modelName = textAt ["knobs", "load.model"] spec
    maximumThreshold = numberAt ["knobs", "load.max-lag-ms"] spec * 1_000_000
    abortThreshold = numberAt ["knobs", "load.abort-lag-ms"] spec * 1_000_000

samplerObservations :: HealthConfig -> Word64 -> (Word64, Word64) -> [CsvRow] -> [HealthObservation]
samplerObservations config effectivePauseNs bounds rows = clock <> late <> overrun
  where
    maximumClockStep = maximumOrZero (fmap abs (mapMaybe (fieldNumber "wall_minus_mono_ns") rows))
    maximumLate = maximumOrZero (mapMaybe (fieldNumber "late_ns") rows)
    maximumCost = maximumOrZero (mapMaybe (fieldNumber "cost_ns") rows)
    interval = if length rows < 2 then 0 else delta "scheduled_mono_ns" rows / fromIntegral (length rows - 1)
    clock = [observation bounds "clock-anomaly" Soft "wall and monotonic clocks changed by more than 50 ms" (object ["maximumStepNs" .= maximumClockStep, "thresholdNs" .= config.clockStepNs]) | maximumClockStep > fromIntegral config.clockStepNs]
    late = [observation bounds "clock-anomaly" Hard "the sampler observed a process or virtual-machine pause" (object ["maximumLateNs" .= maximumLate, "thresholdNs" .= effectivePauseNs]) | maximumLate > fromIntegral effectivePauseNs]
    overrun = [observation bounds "sampler-overrun" Soft "sampling cost exceeded the configured interval" (object ["maximumCostNs" .= maximumCost, "intervalNs" .= interval]) | interval > 0 && maximumCost > interval]

checkpointObservations :: (Word64, Word64) -> [CsvRow] -> [HealthObservation]
checkpointObservations _ [] = []
checkpointObservations bounds rows =
  [ observation
      bounds
      "checkpoint-in-window"
      Info
      "PostgreSQL checkpoint activity in the steady window"
      (object ["started" .= started, "completed" .= completed, "overlapFraction" .= overlapFraction])
  ]
  where
    started = max 0 (delta "num_timed" rows) + max 0 (delta "num_requested" rows)
    lsnChanges = length [() | (left, right) <- adjacent rows, Map.lookup "checkpoint_lsn" left /= Map.lookup "checkpoint_lsn" right]
    completed = case lastNumber "num_done" rows of Just _ -> max 0 (delta "num_done" rows); Nothing -> fromIntegral lsnChanges
    intervals = adjacent rows
    active (left, right) = Map.lookup "checkpoint_lsn" left /= Map.lookup "checkpoint_lsn" right || fromMaybe 0 (fieldNumber "buffers_written" right) > fromMaybe 0 (fieldNumber "buffers_written" left)
    overlapFraction :: Double
    overlapFraction = if null intervals then 0 else fromIntegral (length (filter active intervals)) / fromIntegral (length intervals)

sampleFileObservations :: HealthConfig -> FilePath -> IO ((Word64, Word64) -> [HealthObservation])
sampleFileObservations config runDir = do
  let directory = runDir </> "samples"
  files <- listDirectory directory
  decoded <- traverse (decodeValue . (directory </>)) [file | file <- files, ".meta.json" `isSuffixOf` file]
  pure \bounds -> concatMap (fromMeta bounds) decoded
  where
    fromMeta bounds value =
      let operation = fromMaybe "unknown" (textAt ["operation"] value)
          successes = numberAt ["phaseCounts", "steady", "successes"] value
          failures = numberAt ["phaseCounts", "steady", "failures"] value
          samples = successes + failures
          backpressure = numberAt ["backpressureCount"] value
       in [observation bounds "insufficient-samples" Soft ("operation " <> operation <> " has too few steady samples") (object ["operation" .= operation, "samples" .= samples, "minimum" .= config.minSteadySamples]) | samples < fromIntegral config.minSteadySamples]
            <> [observation bounds "recorder-backpressure" Soft ("operation " <> operation <> " experienced recorder back-pressure") (object ["operation" .= operation, "count" .= backpressure]) | backpressure > 0]

noticeFileObservations :: FilePath -> [CsvRow] -> IO ((Word64, Word64) -> [HealthObservation])
noticeFileObservations runDir samplerRows = do
  let path = runDir </> "health-notices.jsonl"
  exists <- doesFileExist path
  if not exists
    then pure (const [])
    else do
      notices <- fmap (mapMaybe decodeNotice . Text.lines) (Text.readFile path)
      let wallBounds = wallTimeBounds samplerRows
      pure \bounds -> [noticeObservation bounds notice | notice@(HealthNotice _ _ noticeAt _) <- notices, within wallBounds noticeAt]
  where
    decodeNotice :: Text -> Maybe HealthNotice
    decodeNotice = decodeStrict' . Encoding.encodeUtf8
    noticeObservation bounds (HealthNotice noticeSource noticeSeverity noticeAt noticeDetail) = observation bounds "host-notice" noticeSeverity noticeDetail (object ["source" .= noticeSource, "at" .= noticeAt])
    within Nothing _ = True
    within (Just (start, end)) instant = instant >= start && instant <= end

observation :: (Word64, Word64) -> Text -> Severity -> Text -> Value -> HealthObservation
observation (start, end) gate severity detail evidence = HealthObservation gate severity start end detail evidence

steadyWindow :: [CsvRow] -> [CsvRow] -> (Word64, Word64)
steadyWindow loadRows samplerRows =
  let steadyStart = listToMaybeNumber "t_mono_ns" [row | row <- loadRows, Map.lookup "phase" row == Just "steady"]
      steadyEnd = listToMaybeNumber "t_mono_ns" [row | row <- loadRows, Map.lookup "phase" row `elem` [Just "drain", Just "done"]]
      fallback = boundsOf samplerRows
   in (floor (fromMaybe (fromIntegral (fst fallback)) steadyStart), floor (fromMaybe (fromIntegral (snd fallback)) steadyEnd))

wallTimeBounds :: [CsvRow] -> Maybe (UTCTime, UTCTime)
wallTimeBounds rows = do
  start <- listToMaybeNumber "t_wall_ms" rows
  end <- lastNumber "t_wall_ms" rows
  pure (toUtc start, toUtc end)
  where
    toUtc value = posixSecondsToUTCTime (realToFrac (value / 1_000))

readCsvRows :: FilePath -> IO [CsvRow]
readCsvRows path = do
  exists <- doesFileExist path
  if not exists
    then pure []
    else do
      rows <- Text.lines <$> Text.readFile path
      pure case rows of
        [] -> []
        header : body -> fmap (Map.fromList . zip (Text.splitOn "," header) . Text.splitOn ",") body

steadyRows :: FilePath -> IO [CsvRow]
steadyRows path = filter ((== Just "steady") . Map.lookup "phase") <$> readCsvRows path

decodeValue :: FilePath -> IO Value
decodeValue path = do
  decoded <- eitherDecodeFileStrict' path
  pure (either (const Null) id decoded)

textAt :: [Text] -> Value -> Maybe Text
textAt [] (String value) = Just value
textAt (name : rest) (Object value) = KeyMap.lookup (Key.fromText name) value >>= textAt rest
textAt _ _ = Nothing

numberAt :: [Text] -> Value -> Double
numberAt [] (Number value) = realToFrac value
numberAt (name : rest) (Object value) = maybe 0 (numberAt rest) (KeyMap.lookup (Key.fromText name) value)
numberAt _ _ = 0

fieldNumber :: Text -> CsvRow -> Maybe Double
fieldNumber name row = Map.lookup name row >>= readMaybe . Text.unpack

delta :: Text -> [CsvRow] -> Double
delta name rows = fromMaybe 0 ((-) <$> (lastNumber name rows) <*> (listToMaybeNumber name rows))

listToMaybeNumber :: Text -> [CsvRow] -> Maybe Double
listToMaybeNumber _ [] = Nothing
listToMaybeNumber name (row : rest) = fieldNumber name row <|> listToMaybeNumber name rest

lastNumber :: Text -> [CsvRow] -> Maybe Double
lastNumber name = listToMaybeNumber name . reverse

boundsOf :: [CsvRow] -> (Word64, Word64)
boundsOf rows = (floor (fromMaybe 0 (listToMaybeNumber "t_mono_ns" rows)), floor (fromMaybe 0 (lastNumber "t_mono_ns" rows)))

adjacent :: [value] -> [(value, value)]
adjacent values = zip values (drop 1 values)

maximumMaybe :: (Ord value) => [value] -> Maybe value
maximumMaybe [] = Nothing
maximumMaybe values = Just (maximum values)

maximumOrZero :: (Ord value, Num value) => [value] -> value
maximumOrZero = fromMaybe 0 . maximumMaybe
