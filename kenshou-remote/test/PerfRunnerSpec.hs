module PerfRunnerSpec (spec) where

import Control.Concurrent (threadDelay)
import Data.Aeson
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import Kenshou.Core.Id (newRunId)
import Kenshou.Perf.Plan
import Kenshou.Perf.Prepared qualified as Prepared
import Kenshou.Perf.Result
import Kenshou.Perf.Result qualified as Result
import Kenshou.Remote.Cell.Lease qualified as Lease
import Kenshou.Remote.Perf.Journal
import Kenshou.Remote.Perf.Runner
import Kenshou.Remote.Store (Bucket (..))
import Kenshou.Remote.Store.File (newFileStore)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "performance runner orchestration" do
  it "persists a claim before CAS and reconciles a timed-out accepted claim without redispatch" $ withSystemTempDirectory "perf-admission-ambiguous" \directory -> do
    (prepared, path) <- fixture directory
    calls <- newIORef ([] :: [(Text, Int, Bool)])
    hooks <- fixtureHooks calls
    store <- newFileStore (directory </> "store")
    identifier <- newRunId
    writes <- newIORef (0 :: Int)
    let identity = LeaseIdentity "alpha" identifier
        ref = Lease.CellRef "alpha" (Bucket "control")
        stalled =
          hooks
            { admit = \entry _ pending callbacks -> do
                pending `shouldBe` Nothing
                callbacks.proposeClaim identity
                state <- readPerfSession path >>= right >>= right . journalState
                state.pendingClaim `shouldBe` Just (entry.profile.name, identity, now)
                claimed <- Lease.acquireLeaseWithId store ref (Lease.LeaseRequest "fixture" "ambiguous transport control" 180) identifier
                case claimed of Lease.Acquired _ -> pure (); _ -> fail "fixture claim failed"
                modifyIORef' writes (+ 1)
                threadDelay 60000000
                pure (Admitted identity),
              releaseOwnedLease = \_ -> pure False
            }
    failed <- runPerformance stalled prepared path
    failed.exitCode `shouldBe` 4
    retained <- readPerfSession path >>= right >>= right . journalState
    retained.pendingClaim `shouldSatisfy` isJust
    readIORef calls `shouldReturn` []
    let resumed =
          hooks
            { admit = \_ _ pending _ -> do
                case pending of Just (_, proposed, _) -> proposed `shouldBe` identity; _ -> fail "lost retained proposal"
                active <- Lease.reattachActiveLease store ref identifier
                isJust active `shouldBe` True
                pure (Admitted identity),
              ownsLease = \_ -> isJust <$> Lease.reattachActiveLease store ref identifier,
              releaseOwnedLease = \_ -> Lease.reattachLease store ref identifier >>= maybe (pure False) (Lease.releaseLease store ref)
            }
    recovered <- runPerformance resumed prepared path
    recovered.exitCode `shouldBe` 0
    readIORef writes `shouldReturn` 1
    final <- readPerfSession path >>= right >>= right . journalState
    final.pendingClaim `shouldBe` Nothing
    final.executionDeadline `shouldBe` Just (addUTCTime 1800 now)
  it "pins the deadline when cleanup confirms release of an unacknowledged claim" $ withSystemTempDirectory "perf-admission-release" \directory -> do
    (prepared, path) <- fixture directory
    calls <- newIORef ([] :: [(Text, Int, Bool)])
    hooks <- fixtureHooks calls
    identifier <- newRunId
    clockRef <- newIORef now
    let late =
          hooks
            { clock = readIORef clockRef,
              admit = \_ _ _ callbacks -> do
                callbacks.proposeClaim (LeaseIdentity "alpha" identifier)
                writeIORef clockRef (addUTCTime 11 now)
                pure (Admitted (LeaseIdentity "alpha" identifier))
            }
    result <- runPerformance late prepared path
    result.exitCode `shouldBe` 4
    state <- readPerfSession path >>= right >>= right . journalState
    state.pendingClaim `shouldBe` Nothing
    state.executionDeadline `shouldBe` Just (addUTCTime 1800 now)
    readIORef calls `shouldReturn` []
  it "collects sealed runtime failures under a lost lease before starting a fresh attempt" $ withSystemTempDirectory "perf-lost-seal" \directory -> do
    (prepared, path) <- fixture directory
    calls <- newIORef ([] :: [(Text, Int, Bool)])
    hooks <- fixtureHooks calls
    first <- newRunId
    session <- readPerfSession path >>= right
    entry <- case prepared.plan.selected of value : _ -> pure value; _ -> fail "empty fixture"
    acquired <- right (appendEvent (SessionEvent now (LeaseAcquired (LeaseIdentity "alpha" first))) session)
    started <- right (appendEvent (SessionEvent now (ComparisonStarted entry.profile.name 0)) acquired)
    writePerfSession path started
    let recovered =
          hooks
            { ownsLease = \identity -> pure (identity.leaseId /= first),
              recoverRuntimeFailures = \identity -> pure [(entry.profile.name, "sealed exit-zero defect") | identity.leaseId == first]
            }
    result <- runPerformance recovered prepared path
    result.exitCode `shouldBe` 1
    result.blockingRuntimeFailures `shouldBe` ["sealed exit-zero defect"]
    readIORef calls >>= \executed -> map (\(_, attempt, _) -> attempt) executed `shouldBe` [1, 0]
  it "executes both pinned configurations and reuses completed evidence on resume" $ withSystemTempDirectory "perf-runner" \directory -> do
    (prepared, path) <- fixture directory
    calls <- newIORef ([] :: [(Text, Int, Bool)])
    hooks <- fixtureHooks calls
    result <- runPerformance hooks prepared path
    result.exitCode `shouldBe` 0
    length result.configurations `shouldBe` 2
    result.gatingEligible `shouldBe` False
    resumed <- runPerformance hooks prepared path
    resumed `shouldBe` result
    readIORef calls >>= \executed -> length executed `shouldBe` 2
  it "persists runtime blockers and retries a whole configuration after interruption" $ withSystemTempDirectory "perf-runner" \directory -> do
    (prepared, path) <- fixture directory
    calls <- newIORef ([] :: [(Text, Int, Bool)])
    hooks <- fixtureHooks calls
    let interrupted =
          hooks
            { compareConfiguration = \_ _ _ _ callbacks -> do
                callbacks.reserveReplacement 5
                callbacks.recordRuntimeFailure "known defect with exit zero"
                ioError (userError "simulated lost connection")
            }
    failed <- runPerformance interrupted prepared path
    failed.exitCode `shouldBe` 4
    restored <- readPerfSession path >>= right
    interruptedState <- right (journalState restored)
    Map.elems interruptedState.replacements `shouldBe` [1]
    resumed <- runPerformance hooks prepared path
    resumed.exitCode `shouldBe` 1
    resumed.blockingRuntimeFailures `shouldBe` ["known defect with exit zero"]
    resumedState <- readPerfSession path >>= right >>= right . journalState
    resumedState.executionDeadline `shouldBe` interruptedState.executionDeadline
    Map.elems resumedState.replacements `shouldBe` [1]
    readIORef calls >>= \executed -> map (\(_, index, _) -> index) executed `shouldBe` [1, 0]
  it "returns infrastructure failure when durable publication throws or rejects verification" $ withSystemTempDirectory "perf-runner" \directory -> do
    (prepared, path) <- fixture directory
    calls <- newIORef ([] :: [(Text, Int, Bool)])
    hooks <- fixtureHooks calls
    result <- runPerformance hooks {publishAndVerify = \_ _ -> ioError (userError "storage unavailable")} prepared path
    result.exitCode `shouldBe` 4
    recovered <- runPerformance hooks prepared path
    recovered.exitCode `shouldBe` 0
    invalid <- runPerformance hooks {publishAndVerify = \_ _ -> pure False} prepared path
    invalid.exitCode `shouldBe` 4
  it "rejects a report decorator that changes a performance decision" $ withSystemTempDirectory "perf-runner-report" \directory -> do
    (prepared, path) <- fixture directory
    calls <- newIORef ([] :: [(Text, Int, Bool)])
    hooks <- fixtureHooks calls
    published <- newIORef False
    result <- runPerformance hooks {reportMetadata = \_ report -> pure report {Result.changeCoverage = "complete"}, publishAndVerify = \_ _ -> writeIORef published True >> pure True} prepared path
    result.exitCode `shouldBe` 4
    readIORef published `shouldReturn` False
  it "rejects changed immutable preparation before any admission" $ withSystemTempDirectory "perf-runner" \directory -> do
    (prepared, path) <- fixture directory
    calls <- newIORef ([] :: [(Text, Int, Bool)])
    hooks <- fixtureHooks calls
    runPerformance hooks prepared {Prepared.harnessRevision = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"} path `shouldThrow` anyIOException
    readIORef calls `shouldReturn` []
  it "does not extend cleanup or publication time when a finished session is resumed" $ withSystemTempDirectory "perf-runner-deadline" \directory -> do
    (prepared, path) <- fixture directory
    calls <- newIORef ([] :: [(Text, Int, Bool)])
    hooks <- fixtureHooks calls
    original <- runPerformance hooks prepared path
    original.exitCode `shouldBe` 0
    published <- newIORef False
    result <- runPerformance hooks {clock = pure (addUTCTime 1870 now), publishAndVerify = \_ _ -> writeIORef published True >> pure True} prepared path
    result.exitCode `shouldBe` 4
    readIORef published `shouldReturn` False
  it "does not publish during cleanup grace after the execution deadline" $ withSystemTempDirectory "perf-publication-grace" \directory -> do
    (prepared, path) <- fixture directory
    calls <- newIORef ([] :: [(Text, Int, Bool)])
    hooks <- fixtureHooks calls
    runPerformance hooks prepared path >>= \result -> result.exitCode `shouldBe` 0
    published <- newIORef False
    result <- runPerformance hooks {clock = pure (addUTCTime 1830 now), publishAndVerify = \_ _ -> writeIORef published True >> pure True} prepared path
    result.exitCode `shouldBe` 4
    readIORef published `shouldReturn` False
  it "rejects publication that completes beyond the original execution deadline" $ withSystemTempDirectory "perf-publication-late" \directory -> do
    (prepared, path) <- fixture directory
    calls <- newIORef ([] :: [(Text, Int, Bool)])
    hooks <- fixtureHooks calls
    current <- newIORef now
    result <- runPerformance hooks {clock = readIORef current, publishAndVerify = \_ _ -> writeIORef current (addUTCTime 1801 now) >> pure True} prepared path
    result.exitCode `shouldBe` 4
    result.evidenceVerified `shouldBe` False
  it "reserves an identified replacement once when the same callback is reconciled" $ withSystemTempDirectory "perf-runner-reservation" \directory -> do
    (prepared, path) <- fixture directory
    calls <- newIORef ([] :: [(Text, Int, Bool)])
    hooks <- fixtureHooks calls
    let reconciled =
          hooks
            { compareConfiguration = \lease entry index resuming callbacks -> do
                callbacks.reserveReplacement entry.profile.minimumPairs
                callbacks.reserveReplacement entry.profile.minimumPairs
                hooks.compareConfiguration lease entry index resuming callbacks
            }
    result <- runPerformance reconciled prepared path
    result.exitCode `shouldBe` 0
    state <- readPerfSession path >>= right >>= right . journalState
    Map.elems state.replacements `shouldBe` [1, 1]
    length state.replacementIdentities `shouldBe` 2
  it "does not restart cancellation or release grace for an expired interrupted session" $ withSystemTempDirectory "perf-expired-cleanup" \directory -> do
    (prepared, path) <- fixture directory
    session <- readPerfSession path >>= right
    identifier <- newRunId
    acquired <- right (appendEvent (SessionEvent now (LeaseAcquired (LeaseIdentity "alpha" identifier))) session)
    active <- right (appendEvent (SessionEvent now (ComparisonStarted "shibuya-core-quick" 0)) acquired)
    writePerfSession path active
    calls <- newIORef ([] :: [(Text, Int, Bool)])
    cleanupCalls <- newIORef (0 :: Int)
    hooks <- fixtureHooks calls
    result <- runPerformance hooks {clock = pure (addUTCTime 1870 now), cancelOwnedWork = \_ -> modifyIORef' cleanupCalls (+ 1), releaseOwnedLease = \_ -> modifyIORef' cleanupCalls (+ 1) >> pure True} prepared path
    result.exitCode `shouldBe` 4
    readIORef calls `shouldReturn` []
    readIORef cleanupCalls `shouldReturn` 0
  it "releases an incompatible lease before admitting the next configuration" $ withSystemTempDirectory "perf-runner-cells" \directory -> do
    (prepared, path) <- fixture directory
    calls <- newIORef ([] :: [(Text, Int, Bool)])
    hooks <- fixtureHooks calls
    admissions <- newIORef (0 :: Int)
    releases <- newIORef (0 :: Int)
    first <- newRunId
    second <- newRunId
    let changed =
          hooks
            { admit = \_ _ _ _ -> do
                count <- atomicModifyIORef' admissions (\n -> (n + 1, n))
                pure (Admitted (LeaseIdentity "alpha" (if count == 0 then first else second))),
              canRunConfiguration = \lease entry -> pure (lease.leaseId /= first || entry.profile.name == "shibuya-core-quick"),
              releaseOwnedLease = \_ -> modifyIORef' releases (+ 1) >> pure True
            }
    result <- runPerformance changed prepared path
    result.exitCode `shouldBe` 0
    readIORef admissions `shouldReturn` 2
    readIORef releases `shouldReturn` 2
    state <- readPerfSession path >>= right >>= right . journalState
    state.executionDeadline `shouldBe` Just (addUTCTime 1800 now)

fixture :: FilePath -> IO (Prepared.PerfPrepared, FilePath)
fixture directory = do
  prepared <- eitherDecodeFileStrict' "../kenshou-core/test/golden/perf-prepared.fixture.json" >>= either fail pure
  identifier <- newRunId
  session <- right (initialSession identifier (Prepared.preparedDigest prepared) prepared.plan "gs://fixture-evidence/performance" now)
  let path = directory </> "session.json"
  writePerfSession path session
  pure (prepared, path)

fixtureHooks :: IORef [(Text, Int, Bool)] -> IO RunnerHooks
fixtureHooks calls = do
  lease <- newRunId
  pure
    RunnerHooks
      { clock = pure now,
        admit = \_ _ _ _ -> pure (Admitted (LeaseIdentity "alpha" lease)),
        ownsLease = \_ -> pure True,
        canRunConfiguration = \_ _ -> pure True,
        compareConfiguration = \_ entry index resuming _ -> do
          modifyIORef' calls (<> [(entry.profile.name, index, resuming)])
          let comparison = object ["schema" .= ("kenshou.comparison/v1" :: Text), "verdict" .= ("pass" :: Text), "pairCount" .= entry.profile.minimumPairs]
          pure (ConfigurationResult entry.profile.name entry.workloadSha256 "pass" "healthy" [] entry.profile.minimumPairs entry.profile.minimumPairs [] (Just comparison)),
        verifyCompleted = \_ -> pure True,
        cancelOwnedWork = \_ -> pure (),
        releaseOwnedLease = \_ -> pure True,
        recoverRuntimeFailures = \_ -> pure [],
        reportMetadata = \_ result -> pure result,
        publishAndVerify = \_ _ -> pure True
      }

now :: UTCTime
now = UTCTime (fromGregorian 2026 10 11) (secondsToDiffTime 0)

right :: (Show e) => Either e a -> IO a
right = either (fail . show) pure
