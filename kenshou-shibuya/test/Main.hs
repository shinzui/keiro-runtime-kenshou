module Main (main) where

import Data.Either (isLeft)
import Data.List (nub)
import Data.Text qualified as Text
import Hedgehog (forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Kenshou.Core.Bundle (LayerBundle (..))
import Kenshou.Core.Scenario (Scenario (..))
import Kenshou.Suite.Shibuya (bundle)
import Kenshou.Suite.Shibuya.Cohort (CoreLine (..), coreLine, knownOnReleasedCore, rev)
import Kenshou.Suite.Shibuya.Knobs (DecisionPattern (..), PartitionMode (..), parseConcurrency, parseDecisions, parseOrdering, parsePartitions, parseStrategy, renderDecisions, renderPartitions)
import Kenshou.Suite.Shibuya.Matrix (allCells, cellsOf, uncovered)
import Kenshou.Suite.Shibuya.Roles (runGcMode)
import MetricsSpec qualified
import Shibuya.Policy (Concurrency (..), OrderingPolicy (..), validatePolicy)
import SyntheticSpec qualified
import System.Environment (getArgs, getExecutablePath)
import System.Exit (ExitCode (..))
import System.Process (proc, readCreateProcessWithExitCode)
import System.Timeout (timeout)
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

main :: IO ()
main =
  getArgs >>= \case
    ["--gc-probe", mode] -> runGcMode (Text.pack mode)
    _ -> hspec spec

spec :: Spec
spec = do
  describe "process-isolated GC liveness" $
    it "keeps the Shibuya caller alive with and without a retained application handle" $ do
      executable <- getExecutablePath
      mapM_ (checkMode executable) ["live-idle", "finite-ignore", "finite-stop-all", "halted", "failed-source"]
  MetricsSpec.spec
  SyntheticSpec.spec
  describe "lifecycle matrix" $ do
    it "enumerates thirteen distinct boundaries and five cases" $ do
      length allCells `shouldBe` 65
      length (nub allCells) `shouldBe` 65
    it "tags each registered scenario with distinct in-scope cells" $
      mapM_ checkScenario bundle.scenarios
    it "does not mark an exercised cell as inapplicable" $
      all (\(cell, _) -> cell `notElem` exercised) uncovered `shouldBe` True
  describe "cohort capability probe" $ do
    it "agrees with the linked shibuya-core policy" $
      case coreLine of
        CoreReleased0903 -> isLeft (validatePolicy Unordered (Async 0)) `shouldBe` False
        CoreLifecycleRemediated -> isLeft (validatePolicy Unordered (Async 0)) `shouldBe` True
    it "retains a released-only defect only on the released line" $
      (case coreLine of CoreReleased0903 -> knownOnReleasedCore (rev 3 "REV-3-F2") /= Nothing; CoreLifecycleRemediated -> knownOnReleasedCore (rev 3 "REV-3-F2") == Nothing) `shouldBe` True
  describe "configuration parsers" $ do
    it "parses all concurrency forms, including invalid policy bounds for the runtime to reject" $ do
      parseConcurrency "serial" `shouldBe` Right Serial
      parseConcurrency "ahead:4" `shouldBe` Right (Ahead 4)
      parseConcurrency "async:-1" `shouldBe` Right (Async (-1))
      parseConcurrency "async:garbage" `shouldSatisfy` isLeft
    it "parses ordering and supervision without accepting unknown names" $ do
      parseOrdering "partitioned-in-order" `shouldBe` Right PartitionedInOrder
      parseOrdering "unknown" `shouldSatisfy` isLeft
      parseStrategy "stop-all-on-failure" `shouldSatisfy` isRight
      parseStrategy "unknown" `shouldSatisfy` isLeft
    it "round-trips every partition pattern over a representative count range" $
      mapM_ (\mode -> parsePartitions (renderPartitions mode) `shouldBe` Right mode) $
        [NoPartitions, HighCardinality] <> [UniformPartitions n | n <- [1 .. 100]] <> [HotKey n | n <- [1 .. 100]]
    it "round-trips every decision pattern over a representative count range" $
      mapM_ (\patternValue -> parseDecisions (renderDecisions patternValue) `shouldBe` Right patternValue) $
        [AllOk] <> [RetryEvery n | n <- [1 .. 100]] <> [DeadLetterEvery n | n <- [1 .. 100]] <> [ThrowEvery n | n <- [1 .. 100]]
    it "round-trips arbitrary positive pattern counts" $ hedgehog $ do
      count <- forAll (Gen.int (Range.linear 1 1000000))
      parsePartitions (renderPartitions (UniformPartitions count)) === Right (UniformPartitions count)
      parsePartitions (renderPartitions (HotKey count)) === Right (HotKey count)
      parseDecisions (renderDecisions (RetryEvery count)) === Right (RetryEvery count)
      parseDecisions (renderDecisions (DeadLetterEvery count)) === Right (DeadLetterEvery count)
      parseDecisions (renderDecisions (ThrowEvery count)) === Right (ThrowEvery count)
    it "parses arbitrary signed concurrency bounds without normalizing them" $ hedgehog $ do
      count <- forAll (Gen.int (Range.linear (-1000000) 1000000))
      parseConcurrency ("ahead:" <> Text.pack (show count)) === Right (Ahead count)
      parseConcurrency ("async:" <> Text.pack (show count)) === Right (Async count)
    it "rejects zero and malformed pattern counts" $ do
      parsePartitions "uniform:0" `shouldSatisfy` isLeft
      parsePartitions "hot-key:nope" `shouldSatisfy` isLeft
      parseDecisions "retry-every:-1" `shouldSatisfy` isLeft
      parseDecisions "dead-letter-every:0" `shouldSatisfy` isLeft
  where
    isRight = not . isLeft
    checkScenario scenario = do
      let tags = cellsOf scenario.id
      tags `shouldNotBe` []
      length (nub tags) `shouldBe` length tags
      all (`elem` allCells) tags `shouldBe` True
    exercised = concatMap (cellsOf . (.id)) bundle.scenarios
    checkMode executable mode = do
      outcome <- timeout 12000000 $ readCreateProcessWithExitCode (proc executable ["--gc-probe", mode]) ""
      case outcome of
        Nothing -> expectationFailure (mode <> ": GC probe timed out")
        Just (ExitSuccess, _, _) -> pure ()
        Just (exitCode, _, stderrText) -> expectationFailure (mode <> ": " <> show exitCode <> ": " <> stderrText)
