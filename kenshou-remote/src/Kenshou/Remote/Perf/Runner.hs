module Kenshou.Remote.Perf.Runner
  ( RunnerHooks (..),
    ComparisonHooks (..),
    Admission (..),
    runPerformance,
  )
where

import Control.Exception (IOException, onException, try)
import Control.Monad (unless)
import Data.Aeson (toJSON)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, diffUTCTime)
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
  { reserveReplacement :: IO (),
    recordRuntimeFailure :: Text -> IO ()
  }

data RunnerHooks = RunnerHooks
  { clock :: IO UTCTime,
    admit :: Int -> IO Admission,
    ownsLease :: LeaseIdentity -> IO Bool,
    compareConfiguration :: LeaseIdentity -> PlannedProfile -> Int -> Bool -> ComparisonHooks -> IO ConfigurationResult,
    verifyCompleted :: ConfigurationResult -> IO Bool,
    cancelOwnedWork :: LeaseIdentity -> IO (),
    releaseOwnedLease :: LeaseIdentity -> IO Bool,
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
  let checkpoint action = do
        now <- hooks.clock
        before <- readIORef current
        changed <- require (appendEvent (SessionEvent now action) before)
        writePerfSession path changed
        writeIORef current changed
      state = readIORef current >>= require . journalState
      cleanup = do
        saved <- state
        case saved.lease of
          Nothing -> pure ()
          Just identity -> do
            _ <- timeout 60000000 (hooks.cancelOwnedWork identity >> hooks.releaseOwnedLease identity)
            checkpoint (LeaseLost "client interrupted; owned cleanup requested")
      execute = do
        saved <- state
        now <- hooks.clock
        session <- readIORef current
        case saved.lease of
          Just identity -> do
            owned <- hooks.ownsLease identity
            if not owned
              then checkpoint (LeaseLost "lease ownership lost") >> execute
              else case saved.activeComparison of
                Just (name, index) -> do
                  entry <- require (selected session name)
                  runOne identity entry index True
                Nothing -> case filter (\entry -> Map.notMember entry.profile.name saved.completed) session.plan.selected of
                  [] -> release identity
                  entry : _ -> do
                    let index = Map.findWithDefault 0 entry.profile.name saved.attempts
                    case appendEvent (SessionEvent now (ComparisonStarted entry.profile.name index)) session of
                      Left _ -> release identity
                      Right _ -> checkpoint (ComparisonStarted entry.profile.name index) >> runOne identity entry index False
          Nothing -> case filter (\entry -> Map.notMember entry.profile.name saved.completed) session.plan.selected of
            [] -> pure ()
            remaining -> do
              let admissionLeft = session.plan.request.waitSeconds - saved.admissionSpentSeconds
                  measured = saved.executionDeadline /= Nothing
                  enough = maybe True (\deadline -> minimum (map cost remaining) <= floor (diffUTCTime deadline now)) saved.executionDeadline
                  seconds = if measured then 1 else min 10 admissionLeft
              if not enough || seconds <= 0
                then pure ()
                else do
                  unless measured (checkpoint (AdmissionReserved seconds))
                  granted <- hooks.admit seconds
                  case granted of
                    Admitted identity -> checkpoint (LeaseAcquired identity) >> execute
                    Occupied | measured -> pure ()
                    Occupied -> execute
                    AdmissionFailed problem -> ioError (userError (Text.unpack problem))
      runOne identity entry index resuming = do
        saved <- state
        now <- hooks.clock
        let micros = maybe 0 (max 0 . floor . (* 1000000) . (`diffUTCTime` now)) saved.executionDeadline
            callbacks = ComparisonHooks (checkpoint (ReplacementReserved entry.profile.name)) (checkpoint . RuntimeBlocked entry.profile.name)
        result <- timeout micros (hooks.compareConfiguration identity entry index resuming callbacks)
        case result of
          Nothing -> do
            _ <- timeout 60000000 (hooks.cancelOwnedWork identity)
            checkpoint (ComparisonCompleted (ConfigurationResult entry.profile.name entry.workloadSha256 "inconclusive" "pending" [] 0 entry.profile.minimumPairs [] Nothing))
            release identity
          Just comparison -> checkpoint (ComparisonCompleted comparison) >> execute
      release identity = do
        saved <- state
        now <- hooks.clock
        let micros = maybe 60000000 (min 60000000 . max 0 . floor . (* 1000000) . (`diffUTCTime` now)) saved.cleanupDeadline
        released <- timeout micros (hooks.releaseOwnedLease identity)
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
          saved.cleanupDeadline
  publication <- try @IOException (timeout publicationMicros (hooks.publishAndVerify session preliminary))
  let published = either (const False) (== Just True) publication
  require (aggregateResult session.plan session.preparedSha256 (published && either (const False) (const True) execution) completed)
  where
    verify result = hooks.verifyCompleted result >>= \valid -> unless valid (ioError (userError "retained completed configuration failed evidence verification"))
    cost entry = 2 * entry.profile.minimumPairs * (entry.profile.trialSeconds + entry.profile.resetSeconds + entry.profile.sealSeconds)
    selected session name = case filter ((== name) . (.name) . (.profile)) session.plan.selected of
      [entry] -> Right entry
      _ -> Left "active comparison has no pinned profile"

require :: Either Text a -> IO a
require = either (ioError . userError . Text.unpack) pure
