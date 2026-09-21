{-# LANGUAGE FieldSelectors #-}

module Main (main) where

import Data.Aeson (FromJSON, Value, eitherDecode, eitherDecodeFileStrict', encode, toJSON)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Kenshou.Core.Bundle (allScenarios, mkRegistry)
import Kenshou.Core.Cohort
import Kenshou.Core.Dimension
import Kenshou.Core.Id
import Kenshou.Core.Knob
import Kenshou.Core.RunSpec
import Kenshou.Core.RunSpec.Resolve (resolveRunSpec)
import Kenshou.Core.Scenario (Scenario (..))
import Kenshou.Core.Selector (matchesSelector, parseSelector)
import Kenshou.Core.Selftest qualified as Selftest
import Test.Hspec
  ( Spec,
    describe,
    expectationFailure,
    hspec,
    it,
    shouldBe,
    shouldContain,
    shouldNotBe,
  )

main :: IO ()
main = hspec do
  descriptorSpec
  hashSpec
  mismatchSpec
  activeCohortSpec
  identifierSpec
  selectorSpec
  registrySpec
  knobSpec
  dimensionSpec
  runSpecSpec

descriptorSpec :: Spec
descriptorSpec = describe "cohort identity" do
  it "matches the stable JSON golden" do
    descriptor <- decodeFixture "descriptor-released.json"
    plan <- decodeFixture "plan-released.json"
    golden <- decodeFixture "cohort-identity.golden.json"
    case identityFromPlan descriptor "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd" plan of
      Left err -> expectationFailure (show err)
      Right identity -> toJSON identity `shouldBe` (golden :: Value)

hashSpec :: Spec
hashSpec = describe "planHash" do
  it "ignores install-plan order and local checkout paths" do
    baseline <- hashFixture "plan-released.json"
    reordered <- hashFixture "plan-reordered.json"
    moved <- hashFixture "plan-local-change.json"
    reordered `shouldBe` baseline
    moved `shouldBe` baseline

  it "changes with a package version or git revision" do
    baseline <- hashFixture "plan-released.json"
    versionChanged <- hashFixture "plan-version-change.json"
    commitChanged <- hashFixture "plan-commit-change.json"
    versionChanged `shouldNotBe` baseline
    commitChanged `shouldNotBe` baseline

mismatchSpec :: Spec
mismatchSpec = describe "checkCohort" do
  it "reports every mismatch constructor" do
    let descriptor = onePackageDescriptor
        missing = identityWith []
        wrongVersion = identityWith [ResolvedPackage "foo" "2.0.0" (FromHackage Nothing)]
        wrongSource = identityWith [ResolvedPackage "foo" "1.0.0" (FromGit "https://example.com/foo.git" "abc" Nothing)]
        localSource = identityWith [ResolvedPackage "foo" "1.0.0" (FromLocalPath "/tmp/foo")]
    checkCohort descriptor missing `shouldContain` [MissingPackage "foo"]
    checkCohort descriptor wrongVersion `shouldContain` [VersionMismatch "foo" "1.0.0" "2.0.0"]
    checkCohort descriptor wrongSource `shouldContain` [SourceMismatch "foo" HackageSource (FromGit "https://example.com/foo.git" "abc" Nothing)]
    checkCohort descriptor localSource `shouldContain` [LocalPathSource "foo" "/tmp/foo"]

activeCohortSpec :: Spec
activeCohortSpec = describe "activeCohortName" do
  it "accepts exactly one cohort import" do
    result <- activeCohortName (fixtures <> "/valid-project")
    result `shouldBe` Right (CohortName "released")

  it "rejects extra lines" do
    result <- activeCohortName (fixtures <> "/invalid-project")
    case result of
      Left (CohortInvalidActive _) -> pure ()
      other -> expectationFailure ("expected CohortInvalidActive, got " <> show other)

identifierSpec :: Spec
identifierSpec = describe "scenario identifiers" do
  it "round-trips canonical identifiers" do
    let rendered = "kiroku/append/concurrency/expected-version-race"
    fmap renderScenarioId (parseScenarioId rendered) `shouldBe` Right rendered

  it "rejects malformed identifiers" do
    parseScenarioId "kiroku/append/correctness" `shouldBe` Left "scenario identifier must have four segments: \"kiroku/append/correctness\""
    parseScenarioId "KIROKU/append/correctness/example" `shouldBe` Left "unknown layer \"KIROKU\""

  it "generates canonical UUIDv7 run ids" do
    generated <- newRunId
    parseRunId (renderRunId generated) `shouldBe` Right generated

selectorSpec :: Spec
selectorSpec = describe "scenario selectors" do
  it "supports one-segment and recursive wildcards" do
    scenario <- expectRight (parseScenarioId "selftest/kernel/correctness/always-pass")
    one <- expectRight (parseSelector "*/*/correctness/*")
    recursive <- expectRight (parseSelector "selftest/**")
    matchesSelector one scenario `shouldBe` True
    matchesSelector recursive scenario `shouldBe` True

registrySpec :: Spec
registrySpec = describe "scenario registry" do
  it "sorts the kernel self-tests by identifier" do
    case mkRegistry [Selftest.bundle] of
      Left errors -> expectationFailure (show errors)
      Right registry ->
        fmap (renderScenarioId . (.id)) (allScenarios registry)
          `shouldBe` [ "selftest/kernel/correctness/always-fail",
                       "selftest/kernel/correctness/always-pass",
                       "selftest/kernel/correctness/errors"
                     ]

knobSpec :: Spec
knobSpec = describe "knob resolution" do
  let workers = knobName "selftest.workers"
      enabled = knobName "selftest.enabled"
      declarations =
        [ KnobSpec workers "Worker count" KnobInt (VInt 2) (IntRange 1 8) [VInt 1, VInt 8],
          KnobSpec enabled "Enable work" KnobBool (VBool False) AnyValue []
        ]
  it "fills defaults and parses typed command-line values" do
    resolved <- expectRight (resolveKnobs declarations [(workers, RawText "4"), (enabled, RawText "true")])
    knobInt resolved workers `shouldBe` (4 :: Int64)
    knobBool resolved enabled `shouldBe` True
  it "reports duplicates, unknown names and range violations together" do
    let unknown = knobName "selftest.unknown"
        result = resolveKnobs declarations [(workers, RawText "9"), (workers, RawText "1"), (unknown, RawText "x")]
    case result of
      Left problems -> length problems `shouldBe` 3
      Right _ -> expectationFailure "expected knob errors"

dimensionSpec :: Spec
dimensionSpec = describe "dimension resolution" do
  let support = postgresDimensions (PgFsyncOff :| [PgDurable]) (Pg18 :| []) noDimensions
  it "fills every applicable default" do
    resolveDimensions support [] `shouldBe` Right (Dimensions Nothing Nothing (Just PgFsyncOff) (Just Pg18))
  it "rejects unsupported and inapplicable values" do
    case resolveDimensions support [("pg.version", "17"), ("telemetry.tracing", "off")] of
      Left problems -> length problems `shouldBe` 2
      Right _ -> expectationFailure "expected dimension errors"

runSpecSpec :: Spec
runSpecSpec = describe "run specification" do
  it "decodes a minimal document and emits a round-trippable effective document" do
    input <- case eitherDecode "{\"schema\":\"kenshou.run-spec/v1\",\"scenario\":\"selftest/kernel/correctness/always-pass\",\"seed\":7}" of
      Left err -> expectationFailure err >> fail "unreachable"
      Right value -> pure value
    registry <- expectRight (mkRegistry [Selftest.bundle])
    resolution <- resolveRunSpec registry input
    (_, effective) <- expectRight resolution
    eitherDecode (encode effective) `shouldBe` Right (toJSON effective :: Value)
  it "rejects a non-v7 run id while decoding" do
    let document = "{\"schema\":\"kenshou.run-spec/v1\",\"scenario\":\"selftest/kernel/correctness/always-pass\",\"runId\":\"550e8400-e29b-41d4-a716-446655440000\"}"
    case (eitherDecode document :: Either String RunSpec) of
      Left err -> err `shouldContain` "UUIDv7"
      Right _ -> expectationFailure "expected UUIDv7 rejection"

knobName :: Text -> KnobName
knobName = either (error . show) id . mkKnobName

onePackageDescriptor :: CohortDescriptor
onePackageDescriptor =
  CohortDescriptor
    "kenshou.cohort/v1"
    (CohortName "released")
    "fixture"
    "2026-09-20"
    "ghc-9.12.4"
    "2026-09-20T13:44:47Z"
    "cohort/released.project"
    [ComponentSpec (ComponentId "foo") "mori://example/foo" HackageSource [PackagePin "foo" "1.0.0" Nothing]]
    []
    []

identityWith :: [ResolvedPackage] -> CohortIdentity
identityWith packages =
  CohortIdentity
    (CohortName "released")
    "ghc-9.12.4"
    "3.16.1.0"
    "linux"
    "x86_64"
    (Just "2026-09-20T13:44:47Z")
    (PlanHash "sha256:fixture")
    "fixture"
    [ResolvedComponent (ComponentId "foo") "mori://example/foo" packages]

hashFixture :: FilePath -> IO PlanHash
hashFixture name = do
  value <- decodeFixture name
  case planHash value of
    Left err -> expectationFailure (show err) >> fail "unreachable"
    Right result -> pure result

decodeFixture :: (FromJSON value) => FilePath -> IO value
decodeFixture name = do
  result <- eitherDecodeFileStrict' (fixtures <> "/" <> name)
  case result of
    Left err -> expectationFailure err >> fail "unreachable"
    Right value -> pure value

fixtures :: FilePath
fixtures = "test/fixtures"

expectRight :: (Show problem) => Either problem value -> IO value
expectRight (Right value) = pure value
expectRight (Left problem) = expectationFailure (show problem) >> fail "unreachable"
