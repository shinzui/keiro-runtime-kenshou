{-# LANGUAGE FieldSelectors #-}

module Main (main) where

import Data.Aeson (FromJSON, Value, eitherDecodeFileStrict', toJSON)
import Kenshou.Core.Cohort
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
