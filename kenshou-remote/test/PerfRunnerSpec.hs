module PerfRunnerSpec (spec) where

import Data.Aeson
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import Kenshou.Core.Id (newRunId)
import Kenshou.Perf.Plan
import Kenshou.Perf.Prepared qualified as Prepared
import Kenshou.Perf.Result
import Kenshou.Remote.Perf.Journal
import Kenshou.Remote.Perf.Runner
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "performance runner orchestration" do
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
            { admit = \_ _ -> do
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
        admit = \_ _ -> pure (Admitted (LeaseIdentity "alpha" lease)),
        ownsLease = \_ -> pure True,
        canRunConfiguration = \_ _ -> pure True,
        compareConfiguration = \_ entry index resuming _ -> do
          modifyIORef' calls (<> [(entry.profile.name, index, resuming)])
          let comparison = object ["schema" .= ("kenshou.comparison/v1" :: Text), "verdict" .= ("pass" :: Text), "pairCount" .= entry.profile.minimumPairs]
          pure (ConfigurationResult entry.profile.name entry.workloadSha256 "pass" "healthy" [] entry.profile.minimumPairs entry.profile.minimumPairs [] (Just comparison)),
        verifyCompleted = \_ -> pure True,
        cancelOwnedWork = \_ -> pure (),
        releaseOwnedLease = \_ -> pure True,
        publishAndVerify = \_ _ -> pure True
      }

now :: UTCTime
now = UTCTime (fromGregorian 2026 10 11) (secondsToDiffTime 0)

right :: (Show e) => Either e a -> IO a
right = either (fail . show) pure
