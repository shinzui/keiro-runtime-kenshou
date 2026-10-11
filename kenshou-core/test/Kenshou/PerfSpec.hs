{-# LANGUAGE FieldSelectors #-}

module Kenshou.PerfSpec (spec) where

import Control.Monad (forM_)
import Data.Aeson
import Data.ByteString qualified as ByteString
import Data.Either (isLeft)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Cohort qualified as Cohort
import Kenshou.Core.Dimension
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob
import Kenshou.Core.Scenario (Placement (..), Tier (..))
import Kenshou.Perf.Plan qualified as Perf
import Kenshou.Perf.Request qualified as Request
import Kenshou.Perf.Source qualified as Source
import Kenshou.Plan.Catalog (ScenarioInfo (..))
import Kenshou.Plan.Change
import Kenshou.Plan.Components qualified as Graph
import System.Directory (doesFileExist)
import Test.Hspec hiding (context)

spec :: Spec
spec = do
  describe "performance requests" do
    it "normalizes defaults and round-trips explicit request fields" do
      eitherDecode (encode request) `shouldBe` Right request
    it "binds scope, purpose, control and budgets to request identity" do
      map Request.requestDigest [request {Request.coverageMode = "affected"}, request {Request.purpose = "gating"}, request {Request.control = "none"}, request {Request.budgetMinutes = 31}]
        `shouldSatisfy` all (/= Request.requestDigest request)
    it "sorts set fields without changing the digest" do
      Request.requestDigest request {Request.profiles = reverse request.profiles} `shouldBe` Request.requestDigest request
    it "rejects abbreviated, mutable, uppercase and placeholder revisions" do
      mapM_ (\revision -> Request.validateRequest request {Request.baselineRevision = revision} `shouldSatisfy` isLeft) ["main", "HEAD", "BASE_SHA", "abcd", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"]
    it "rejects cross-project artifact URIs and malformed canonical project URIs" do
      mapM_ (\project -> Request.validateRequest request {Request.project = project} `shouldSatisfy` isLeft) ["shibuya", "mori://shinzui/shibuya/packages/shibuya-core", "mori://shinzui/../shibuya"]
    it "rejects A/A with distinct revisions and A/A without explicit profiles" do
      Request.validateRequest request {Request.candidateRevision = shaB} `shouldSatisfy` isLeft
      Request.validateRequest request {Request.profiles = []} `shouldSatisfy` isLeft
    it "rejects duplicate target IDs, empty scope and invalid budgets" do
      mapM_
        (\value -> Request.validateRequest value `shouldSatisfy` isLeft)
        [request {Request.targetComponents = ["shibuya", "shibuya"]}, request {Request.profiles = []}, request {Request.budgetMinutes = 0}, request {Request.waitSeconds = -1}]
    it "rejects unknown wire fields instead of silently ignoring a typo" do
      let malformed = object ["schema" .= ("kenshou.perf-request/v1" :: Text), "purpos" .= ("calibration" :: Text)]
      (eitherDecode (encode malformed) :: Either String Request.PerfRequest) `shouldSatisfy` isLeft
  describe "performance source identities for generated cohorts" do
    it "reuses an unchanged cohort across candidate revisions, calibration seeds and measurement scope" do
      descriptor <- template
      manifest <- right (Source.parsePackageManifest "shibuya-core/shibuya-core.cabal" "name: shibuya-core\nversion: 0.9.0.3\n")
      metrics <- right (Source.parsePackageManifest "shibuya-metrics/shibuya-metrics.cabal" "name: shibuya-metrics\nversion: 0.9.0.3\n")
      snapshot <- right (Source.sourceSnapshot request descriptor upstream shaA [manifest, metrics])
      baseline <- right (Source.descriptorForSnapshot request descriptor "baseline" snapshot)
      let otherCandidate = request {Request.control = "none", Request.candidateRevision = shaB}
          revised = [request {Request.seed = request.seed + 1}, request {Request.cells = ["beta"]}, request {Request.budgetMinutes = 31}, request {Request.waitSeconds = 0}, request {Request.profiles = take 1 request.profiles}, request {Request.purpose = "gating"}, otherCandidate, otherCandidate {Request.candidateRevision = Text.replicate 40 "c"}]
      forM_ revised \selection -> Source.descriptorForSnapshot selection descriptor "baseline" snapshot `shouldBe` Right baseline
      Source.descriptorForSnapshot otherCandidate {Request.baselineRevision = shaB, Request.candidateRevision = shaA} descriptor "candidate" snapshot `shouldBe` Right baseline
      different <- right (Source.sourceSnapshot otherCandidate descriptor upstream shaB [manifest, metrics])
      Source.descriptorForSnapshot otherCandidate descriptor "candidate" different `shouldNotBe` Right baseline
    it "invalidates cohort identity when compiler, index state or fixed dependency inputs change" do
      descriptor <- template
      manifest <- right (Source.parsePackageManifest "shibuya-core/shibuya-core.cabal" "name: shibuya-core\nversion: 0.9.0.3\n")
      metrics <- right (Source.parsePackageManifest "shibuya-metrics/shibuya-metrics.cabal" "name: shibuya-metrics\nversion: 0.9.0.3\n")
      snapshot <- right (Source.sourceSnapshot request descriptor upstream shaA [manifest, metrics])
      original <- right (Source.descriptorForSnapshot request descriptor "baseline" snapshot)
      let altered = descriptor {Cohort.descriptorComponents = map (\component -> if component.componentId == Cohort.ComponentId "shibuya" then component else component {Cohort.componentPackages = map (\pin -> pin {Cohort.pinVersion = "99.0.0"}) component.componentPackages}) descriptor.descriptorComponents}
      forM_ [descriptor {Cohort.descriptorCompiler = "ghc-9.14.1"}, descriptor {Cohort.descriptorIndexState = "2026-10-11T00:00:00Z"}, altered] \changed -> Source.descriptorForSnapshot request changed "baseline" snapshot `shouldNotBe` Right original
    it "reads manifest version and package directory independently in each revision" do
      descriptor <- template
      manifest <- right (Source.parsePackageManifest "moved/shibuya-core.cabal" "name: shibuya-core\nversion: 0.9.0.4\n")
      metrics <- right (Source.parsePackageManifest "shibuya-metrics/shibuya-metrics.cabal" "name: shibuya-metrics\nversion: 0.9.0.4\n")
      snapshot <- right (Source.sourceSnapshot request descriptor upstream shaA [manifest, metrics])
      generated <- right (Source.descriptorForSnapshot request descriptor "baseline" snapshot)
      otherArm <- right (Source.descriptorForSnapshot request descriptor "candidate" snapshot)
      generated `shouldBe` otherArm
      target <- first (filter ((== Cohort.ComponentId "shibuya") . (.componentId)) generated.descriptorComponents)
      target.componentSource `shouldBe` Cohort.GitSource upstream shaA
      map (.pinVersion) target.componentPackages `shouldBe` ["0.9.0.4", "0.9.0.4"]
      map (.pinSubdir) target.componentPackages `shouldBe` [Just "moved", Just "shibuya-metrics"]
      filter ((/= Cohort.ComponentId "shibuya") . (.componentId)) generated.descriptorComponents
        `shouldBe` filter ((/= Cohort.ComponentId "shibuya") . (.componentId)) descriptor.descriptorComponents
    it "rejects unknown descriptor IDs and targets owned by a different project" do
      descriptor <- template
      Source.targetPackages request {Request.targetComponents = ["unknown"]} descriptor `shouldSatisfy` isLeft
      Source.targetPackages request {Request.targetComponents = ["shibuya-pgmq-adapter"]} descriptor `shouldSatisfy` isLeft
    it "rejects missing and duplicate packages at a requested revision" do
      descriptor <- template
      manifest <- right (Source.parsePackageManifest "shibuya-core/shibuya-core.cabal" "name: shibuya-core\nversion: 0.9.0.3\n")
      Source.sourceSnapshot request descriptor upstream shaA [manifest] `shouldSatisfy` isLeft
      Source.sourceSnapshot request descriptor upstream shaA [manifest, manifest] `shouldSatisfy` isLeft
    it "rejects mutable template source pins" do
      descriptor <- template
      let components = map (\component -> component {Cohort.componentSource = Cohort.GitSource upstream "main"}) descriptor.descriptorComponents
      Source.targetPackages request descriptor {Cohort.descriptorComponents = components} `shouldSatisfy` isLeft
    it "rejects forged wire paths and manifest digests" do
      manifest <- right (Source.parsePackageManifest "safe/package.cabal" "name: package\nversion: 1.0\n")
      (eitherDecode (encode manifest {Source.path = "../outside.cabal"}) :: Either String Source.PackageManifest) `shouldSatisfy` isLeft
      (eitherDecode (encode manifest {Source.sha256 = "sha256:fake"}) :: Either String Source.PackageManifest) `shouldSatisfy` isLeft
    it "rejects ambiguous identity and paths that escape generated inputs" do
      Source.parsePackageManifest "../bad.cabal" "name: bad\nversion: 1.0\n" `shouldSatisfy` isLeft
      Source.parsePackageManifest "bad.cabal" "name: bad\nname: other\nversion: 1.0\n" `shouldSatisfy` isLeft
  describe "bounded performance planning" do
    it "retains explicit A/A profiles in calibration mode with an empty diff" do
      (graph, profiles, catalog) <- context
      plan <- right (Perf.planPerformance request graph catalog profiles [] [] [] policyDigests Map.empty)
      length plan.selected `shouldBe` 2
      plan.coverage `shouldBe` "complete"
      plan.gatingEligible `shouldBe` False
      plan.estimateSeconds `shouldBe` 1540
      eitherDecode (encode plan) `shouldBe` Right plan
      map (.reasons) plan.selected `shouldSatisfy` all (not . null)
    it "cannot admit a catalog's unverified calibration claim to a gating plan" do
      (graph, profiles, catalog) <- context
      let claimed = profiles {Perf.profiles = map (\profile -> profile {Perf.calibration = Just (object ["calibrated" .= True])}) profiles.profiles}
      plan <- right (Perf.planPerformance request {Request.purpose = "gating"} graph catalog claimed [] [] [] policyDigests Map.empty)
      plan.coverage `shouldBe` "incomplete"
      map snd plan.excluded `shouldBe` ["uncalibrated", "uncalibrated"]
      plan.gatingEligible `shouldBe` False
    it "binds workload identity without making calibration promotion self-referential" do
      (_, profiles, _) <- context
      profile <- first profiles.profiles
      Perf.workloadDigest profile "sha256:policy" `shouldBe` Perf.workloadDigest profile {Perf.calibration = Just (String "evidence")} "sha256:policy"
      Perf.workloadDigest profile "sha256:policy" `shouldNotBe` Perf.workloadDigest profile {Perf.scenarioRevision = 3} "sha256:policy"
    it "defers an entire configuration when the paired estimate exceeds budget" do
      (graph, profiles, catalog) <- context
      plan <- right (Perf.planPerformance request {Request.budgetMinutes = 13} graph catalog profiles [] [] [] policyDigests Map.empty)
      length plan.selected `shouldBe` 1
      map snd plan.excluded `shouldBe` ["over-budget"]
      plan.coverage `shouldBe` "incomplete"
    it "reports transitive dependent and uncovered correctness paths" do
      (graph, profiles, catalog) <- context
      reference <- right (Graph.parseRef graph "shibuya-core:contract")
      let changes = [Change reference Named "core contract changed"]
      plan <- right (Perf.planPerformance request {Request.control = "none", Request.coverageMode = "affected", Request.profiles = []} graph catalog profiles changes [] [] policyDigests Map.empty)
      plan.affectedScenarios `shouldContain` ["shibuya/pgmq-adapter/benchmark/end-to-end-throughput-latency"]
      plan.uncoveredScenarios `shouldContain` ["shibuya/metrics/correctness/test"]
      plan.coverage `shouldBe` "incomplete"
    it "separates selected-profile completion from whole-change coverage" do
      (graph, profiles, catalog) <- context
      reference <- right (Graph.parseRef graph "shibuya-core:contract")
      plan <- right (Perf.planPerformance request {Request.control = "none"} graph catalog profiles [Change reference Named "core changed"] [] [] policyDigests Map.empty)
      plan.coverage `shouldBe` "complete"
      plan.changeCoverage `shouldBe` "incomplete"
    it "does not certify a telemetry change with disabled telemetry" do
      (graph, profiles, catalog) <- context
      reference <- right (Graph.parseRef graph "shibuya-core:telemetry")
      plan <- right (Perf.planPerformance request {Request.control = "none", Request.coverageMode = "affected", Request.profiles = []} graph catalog profiles [Change reference Named "telemetry changed"] [] [] policyDigests Map.empty)
      plan.uncoveredScenarios `shouldContain` ["shibuya/core-ordering/benchmark/concurrency-sweep"]
      plan.coverage `shouldBe` "incomplete"
    it "selects conservatively for unmapped build inputs" do
      (graph, _, _) <- context
      let (changes, unknown, documentation) = Perf.conservativeChanges graph "shibuya" ["cabal.project", "docs/guide.md"] []
      map (.source) changes `shouldBe` [Everything]
      unknown `shouldBe` ["cabal.project"]
      documentation `shouldBe` ["docs/guide.md"]
    it "requires a repository-scoped documentation proof for not-applicable" do
      (graph, profiles, catalog) <- context
      let normal = request {Request.control = "none", Request.profiles = [], Request.coverageMode = "affected"}
      empty <- right (Perf.planPerformance normal graph catalog profiles [] [] [] policyDigests Map.empty)
      empty.coverage `shouldBe` "incomplete"
      proved <- right (Perf.planPerformance normal graph catalog profiles [] [] ["docs/guide.md"] policyDigests Map.empty)
      proved.coverage `shouldBe` "not-applicable"
      proved.gatingEligible `shouldBe` False
    it "rejects phases the pinned scenario revision cannot honor" do
      (_, profiles, catalog) <- context
      profile <- first profiles.profiles
      Perf.validateProfile catalog profile {Perf.warmupSeconds = 1} `shouldSatisfy` isLeft
      Perf.validateProfile catalog profile {Perf.steadyCount = 2000} `shouldSatisfy` isLeft
      Perf.validateProfile catalog profile {Perf.timeoutSeconds = 181} `shouldSatisfy` isLeft
    it "rejects unknown profile names and raw sample suppression" do
      (graph, profiles, catalog) <- context
      Perf.planPerformance request {Request.profiles = ["missing"]} graph catalog profiles [] [] [] policyDigests Map.empty `shouldSatisfy` isLeft
      profile <- first profiles.profiles
      Perf.validateProfile catalog profile {Perf.knobs = Map.insert "measure.raw-samples" (String "off") profile.knobs} `shouldSatisfy` isLeft

shaA, shaB, upstream :: Text
shaA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
shaB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
upstream = "https://github.com/shinzui/shibuya.git"

request :: Request.PerfRequest
request = Request.PerfRequest "mori://shinzui/shibuya" shaA shaA "cohort/released.json" ["shibuya"] "change-performance" "selected-profiles" "calibration" "aa" ["shibuya-core-quick", "shibuya-pgmq-quick"] 20261010 ["alpha"] 90 30

policyDigests :: Map.Map Text Text
policyDigests = Map.singleton "policies/default.json" "sha256:policy"

context :: IO (Graph.ComponentGraph, Perf.ProfileCatalog, [ScenarioInfo])
context = do
  graph <- right Graph.embeddedGraph
  profiles <- load "policies/performance/catalog.v1.json"
  catalog <- traverse makeScenario [(profile.scenario, profile.scenarioRevision, True) | profile <- profiles.profiles]
  correctness <- makeScenario ("shibuya/metrics/correctness/test", 1, False)
  pure (graph, profiles, catalog <> [correctness])
  where
    makeScenario (name, revision, benchmark) = do
      identifier <- right (parseScenarioId name)
      let dimensions = if name == "shibuya/core-ordering/benchmark/concurrency-sweep" then allTelemetryArms noDimensions else postgresDimensions (PgDurable :| []) (Pg18 :| [Pg17]) noDimensions
      knobs <- traverse makeKnob [("bench.arm", KnobText, VText "configured"), ("bench.rate", KnobInt, VInt 200), ("shibuya.messages", KnobInt, VInt 1000), ("measure.raw-samples", KnobText, VText "full")]
      pure (ScenarioInfo identifier revision "fixture" TierStandard PlaceEither (if benchmark then knobs else []) dimensions Nothing)
    makeKnob (name, kind, def) = do
      key <- right (mkKnobName name)
      pure (KnobSpec key "fixture" kind def AnyValue [])

template :: IO Cohort.CohortDescriptor
template = load "cohort/released.json"

load :: (FromJSON a) => FilePath -> IO a
load path = do
  exists <- doesFileExist path
  ByteString.readFile (if exists then path else "../" <> path) >>= right . eitherDecodeStrict'

right :: (Show e) => Either e a -> IO a
right (Right value) = pure value
right (Left problem) = expectationFailure (show problem) >> fail "expected Right"

first :: [a] -> IO a
first (value : _) = pure value
first [] = expectationFailure "expected a nonempty fixture" >> fail "empty fixture"
