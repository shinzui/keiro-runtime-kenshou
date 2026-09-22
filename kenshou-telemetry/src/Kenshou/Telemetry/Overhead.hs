module Kenshou.Telemetry.Overhead
  ( Arm (..),
    Slot (..),
    OverheadMode (..),
    OverheadRequest (..),
    OverheadPlan (..),
    SlotRun (..),
    OverheadState (..),
    OverheadHooks (..),
    OverheadComparison (..),
    OverheadReport (..),
    UsageError (..),
    planOverhead,
    executeOverhead,
    analyseOverhead,
    loadOverheadState,
    overheadVerdictExitCode,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Control.Monad (foldM, when)
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (nub, sort, sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64)
import Kenshou.Core.Canonical (canonicalEncode, sha256Hex)
import Kenshou.Core.Dimension
import Kenshou.Core.Id
import Kenshou.Core.Knob
import Kenshou.Core.Manifest (verifyManifest)
import Kenshou.Core.RunSpec
import Kenshou.Core.Scenario (Scenario (..))
import Kenshou.Measure.Compare
import Kenshou.Measure.Compare.Compatibility (VaryingAxis (..))
import Kenshou.Measure.Compare.Policy (Policy (..))
import Kenshou.Measure.Stats (Interval (..))
import Kenshou.Telemetry.Overhead.Policy
import System.Directory (createDirectoryIfMissing, doesFileExist, renameFile)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Random.SplitMix (mkSMGen, nextWord64)

data Arm = Arm
  { armId :: Text,
    dimensions :: Map Text Text,
    knobs :: Map Text KnobValue,
    control :: Bool
  }
  deriving stock (Eq, Show)

data Slot = Slot
  { block :: Int,
    position :: Int,
    arm :: Arm,
    spec :: RunSpec
  }
  deriving stock (Eq, Show)

data OverheadMode = OneFactor | FullFactorial deriving stock (Eq, Show)

data OverheadRequest = OverheadRequest
  { requestId :: Text,
    scenarioId :: ScenarioId,
    factors :: Map Text [Text],
    mode :: OverheadMode,
    includeControl :: Bool,
    trials :: Int,
    fixedKnobs :: [(KnobName, RawKnob)],
    fixedDimensions :: Map Text Text,
    seed :: Word64,
    settleSeconds :: Int,
    retries :: Int
  }
  deriving stock (Eq, Show)

data OverheadPlan = OverheadPlan
  { planId :: Text,
    scenarioId :: ScenarioId,
    scenarioRevision :: Int,
    mode :: OverheadMode,
    factorValues :: Map Text [Text],
    baselineArm :: Text,
    arms :: [Arm],
    trials :: Int,
    seed :: Word64,
    settleSeconds :: Int,
    retries :: Int,
    fixedDimensions :: Map Text Text,
    fixedKnobs :: Map Text KnobValue,
    slots :: [Slot]
  }
  deriving stock (Eq, Show)

data SlotRun = SlotRun
  { block :: Int,
    position :: Int,
    armId :: Text,
    runIds :: [RunId],
    exitCode :: Maybe Int,
    complete :: Bool
  }
  deriving stock (Eq, Show)

data OverheadState = OverheadState
  { plan :: OverheadPlan,
    slots :: [SlotRun]
  }
  deriving stock (Eq, Show)

data OverheadHooks = OverheadHooks
  { runChild :: RunSpec -> FilePath -> IO ExitCode,
    compare :: Policy -> NonEmpty VaryingAxis -> [FilePath] -> [FilePath] -> IO (Either CompareError Comparison),
    leakCheck :: Maybe (FilePath -> IO (Maybe Value))
  }

data OverheadComparison = OverheadComparison
  { candidate :: Text,
    baseline :: Text,
    factor :: Text,
    fromValue :: Text,
    toValue :: Text,
    comparisonPath :: Maybe FilePath,
    verdict :: Verdict,
    degraded :: Bool,
    deltas :: Value,
    reasons :: [Text]
  }
  deriving stock (Eq, Show)

data OverheadReport = OverheadReport
  { reportId :: Text,
    scenarioId :: ScenarioId,
    mode :: OverheadMode,
    baselineDimensions :: Map Text Text,
    fixedDimensions :: Map Text Text,
    fixedKnobs :: Map Text KnobValue,
    trials :: Int,
    seed :: Word64,
    validBlocks :: Int,
    order :: [[Text]],
    armRuns :: [ArmEvidence],
    comparisons :: [OverheadComparison],
    reportFindings :: [Value],
    policyIdentity :: Value,
    verdict :: Verdict
  }
  deriving stock (Eq, Show)

data ArmEvidence = ArmEvidence
  { arm :: Arm,
    runs :: [RunId],
    telemetry :: Value,
    leak :: Maybe Value,
    findings :: [Value],
    degraded :: Bool
  }
  deriving stock (Eq, Show)

newtype UsageError = UsageError Text deriving stock (Eq, Show)

instance ToJSON Arm where
  toJSON value = object ["arm" .= value.armId, "dimensions" .= value.dimensions, "knobs" .= value.knobs, "control" .= value.control]

instance FromJSON Arm where
  parseJSON = withObject "Arm" \value -> Arm <$> value .: "arm" <*> value .: "dimensions" <*> value .: "knobs" <*> value .:? "control" .!= False

instance ToJSON OverheadMode where
  toJSON OneFactor = String "one-factor"
  toJSON FullFactorial = String "full"

instance FromJSON OverheadMode where
  parseJSON = withText "OverheadMode" \case
    "one-factor" -> pure OneFactor
    "full" -> pure FullFactorial
    _ -> fail "mode must be one-factor or full"

instance ToJSON Slot where
  toJSON value = object ["block" .= value.block, "position" .= value.position, "arm" .= value.arm, "spec" .= value.spec]

instance FromJSON Slot where
  parseJSON = withObject "Slot" \value -> Slot <$> value .: "block" <*> value .: "position" <*> value .: "arm" <*> value .: "spec"

instance ToJSON OverheadPlan where
  toJSON value =
    object
      [ "schema" .= ("kenshou.overhead-plan/v1" :: Text),
        "id" .= value.planId,
        "scenario" .= value.scenarioId,
        "scenarioRevision" .= value.scenarioRevision,
        "mode" .= value.mode,
        "factorValues" .= value.factorValues,
        "baselineArm" .= value.baselineArm,
        "arms" .= value.arms,
        "trials" .= value.trials,
        "seed" .= value.seed,
        "settleSeconds" .= value.settleSeconds,
        "retries" .= value.retries,
        "fixedDimensions" .= value.fixedDimensions,
        "fixedKnobs" .= value.fixedKnobs,
        "slots" .= value.slots
      ]

instance FromJSON OverheadPlan where
  parseJSON = withObject "OverheadPlan" \value -> do
    schema <- value .: "schema"
    if schema /= ("kenshou.overhead-plan/v1" :: Text) then fail "unsupported overhead plan" else pure ()
    OverheadPlan <$> value .: "id" <*> value .: "scenario" <*> value .: "scenarioRevision" <*> value .: "mode" <*> value .: "factorValues" <*> value .: "baselineArm" <*> value .: "arms" <*> value .: "trials" <*> value .: "seed" <*> value .: "settleSeconds" <*> value .: "retries" <*> value .: "fixedDimensions" <*> value .: "fixedKnobs" <*> value .: "slots"

instance ToJSON SlotRun where
  toJSON value = object ["block" .= value.block, "position" .= value.position, "arm" .= value.armId, "runIds" .= value.runIds, "exitCode" .= value.exitCode, "complete" .= value.complete]

instance FromJSON SlotRun where
  parseJSON = withObject "SlotRun" \value -> SlotRun <$> value .: "block" <*> value .: "position" <*> value .: "arm" <*> value .:? "runIds" .!= [] <*> value .:? "exitCode" <*> value .:? "complete" .!= False

instance ToJSON OverheadState where
  toJSON value = object ["schema" .= ("kenshou.overhead-state/v1" :: Text), "plan" .= value.plan, "slots" .= value.slots]

instance FromJSON OverheadState where
  parseJSON = withObject "OverheadState" \value -> do
    schema <- value .: "schema"
    if schema /= ("kenshou.overhead-state/v1" :: Text) then fail "unsupported overhead state" else pure ()
    OverheadState <$> value .: "plan" <*> value .:? "slots" .!= []

instance ToJSON OverheadComparison where
  toJSON value =
    object
      [ "candidate" .= value.candidate,
        "baseline" .= value.baseline,
        "factor" .= value.factor,
        "from" .= value.fromValue,
        "to" .= value.toValue,
        "comparison" .= value.comparisonPath,
        "verdict" .= value.verdict,
        "degraded" .= value.degraded,
        "deltas" .= value.deltas,
        "reasons" .= value.reasons
      ]

instance ToJSON OverheadReport where
  toJSON value =
    object
      [ "schema" .= ("kenshou.overhead-report/v1" :: Text),
        "id" .= value.reportId,
        "scenario" .= value.scenarioId,
        "mode" .= value.mode,
        "baseline" .= value.baselineDimensions,
        "fixed" .= object ["knobs" .= value.fixedKnobs, "dimensions" .= value.fixedDimensions],
        "trials" .= value.trials,
        "seed" .= value.seed,
        "validBlocks" .= value.validBlocks,
        "order" .= value.order,
        "arms" .= [object ["arm" .= row.arm.armId, "dimensions" .= row.arm.dimensions, "runs" .= row.runs, "telemetry" .= row.telemetry, "leak" .= row.leak, "findings" .= row.findings] | row <- value.armRuns],
        "comparisons" .= value.comparisons,
        "findings" .= value.reportFindings,
        "policy" .= value.policyIdentity,
        "cohort" .= object [],
        "verdict" .= value.verdict,
        "algorithm" .= object ["name" .= ("kenshou-overhead" :: Text), "version" .= (1 :: Int)]
      ]

planOverhead :: OverheadRequest -> Scenario -> Either UsageError OverheadPlan
planOverhead request scenario = do
  whenEither (request.scenarioId /= scenario.id) "scenario request does not match the selected scenario"
  whenEither (request.trials < 3) "trials must be at least 3"
  whenEither (request.settleSeconds < 0) "settle-seconds must be non-negative"
  whenEither (request.retries < 0) "retries must be non-negative"
  whenEither (Map.null request.factors) "at least one --arms factor is required"
  traverse_ validateFactor (Map.toList request.factors)
  whenEither (any (`Map.member` request.fixedDimensions) (Map.keys request.factors)) "a varied factor cannot also be fixed with --dim"
  resolvedKnobs <- firstUsage (resolveKnobs scenario.knobs request.fixedKnobs)
  let knobMap = Map.fromList [(renderKnobName name, value) | (name, value) <- Map.toList (resolvedKnobsMap resolvedKnobs)]
      baselineCell = Map.map (fromMaybe "" . listToMaybe) request.factors
      cells = case request.mode of
        OneFactor -> baselineCell : [Map.insert factor armValue baselineCell | (factor, values) <- Map.toAscList request.factors, armValue <- drop 1 values]
        FullFactorial -> cartesian (Map.toAscList request.factors)
  plannedArms <- traverse (makeArm scenario knobMap) (zip [0 :: Int ..] (nub cells))
  baselinePlanned <- maybe (Left (UsageError "overhead planning produced no baseline arm")) Right (listToMaybe plannedArms)
  let withControl = plannedArms <> [Arm "control" baselinePlanned.dimensions knobMap True | request.includeControl]
      shuffled = shuffle request.seed withControl
      template =
        OverheadPlan
          request.requestId
          scenario.id
          scenario.revision
          request.mode
          request.factors
          baselinePlanned.armId
          withControl
          request.trials
          request.seed
          request.settleSeconds
          request.retries
          request.fixedDimensions
          knobMap
          []
      initialSlots = concatMap (blockSlots template shuffled) [0 .. request.trials - 1]
  pure (setPlanSlots initialSlots template)
  where
    validateFactor (factor, values) = do
      whenEither (factor `notElem` ["telemetry.tracing", "telemetry.metrics"]) ("unknown overhead factor " <> factor)
      whenEither (null values) (factor <> " has no values")
      whenEither (length values /= length (nub values)) (factor <> " repeats a value")
    makeArm selected knobMap (index, cell) = do
      let assignments = Map.toList (request.fixedDimensions <> cell)
      dimensions <- firstUsage (resolveDimensions selected.dimensions assignments)
      let armName = "a" <> Text.pack (show index)
      pure (Arm armName (Map.fromList (renderDimensions dimensions)) knobMap False)

blockSlots :: OverheadPlan -> [Arm] -> Int -> [Slot]
blockSlots plan shuffled blockNumber = zipWith make [0 ..] ordered
  where
    count = length shuffled
    rotated = rotate ((blockNumber `div` 2) `mod` max 1 count) shuffled
    ordered = if even blockNumber then rotated else reverse rotated
    make position arm =
      let rawKnobs = [(name, RawJson (toJSON value)) | (nameText, value) <- Map.toList arm.knobs, Right name <- [mkKnobName nameText]]
          blockSeed = (plan.seed + fromIntegral blockNumber) `mod` 9007199254740992
          seedValue = either (const Nothing) Just (mkSeed blockSeed)
          base :: RunSpec
          base = minimalRunSpec plan.scenarioId
          runSpec =
            RunSpec
              base.runId
              base.scenario
              (Just plan.scenarioRevision)
              rawKnobs
              (Map.toList arm.dimensions)
              seedValue
              base.phases
              base.timeoutSeconds
              base.environment
              base.cohortExpectation
              (Just (ComparisonMembership plan.planId arm.armId blockNumber (blockNumber * count + position)))
              (Map.fromList [("overhead", plan.planId), ("overhead-arm", arm.armId)])
       in Slot blockNumber position arm runSpec

executeOverhead :: OverheadHooks -> OverheadPlan -> FilePath -> IO OverheadState
executeOverhead hooks plan output = do
  createDirectoryIfMissing True (output </> "runs")
  createDirectoryIfMissing True (output </> "comparisons")
  loaded <- loadOverheadState output
  initial <- case loaded of
    Right state | state.plan.planId == plan.planId -> pure state
    Right _ -> fail "state.json belongs to a different overhead plan"
    Left _ -> pure (OverheadState plan [])
  writeState output initial
  runBlocks initial 0
  where
    shuffled = shuffle plan.seed plan.arms
    maximumBlocks = plan.trials * 2
    runBlocks state blockNumber
      | validBlockCount state >= plan.trials = pure state
      | blockNumber >= maximumBlocks = pure state
      | otherwise = do
          let slotsForBlock = blockSlots plan shuffled blockNumber
          stateWithSlots <- ensureSlots output state slotsForBlock
          finished <- foldM (runSlot hooks output plan) stateWithSlots slotsForBlock
          runBlocks finished (blockNumber + 1)

analyseOverhead :: OverheadHooks -> OverheadPolicy -> OverheadPlan -> OverheadState -> FilePath -> IO OverheadReport
analyseOverhead hooks policy plan state output = do
  createDirectoryIfMissing True (output </> "comparisons")
  baseline <- maybe (fail "overhead plan has no baseline arm") pure (findArm plan.baselineArm plan.arms)
  let valid = validBlockNumbers state
      candidates = filter ((/= plan.baselineArm) . (.armId)) plan.arms
  armRows <- traverse (armRow valid) plan.arms
  let degradedArms = Map.fromList [(row.arm.armId, row.degraded) | row <- armRows]
  comparisons <- traverse (compareArm degradedArms valid baseline) candidates
  let overall = if length valid < 3 then VerdictInfrastructureFailure else worstVerdict (fmap (.verdict) comparisons)
      report =
        OverheadReport
          plan.planId
          plan.scenarioId
          plan.mode
          baseline.dimensions
          plan.fixedDimensions
          plan.fixedKnobs
          plan.trials
          plan.seed
          (length valid)
          [[slot.armId | slot <- sortOn (.position) state.slots, slot.block == blockNumber] | blockNumber <- sort valid]
          armRows
          comparisons
          (concatMap (.findings) armRows)
          (object ["name" .= policy.defaultPolicy.name, "sha256" .= sha256Hex (canonicalEncode (toJSON policy))])
          overall
  LazyByteString.writeFile (output </> "overhead-report.json") (encode report)
  pure report
  where
    compareArm degradedArms valid baseline candidate
      | length valid < 3 = pure (failedComparison candidate baseline VerdictInfrastructureFailure ["fewer than three valid blocks"])
      | otherwise = do
          let baselineDirs = mapMaybeRunDirs output state valid baseline.armId
              candidateDirs = mapMaybeRunDirs output state valid candidate.armId
              changes = [(name, from, to) | (name, from) <- Map.toList baseline.dimensions, Just to <- [Map.lookup name candidate.dimensions], from /= to]
              transition = case changes of [change] -> Just change; _ -> Nothing
              axes =
                if candidate.control
                  then VaryControl :| []
                  else case changes of
                    [] -> VaryControl :| []
                    (name, _, _) : rest -> VaryDimension name :| [VaryDimension other | (other, _, _) <- rest]
              selectedPolicy = if candidate.control then policy.controlPolicy else policyForTransition policy transition
          compared <- hooks.compare selectedPolicy axes baselineDirs candidateDirs
          case compared of
            Left err -> pure (failedComparison candidate baseline VerdictInfrastructureFailure [Text.pack (show err)])
            Right comparison -> do
              let relative = "comparisons" </> Text.unpack candidate.armId <> "-vs-" <> Text.unpack baseline.armId <> ".json"
                  candidateDegraded = Map.findWithDefault False candidate.armId degradedArms
                  reportedVerdict
                    | candidateDegraded && comparison.verdict `elem` [VerdictPass, VerdictRegression] = VerdictInconclusive
                    | candidate.control && comparison.verdict /= VerdictPass = VerdictInconclusive
                    | otherwise = comparison.verdict
              LazyByteString.writeFile (output </> relative) (encode comparison)
              pure
                OverheadComparison
                  { candidate = candidate.armId,
                    baseline = baseline.armId,
                    factor = maybe (if candidate.control then "control" else "multiple") (\(name, _, _) -> name) transition,
                    fromValue = maybe "baseline" (\(_, value, _) -> value) transition,
                    toValue = maybe (if candidate.control then "control" else "candidate") (\(_, _, value) -> value) transition,
                    comparisonPath = Just relative,
                    verdict = reportedVerdict,
                    degraded = candidateDegraded,
                    deltas = metricDeltas comparison,
                    reasons = comparison.reasons
                  }
    armRow valid arm = do
      let runIds = mapMaybeRunIds state valid arm.armId
          directories = fmap (\runId -> output </> "runs" </> Text.unpack (renderRunId runId)) runIds
      leak <- case (hooks.leakCheck, reverse directories) of (Just check, directory : _) -> check directory; _ -> pure Nothing
      telemetryValues <- catMaybes <$> traverse readTelemetry directories
      let findings = concatMap findingsFromTelemetry telemetryValues
      pure (ArmEvidence arm runIds (aggregateTelemetry telemetryValues) leak findings (any degradedFinding findings))

loadOverheadState :: FilePath -> IO (Either String OverheadState)
loadOverheadState output = do
  let path = output </> "state.json"
  exists <- doesFileExist path
  if exists then eitherDecodeFileStrict' path else pure (Left "state.json does not exist")

overheadVerdictExitCode :: Verdict -> Int
overheadVerdictExitCode = verdictExitCode

ensureSlots :: FilePath -> OverheadState -> [Slot] -> IO OverheadState
ensureSlots output state wanted = do
  let existingKeys = [(slot.block, slot.position) | slot <- state.slots]
      additions = [SlotRun slot.block slot.position slot.arm.armId [] Nothing False | slot <- wanted, (slot.block, slot.position) `notElem` existingKeys]
      updated = setStateSlots (state.slots <> additions) state
  writeState output updated
  pure updated

runSlot :: OverheadHooks -> FilePath -> OverheadPlan -> OverheadState -> Slot -> IO OverheadState
runSlot hooks output plan state slot = case findSlotRun slot state.slots of
  Just recorded | recorded.complete -> do
    valid <- completedRunIsValid output recorded
    if valid then pure state else attempt state 0
  _ -> attempt state 0
  where
    attempt current retryNumber = do
      runId <- newRunId
      let spec = setRunId runId slot.spec
          prepared = updateSlot slot (\old -> old {runIds = old.runIds <> [runId], exitCode = Nothing, complete = False}) current
      writeState output prepared
      result <- try (hooks.runChild spec (output </> "runs")) :: IO (Either SomeException ExitCode)
      let code = either (const 4) exitNumber result
          runDirectory = output </> "runs" </> Text.unpack (renderRunId runId)
      complete <- if code == 0 then either (const False) (const True) <$> verifyManifest runDirectory else pure False
      let finished = updateSlot slot (\old -> old {exitCode = Just code, complete}) prepared
      writeState output finished
      when (plan.settleSeconds > 0) (threadDelay (plan.settleSeconds * 1_000_000))
      if code == 4 && retryNumber < plan.retries then attempt finished (retryNumber + 1) else pure finished

writeState :: FilePath -> OverheadState -> IO ()
writeState output state = do
  let temporary = output </> "state.json.tmp"
  LazyByteString.writeFile temporary (encode state)
  renameFile temporary (output </> "state.json")

validBlockCount :: OverheadState -> Int
validBlockCount = length . validBlockNumbers

validBlockNumbers :: OverheadState -> [Int]
validBlockNumbers state =
  [ blockNumber
  | blockNumber <- nub (fmap (.block) state.slots),
    let blockRuns = filter ((== blockNumber) . (.block)) state.slots,
    length blockRuns == length state.plan.arms,
    all (.complete) blockRuns
  ]

completedRunIsValid :: FilePath -> SlotRun -> IO Bool
completedRunIsValid output recorded = case reverse recorded.runIds of
  [] -> pure False
  runId : _ -> either (const False) (const True) <$> verifyManifest (output </> "runs" </> Text.unpack (renderRunId runId))

findSlotRun :: Slot -> [SlotRun] -> Maybe SlotRun
findSlotRun slot = listToMaybe . filter (\recorded -> recorded.block == slot.block && recorded.position == slot.position)

updateSlot :: Slot -> (SlotRun -> SlotRun) -> OverheadState -> OverheadState
updateSlot slot change state = setStateSlots (fmap update state.slots) state
  where
    update current | current.block == slot.block && current.position == slot.position = change current
    update current = current

mapMaybeRunIds :: OverheadState -> [Int] -> Text -> [RunId]
mapMaybeRunIds state blocks armName =
  catMaybes
    [ listToMaybe (reverse slot.runIds)
    | blockNumber <- sort blocks,
      slot <- state.slots,
      slot.block == blockNumber,
      slot.armId == armName,
      slot.complete
    ]

mapMaybeRunDirs :: FilePath -> OverheadState -> [Int] -> Text -> [FilePath]
mapMaybeRunDirs output state blocks armName = fmap (\runId -> output </> "runs" </> Text.unpack (renderRunId runId)) (mapMaybeRunIds state blocks armName)

readTelemetry :: FilePath -> IO (Maybe Value)
readTelemetry directory = do
  decoded <- eitherDecodeFileStrict' (directory </> "run-result.json") :: IO (Either String Value)
  pure (either (const Nothing) (valueAt ["summaries", "telemetry", "telemetry"]) decoded)

aggregateTelemetry :: [Value] -> Value
aggregateTelemetry [] = Null
aggregateTelemetry values =
  object
    [ "runs" .= length values,
      "spansEnded" .= sumNumbers ["pipeline", "spansEnded"],
      "spansDropped" .= sumNumbers ["pipeline", "spansDropped"],
      "exportFailures" .= sumNumbers ["pipeline", "spansExportFailed"],
      "shutdownMsMax" .= maximumOrZero (mapMaybeNumber ["pipeline", "shutdown", "durationMs"] values),
      "sinkSpansReceived" .= sumNumbers ["sink", "spansReceived"]
    ]
  where
    sumNumbers path = sum (mapMaybeNumber path values)

findingsFromTelemetry :: Value -> [Value]
findingsFromTelemetry value = case valueAt ["findings"] value of Just (Array findings) -> toList findings; _ -> []

degradedFinding :: Value -> Bool
degradedFinding value = textAt ["status"] value == Just "fired" && textAt ["severity"] value == Just "degraded"

valueAt :: [Text] -> Value -> Maybe Value
valueAt [] value = Just value
valueAt (key : rest) (Object values) = KeyMap.lookup (Key.fromText key) values >>= valueAt rest
valueAt _ _ = Nothing

textAt :: [Text] -> Value -> Maybe Text
textAt path value = case valueAt path value of Just (String textValue) -> Just textValue; _ -> Nothing

mapMaybeNumber :: [Text] -> [Value] -> [Double]
mapMaybeNumber path = foldr (\value numbers -> maybe numbers (: numbers) (numberAt path value)) []

numberAt :: [Text] -> Value -> Maybe Double
numberAt path value = case valueAt path value of Just (Number number) -> Just (realToFrac number); _ -> Nothing

maximumOrZero :: [Double] -> Double
maximumOrZero [] = 0
maximumOrZero values = maximum values

toList :: (Foldable collection) => collection value -> [value]
toList = foldr (:) []

metricDeltas :: Comparison -> Value
metricDeltas comparison =
  toJSON
    ( Map.map
        (\metric -> object ["relative" .= (metric.ratio.estimate - 1), "ci95" .= [metric.ratio.low - 1, metric.ratio.high - 1], "absolute" .= metric.delta.estimate, "unit" .= metric.unit])
        comparison.metrics
    )

setPlanSlots :: [Slot] -> OverheadPlan -> OverheadPlan
setPlanSlots value plan = OverheadPlan plan.planId plan.scenarioId plan.scenarioRevision plan.mode plan.factorValues plan.baselineArm plan.arms plan.trials plan.seed plan.settleSeconds plan.retries plan.fixedDimensions plan.fixedKnobs value

setStateSlots :: [SlotRun] -> OverheadState -> OverheadState
setStateSlots value state = OverheadState state.plan value

setRunId :: RunId -> RunSpec -> RunSpec
setRunId value spec =
  RunSpec
    (Just value)
    spec.scenario
    spec.scenarioRevision
    spec.knobs
    spec.dimensions
    spec.seed
    spec.phases
    spec.timeoutSeconds
    spec.environment
    spec.cohortExpectation
    spec.comparison
    spec.labels

failedComparison :: Arm -> Arm -> Verdict -> [Text] -> OverheadComparison
failedComparison candidate baseline verdict reasons =
  OverheadComparison candidate.armId baseline.armId (if candidate.control then "control" else "unknown") "baseline" "candidate" Nothing verdict False (object []) reasons

worstVerdict :: [Verdict] -> Verdict
worstVerdict [] = VerdictInfrastructureFailure
worstVerdict values = maximumByRank values
  where
    rank VerdictPass = 0 :: Int
    rank VerdictInconclusive = 1
    rank VerdictRegression = 2
    rank VerdictInfrastructureFailure = 3
    maximumByRank (first : rest) = foldl (\current candidate -> if rank candidate > rank current then candidate else current) first rest
    maximumByRank [] = VerdictInfrastructureFailure

findArm :: Text -> [Arm] -> Maybe Arm
findArm name = listToMaybe . filter ((== name) . (.armId))

shuffle :: Word64 -> [value] -> [value]
shuffle seed values = fmap snd (sortOn fst (zip (randomWords (mkSMGen seed)) values))
  where
    randomWords generator = let (word, next) = nextWord64 generator in word : randomWords next

rotate :: Int -> [value] -> [value]
rotate _ [] = []
rotate count values = drop offset values <> take offset values where offset = count `mod` length values

cartesian :: [(Text, [Text])] -> [Map Text Text]
cartesian [] = [Map.empty]
cartesian ((name, values) : rest) = [Map.insert name value suffix | value <- values, suffix <- cartesian rest]

whenEither :: Bool -> Text -> Either UsageError ()
whenEither condition message = if condition then Left (UsageError message) else Right ()

firstUsage :: (Show error) => Either error value -> Either UsageError value
firstUsage = either (Left . UsageError . Text.pack . show) Right

exitNumber :: ExitCode -> Int
exitNumber ExitSuccess = 0
exitNumber (ExitFailure code) = code

traverse_ :: (a -> Either error b) -> [a] -> Either error ()
traverse_ action = foldM (\() value -> action value >> pure ()) ()
