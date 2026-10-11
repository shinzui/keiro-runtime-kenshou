module Kenshou.Remote.Perf.Runner
  ( RunnerHooks (..),
    ComparisonHooks (..),
    Admission (..),
    AdmissionHooks (..),
    runPerformance,
  )
where

import Control.Exception (IOException, mask_, onException, try)
import Control.Monad (unless, when)
import Data.Aeson (toJSON)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, addUTCTime, diffUTCTime)
import Kenshou.Perf.Plan (PerfPlan (..), PerfProfile (..), PlannedProfile (..))
import Kenshou.Perf.Prepared qualified as Prepared
import Kenshou.Perf.Request (PerfRequest (..))
import Kenshou.Perf.Result
import Kenshou.Remote.Perf.Journal
import System.Timeout (timeout)

data Admission = Admitted LeaseIdentity | Occupied | AdmissionFailed Text
  deriving stock (Eq, Show)

-- Replacement and runtime observations are persisted before another trial can
-- be dispatched. The cell adapter also persists its low-level work/submission
-- journal before effects and reconciles that journal when resuming an attempt.
data ComparisonHooks = ComparisonHooks
  { reserveReplacement :: Int -> IO (),
    recordRuntimeFailure :: Text -> IO ()
  }

-- Persist the proposed ID before CAS; withdraw only on a definite non-claim.
-- An unresolved proposal is reconciled read-only on resume, never replaced.
data AdmissionHooks = AdmissionHooks {proposeClaim :: LeaseIdentity -> IO (), withdrawClaim :: IO ()}

data RunnerHooks = RunnerHooks
  { clock :: IO UTCTime,
    admit :: PlannedProfile -> Int -> Maybe (Text, LeaseIdentity, UTCTime) -> AdmissionHooks -> IO Admission,
    ownsLease :: LeaseIdentity -> IO Bool,
    canRunConfiguration :: LeaseIdentity -> PlannedProfile -> IO Bool,
    compareConfiguration :: LeaseIdentity -> PlannedProfile -> Int -> Bool -> ComparisonHooks -> IO ConfigurationResult,
    verifyCompleted :: ConfigurationResult -> IO Bool,
    cancelOwnedWork :: LeaseIdentity -> IO (),
    releaseOwnedLease :: LeaseIdentity -> IO Bool,
    recoverRuntimeFailures :: LeaseIdentity -> IO [(Text, Text)],
    reportMetadata :: PerfSession -> PerfResult -> IO PerfResult,
    publishAndVerify :: PerfSession -> PerfResult -> IO Bool
  }

-- Caller holds the session's exclusive orchestration lock. All inputs have
-- already passed manifest and payload retrieval verification. Admission hooks
-- include their bounded waiting; measurement callbacks must never pool pairs
-- across different lease identities or extend the supplied session deadline.
runPerformance :: RunnerHooks -> Prepared.PerfPrepared -> FilePath -> IO PerfResult
runPerformance hooks prepared path = do
  loaded <- readPerfSession path >>= require
  require (validateSessionInputs prepared loaded)
  retained <- require (journalState loaded)
  mapM_ verify (Map.elems retained.completed)
  current <- newIORef loaded
  let checkpoint action = mask_ do
        now <- hooks.clock
        before <- readIORef current
        changed <- require (appendEvent (SessionEvent now action) before)
        writePerfSession path changed
        writeIORef current changed
      state = readIORef current >>= require . journalState
      cleanup = do
        saved <- state
        let proposed = case saved.pendingClaim of Just (_, identity, _) -> Just identity; Nothing -> Nothing
        case (case saved.lease of Just identity -> Just identity; Nothing -> proposed) of
          Nothing -> pure ()
          Just identity -> do
            now <- hooks.clock
            let deadline = case saved.pendingClaim of Just (_, _, at) -> Just (addUTCTime (fromIntegral (prepared.plan.request.budgetMinutes * 60 + 60)) at); Nothing -> saved.cleanupDeadline
                micros = maybe 60000000 (min 60000000 . max 0 . floor . (* 1000000) . (`diffUTCTime` now)) deadline
            released <- timeout micros (hooks.cancelOwnedWork identity >> hooks.releaseOwnedLease identity >>= \released -> when released (recover identity) >> pure released)
            case saved.lease of
              Just _ -> checkpoint (LeaseLost "client interrupted; owned cleanup requested")
              Nothing -> when (released == Just True) (checkpoint LeaseClaimReleased)
      recover identity = do
        faults <- hooks.recoverRuntimeFailures identity
        mapM_ (\(profile, reason) -> do observed <- state; unless (reason `elem` Map.findWithDefault [] profile observed.runtimeBlockers) (checkpoint (RuntimeBlocked profile reason))) faults
      bounded :: String -> IO value -> IO value
      bounded label action = do
        observed <- state
        started <- hooks.clock
        let micros = maybe 10000000 (min 10000000 . max 0 . floor . (* 1000000) . (`diffUTCTime` started)) observed.executionDeadline
        timeout micros action >>= maybe (ioError (userError (label <> " exceeded its bounded transport allowance"))) pure
      execute = do
        saved <- state
        now <- hooks.clock
        session <- readIORef current
        case saved.lease of
          Just identity -> do
            owned <- bounded "lease ownership check" (hooks.ownsLease identity)
            if not owned
              then do
                released <- bounded "lost lease reconciliation" (hooks.releaseOwnedLease identity)
                unless released (ioError (userError "lost lease still has unsettled owned work"))
                bounded "sealed lost-lease observations" (recover identity)
                checkpoint (LeaseLost "lease ownership lost; owned work reconciled")
                execute
              else case saved.activeComparison of
                Just (name, index) -> do
                  entry <- require (selected session name)
                  runOne identity entry index True
                Nothing -> case filter (\entry -> Map.notMember entry.profile.name saved.completed) session.plan.selected of
                  [] -> release identity
                  entry : _ -> do
                    let index = Map.findWithDefault 0 entry.profile.name saved.attempts
                    compatible <- bounded "configuration compatibility check" (hooks.canRunConfiguration identity entry)
                    if not compatible
                      then release identity >> execute
                      else case appendEvent (SessionEvent now (ComparisonStarted entry.profile.name index)) session of
                        Left _ -> release identity
                        Right _ -> checkpoint (ComparisonStarted entry.profile.name index) >> runOne identity entry index False
          Nothing -> case filter (\entry -> Map.notMember entry.profile.name saved.completed) session.plan.selected of
            [] -> pure ()
            entry : _ -> do
              let admissionLeft = session.plan.request.waitSeconds - saved.admissionSpentSeconds
                  measured = saved.executionDeadline /= Nothing
                  enough = maybe True (\deadline -> cost entry <= floor (diffUTCTime deadline now)) saved.executionDeadline
                  initialAdmissionAt = case [event.at | event <- session.events, AdmissionReserved _ <- [event.action]] of first : _ -> first; [] -> now
                  wallLeft = max 0 (session.plan.request.waitSeconds - ceiling (diffUTCTime now initialAdmissionAt))
                  seconds = if measured then maybe 1 (min 10 . max 0 . floor . (`diffUTCTime` now)) saved.executionDeadline else case saved.pendingClaim of Just _ -> 10; Nothing -> min 10 (min admissionLeft wallLeft)
              if not enough || seconds <= 0
                then case saved.pendingClaim of Nothing -> pure (); Just _ -> ioError (userError "unresolved cell claim exceeds the original session budget")
                else do
                  unless (measured || saved.pendingClaim /= Nothing) (checkpoint (AdmissionReserved seconds))
                  let callbacks = AdmissionHooks (checkpoint . LeaseClaimProposed entry.profile.name) (checkpoint LeaseClaimWithdrawn)
                  granted <- timeout (seconds * 1000000) (hooks.admit entry seconds saved.pendingClaim callbacks)
                  receivedAt <- hooks.clock
                  observed <- state
                  admission <- case granted of
                    Nothing | observed.pendingClaim == Nothing -> pure Occupied
                    Nothing -> ioError (userError "cell admission transport exceeded its reserved allowance; proposed claim retained")
                    Just response -> do
                      when (receivedAt > addUTCTime (fromIntegral seconds) now) (ioError (userError "cell admission returned after its reserved allowance"))
                      pure response
                  case admission of
                    Admitted identity -> checkpoint (LeaseAcquired identity) >> execute
                    Occupied -> do
                      unless (observed.pendingClaim == Nothing) (ioError (userError "occupied admission left an unresolved claim"))
                      if measured then pure () else execute
                    AdmissionFailed problem -> ioError (userError (Text.unpack problem))
      runOne identity entry index resuming = do
        saved <- state
        now <- hooks.clock
        let micros = maybe 0 (max 0 . floor . (* 1000000) . (`diffUTCTime` now)) saved.executionDeadline
            reserve pair = do
              session <- readIORef current
              let action = ReplacementScheduled entry.profile.name index pair
              unless (action `elem` map (.action) session.events) (checkpoint action)
            blocked reason = do
              observed <- state
              unless (reason `elem` Map.findWithDefault [] entry.profile.name observed.runtimeBlockers) (checkpoint (RuntimeBlocked entry.profile.name reason))
            callbacks = ComparisonHooks reserve blocked
        result <- timeout micros (hooks.compareConfiguration identity entry index resuming callbacks)
        case result of
          Nothing -> do
            cleanupAt <- hooks.clock
            let cleanupMicros = maybe 60000000 (min 60000000 . max 0 . floor . (* 1000000) . (`diffUTCTime` cleanupAt)) saved.cleanupDeadline
            _ <- timeout cleanupMicros (hooks.cancelOwnedWork identity)
            checkpoint (ComparisonCompleted (ConfigurationResult entry.profile.name entry.workloadSha256 "inconclusive" "pending" [] 0 entry.profile.minimumPairs [] Nothing))
            release identity
          Just comparison -> checkpoint (ComparisonCompleted comparison) >> execute
      release identity = do
        saved <- state
        now <- hooks.clock
        let micros = maybe 60000000 (min 60000000 . max 0 . floor . (* 1000000) . (`diffUTCTime` now)) saved.cleanupDeadline
        released <- timeout micros (hooks.releaseOwnedLease identity >>= \released -> when released (recover identity) >> pure released)
        if released == Just True then checkpoint LeaseReleased else ioError (userError "owned lease release failed or exceeded cleanup grace")
  execution <- try @IOException (execute `onException` cleanup)
  session <- readIORef current
  saved <- require (journalState session)
  let unfinished entry =
        ConfigurationResult
          entry.profile.name
          entry.workloadSha256
          "not-run"
          (either (const "failed") (const "pending") execution)
          (Map.findWithDefault [] entry.profile.name saved.runtimeBlockers)
          0
          entry.profile.minimumPairs
          (map toJSON session.events)
          Nothing
      completed = [Map.findWithDefault (unfinished entry) entry.profile.name saved.completed | entry <- session.plan.selected]
  preliminary <- require (aggregateResult session.plan session.preparedSha256 (either (const False) (const True) execution) completed)
  publicationStarted <- hooks.clock
  let publicationMicros =
        maybe
          (session.plan.request.budgetMinutes * 60000000)
          (min (session.plan.request.budgetMinutes * 60000000) . max 0 . floor . (* 1000000) . (`diffUTCTime` publicationStarted))
          saved.executionDeadline
  publication <-
    try @IOException
      ( timeout publicationMicros do
          reported <- hooks.reportMetadata session preliminary
          require (validateResult reported)
          unless (reported {stageSeconds = Map.empty, artifactReferences = []} == preliminary) (ioError (userError "report metadata changed a performance decision"))
          published <- hooks.publishAndVerify session reported
          pure (reported, published)
      )
  let (reported, published) = either (const (preliminary, False)) (maybe (preliminary, False) id) publication
  verifiedAt <- hooks.clock
  let withinBudget = maybe True (verifiedAt <=) saved.executionDeadline
  final <- require (aggregateResult session.plan session.preparedSha256 (published && withinBudget && either (const False) (const True) execution) completed)
  pure final {stageSeconds = reported.stageSeconds, artifactReferences = reported.artifactReferences}
  where
    verify result = hooks.verifyCompleted result >>= \valid -> unless valid (ioError (userError "retained completed configuration failed evidence verification"))
    cost entry = 2 * entry.profile.minimumPairs * (entry.profile.trialSeconds + entry.profile.resetSeconds + entry.profile.sealSeconds)
    selected session name = case filter ((== name) . (.name) . (.profile)) session.plan.selected of
      [entry] -> Right entry
      _ -> Left "active comparison has no pinned profile"

require :: Either Text a -> IO a
require = either (ioError . userError . Text.unpack) pure
