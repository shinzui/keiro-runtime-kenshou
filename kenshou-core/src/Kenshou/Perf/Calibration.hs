{-# LANGUAGE FieldSelectors #-}

module Kenshou.Perf.Calibration
  ( CalibrationReference (..),
    CalibrationDefinition (..),
    CalibrationSlot (..),
    CalibrationAcceptance (..),
    CalibrationReceipt (..),
    VerifiedCalibrationTrial (..),
    validateCalibration,
    validateCalibrationDefinition,
    toolchainDigest,
  )
where

import Control.Monad (unless)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Kenshou.Core.Canonical (canonicalEncode, sha256Hex)
import Kenshou.Core.Id (RunId)
import Kenshou.Perf.Prepared (BuildInventory (..))
import Kenshou.Perf.Request (canonicalProject, immutableRevision, strictObject)

data CalibrationReference = CalibrationReference {definitionUri :: Text, definitionSha256 :: Text, acceptanceUri :: Text, acceptanceSha256 :: Text}
  deriving stock (Eq, Show)

data CalibrationDefinition = CalibrationDefinition
  { batchId :: RunId,
    project :: Text,
    profile :: Text,
    machineProfile :: Text,
    healthPolicySha256 :: Text,
    workloadSha256 :: Text,
    toolchainSha256 :: Text,
    harnessSemanticsSha256 :: Text,
    baselineRevision :: Text,
    slowdownRevision :: Text,
    injectionMechanism :: Text,
    targetMetric :: Text,
    targetRelativeEffect :: Double,
    targetAbsoluteEffect :: Double,
    seeds :: [Integer],
    infrastructureRetryCap :: Int,
    expiresAt :: UTCTime
  }
  deriving stock (Eq, Show)

data CalibrationReceipt = CalibrationReceipt {uri :: Text, sha256 :: Text}
  deriving stock (Eq, Show)

data CalibrationSlot = CalibrationSlot {seed :: Integer, receipts :: [CalibrationReceipt]}
  deriving stock (Eq, Show)

data CalibrationAcceptance = CalibrationAcceptance {batchId :: RunId, aa :: [CalibrationSlot], slowdown :: [CalibrationSlot]}
  deriving stock (Eq, Show)

-- These observations are constructed only after the ordinary full report replay.
-- They are not accepted as a calibration input document or catalog assertion.
data VerifiedCalibrationTrial = VerifiedCalibrationTrial
  { sessionId :: RunId,
    seed :: Integer,
    control :: Text,
    project :: Text,
    baselineRevision :: Text,
    candidateRevision :: Text,
    profile :: Text,
    trialMachineProfile :: Text,
    trialHealthPolicySha256 :: Text,
    workloadSha256 :: Text,
    trialToolchainSha256 :: Text,
    trialHarnessSemanticsSha256 :: Text,
    verdict :: Text,
    infrastructureState :: Text,
    runtimeBlockers :: [Text],
    createdAt :: UTCTime,
    elapsedSeconds :: Double
  }
  deriving stock (Eq, Show)

-- Commit identity belongs to preparation, not this toolchain identity: attaching
-- a calibration link in a new catalog commit must not invalidate itself.
toolchainDigest :: BuildInventory -> Text
toolchainDigest inventory = sha256Hex (canonicalEncode (object ["compiler" .= inventory.compiler, "platform" .= inventory.platform, "toolchain" .= stable]))
  where
    stable = case inventory.toolchain of Object value -> Object (KeyMap.delete "harnessRevision" value); value -> value

validateCalibration :: UTCTime -> UTCTime -> CalibrationDefinition -> CalibrationAcceptance -> [[VerifiedCalibrationTrial]] -> [[VerifiedCalibrationTrial]] -> Either Text Double
validateCalibration now declaredAt definition acceptance aaTrials slowdownTrials = do
  validateCalibrationDefinition now declaredAt definition
  require (acceptance.batchId == definition.batchId) "calibration batch identity differs"
  mapM_ (\slots -> require (map (.seed) slots == definition.seeds && all (not . null . (.receipts)) slots) "acceptance omitted or reordered a declared slot") [acceptance.aa, acceptance.slowdown]
  let references = concatMap (.receipts) (acceptance.aa <> acceptance.slowdown)
      trials = concat (aaTrials <> slowdownTrials)
  require (nub (map (.uri) references) == map (.uri) references && nub (map (.sessionId) trials) == map (.sessionId) trials) "duplicate calibration evidence or session"
  aaAccepted <- check "aa" acceptance.aa aaTrials
  slowdownAccepted <- check "none" acceptance.slowdown slowdownTrials
  require (length (filter ((== "failed") . (.infrastructureState)) trials) <= definition.infrastructureRetryCap) "calibration infrastructure retry cap exceeded"
  require (counts "pass" aaAccepted >= 19 && counts "regression" aaAccepted == 0 && counts "inconclusive" aaAccepted <= 1) "A/A statistical acceptance failed"
  require (counts "regression" slowdownAccepted >= 19 && counts "pass" slowdownAccepted == 0 && counts "inconclusive" slowdownAccepted <= 1) "slowdown sensitivity acceptance failed"
  let elapsed = sort (map (sum . map (.elapsedSeconds)) aaTrials)
      p95 = elapsed !! 18 -- nearest rank ceil(0.95 * 20), including every retained retry
  require (p95 <= 900) "A/A warm turnaround p95 exceeds fifteen minutes"
  pure p95
  where
    require condition message = unless condition (Left message)
    counts outcome = length . filter ((== outcome) . (.verdict))
    check control slots groups = do
      require (length groups == 20 && length groups == length slots) "missing calibration trial group"
      traverse (checkSlot control) (zip slots groups)
    checkSlot control (slot, trials) = do
      require (not (null trials) && length trials == length slot.receipts) "calibration receipt/trial count differs"
      mapM_ (checkTrial slot.seed control) trials
      require (all ((== "failed") . (.infrastructureState)) (init trials) && (.infrastructureState) (last trials) == "healthy") "statistical outcomes were discarded or slot never completed"
      pure (last trials)
    checkTrial seed control trial = do
      require (trial.createdAt >= declaredAt && trial.createdAt <= definition.expiresAt) "trial is outside the frozen batch lifetime"
      require ((trial.seed, trial.control, trial.project, trial.profile, trial.trialMachineProfile, trial.trialHealthPolicySha256, trial.workloadSha256, trial.trialToolchainSha256, trial.trialHarnessSemanticsSha256) == (seed, control, definition.project, definition.profile, definition.machineProfile, definition.healthPolicySha256, definition.workloadSha256, definition.toolchainSha256, definition.harnessSemanticsSha256)) "calibration workload, seed, toolchain or harness drift"
      require (trial.baselineRevision == definition.baselineRevision && trial.candidateRevision == if control == "aa" then definition.baselineRevision else definition.slowdownRevision) "calibration source revision differs"
      require (null trial.runtimeBlockers) "runtime blocker invalidates calibration"
      require (trial.infrastructureState `elem` ["healthy", "failed"] && trial.verdict `elem` ["pass", "regression", "inconclusive", "not-run"]) "unsupported calibration outcome"
      require (trial.infrastructureState /= "healthy" || trial.verdict /= "not-run") "unexecuted slot is not a statistical outcome"
      require (not (isNaN trial.elapsedSeconds || isInfinite trial.elapsedSeconds) && trial.elapsedSeconds >= 0) "invalid retained calibration timing"

finitePositive :: Double -> Bool
finitePositive value = not (isNaN value || isInfinite value) && value > 0

validateCalibrationDefinition :: UTCTime -> UTCTime -> CalibrationDefinition -> Either Text ()
validateCalibrationDefinition now declaredAt definition = do
  require (canonicalProject definition.project && all immutableRevision [definition.baselineRevision, definition.slowdownRevision] && definition.baselineRevision /= definition.slowdownRevision) "invalid calibration source identity"
  require (length definition.seeds == 20 && nub definition.seeds == definition.seeds && all (\seed -> seed >= 0 && seed <= 9007199254740991) definition.seeds) "calibration needs twenty unique declared seeds"
  require (definition.infrastructureRetryCap >= 0 && definition.infrastructureRetryCap <= 20) "invalid calibration infrastructure retry cap"
  require (declaredAt <= now && declaredAt < definition.expiresAt && now <= definition.expiresAt) "calibration expired or predates its declaration"
  require (not (Text.null definition.injectionMechanism) && not (Text.null definition.targetMetric) && finitePositive definition.targetRelativeEffect && finitePositive definition.targetAbsoluteEffect) "missing or invalid injected effect"
  require (not (Text.null definition.profile) && not (Text.null definition.machineProfile) && not ("pending" `Text.isInfixOf` definition.machineProfile) && all digest [definition.healthPolicySha256, definition.workloadSha256, definition.toolchainSha256, definition.harnessSemanticsSha256]) "calibration needs immutable workload, toolchain and harness digests"
  where
    require condition message = unless condition (Left message)
    digest value = Text.length value == 71 && "sha256:" `Text.isPrefixOf` value && Text.all (`elem` (['0' .. '9'] <> ['a' .. 'f'])) (Text.drop 7 value)

instance ToJSON CalibrationReference where
  toJSON value = object ["definitionUri" .= value.definitionUri, "definitionSha256" .= value.definitionSha256, "acceptanceUri" .= value.acceptanceUri, "acceptanceSha256" .= value.acceptanceSha256]

instance FromJSON CalibrationReference where
  parseJSON = withObject "CalibrationReference" \v -> do
    strictObject ["definitionUri", "definitionSha256", "acceptanceUri", "acceptanceSha256"] v
    CalibrationReference <$> v .: "definitionUri" <*> v .: "definitionSha256" <*> v .: "acceptanceUri" <*> v .: "acceptanceSha256"

instance ToJSON CalibrationDefinition where
  toJSON value = object ["schema" .= ("kenshou.perf-calibration-definition/v1" :: Text), "batchId" .= value.batchId, "project" .= value.project, "profile" .= value.profile, "machineProfile" .= value.machineProfile, "healthPolicySha256" .= value.healthPolicySha256, "workloadSha256" .= value.workloadSha256, "toolchainSha256" .= value.toolchainSha256, "harnessSemanticsSha256" .= value.harnessSemanticsSha256, "baselineRevision" .= value.baselineRevision, "slowdownRevision" .= value.slowdownRevision, "injectionMechanism" .= value.injectionMechanism, "targetMetric" .= value.targetMetric, "targetRelativeEffect" .= value.targetRelativeEffect, "targetAbsoluteEffect" .= value.targetAbsoluteEffect, "seeds" .= value.seeds, "infrastructureRetryCap" .= value.infrastructureRetryCap, "expiresAt" .= value.expiresAt]

instance FromJSON CalibrationDefinition where
  parseJSON = withObject "CalibrationDefinition" \v -> do
    strictObject ["schema", "batchId", "project", "profile", "machineProfile", "healthPolicySha256", "workloadSha256", "toolchainSha256", "harnessSemanticsSha256", "baselineRevision", "slowdownRevision", "injectionMechanism", "targetMetric", "targetRelativeEffect", "targetAbsoluteEffect", "seeds", "infrastructureRetryCap", "expiresAt"] v
    schema <- v .: "schema"
    unless (schema == ("kenshou.perf-calibration-definition/v1" :: Text)) (fail "unsupported calibration definition")
    CalibrationDefinition <$> v .: "batchId" <*> v .: "project" <*> v .: "profile" <*> v .: "machineProfile" <*> v .: "healthPolicySha256" <*> v .: "workloadSha256" <*> v .: "toolchainSha256" <*> v .: "harnessSemanticsSha256" <*> v .: "baselineRevision" <*> v .: "slowdownRevision" <*> v .: "injectionMechanism" <*> v .: "targetMetric" <*> v .: "targetRelativeEffect" <*> v .: "targetAbsoluteEffect" <*> v .: "seeds" <*> v .: "infrastructureRetryCap" <*> v .: "expiresAt"

instance ToJSON CalibrationReceipt where
  toJSON value = object ["uri" .= value.uri, "sha256" .= value.sha256]

instance FromJSON CalibrationReceipt where
  parseJSON = withObject "CalibrationReceipt" \v -> do
    strictObject ["uri", "sha256"] v
    CalibrationReceipt <$> v .: "uri" <*> v .: "sha256"

instance ToJSON CalibrationSlot where
  toJSON value = object ["seed" .= value.seed, "receipts" .= value.receipts]

instance FromJSON CalibrationSlot where
  parseJSON = withObject "CalibrationSlot" \v -> do
    strictObject ["seed", "receipts"] v
    CalibrationSlot <$> v .: "seed" <*> v .: "receipts"

instance ToJSON CalibrationAcceptance where
  toJSON value = object ["schema" .= ("kenshou.perf-calibration-acceptance/v1" :: Text), "batchId" .= value.batchId, "aa" .= value.aa, "slowdown" .= value.slowdown]

instance FromJSON CalibrationAcceptance where
  parseJSON = withObject "CalibrationAcceptance" \v -> do
    strictObject ["schema", "batchId", "aa", "slowdown"] v
    schema <- v .: "schema"
    unless (schema == ("kenshou.perf-calibration-acceptance/v1" :: Text)) (fail "unsupported calibration acceptance")
    CalibrationAcceptance <$> v .: "batchId" <*> v .: "aa" <*> v .: "slowdown"
