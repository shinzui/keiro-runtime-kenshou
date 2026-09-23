module Kenshou.Diagnose.Leak
  ( LeakVerdict (..),
    Expectation (..),
    Aggregation (..),
    ProbeSpec (..),
    LeakSpec (..),
    ProbeReport (..),
    LeakReport (..),
    defaultLeakSpec,
    loadLeakPolicy,
    judgeLeaks,
    analyseRunDirectory,
    majorGcSamples,
    judgeSeries,
    leakOutcome,
  )
where

import Data.Aeson
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import Data.Word (Word64)
import Kenshou.Core.Context qualified as Core
import Kenshou.Core.Outcome (Outcome (..))
import Kenshou.Diagnose.Context qualified as Context
import Kenshou.Diagnose.Document
import Kenshou.Diagnose.Series
import Kenshou.Diagnose.Series.Catalog
import Kenshou.Diagnose.Stats
import System.Directory (doesFileExist)
import System.FilePath ((</>))

data LeakVerdict = LeakSuspected | Stable | InsufficientData
  deriving stock (Eq, Ord, Show)

data Expectation = Bounded | Informational deriving stock (Eq, Show)

data Aggregation = WindowMin | WindowMedian deriving stock (Eq, Show)

data ProbeSpec = ProbeSpec
  { name :: !Text,
    unit :: !Text,
    binding :: !SeriesBinding,
    aggregation :: !Aggregation,
    expectation :: !Expectation,
    floorPerHour :: !Double,
    minGrowth :: !Double,
    minRelativeGrowth :: !Double,
    limit :: !(Maybe Double)
  }
  deriving stock (Eq, Show)

data LeakSpec = LeakSpec
  { probes :: ![ProbeSpec],
    warmupCutSeconds :: !Double,
    minPoints :: !Int,
    minDurationSeconds :: !Double,
    envelopeWindowSeconds :: !Double,
    resamples :: !Int,
    confidence :: !Double
  }
  deriving stock (Eq, Show)

data ProbeReport = ProbeReport
  { probe :: !Text,
    process :: !Text,
    unit :: !Text,
    expectation :: !Expectation,
    basis :: !Text,
    points :: !Int,
    durationSeconds :: !Double,
    first :: !(Maybe Double),
    last :: !(Maybe Double),
    medianLevel :: !(Maybe Double),
    slopePerHour :: !(Maybe Double),
    intervalPerHour :: !(Maybe (Double, Double)),
    secondHalfSlopePerHour :: !(Maybe Double),
    growthOverWindow :: !(Maybe Double),
    projectedHoursToLimit :: !(Maybe Double),
    verdict :: !LeakVerdict,
    reason :: !Text,
    sourceFile :: !FilePath,
    sourceColumn :: !Text
  }
  deriving stock (Eq, Show)

data LeakReport = LeakReport
  { verdict :: !LeakVerdict,
    window :: !(Maybe (Double, Double)),
    seed :: !Word64,
    policy :: !Text,
    probes :: ![ProbeReport]
  }
  deriving stock (Eq, Show)

defaultLeakSpec :: LeakSpec
defaultLeakSpec =
  LeakSpec
    { probes =
        [ bounded "heap.live-bytes" "bytes" WindowMin 1_048_576 2_097_152 0.01,
          bounded "process.native-bytes" "bytes" WindowMedian 8_388_608 8_388_608 0.05,
          bounded "haskell.threads" "count" WindowMedian 1 5 0,
          bounded "os.threads" "count" WindowMedian 1 5 0,
          bounded "os.fds" "count" WindowMedian 1 5 0,
          bounded "pg.connections" "count" WindowMedian 1 5 0,
          informational "pg.relation-bytes" "bytes" WindowMin,
          informational "pg.dead-tuples" "count" WindowMin
        ],
      warmupCutSeconds = 300,
      minPoints = 30,
      minDurationSeconds = 1200,
      envelopeWindowSeconds = 60,
      resamples = 1000,
      confidence = 0.95
    }
  where
    catalog name = fromMaybe (error ("missing default catalog binding " <> Text.unpack name)) (Map.lookup name defaultCatalog)
    bounded name unit aggregation slopeFloor growth relative = ProbeSpec name unit (catalog (if name == "process.native-bytes" then "process.rss-bytes" else name)) aggregation Bounded slopeFloor growth relative Nothing
    informational name unit aggregation = ProbeSpec name unit (catalog name) aggregation Informational 0 0 0 Nothing

loadLeakPolicy :: FilePath -> IO (Either Text LeakSpec)
loadLeakPolicy path = do
  decoded <- eitherDecodeFileStrict' path
  pure case decoded of
    Left err -> Left (Text.pack err)
    Right spec -> Right spec

judgeLeaks :: Core.RunContext -> LeakSpec -> IO LeakReport
judgeLeaks context spec = do
  report <- analyse (Context.runDirectory context) spec (Context.runSeed context) (Context.steadyWindow context)
  generatedAt <- getCurrentTime
  let (runId, scenario) = Context.runIdentity context
      document = Diagnosis LeakDiagnosis runId scenario generatedAt generator (toJSON report)
      relative = "diagnosis/leak.json"
  path <- Core.artifactPath context Core.DiagnosisDir "leak.json"
  LazyByteString.writeFile path (encodeDiagnosis document)
  Core.declareMediaType context relative "application/json"
  Context.publishDiagnosis context "leak" (toJSON report)
  pure report
  where
    generator = Generator "kenshou-diagnose" "0.1.0.0" "theil-sen+moving-block-bootstrap/1"

analyseRunDirectory :: FilePath -> LeakSpec -> Word64 -> IO (Either DiagnoseError LeakReport)
analyseRunDirectory runDirectory spec seed = do
  exists <- doesFileExist (runDirectory </> "run-result.json")
  if not exists
    then pure (Left (InvalidRunDirectory runDirectory "run-result.json is missing"))
    else Right <$> analyse runDirectory spec seed (pure Nothing)

analyse :: FilePath -> LeakSpec -> Word64 -> IO (Maybe (Double, Double)) -> IO LeakReport
analyse runDirectory spec seed getWindow = do
  reports <- catMaybes <$> traverse (analyseProbe runDirectory spec seed) spec.probes
  window <- getWindow
  let bounded = [report.verdict | report <- reports, report.expectation == Bounded]
      overall
        | LeakSuspected `elem` bounded = LeakSuspected
        | null bounded || InsufficientData `elem` bounded = InsufficientData
        | otherwise = Stable
  pure (LeakReport overall window seed "policy" reports)

analyseProbe :: FilePath -> LeakSpec -> Word64 -> ProbeSpec -> IO (Maybe ProbeReport)
analyseProbe runDirectory spec seed probe = do
  (series, postMajor) <-
    if probe.name == "heap.live-bytes"
      then heapSeries runDirectory probe
      else do
        result <- if probe.name == "process.native-bytes" then nativeSeries runDirectory probe else ordinarySeries runDirectory probe
        pure (result, False)
  pure $ Just case series of
    Left err -> emptyReport probe (Text.pack (show err))
    Right raw ->
      let report = judgeSeries (if postMajor then spec {minPoints = min 10 spec.minPoints} else spec) seed probe raw
       in if postMajor then report {basis = "post-major-collection"} else report

heapSeries :: FilePath -> ProbeSpec -> IO (Either DiagnoseError (Vector (Double, Double)), Bool)
heapSeries runDirectory probe = do
  let path = runDirectory </> "series" </> probe.binding.file
      unfiltered = probe.binding {filters = Map.empty}
  live <- readBinding path unfiltered
  majors <- readBinding path (unfiltered {valueColumn = "major_gcs"})
  pure case (live, majors) of
    (Right values, Right counts) -> (Right (majorGcSamples values counts), True)
    (Right _, Left (MissingColumn _ _)) -> (live, False)
    (Left err, _) -> (Left err, False)
    (_, Left err) -> (Left err, False)

majorGcSamples :: Vector (Double, Double) -> Vector (Double, Double) -> Vector (Double, Double)
majorGcSamples live majors = Vector.fromList (go Nothing (Vector.toList (Vector.zip live majors)))
  where
    go _ [] = []
    go previous (((time, value), (_, count)) : rest) =
      let selected = maybe False (count >) previous
       in (if selected then [(time, value)] else []) <> go (Just count) rest

ordinarySeries :: FilePath -> ProbeSpec -> IO (Either DiagnoseError (Vector (Double, Double)))
ordinarySeries runDirectory probe =
  let binding = probe.binding
      path = runDirectory </> "series" </> binding.file
   in readBinding path binding

nativeSeries :: FilePath -> ProbeSpec -> IO (Either DiagnoseError (Vector (Double, Double)))
nativeSeries runDirectory probe = do
  rss <- ordinarySeries runDirectory probe
  let memBinding = fromMaybe (error "runtime mem binding missing") (Map.lookup "runtime.mem-in-use-bytes" defaultCatalog)
  mem <- readBinding (runDirectory </> "series" </> memBinding.file) memBinding
  pure ((Vector.zipWith difference) <$> rss <*> mem)
  where
    difference (time, resident) (_, inUse) = (time, max 0 (resident - inUse))

judgeSeries :: LeakSpec -> Word64 -> ProbeSpec -> Vector (Double, Double) -> ProbeReport
judgeSeries spec seed probe raw
  | Vector.length reduced < spec.minPoints = emptyReport probe "too-few-points"
  | duration < spec.minDurationSeconds = emptyReport probe "too-short"
  | otherwise = case slopeWithInterval seed spec.resamples spec.confidence reduced of
      Nothing -> emptyReport probe "slope-unavailable"
      Just estimate -> finish estimate
  where
    cut = Vector.dropWhile (\(time, _) -> time < spec.warmupCutSeconds) raw
    reduced = case probe.aggregation of WindowMin -> windowMinima spec.envelopeWindowSeconds cut; WindowMedian -> windowMedians spec.envelopeWindowSeconds cut
    duration = if Vector.length reduced < 2 then 0 else fst (Vector.last reduced) - fst (Vector.head reduced)
    values = fmap snd (Vector.toList reduced)
    firstValue = snd <$> reduced Vector.!? 0
    lastValue = snd <$> reduced Vector.!? (Vector.length reduced - 1)
    medianValue = if null values then Nothing else Just (median values)
    growth = (-) <$> lastValue <*> firstValue
    finish estimate =
      let slopeHour = estimate.slope * 3600
          lowHour = estimate.low * 3600
          highHour = estimate.high * 3600
          half = Vector.drop (Vector.length reduced `div` 2) reduced
          second = (* 3600) . fst <$> theilSen half
          enoughGrowth = fromMaybe False ((\value level -> value >= probe.minGrowth && value >= probe.minRelativeGrowth * level) <$> growth <*> medianValue)
          plateau = maybe True (< probe.floorPerHour / 2) second
          (verdict, reason)
            | lowHour > probe.floorPerHour && enoughGrowth && not plateau = (LeakSuspected, "interval-above-floor")
            | lowHour > probe.floorPerHour && plateau = (Stable, "plateau-after-growth")
            | highHour < probe.floorPerHour || not enoughGrowth = (Stable, "below-growth-floor")
            | otherwise = (InsufficientData, "interval-straddles-floor")
          projected = do
            limit <- probe.limit
            level <- lastValue
            if slopeHour > 0 then Just ((limit - level) / slopeHour) else Nothing
       in ProbeReport probe.name "main" probe.unit probe.expectation (basisFor probe) (Vector.length reduced) duration firstValue lastValue medianValue (Just slopeHour) (Just (lowHour, highHour)) second growth projected verdict reason probe.binding.file probe.binding.valueColumn

emptyReport :: ProbeSpec -> Text -> ProbeReport
emptyReport probe reason = ProbeReport probe.name "main" probe.unit probe.expectation (basisFor probe) 0 0 Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing InsufficientData reason probe.binding.file probe.binding.valueColumn

basisFor :: ProbeSpec -> Text
basisFor probe = case probe.aggregation of WindowMin -> "window-minimum"; WindowMedian -> "window-median"

leakOutcome :: LeakReport -> Outcome
leakOutcome report = case report.verdict of LeakSuspected -> Failed; Stable -> Passed; InsufficientData -> Inconclusive

verdictText :: LeakVerdict -> Text
verdictText LeakSuspected = "leak-suspected"
verdictText Stable = "stable"
verdictText InsufficientData = "insufficient-data"

instance ToJSON LeakVerdict where toJSON = toJSON . verdictText

instance ToJSON Expectation where toJSON Bounded = String "bounded"; toJSON Informational = String "informational"

instance ToJSON Aggregation where toJSON WindowMin = String "window-min"; toJSON WindowMedian = String "window-median"

instance ToJSON ProbeReport where
  toJSON report = object ["probe" .= report.probe, "process" .= report.process, "unit" .= report.unit, "expectation" .= report.expectation, "basis" .= report.basis, "points" .= report.points, "durationSeconds" .= report.durationSeconds, "level" .= object ["first" .= report.first, "last" .= report.last, "median" .= report.medianLevel], "slopePerHour" .= report.slopePerHour, "intervalPerHour" .= fmap (\(low, high) -> [low, high]) report.intervalPerHour, "secondHalfSlopePerHour" .= report.secondHalfSlopePerHour, "growthOverWindow" .= report.growthOverWindow, "projectedHoursToLimit" .= report.projectedHoursToLimit, "verdict" .= report.verdict, "reason" .= report.reason, "source" .= object ["file" .= report.sourceFile, "column" .= report.sourceColumn]]

instance ToJSON LeakReport where
  toJSON report = object ["verdict" .= report.verdict, "window" .= fmap (\(start, end) -> object ["startSeconds" .= start, "endSeconds" .= end]) report.window, "parameters" .= object ["seed" .= report.seed, "policy" .= report.policy], "probes" .= report.probes]

instance FromJSON LeakSpec where
  parseJSON = withObject "LeakSpec" \value -> do
    schema <- value .:? "schema" .!= ("kenshou.leak-policy/v1" :: Text)
    if schema /= ("kenshou.leak-policy/v1" :: Text)
      then fail "unsupported leak policy schema"
      else LeakSpec <$> value .: "probes" <*> value .: "warmupCutSeconds" <*> value .: "minPoints" <*> value .: "minDurationSeconds" <*> value .: "envelopeWindowSeconds" <*> value .: "resamples" <*> value .: "confidence"

instance FromJSON ProbeSpec where
  parseJSON = withObject "ProbeSpec" \value -> do
    name <- value .: "name"
    unit <- value .: "unit"
    file <- value .: "file"
    timeColumn <- value .:? "timeColumn" .!= "t_mono_ns"
    valueColumn <- value .: "valueColumn"
    aggregationText <- value .: "aggregation"
    expectationText <- value .: "expectation"
    aggregation <- case (aggregationText :: Text) of "window-min" -> pure WindowMin; "window-median" -> pure WindowMedian; other -> fail ("unknown aggregation " <> Text.unpack other)
    expectation <- case (expectationText :: Text) of "bounded" -> pure Bounded; "informational" -> pure Informational; other -> fail ("unknown expectation " <> Text.unpack other)
    let filters = if file == ("rts.csv" :: FilePath) || file == "proc.csv" then Map.singleton "phase" "steady" else Map.empty
    ProbeSpec name unit (SeriesBinding file timeColumn valueColumn filters) aggregation expectation <$> value .: "floorPerHour" <*> value .: "minGrowth" <*> value .: "minRelativeGrowth" <*> value .:? "limit"

median :: [Double] -> Double
median [] = 0
median values = let ordered = quicksort values in ordered !! ((length ordered - 1) `div` 2)
  where
    quicksort [] = []
    quicksort (item : rest) = quicksort (filter (<= item) rest) <> [item] <> quicksort (filter (> item) rest)
