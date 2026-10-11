module PerfRunnerSpec (spec) where

import Data.Aeson
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
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
                callbacks.reserveReplacement
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
        admit = \_ -> pure (Admitted (LeaseIdentity "alpha" lease)),
        ownsLease = \_ -> pure True,
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
