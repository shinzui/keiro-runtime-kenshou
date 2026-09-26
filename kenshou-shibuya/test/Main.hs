module Main (main) where

import Data.Either (isLeft)
import Data.List (nub)
import Data.Text qualified as Text
import Hedgehog (forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Kenshou.Core.Bundle (LayerBundle (..), mkRegistry)
import Kenshou.Core.Context (Environment (..), RunContext (..), newRunState, readRunState)
import Kenshou.Core.Env (EnvRequirements (..))
import Kenshou.Core.Env.Postgres (withPostgresEnv)
import Kenshou.Core.Id (renderRunId)
import Kenshou.Core.Log (nullLogger)
import Kenshou.Core.Outcome (Outcome (..))
import Kenshou.Core.RunSpec (EffectiveRunSpec (..), EnvironmentSpec (..), RunSpec (..), SpecPlacement (..))
import Kenshou.Core.RunSpec.Resolve (resolveRunSpec)
import Kenshou.Core.Scenario (Scenario (..), ScenarioReport (..))
import Kenshou.Suite.Shibuya (bundle)
import Kenshou.Suite.Shibuya.Cohort (CoreLine (..), coreLine, knownOnReleasedCore, rev)
import Kenshou.Suite.Shibuya.Concurrency.KeyedModel (Action (..), Item (..), ModelCase (..), modelProperty, runCase)
import Kenshou.Suite.Shibuya.Concurrency.PgmqPoolStarvation qualified as PgmqPoolStarvation
import Kenshou.Suite.Shibuya.Knobs (DecisionPattern (..), PartitionMode (..), parseConcurrency, parseDecisions, parseOrdering, parsePartitions, parseStrategy, renderDecisions, renderPartitions)
import Kenshou.Suite.Shibuya.Matrix (allCells, cellsOf, uncovered)
import Kenshou.Suite.Shibuya.Roles (runGcMode)
import MetricsSpec qualified
import Shibuya.Policy (Concurrency (..), OrderingPolicy (..), validatePolicy)
import SyntheticSpec qualified
import System.Environment (getArgs, getExecutablePath)
import System.Exit (ExitCode (..), exitFailure)
import System.Process (proc, readCreateProcessWithExitCode)
import System.Timeout (timeout)
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

main :: IO ()
main =
  getArgs >>= \case
    ["--gc-probe", mode] -> runGcMode (Text.pack mode)
    ["--pgmq-live-probe", version] -> runPgmqLiveProbe version
    _ -> hspec spec

runPgmqLiveProbe :: String -> IO ()
runPgmqLiveProbe version = do
  let scenario = PgmqPoolStarvation.scenario
      input = RunSpec Nothing scenario.id Nothing [] [("pg.version", Text.pack version)] Nothing Nothing Nothing (EnvironmentSpec RunLocal Nothing Nothing mempty Nothing Nothing) Nothing Nothing mempty
  registry <- either (fail . show) pure (mkRegistry [bundle])
  (_, resolved) <- resolveRunSpec registry input >>= either (fail . show) pure
  let directory = "/tmp/kenshou-shibuya-pgmq-live-" <> Text.unpack (renderRunId resolved.runId)
  case (scenario.requires.postgres, resolved.environment.postgres) of
    (Just requirement, Just postgresSpec) -> do
      result <- withPostgresEnv nullLogger directory resolved.runId requirement postgresSpec resolved.dimensions $ \postgres -> do
        state <- newRunState
        let probeContext = RunContext resolved.runId scenario.id resolved.knobs resolved.dimensions resolved.seed resolved.phases (Environment (Just postgres) mempty) resolved.environment resolved.comparison directory nullLogger state
        report <- scenario.run probeContext
        (summaries, _, _, _) <- readRunState state
        print summaries
        pure report
      case result of
        Left err -> print err >> exitFailure
        Right report -> print report >> if report.outcome == Passed then pure () else exitFailure
    _ -> fail "PGMQ live probe requires a PostgreSQL environment"

spec :: Spec
spec = do
  describe "keyed scheduler model" $ do
    it "checks generated delivery histories on the linked Shibuya release" $ hedgehog modelProperty
    it "conserves retried, thrown and dead-lettered deliveries across partition keys" $ do
      runCase (ModelCase [Item 0 1000 RetryOnce, Item 1 1500 ThrowOnce, Item 0 500 DeadLetter, Item 1 1000 Succeed] Nothing) `shouldReturn` []
    it "drains and repeats a stop during keyed work" $ do
      runCase (ModelCase (replicate 8 (Item 0 2000 Succeed) <> replicate 8 (Item 1 2000 Succeed)) (Just 1500)) `shouldReturn` []
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
