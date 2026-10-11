module Kenshou.Remote.Perf.Journal
  ( PerfSession (..),
    SessionEvent (..),
    SessionAction (..),
    LeaseIdentity (..),
    JournalState (..),
    initialSession,
    journalState,
    appendEvent,
    readPerfSession,
    writePerfSession,
    validateSessionInputs,
  )
where

import Control.Exception (bracket)
import Control.Monad (foldM, unless)
import Data.Aeson
import Data.Aeson.Types (Parser)
import Data.ByteString.Lazy qualified as ByteString
import Data.List (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, addUTCTime, diffUTCTime)
import Kenshou.Core.Id (RunId)
import Kenshou.Perf.Plan
import Kenshou.Perf.Prepared qualified as Prepared
import Kenshou.Perf.Request (PerfRequest (..), strictObject)
import Kenshou.Perf.Result (ConfigurationResult (..))
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile, renameFile)
import System.FilePath (takeDirectory)
import System.IO (hClose, openBinaryTempFile)

data LeaseIdentity = LeaseIdentity {cell :: Text, leaseId :: RunId}
  deriving stock (Eq, Show)

data SessionAction
  = AdmissionReserved Int
  | LeaseAcquired LeaseIdentity
  | LeaseLost Text
  | LeaseReleased
  | ComparisonStarted Text Int
  | ReplacementReserved Text
  | RuntimeBlocked Text Text
  | ComparisonCompleted ConfigurationResult
  deriving stock (Eq, Show)

data SessionEvent = SessionEvent {at :: UTCTime, action :: SessionAction}
  deriving stock (Eq, Show)

-- Immutable header plus an append-only transition history. State is derived
-- from that history, so resume cannot silently reset allowances or a deadline.
data PerfSession = PerfSession
  { sessionId :: RunId,
    preparedSha256 :: Text,
    plan :: PerfPlan,
    evidenceBaseUri :: Text,
    createdAt :: UTCTime,
    events :: [SessionEvent]
  }
  deriving stock (Eq, Show)

data JournalState = JournalState
  { admissionSpentSeconds :: Int,
    executionDeadline :: Maybe UTCTime,
    cleanupDeadline :: Maybe UTCTime,
    lease :: Maybe LeaseIdentity,
    activeComparison :: Maybe (Text, Int),
    attempts :: Map Text Int,
    replacements :: Map Text Int,
    completed :: Map Text ConfigurationResult,
    runtimeBlockers :: Map Text [Text],
    lastAt :: UTCTime
  }
  deriving stock (Eq, Show)

initialSession :: RunId -> Text -> PerfPlan -> Text -> UTCTime -> Either Text PerfSession
initialSession identifier digest plan uri now = do
  let (bucket, path) = Text.breakOn "/" (Text.drop 5 uri)
  unless (validDigest digest && "gs://" `Text.isPrefixOf` uri && not (Text.null bucket) && Text.length path > 1 && not (Text.any (`elem` ['\n', '\r', ' ', '?', '#']) uri)) (Left "invalid prepared digest or durable evidence destination")
  case fromJSON (toJSON plan) :: Result PerfPlan of
    Error problem -> Left (Text.pack problem)
    Success _ -> pure ()
  pure (PerfSession identifier digest plan uri now [])

validateSessionInputs :: Prepared.PerfPrepared -> PerfSession -> Either Text ()
validateSessionInputs prepared session = do
  Prepared.validatePrepared prepared
  unless
    (session.preparedSha256 == Prepared.preparedDigest prepared && toJSON session.plan == toJSON prepared.plan)
    (Left "session inputs differ from the verified immutable preparation")
  _ <- journalState session
  pure ()

journalState :: PerfSession -> Either Text JournalState
journalState session = foldM (advance session) initial session.events
  where
    initial = JournalState 0 Nothing Nothing Nothing Nothing Map.empty Map.empty Map.empty Map.empty session.createdAt

appendEvent :: SessionEvent -> PerfSession -> Either Text PerfSession
appendEvent event session = do
  before <- journalState session
  _ <- advance session before event
  pure session {events = session.events <> [event]}

advance :: PerfSession -> JournalState -> SessionEvent -> Either Text JournalState
advance session state event = do
  unless (event.at >= state.lastAt) (Left "performance journal clock moved backwards")
  changed <- case event.action of
    AdmissionReserved seconds -> do
      unless (state.executionDeadline == Nothing && state.lease == Nothing && seconds > 0 && state.admissionSpentSeconds + seconds <= session.plan.request.waitSeconds) (Left "initial admission allowance exhausted or already measured")
      pure state {admissionSpentSeconds = state.admissionSpentSeconds + seconds}
    LeaseAcquired identity -> do
      unless (state.lease == Nothing && identity.cell `elem` session.plan.request.cells) (Left "unexpected or overlapping cell lease")
      measurementTime
      let deadline = maybe (addUTCTime (fromIntegral (session.plan.request.budgetMinutes * 60)) event.at) id state.executionDeadline
      pure state {lease = Just identity, executionDeadline = Just deadline, cleanupDeadline = Just (addUTCTime 60 deadline)}
    LeaseLost reason -> do
      unless (state.lease /= Nothing && not (Text.null reason)) (Left "cannot lose an absent lease without a diagnosis")
      -- Retained low-level journals belong to the abandoned attempt. The next
      -- comparison starts a full schedule and cannot pool those old pairs.
      pure state {lease = Nothing, activeComparison = Nothing}
    LeaseReleased -> do
      unless (state.lease /= Nothing && state.activeComparison == Nothing) (Left "cannot release a lease with unresolved active comparison")
      pure state {lease = Nothing}
    ComparisonStarted name index -> do
      entry <- selected name
      measurementTime
      let count = Map.findWithDefault 0 name state.attempts
          remaining = maybe 0 (floor . (`diffUTCTime` event.at)) state.executionDeadline :: Integer
          fixedCost = 2 * fromIntegral entry.profile.minimumPairs * fromIntegral (entry.profile.trialSeconds + entry.profile.resetSeconds + entry.profile.sealSeconds)
      unless (state.lease /= Nothing && state.activeComparison == Nothing && Map.notMember name state.completed && index == count && count <= entry.profile.replacementPairs && fixedCost <= remaining) (Left "comparison has no lease, is already complete, or exceeds persistent attempt/deadline budget")
      pure state {activeComparison = Just (name, index), attempts = Map.insert name (count + 1) state.attempts}
    ReplacementReserved name -> do
      entry <- selected name
      measurementTime
      let spent = Map.findWithDefault 0 name state.replacements
      unless (maybe False ((== name) . fst) state.activeComparison && spent < entry.profile.replacementPairs) (Left "infrastructure replacement allowance exhausted or wrong active configuration")
      pure state {replacements = Map.insert name (spent + 1) state.replacements}
    RuntimeBlocked name reason -> do
      _ <- selected name
      unless (maybe False ((== name) . fst) state.activeComparison && not (Text.null reason)) (Left "runtime blocker must name its active configuration and diagnosis")
      pure state {runtimeBlockers = Map.insertWith (flip (<>)) name [reason] state.runtimeBlockers}
    ComparisonCompleted result -> do
      entry <- selected result.profile
      unless (maybe False ((== result.profile) . fst) state.activeComparison && result.workloadSha256 == entry.workloadSha256 && result.requiredPairs == entry.profile.minimumPairs && Map.notMember result.profile state.completed) (Left "completion differs from active pinned configuration")
      -- Sealing/retrieval may finish in cleanup grace; result assembly still
      -- reports deadline exhaustion and cannot admit more measurements.
      unless (maybe False (event.at <=) state.cleanupDeadline) (Left "comparison completion exceeded cleanup grace")
      case fromJSON (toJSON result) :: Result ConfigurationResult of
        Error problem -> Left (Text.pack problem)
        Success _ -> pure ()
      let retained = result {runtimeFailures = Map.findWithDefault [] result.profile state.runtimeBlockers <> result.runtimeFailures}
      pure state {activeComparison = Nothing, completed = Map.insert result.profile retained state.completed, runtimeBlockers = Map.insert result.profile retained.runtimeFailures state.runtimeBlockers}
  pure changed {lastAt = event.at}
  where
    selected name = maybe (Left "journal names an unselected configuration") Right (find ((== name) . (.name) . (.profile)) session.plan.selected)
    measurementTime = unless (maybe True (event.at <) state.executionDeadline) (Left "original performance deadline exhausted")

validDigest :: Text -> Bool
validDigest digest = Text.length digest == 71 && "sha256:" `Text.isPrefixOf` digest && Text.all (`elem` (['0' .. '9'] <> ['a' .. 'f'])) (Text.drop 7 digest)

readPerfSession :: FilePath -> IO (Either Text PerfSession)
readPerfSession path = either (Left . Text.pack) Right <$> eitherDecodeFileStrict' path

-- The caller holds the session's exclusive orchestration lock and writes this
-- transition before its corresponding side effect. Atomic replacement alone
-- does not serialize two clients.
writePerfSession :: FilePath -> PerfSession -> IO ()
writePerfSession path session = do
  either (ioError . userError . Text.unpack) (const (pure ())) (journalState session)
  present <- doesFileExist path
  if present
    then do
      previous <- readPerfSession path >>= either (ioError . userError . Text.unpack) pure
      unless (toJSON previous {events = []} == toJSON session {events = []}) (ioError (userError "immutable performance session header differs"))
      unless (toJSON previous.events == toJSON (take (length previous.events) session.events)) (ioError (userError "performance journal history is not an append-only continuation"))
    else pure ()
  let directory = takeDirectory path
  createDirectoryIfMissing True directory
  bracket (openBinaryTempFile directory ".kenshou-perf-session-") cleanup \(temporary, handle) -> do
    hClose handle
    ByteString.writeFile temporary (encode session)
    renameFile temporary path
  where
    cleanup (temporary, _) = do
      exists <- doesFileExist temporary
      if exists then removeFile temporary else pure ()

instance ToJSON LeaseIdentity where
  toJSON identity = object ["cell" .= identity.cell, "leaseId" .= identity.leaseId]

instance FromJSON LeaseIdentity where
  parseJSON = withObject "PerformanceLease" \v -> do
    strictObject ["cell", "leaseId"] v
    LeaseIdentity <$> v .: "cell" <*> v .: "leaseId"

instance ToJSON SessionAction where
  toJSON = \case
    AdmissionReserved seconds -> object ["kind" .= ("admission-reserved" :: Text), "seconds" .= seconds]
    LeaseAcquired lease -> object ["kind" .= ("lease-acquired" :: Text), "lease" .= lease]
    LeaseLost reason -> object ["kind" .= ("lease-lost" :: Text), "reason" .= reason]
    LeaseReleased -> object ["kind" .= ("lease-released" :: Text)]
    ComparisonStarted name index -> object ["kind" .= ("comparison-started" :: Text), "profile" .= name, "index" .= index]
    ReplacementReserved name -> object ["kind" .= ("replacement-reserved" :: Text), "profile" .= name]
    RuntimeBlocked name reason -> object ["kind" .= ("runtime-blocked" :: Text), "profile" .= name, "reason" .= reason]
    ComparisonCompleted result -> object ["kind" .= ("comparison-completed" :: Text), "result" .= result]

instance FromJSON SessionAction where
  parseJSON = withObject "PerformanceAction" \v -> do
    kind <- v .: "kind" :: Parser Text
    case kind of
      "admission-reserved" -> strictObject ["kind", "seconds"] v >> AdmissionReserved <$> v .: "seconds"
      "lease-acquired" -> strictObject ["kind", "lease"] v >> LeaseAcquired <$> v .: "lease"
      "lease-lost" -> strictObject ["kind", "reason"] v >> LeaseLost <$> v .: "reason"
      "lease-released" -> strictObject ["kind"] v >> pure LeaseReleased
      "comparison-started" -> strictObject ["kind", "profile", "index"] v >> ComparisonStarted <$> v .: "profile" <*> v .: "index"
      "replacement-reserved" -> strictObject ["kind", "profile"] v >> ReplacementReserved <$> v .: "profile"
      "runtime-blocked" -> strictObject ["kind", "profile", "reason"] v >> RuntimeBlocked <$> v .: "profile" <*> v .: "reason"
      "comparison-completed" -> strictObject ["kind", "result"] v >> ComparisonCompleted <$> v .: "result"
      _ -> fail "unknown performance journal action"

instance ToJSON SessionEvent where
  toJSON event = object ["at" .= event.at, "action" .= event.action]

instance FromJSON SessionEvent where
  parseJSON = withObject "PerformanceEvent" \v -> do
    strictObject ["at", "action"] v
    SessionEvent <$> v .: "at" <*> v .: "action"

instance ToJSON PerfSession where
  toJSON session = object ["schema" .= ("kenshou.perf-session/v1" :: Text), "sessionId" .= session.sessionId, "preparedSha256" .= session.preparedSha256, "plan" .= session.plan, "evidenceBaseUri" .= session.evidenceBaseUri, "createdAt" .= session.createdAt, "events" .= session.events]

instance FromJSON PerfSession where
  parseJSON = withObject "PerfSession" \v -> do
    strictObject ["schema", "sessionId", "preparedSha256", "plan", "evidenceBaseUri", "createdAt", "events"] v
    schema <- v .: "schema"
    unless (schema == ("kenshou.perf-session/v1" :: Text)) (fail "unsupported performance session schema")
    session <- PerfSession <$> v .: "sessionId" <*> v .: "preparedSha256" <*> v .: "plan" <*> v .: "evidenceBaseUri" <*> v .: "createdAt" <*> v .: "events"
    _ <- either (fail . Text.unpack) pure (initialSession session.sessionId session.preparedSha256 session.plan session.evidenceBaseUri session.createdAt)
    _ <- either (fail . Text.unpack) pure (journalState session)
    pure session
