module Kenshou.PlanSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Dimension
import Kenshou.Core.Id (Kind (..), mkSeed, parseRunId, parseScenarioId, renderScenarioId)
import Kenshou.Core.Outcome (Outcome (..))
import Kenshou.Core.RunSpec (SpecPlacement (..))
import Kenshou.Core.Scenario (Placement (..), Tier (..))
import Kenshou.Plan.Catalog (ScenarioInfo (..), readCatalogFile)
import Kenshou.Plan.Change
import Kenshou.Plan.Change.Cohort
import Kenshou.Plan.Change.Git qualified as Git
import Kenshou.Plan.Components
import Kenshou.Plan.Components.Check
import Kenshou.Plan.Matrix
import Kenshou.Plan.Policy
import Kenshou.Plan.Policy qualified as Policy
import Kenshou.Plan.RunPlan (PlanContext (..), PlanInputs (..), PlanSkeleton (..), SkipReason (..), Skipped (..), buildPlan)
import Kenshou.Plan.Selector
import Kenshou.Plan.Suite
import Kenshou.Plan.Summary qualified as Summary
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (callProcess)
import Test.Hspec

spec :: Spec
spec = do
  describe "Kenshou.Plan.Selector" do
    it "round-trips and matches recursive selectors" do
      selector <- expectRight (parseSelector "shibuya/pgmq-adapter/**")
      scenario <- expectRight (parseScenarioId "shibuya/pgmq-adapter/correctness/finalize")
      renderSelector selector `shouldBe` "shibuya/pgmq-adapter/**"
      matches selector scenario `shouldBe` True
    it "rejects recursive wildcards before the final position" do
      parseSelector "shibuya/**/correctness/*" `shouldBe` Left "** is permitted only as the final segment"

  describe "Kenshou.Plan.Catalog" do
    it "decodes the planned scenario catalog" do
      result <- readCatalogFile "test/fixtures/plan/catalog-planned.json"
      catalog <- expectRight result
      length catalog `shouldSatisfy` (> 40)

  describe "Kenshou.Plan.Components" do
    it "validates the embedded graph" do
      graph <- expectRight embeddedGraph
      validateGraph graph `shouldBe` []
    it "computes the pgmq dependent closure" do
      graph <- expectRight embeddedGraph
      origin <- expectRight (parseRef graph "pgmq-hs")
      let affected = dependents graph (Set.singleton origin)
          present text = either (const False) (`Map.member` affected) (parseRef graph text)
      present "shibuya-pgmq-adapter" `shouldBe` True
      present "keiro-pgmq" `shouldBe` True
      present "kenshou-harness" `shouldBe` True
      present "runtime-assembly" `shouldBe` True
    it "keeps shibuya runner changes away from keiro contract consumers" do
      graph <- expectRight embeddedGraph
      origin <- expectRight (parseRef graph "shibuya-core:runner")
      let affected = dependents graph (Set.singleton origin)
          present text = either (const False) (`Map.member` affected) (parseRef graph text)
      present "keiro-pgmq" `shouldBe` True
      present "shibuya-metrics" `shouldBe` True
      present "shibuya-kiroku-adapter" `shouldBe` True
      present "runtime-assembly" `shouldBe` True
      present "keiro" `shouldBe` False
      present "keiro:router" `shouldBe` False
    it "routes shibuya contract changes to the three keiro consumers" do
      graph <- expectRight embeddedGraph
      origin <- expectRight (parseRef graph "shibuya-core:contract")
      let affected = dependents graph (Set.singleton origin)
          present text = either (const False) (`Map.member` affected) (parseRef graph text)
      present "keiro:process-manager" `shouldBe` True
      present "keiro:router" `shouldBe` True
      present "keiro:inbox" `shouldBe` True
      present "keiro:command" `shouldBe` False
      present "keiro:outbox" `shouldBe` False
      present "keiro:workflow" `shouldBe` False

  describe "Kenshou.Plan.Components.Check" do
    it "resolves shortened unit ids and finds a planted missing edge" do
      graph <- expectRight embeddedGraph
      result <- checkAgainstPlanJson graph "test/fixtures/plan/plan-missing-edge.json"
      findings <- expectRight result
      findings `shouldSatisfy` any isMissing

  describe "Kenshou.Plan.Change" do
    it "selects only the PGMQ family and its dependents" do
      (graph, catalog) <- fixtureInputs
      changed <- named graph "pgmq-hs"
      selectedIds (selectScenarios graph catalog [changed])
        `shouldBe` expectedIds catalog ["pgmq/", "shibuya/pgmq-adapter/", "keiro/queue/", "runtime/", "selftest/kernel/correctness/postgres-roundtrip"]
    it "selects all Kiroku, Keiro, runtime, and kernel evidence for kiroku-store" do
      (graph, catalog) <- fixtureInputs
      changed <- named graph "kiroku-store"
      selectedIds (selectScenarios graph catalog [changed])
        `shouldBe` expectedIds catalog ["kiroku/", "shibuya/kiroku-adapter/", "keiro/", "runtime/", "selftest/kernel/"]
    it "distinguishes shibuya runner changes from contract changes" do
      (graph, catalog) <- fixtureInputs
      runner <- named graph "shibuya-core:runner"
      contract <- named graph "shibuya-core:contract"
      selectedIds (selectScenarios graph catalog [runner])
        `shouldBe` expectedIds catalog ["shibuya/", "kafka/", "keiro/queue/", "runtime/"]
      let contractIds = selectedIds (selectScenarios graph catalog [contract])
      contractIds `shouldSatisfy` Set.member "keiro/process-manager/correctness/react"
      contractIds `shouldSatisfy` Set.member "keiro/router/correctness/route"
      contractIds `shouldSatisfy` Set.member "keiro/inbox/correctness/deduplicate"
      contractIds `shouldSatisfy` Set.notMember "keiro/command/correctness/decide"
      contractIds `shouldSatisfy` Set.notMember "keiro/outbox/concurrency/publish"
      contractIds `shouldSatisfy` Set.notMember "keiro/workflow/correctness/resume"
    it "maps an outbox-only upstream diff and ignores upstream documentation" do
      (graph, catalog) <- fixtureInputs
      withSystemTempDirectory "kenshou-upstream" \repository -> do
        initialiseRepository repository
        writeRepoFile repository "keiro/src/Keiro/Outbox/Schema.hs" "module Schema where\n"
        writeRepoFile repository "docs/readme.md" "initial\n"
        commitAll repository "initial"
        writeRepoFile repository "keiro/src/Keiro/Outbox/Schema.hs" "module Schema where\nvalue = 1\n"
        commitAll repository "outbox"
        result <- Git.changesFromUpstream graph (Git.UpstreamDiff "keiro" repository "HEAD^" "HEAD")
        (changes, ignored) <- expectRight result
        ignored `shouldBe` 0
        selectedIds (selectScenarios graph catalog changes)
          `shouldBe` expectedIds catalog ["keiro/outbox/", "runtime/"]
        writeRepoFile repository "docs/readme.md" "changed\n"
        commitAll repository "docs"
        docsResult <- Git.changesFromUpstream graph (Git.UpstreamDiff "keiro" repository "HEAD^" "HEAD")
        (docsChanges, docsIgnored) <- expectRight docsResult
        docsChanges `shouldBe` []
        docsIgnored `shouldBe` 1
    it "maps --since repository paths to selectors and ignores docs" do
      (graph, catalog) <- fixtureInputs
      withSystemTempDirectory "kenshou-since" \repository -> do
        initialiseRepository repository
        writeRepoFile repository "kenshou-kiroku/x" "initial\n"
        writeRepoFile repository "docs/z" "initial\n"
        commitAll repository "initial"
        writeRepoFile repository "kenshou-kiroku/x" "changed\n"
        result <- Git.changesSince graph repository "HEAD"
        (changes, selectors, warnings) <- expectRight result
        changes `shouldBe` []
        warnings `shouldBe` []
        selectedIds (selectBySelectors Since "repository path" selectors catalog)
          `shouldBe` expectedIds catalog ["kiroku/"]
    it "maps a cohort package difference and fails safe for unknown packages" do
      (graph, _catalog) <- fixtureInputs
      let old = Map.fromList [("kiroku-store", FromHackage "0.8.0.1")]
          new = Map.fromList [("kiroku-store", FromHackage "0.8.0.2"), ("unmapped", FromHackage "1")]
          (changes, warnings) = diffCohorts graph old new
      fmap (.ref) changes `shouldContain` [ComponentRef (ComponentId "kiroku-store") Nothing]
      fmap (.source) changes `shouldContain` [Everything]
      fmap (.code) warnings `shouldContain` ["unmapped-package"]

  describe "Kenshou.Plan.Matrix" do
    it "covers every pair in at most twenty rows" do
      let dimensions = [("a", ["0", "1", "2", "3"]), ("b", ["0", "1", "2", "3"]), ("c", ["0", "1"]), ("d", ["0", "1"])]
          rows = pairwiseCover dimensions
      length rows `shouldSatisfy` (<= 20)
      pairSet rows `shouldBe` pairSet (fullRows dimensions)
    it "raises an observability change to telemetry corners" do
      selected <- matrixSelected Correctness (Just "telemetry-corners")
      seed <- expectRight (mkSeed 42)
      let (configs, skipped) = expandScenario (defaultPlanPolicy seed) selected
      skipped `shouldBe` []
      length configs `shouldBe` 4
    it "never emits fsync-off for a benchmark" do
      selected <- matrixSelected Benchmark Nothing
      seed <- expectRight (mkSeed 42)
      let policy = (defaultPlanPolicy seed :: PlanPolicy) {Policy.placement = RunOnCell}
          (configs, skipped) = expandScenario policy selected
      skipped `shouldBe` []
      fmap (Map.lookup "pg.durability" . (.dimensions)) configs `shouldSatisfy` all (== Just "durable")

  describe "Kenshou.Plan.RunPlan" do
    it "keeps benchmark trial groups whole under a budget" do
      selected <- matrixSelected Benchmark Nothing
      seed <- expectRight (mkSeed 42)
      let policy = (defaultPlanPolicy seed :: PlanPolicy) {Policy.placement = RunOnCell, Policy.budgetMinutes = Just 2}
          skeleton = buildPlan testPlanContext policy [selected]
      skeleton.runs `shouldBe` []
      fmap (.reason) skeleton.skipped `shouldContain` [SkipOverBudget]

  describe "Kenshou.Plan.Suite" do
    it "decodes every checked-in suite" do
      let names = ["smoke", "change", "nightly", "weekly-soak", "release"] :: [Text]
      results <- traverse (readSuite . ("../suites/" <>) . (<> ".json") . Text.unpack) names
      suites <- traverse expectRight results
      fmap (.name) suites `shouldBe` names
    it "raises knob policy only for directly selected scenarios" do
      suite <- readSuite "../suites/change.json" >>= expectRight
      (_, catalog) <- fixtureInputs
      scenario <- maybe (expectationFailure "fixture has no scenario with knobs" >> fail "unreachable") pure (find (not . null . (.knobs)) catalog)
      selector <- expectRight (parseSelector "**")
      let change = Change (ComponentRef (ComponentId "fixture") Nothing) Named "fixture"
          selected distance = Selected scenario (Reason change [change.ref] selector distance :| []) Nothing Nothing
          direct = applySuite suite [scenario] [selected 0]
          dependent = applySuite suite [scenario] [selected 1]
      fmap (.minKnobPolicy) direct `shouldBe` [Just "declared-variants"]
      fmap (.minKnobPolicy) dependent `shouldBe` [Nothing]

  describe "Kenshou.Plan.Summary" do
    it "treats reproduced known defects as non-blocking" do
      runId <- expectRight (parseRunId "0199a3f2-7c20-7f00-8a11-0c0d0e0f1011")
      scenarioId <- expectRight (parseScenarioId "selftest/kernel/correctness/known-defect")
      let attempt = Summary.Attempt runId (read "2026-09-21 00:00:00 UTC") (Just (read "2026-09-21 00:00:01 UTC")) (Just Failed) True (Just 0)
          summary = Summary.PlanSummary runId [Summary.SummaryEntry 1 scenarioId Summary.Completed [attempt]] Map.empty Passed 0
      Summary.worstOutcome summary `shouldBe` Passed
    it "counts an unfinished entry as errored" do
      runId <- expectRight (parseRunId "0199a3f2-7c20-7f00-8a11-0c0d0e0f1011")
      scenarioId <- expectRight (parseScenarioId "selftest/kernel/correctness/always-pass")
      let summary = Summary.PlanSummary runId [Summary.SummaryEntry 1 scenarioId Summary.Pending []] Map.empty Passed 0
      Summary.worstOutcome summary `shouldBe` Errored
  where
    isMissing (MissingEdge (ComponentId "pgmq-hs") (ComponentId "kiroku-store") _) = True
    isMissing _ = False

fixtureInputs :: IO (ComponentGraph, [ScenarioInfo])
fixtureInputs = do
  graph <- expectRight embeddedGraph
  catalog <- readCatalogFile "test/fixtures/plan/catalog-planned.json" >>= expectRight
  pure (graph, catalog)

named :: ComponentGraph -> Text -> IO Change
named graph reference = do
  parsed <- expectRight (parseRef graph reference)
  pure (Change parsed Named ("--changed " <> reference))

selectedIds :: [Selected] -> Set.Set Text
selectedIds = Set.fromList . fmap (renderScenarioId . (.id) . (.scenario))

expectedIds :: [ScenarioInfo] -> [Text] -> Set.Set Text
expectedIds catalog prefixes =
  Set.fromList
    [ identifier
    | scenario <- catalog,
      let identifier = renderScenarioId scenario.id,
      any (`Text.isPrefixOf` identifier) prefixes
    ]

initialiseRepository :: FilePath -> IO ()
initialiseRepository repository = do
  callProcess "git" ["-C", repository, "init", "-q"]
  callProcess "git" ["-C", repository, "config", "user.email", "kenshou@example.invalid"]
  callProcess "git" ["-C", repository, "config", "user.name", "Kenshou Test"]

writeRepoFile :: FilePath -> FilePath -> String -> IO ()
writeRepoFile repository relative contents = do
  createDirectoryIfMissing True (repository </> takeDirectory relative)
  writeFile (repository </> relative) contents

commitAll :: FilePath -> String -> IO ()
commitAll repository message = do
  callProcess "git" ["-C", repository, "add", "."]
  callProcess "git" ["-C", repository, "commit", "-q", "-m", message]

matrixSelected :: Kind -> Maybe Text -> IO Selected
matrixSelected kind minimumPolicy = do
  scenarioId <- expectRight (parseScenarioId ("kiroku/append/" <> kindText kind <> "/matrix"))
  selector <- expectRight (parseSelector "kiroku/**")
  let scenario =
        ScenarioInfo
          { id = scenarioId,
            revision = 1,
            summary = "matrix fixture",
            tier = TierSmoke,
            placement = if kind == Benchmark then PlaceCell else PlaceEither,
            knobs = [],
            dimensions = allMatrixDimensions,
            knownDefect = Nothing
          }
      change = Change (ComponentRef (ComponentId "kiroku-store") Nothing) Named "fixture"
  pure (Selected scenario (Reason change [change.ref] selector 0 :| []) minimumPolicy Nothing)
  where
    kindText Correctness = "correctness"
    kindText Concurrency = "concurrency"
    kindText Benchmark = "benchmark"
    kindText Soak = "soak"

allMatrixDimensions :: DimensionSupport
allMatrixDimensions =
  DimensionSupport
    (Supported (Support (TracingOff :| [TracingNoop, TracingSdkInMemory, TracingSdkOtlp]) TracingOff))
    (Supported (Support (MetricsOff :| [MetricsCollect, MetricsServe, MetricsServeScraped]) MetricsOff))
    (Supported (Support (PgFsyncOff :| [PgDurable]) PgFsyncOff))
    (Supported (Support (Pg17 :| [Pg18]) Pg18))

pairSet :: [Map.Map Text Text] -> Set.Set ((Text, Text), (Text, Text))
pairSet rows =
  Set.fromList
    [ (left, right)
    | row <- rows,
      (leftIndex, left) <- zip [0 :: Int ..] (Map.toAscList row),
      (rightIndex, right) <- zip [0 :: Int ..] (Map.toAscList row),
      leftIndex < rightIndex
    ]

fullRows :: [(Text, [Text])] -> [Map.Map Text Text]
fullRows = foldr (\(name, values) rows -> [Map.insert name value row | value <- values, row <- rows]) [Map.empty]

testPlanContext :: PlanContext
testPlanContext =
  PlanContext
    { suite = Nothing,
      graphDigest = "sha256:test",
      cohortName = "released",
      cohortPlanHash = "sha256:test",
      inputs = PlanInputs (Aeson.object []),
      changes = [],
      warnings = []
    }

expectRight :: (Show problem) => Either problem value -> IO value
expectRight (Right value) = pure value
expectRight (Left problem) = expectationFailure (show problem) >> fail "unreachable"
