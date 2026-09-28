module Kenshou.Remote.Cell.Session.Journal
  ( LeaseMode (..),
    SliceState (..),
    RejectedRun (..),
    SliceJournal (..),
    SessionJournal (..),
    applyTransition,
    readSessionJournal,
    writeSessionJournal,
  )
where

import Control.Exception (bracket)
import Control.Monad (unless)
import Data.Aeson (FromJSON (..), ToJSON (..), eitherDecode, encode, object, withObject, withText, (.:), (.:?), (.=))
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (find, sort)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Kenshou.Core.Id (RunId)
import Kenshou.Remote.Cell.Docs (CellOutcome (..), CellStatus (..), Rejected (..), ResetBlock, Submission (..))
import Kenshou.Remote.Cell.Index (CellManifestLink (..), CellRunIndex (..), RunLink (..))
import Kenshou.Remote.Cell.Session (SessionTransition (..))
import Kenshou.Remote.Payload (PayloadDescriptor)
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile, renameFile)
import System.FilePath (isAbsolute, splitDirectories, takeDirectory)
import System.IO (hClose, openBinaryTempFile)

data LeaseMode = Held | Detached
  deriving stock (Eq, Show)

data SliceState = SlicePlanned | SliceSubmitted | SliceSealed | SliceRejected | SliceFetched | SliceVerified
  deriving stock (Eq, Show)

data RejectedRun = RejectedRun
  { runId :: !RunId,
    reason :: !Text
  }
  deriving stock (Eq, Show)

data SliceJournal = SliceJournal
  { index :: !Int,
    cellRun :: !RunId,
    ordinals :: ![Int],
    runIds :: ![RunId],
    reset :: !ResetBlock,
    submission :: !Submission,
    workPath :: !FilePath,
    state :: !SliceState,
    cellOutcome :: !(Maybe CellOutcome),
    entryExitCode :: !(Maybe Int),
    manifestSha256 :: !(Maybe Text),
    rejectionReason :: !(Maybe Text),
    fetchedPath :: !(Maybe FilePath)
  }
  deriving stock (Eq, Show)

data SessionJournal = SessionJournal
  { sessionId :: !RunId,
    cell :: !Text,
    store :: !Text,
    project :: !(Maybe Text),
    controlBucket :: !Text,
    resultsBucket :: !Text,
    leaseId :: !RunId,
    leaseMode :: !LeaseMode,
    payloads :: !(Map Text PayloadDescriptor),
    planSha256 :: !Text,
    rejectedRuns :: ![RejectedRun],
    slices :: ![SliceJournal],
    createdAt :: !UTCTime,
    updatedAt :: !UTCTime
  }
  deriving stock (Eq, Show)

instance ToJSON LeaseMode where
  toJSON Held = toJSON ("held" :: Text)
  toJSON Detached = toJSON ("detached" :: Text)

instance FromJSON LeaseMode where
  parseJSON = withText "cell lease mode" \case
    "held" -> pure Held
    "detached" -> pure Detached
    _ -> fail "unknown cell lease mode"

instance ToJSON SliceState where
  toJSON SlicePlanned = toJSON ("planned" :: Text)
  toJSON SliceSubmitted = toJSON ("submitted" :: Text)
  toJSON SliceSealed = toJSON ("sealed" :: Text)
  toJSON SliceRejected = toJSON ("rejected" :: Text)
  toJSON SliceFetched = toJSON ("fetched" :: Text)
  toJSON SliceVerified = toJSON ("verified" :: Text)

instance FromJSON SliceState where
  parseJSON = withText "cell slice state" \case
    "planned" -> pure SlicePlanned
    "submitted" -> pure SliceSubmitted
    "sealed" -> pure SliceSealed
    "rejected" -> pure SliceRejected
    "fetched" -> pure SliceFetched
    "verified" -> pure SliceVerified
    _ -> fail "unknown cell slice state"

instance ToJSON RejectedRun where
  toJSON run = object ["runId" .= run.runId, "reason" .= run.reason]

instance FromJSON RejectedRun where
  parseJSON = withObject "rejected planned run" \value -> RejectedRun <$> value .: "runId" <*> value .: "reason"

instance ToJSON SliceJournal where
  toJSON slice =
    object
      [ "index" .= slice.index,
        "cellRun" .= slice.cellRun,
        "ordinals" .= slice.ordinals,
        "runIds" .= slice.runIds,
        "reset" .= slice.reset,
        "submission" .= slice.submission,
        "workPath" .= slice.workPath,
        "state" .= slice.state,
        "cellOutcome" .= slice.cellOutcome,
        "entryExitCode" .= slice.entryExitCode,
        "manifestSha256" .= slice.manifestSha256,
        "rejectionReason" .= slice.rejectionReason,
        "fetchedPath" .= slice.fetchedPath
      ]

instance FromJSON SliceJournal where
  parseJSON = withObject "cell slice journal" \value -> do
    slice <- SliceJournal <$> value .: "index" <*> value .: "cellRun" <*> value .: "ordinals" <*> value .: "runIds" <*> value .: "reset" <*> value .: "submission" <*> value .: "workPath" <*> value .: "state" <*> value .:? "cellOutcome" <*> value .:? "entryExitCode" <*> value .:? "manifestSha256" <*> value .:? "rejectionReason" <*> value .:? "fetchedPath"
    unless (slice.index >= 0 && slice.cellRun == slice.submission.runId && slice.reset == slice.submission.reset && not (null slice.ordinals) && not (null slice.runIds) && unique slice.ordinals && unique slice.runIds && validWorkPath slice.workPath && validSliceState slice) (fail "inconsistent cell slice journal")
    pure slice

instance ToJSON SessionJournal where
  toJSON journal =
    object
      [ "schema" .= ("kenshou.cell-session/v1" :: Text),
        "sessionId" .= journal.sessionId,
        "cell" .= journal.cell,
        "store" .= journal.store,
        "project" .= journal.project,
        "controlBucket" .= journal.controlBucket,
        "resultsBucket" .= journal.resultsBucket,
        "leaseId" .= journal.leaseId,
        "leaseMode" .= journal.leaseMode,
        "payloads" .= journal.payloads,
        "planSha256" .= journal.planSha256,
        "rejectedRuns" .= journal.rejectedRuns,
        "slices" .= journal.slices,
        "createdAt" .= journal.createdAt,
        "updatedAt" .= journal.updatedAt
      ]

instance FromJSON SessionJournal where
  parseJSON = withObject "cell session journal" \value -> do
    schema <- value .: "schema"
    unless (schema == ("kenshou.cell-session/v1" :: Text)) (fail "unsupported cell session journal")
    journal <- SessionJournal <$> value .: "sessionId" <*> value .: "cell" <*> value .: "store" <*> value .:? "project" <*> value .: "controlBucket" <*> value .: "resultsBucket" <*> value .: "leaseId" <*> value .: "leaseMode" <*> value .: "payloads" <*> value .: "planSha256" <*> value .: "rejectedRuns" <*> value .: "slices" <*> value .: "createdAt" <*> value .: "updatedAt"
    unless (unique (fmap (.index) journal.slices) && unique (fmap (.cellRun) journal.slices) && validDigest journal.planSha256 && journal.createdAt <= journal.updatedAt) (fail "inconsistent cell session journal")
    pure journal

applyTransition :: UTCTime -> RunId -> SessionTransition -> SessionJournal -> Either Text SessionJournal
applyTransition now identifier transition journal = do
  slice <- maybe (Left "cell run is not in session") Right (find ((== identifier) . (.cellRun)) journal.slices)
  changed <- advance slice transition
  pure journal {slices = fmap (\current -> if current.cellRun == identifier then changed else current) journal.slices, updatedAt = now}
  where
    advance slice SubmissionPublished = require SlicePlanned slice $ slice {state = SliceSubmitted}
    advance slice (SubmissionRejectedByCell rejected)
      | rejected.runId /= identifier = Left "rejection names another cell run"
      | otherwise = require SliceSubmitted slice $ slice {state = SliceRejected, rejectionReason = Just rejected.reason}
    advance slice (SubmissionSealed status)
      | status.runId /= identifier = Left "seal names another cell run"
      | otherwise = case (status.outcome, status.manifestSha256) of
          (Just outcome, Just digest) -> require SliceSubmitted slice $ slice {state = SliceSealed, cellOutcome = Just outcome, manifestSha256 = Just digest}
          _ -> Left "sealed status is missing outcome or manifest digest"
    advance slice (ResultsFetched path)
      | null path = Left "fetched tree path is empty"
      | otherwise = require SliceSealed slice $ slice {state = SliceFetched, fetchedPath = Just path}
    advance slice (ResultsVerified index)
      | index.cellRun /= identifier || index.leaseId /= slice.submission.leaseId = Left "verified index names another run or lease"
      | Just index.cellOutcome /= slice.cellOutcome || Just index.cellManifest.sha256 /= slice.manifestSha256 = Left "verified index disagrees with seal"
      | index.cellOutcome == Completed && sort (fmap (.runId) index.runs) /= sort slice.runIds = Left "verified index nested runs differ from planned slice"
      | any (\run -> run.runId `notElem` slice.runIds) index.runs = Left "verified index nested runs differ from planned slice"
      | otherwise = require SliceFetched slice $ slice {state = SliceVerified, entryExitCode = index.entryExitCode}
    require expected slice next
      | slice.state == expected = Right next
      | otherwise = Left ("invalid cell slice transition from " <> Text.pack (show slice.state))

readSessionJournal :: FilePath -> IO (Either Text SessionJournal)
readSessionJournal path = do
  bytes <- LazyByteString.readFile path
  pure case eitherDecode bytes of
    Left failure -> Left (Text.pack failure)
    Right journal -> Right journal

writeSessionJournal :: FilePath -> SessionJournal -> IO ()
writeSessionJournal path journal = do
  let directory = takeDirectory path
  createDirectoryIfMissing True directory
  bracket (openBinaryTempFile directory ".kenshou-session-") cleanup \(temporary, handle) -> do
    hClose handle
    LazyByteString.writeFile temporary (encode journal)
    renameFile temporary path
  where
    cleanup (temporary, _) = do
      exists <- doesFileExist temporary
      if exists then removeFile temporary else pure ()

unique :: (Eq value) => [value] -> Bool
unique [] = True
unique (first : rest) = first `notElem` rest && unique rest

validWorkPath :: FilePath -> Bool
validWorkPath path = not (null path) && not (isAbsolute path) && all (`notElem` ["..", "."]) (splitDirectories path)

validSliceState :: SliceJournal -> Bool
validSliceState slice = case slice.state of
  SlicePlanned -> empty
  SliceSubmitted -> empty
  SliceSealed -> sealed && slice.fetchedPath == Nothing && slice.entryExitCode == Nothing
  SliceRejected -> slice.rejectionReason /= Nothing && slice.cellOutcome == Nothing && slice.manifestSha256 == Nothing && slice.fetchedPath == Nothing && slice.entryExitCode == Nothing
  SliceFetched -> sealed && slice.fetchedPath /= Nothing && slice.entryExitCode == Nothing
  SliceVerified -> sealed && slice.fetchedPath /= Nothing
  where
    empty = slice.cellOutcome == Nothing && slice.entryExitCode == Nothing && slice.manifestSha256 == Nothing && slice.rejectionReason == Nothing && slice.fetchedPath == Nothing
    sealed = slice.cellOutcome /= Nothing && maybe False validDigest slice.manifestSha256 && slice.rejectionReason == Nothing

validDigest :: Text -> Bool
validDigest digest = Text.length digest == 64 && Text.all (\character -> character `elem` ['0' .. '9'] || character `elem` ['a' .. 'f']) digest
