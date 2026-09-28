module Kenshou.Remote.Cell.Prepare
  ( Granularity (..),
    PreparedRun (..),
    Slice (..),
    OtlpSink (..),
    SubmissionInputs (..),
    sliceRuns,
    slicePlan,
    submissionFor,
  )
where

import Data.Aeson (eitherDecode, encode)
import Data.Int (Int64)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Id (Kind (..), RunId, ScenarioId (..), renderRunId)
import Kenshou.Core.RunSpec (RunSpec (..))
import Kenshou.Plan.RunPlan (PlannedRun (..), RunPlan (..))
import Kenshou.Remote.Cell.Docs (Limits (..), Requirements (..), ResetBlock, Submission (..), WorkObject (..))
import Kenshou.Remote.Cell.Lease (CellRef (..))
import Kenshou.Remote.Payload (Bundle (..), CellPayload (..), PayloadDescriptor (..))
import Kenshou.Remote.Store (Bucket (..))

data Granularity = GranularityAuto | GranularityPlan | GranularityRun
  deriving stock (Eq, Show)

data PreparedRun = PreparedRun
  { ordinal :: !Int,
    runId :: !RunId,
    spec :: !RunSpec,
    payloadLabel :: !Text,
    reset :: !ResetBlock,
    timeoutSeconds :: !Int
  }
  deriving stock (Eq, Show)

data Slice = Slice
  { index :: !Int,
    payloadLabel :: !Text,
    reset :: !ResetBlock,
    entries :: !(NonEmpty PreparedRun),
    wallClockSeconds :: !Int
  }
  deriving stock (Eq, Show)

data OtlpSink = NullSink | FileSink
  deriving stock (Eq, Show)

data SubmissionInputs = SubmissionInputs
  { cellRun :: !RunId,
    leaseId :: !RunId,
    sessionId :: !RunId,
    planId :: !RunId,
    otlpSink :: !OtlpSink,
    rtsOptions :: !(Maybe Text),
    memoryMaxBytes :: !Int64,
    outputMaxBytes :: !Int64,
    minAgentVersion :: !Text,
    requiredCapabilities :: !(Maybe [Text])
  }
  deriving stock (Eq, Show)

sliceRuns :: Granularity -> [PreparedRun] -> Either Text [Slice]
sliceRuns granularity prepared = do
  if all valid prepared && unique (fmap (.runId) prepared) && unique (fmap (.ordinal) prepared)
    then pure ()
    else Left "prepared runs have an empty payload, invalid timeout, duplicate identity or invalid ordinal"
  groups <- case granularity of
    GranularityRun -> pure (fmap (:| []) prepared)
    GranularityAuto -> pure (autoGroups prepared)
    GranularityPlan -> case NonEmpty.nonEmpty prepared of
      Nothing -> pure []
      Just group
        | all (compatible (NonEmpty.head group)) (NonEmpty.tail group) -> pure [group]
        | otherwise -> Left "plan granularity requires one payload and reset for every run"
  traverse makeSlice (zip [0 ..] groups)
  where
    valid run = run.ordinal >= 0 && run.timeoutSeconds > 0 && not (Text.null run.payloadLabel) && maybe True (== run.runId) run.spec.runId
    makeSlice (index, group) =
      let total = 300 + sum (fmap (toInteger . (.timeoutSeconds)) (NonEmpty.toList group))
       in if total > toInteger (maxBound :: Int)
            then Left "cell slice wall-clock limit is too large"
            else Right (Slice index (NonEmpty.head group).payloadLabel (NonEmpty.head group).reset group (fromInteger total))

slicePlan :: RunPlan -> Slice -> Either Text RunPlan
slicePlan plan slice = do
  selected <- traverse select (NonEmpty.toList slice.entries)
  pure (RunPlan plan.planId plan.createdAt plan.context plan.policy selected plan.skipped (sum (fmap (.estimateMinutes) selected)))
  where
    select prepared = case find ((== prepared.runId) . (.runId)) plan.runs of
      Nothing -> Left "slice contains a run absent from its plan"
      Just original
        | original.ordinal /= prepared.ordinal -> Left "slice ordinal differs from its plan"
        | original.spec.scenario /= prepared.spec.scenario -> Left "slice scenario differs from its plan"
        | otherwise -> Right (PlannedRun original.ordinal original.runId original.estimateMinutes original.reasons original.trial prepared.spec)

submissionFor :: CellRef -> SubmissionInputs -> PayloadDescriptor -> Slice -> WorkObject -> Either Text Submission
submissionFor ref inputs descriptor slice work = do
  case eitherDecode (encode descriptor) :: Either String PayloadDescriptor of
    Left failure -> Left ("invalid payload descriptor: " <> Text.pack failure)
    Right _ -> pure ()
  case eitherDecode (encode work) :: Either String WorkObject of
    Left failure -> Left ("invalid work object: " <> Text.pack failure)
    Right _ -> pure ()
  if work.mediaType /= "application/json" || work.bytes <= 0
    then Left "cell work must be a nonempty JSON run plan"
    else pure ()
  let bundle = descriptor.cell.bundle
      expectedPrefix = "gs://" <> ref.controlBucket.unBucket <> "/payloads/sha256/"
  if not (expectedPrefix `Text.isPrefixOf` bundle.uri)
    then Left "payload bundle is outside the cell control bucket"
    else pure ()
  if inputs.memoryMaxBytes <= 0 || inputs.outputMaxBytes <= 0 || Text.null inputs.minAgentVersion || maybe False Text.null inputs.rtsOptions
    then Left "invalid cell submission limits or options"
    else pure ()
  let env =
        Map.fromList
          ( [ ("KENSHOU_PAYLOAD_BUNDLE_SHA256", bundle.sha256),
              ("KENSHOU_PAYLOAD_STORE_PATH", descriptor.cell.storePath),
              ("KENSHOU_PAYLOAD_NAR_HASH", descriptor.cell.narHash),
              ("KENSHOU_PAYLOAD_COHORT", descriptor.cohort),
              ("KENSHOU_OTLP_SINK", case inputs.otlpSink of NullSink -> "null"; FileSink -> "file")
            ]
              <> maybe [] (\options -> [("GHCRTS", options)]) inputs.rtsOptions
          )
      labels =
        Map.fromList
          [ ("session", renderRunId inputs.sessionId),
            ("plan", renderRunId inputs.planId),
            ("slice", Text.pack (show slice.index)),
            ("payload", slice.payloadLabel)
          ]
      submission = Submission inputs.cellRun inputs.leaseId descriptor.cell work env slice.reset (Limits (fromIntegral slice.wallClockSeconds) inputs.memoryMaxBytes inputs.outputMaxBytes) (Requirements inputs.minAgentVersion inputs.requiredCapabilities) labels
  case eitherDecode (encode submission) :: Either String Submission of
    Left failure -> Left ("invalid cell submission: " <> Text.pack failure)
    Right _ -> Right submission

autoGroups :: [PreparedRun] -> [NonEmpty PreparedRun]
autoGroups [] = []
autoGroups (first : rest)
  | isolated first = (first :| []) : autoGroups rest
  | otherwise =
      let (same, later) = span (\candidate -> not (isolated candidate) && compatible first candidate) rest
       in (first :| same) : autoGroups later

compatible :: PreparedRun -> PreparedRun -> Bool
compatible first second = first.payloadLabel == second.payloadLabel && first.reset == second.reset

isolated :: PreparedRun -> Bool
isolated run = run.spec.scenario.kind `elem` [Benchmark, Soak]

unique :: (Eq value) => [value] -> Bool
unique [] = True
unique (first : rest) = first `notElem` rest && unique rest
