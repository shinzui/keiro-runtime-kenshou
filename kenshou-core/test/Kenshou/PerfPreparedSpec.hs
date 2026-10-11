{-# LANGUAGE FieldSelectors #-}

module Kenshou.PerfPreparedSpec (spec) where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Either (isLeft)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified
import Kenshou.Core.Canonical (sha256Hex)
import Kenshou.Core.Cohort qualified as Cohort
import Kenshou.Core.Manifest qualified as Manifest
import Kenshou.Perf.Artifacts
import Kenshou.Perf.Calibration qualified as Calibration
import Kenshou.Perf.Prepared hiding (plan)
import Kenshou.Perf.Source qualified as Source
import System.Directory (createFileLink)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "performance preparation integrity" do
  it "validates the pinned synthetic protocol fixture and rejects changed build keys" do
    prepared <- eitherDecodeFileStrict' "test/golden/perf-prepared.fixture.json" >>= right
    validatePrepared prepared `shouldBe` Right ()
    let baselineArm = (prepared :: PerfPrepared).baseline
    validatePrepared prepared {baseline = baselineArm {buildKey = "sha256:changed"}} `shouldSatisfy` isLeft
    decoded <- right (eitherDecode (encode prepared) :: Either String PerfPrepared)
    toJSON decoded `shouldBe` toJSON prepared
  it "admits resolved-cohort identities, replays legacy identities and rejects a rehashed alias" do
    prepared <- eitherDecodeFileStrict' "test/golden/perf-prepared.fixture.json" >>= right
    (request, template, baselineSource, candidateSource) <- right (parseEither (withObject "Inputs" \fields -> (,,,) <$> fields .: "request" <*> fields .: "template" <*> fields .: "baselineSource" <*> fields .: "candidateSource") (prepared :: PerfPrepared).inputs)
    baselineDescriptor <- right (Source.descriptorForSnapshot request template "baseline" baselineSource)
    candidateDescriptor <- right (Source.descriptorForSnapshot request template "candidate" candidateSource)
    let bind descriptor arm = do
          let digest = Data.Text.drop 7 (sha256Hex (LazyByteString.toStrict (encode descriptor)))
          lock <- case arm.sourceLock of
            Object fields -> pure (Object (KeyMap.insert "cohort" (toJSON descriptor.descriptorName) (KeyMap.insert "descriptorSha256" (String digest) fields)))
            _ -> fail "fixture source lock is not an object"
          payload <- case arm.payload of
            Object fields -> do
              original <- maybe (fail "fixture payload has no identity") pure (KeyMap.lookup "cohortIdentity" fields)
              identity <- case fromJSON original of Error problem -> fail problem; Success value -> pure value
              let changed = (identity :: Cohort.CohortIdentity) {Cohort.identityCohort = descriptor.descriptorName, Cohort.identityDescriptorSha256 = digest}
              pure (Object (KeyMap.insert "cohortIdentity" (toJSON changed) (KeyMap.insert "flakeAttr" (String ("packages.x86_64-linux.kenshou-" <> Cohort.unCohortName descriptor.descriptorName)) fields)))
            _ -> fail "fixture payload is not an object"
          pure arm {descriptor = descriptor, sourceLock = lock, payload = payload, buildKey = buildKeyFor prepared.harnessRevision descriptor lock arm.buildInventory arm.boundsInventory}
    baseline <- bind baselineDescriptor prepared.baseline
    candidate <- bind candidateDescriptor prepared.candidate
    let modern = prepared {baseline = baseline, candidate = candidate}
    validatePrepared modern `shouldBe` Right ()
    validatePrepared prepared `shouldBe` Right ()
    validatePrepared modern {candidate = prepared.candidate} `shouldSatisfy` isLeft
    alias <- bind baselineDescriptor {Cohort.descriptorName = Cohort.CohortName "perf-unrelated-alias", Cohort.descriptorProjectFile = "perf-unrelated-alias.project"} baseline
    validatePrepared modern {baseline = alias, candidate = alias} `shouldSatisfy` isLeft
  it "binds actual inventories to the planning toolchain while allowing catalog-only promotion" do
    prepared <- eitherDecodeFileStrict' "test/golden/perf-prepared.fixture.json" >>= right
    let inventory = (prepared :: PerfPrepared).baseline.buildInventory
    case (prepared.inputs, inventory.toolchain) of
      (Object inputs, Object toolchain) -> do
        let expected = Object (KeyMap.delete "harnessRevision" toolchain)
            pinned = prepared {inputs = Object (KeyMap.insert "buildToolchain" expected inputs)}
            changed = inventory {toolchain = Object (KeyMap.insert "harnessRevision" (String "another catalog commit") toolchain)}
        validatePrepared pinned `shouldBe` Right ()
        Calibration.toolchainDigest inventory `shouldBe` Calibration.toolchainDigest changed
        validatePrepared prepared {inputs = Object (KeyMap.insert "buildToolchain" (object ["strictBounds" .= False]) inputs)} `shouldSatisfy` isLeft
      _ -> expectationFailure "invalid synthetic inventory fixture"
  it "rejects bound lifting inside a resealed inventory even when its toolchain claims strict bounds" do
    prepared <- eitherDecodeFileStrict' "test/golden/perf-prepared.fixture.json" >>= right
    let arm = (prepared :: PerfPrepared).baseline
        corrupt = arm.buildInventory {packages = [entry {settings = object ["jailbreak" .= True, "configureFlags" .= ([] :: [Text])]} | entry <- arm.buildInventory.packages]}
        changed = arm {buildInventory = corrupt, buildKey = buildKeyFor prepared.harnessRevision arm.descriptor arm.sourceLock corrupt arm.boundsInventory}
    validatePrepared prepared {baseline = changed, candidate = changed} `shouldSatisfy` isLeft
  it "allows only target source/version changes; target flags still must match" do
    compareInventories ["runtime"] inventory inventory {packages = [runtime {version = "2", source = String "candidate"}, dependency]} `shouldBe` Right ()
    compareInventories ["runtime"] inventory inventory {packages = [runtime {flags = Map.singleton "feature" True}, dependency]} `shouldSatisfy` isLeft
    compareInventories ["runtime"] inventory inventory {packages = [runtime {settings = String "different"}, dependency]} `shouldSatisfy` isLeft
  it "rejects unrelated source, version, toolchain and package-set drift" do
    mapM_
      (\changed -> compareInventories ["runtime"] inventory changed `shouldSatisfy` isLeft)
      [inventory {packages = [runtime, dependency {source = String "other"}]}, inventory {packages = [runtime, dependency {version = "2"}]}, inventory {toolchain = String "other"}, inventory {packages = [runtime]}]
  it "rejects missing targets and ambiguous package identities" do
    compareInventories ["missing"] inventory inventory `shouldSatisfy` isLeft
    compareInventories ["runtime"] inventory inventory {packages = [runtime, dependency, dependency]} `shouldSatisfy` isLeft
  it "identifies harness sources by commit and includes transitive flags/revisions" do
    resolved <- right (cabalInventory "/workspace/harness" revision plan)
    length resolved.packages `shouldBe` 2
    map (.flags) resolved.packages `shouldContain` [Map.singleton "feature" True]
    cabalInventory "/workspace/other" revision plan `shouldSatisfy` isLeft
    cabalInventory "/workspace/harness" "main" plan `shouldSatisfy` isLeft
    eitherDecode (encode resolved) `shouldBe` Right resolved
  it "renders a standalone bounds project and rejects blanket exceptions" do
    bytes <- ByteString.readFile "../cohort/released.json"
    descriptor <- right (eitherDecodeStrict' bytes :: Either String Cohort.CohortDescriptor)
    project <- right (renderBoundsProject ["/harness/kenshou-core/kenshou-core.cabal"] descriptor)
    project `shouldNotContainText` "active.project"
    renderBoundsProject ["/harness/package.cabal"] descriptor {Cohort.descriptorAllowNewer = ["all"]} `shouldSatisfy` isLeft
    renderBoundsProject ["/unsafe path/package.cabal"] descriptor `shouldSatisfy` isLeft
  it "verifies the complete sealed file set and refuses an omitted file" $ withSystemTempDirectory "perf-seal" \root -> do
    writeFile (root </> "input.json") "{}"
    sealPerfDirectory root `shouldReturn` Right ()
    verifyPerfManifest root `shouldReturn` Right ()
    writeFile (root </> "unlisted.json") "{}"
    verifyPerfManifest root >>= (`shouldSatisfy` isLeft)
  it "refuses duplicate and escaping paths before opening a listed file" $ withSystemTempDirectory "perf-seal" \root -> do
    writeFile (root </> "input.json") "{}"
    sealPerfDirectory root `shouldReturn` Right ()
    original <- eitherDecodeFileStrict' (root </> "manifest.json") >>= right
    encodeFile (root </> "manifest.json") (original :: Manifest.Manifest) {Manifest.files = original.files <> original.files}
    verifyPerfManifest root >>= (`shouldSatisfy` isLeft)
    encodeFile (root </> "manifest.json") original {Manifest.files = map (\file -> file {Manifest.path = "../outside.json"}) original.files}
    verifyPerfManifest root >>= (`shouldSatisfy` isLeft)
  it "refuses symbolic links when sealing or verifying evidence" $ withSystemTempDirectory "perf-seal" \root -> do
    writeFile (root </> "input.json") "{}"
    sealPerfDirectory root `shouldReturn` Right ()
    createFileLink (root </> "input.json") (root </> "link.json")
    sealPerfDirectory root >>= (`shouldSatisfy` isLeft)
    verifyPerfManifest root >>= (`shouldSatisfy` isLeft)

runtime, dependency :: InventoryPackage
runtime = InventoryPackage "runtime" "1" (String "baseline") Map.empty (object [])
dependency = InventoryPackage "dependency" "1" (String "fixed") Map.empty (object [])

inventory :: BuildInventory
inventory = BuildInventory "nix" "ghc-9.12.4" "x86_64-linux" (String "pins") [dependency, runtime]

revision :: Text
revision = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

plan :: Value
plan =
  object
    [ "compiler-id" .= ("ghc-9.12.4" :: Text),
      "cabal-version" .= ("3.16" :: Text),
      "os" .= ("linux" :: Text),
      "arch" .= ("x86_64" :: Text),
      "install-plan"
        .= [ object ["type" .= ("configured" :: Text), "pkg-name" .= ("kenshou-core" :: Text), "pkg-version" .= ("0.1" :: Text), "pkg-src" .= object ["type" .= ("local" :: Text), "path" .= ("/workspace/harness/kenshou-core" :: Text)]],
             object ["type" .= ("configured" :: Text), "pkg-name" .= ("dependency" :: Text), "pkg-version" .= ("1" :: Text), "pkg-src" .= object ["type" .= ("repo-tar" :: Text)], "flags" .= Map.singleton ("feature" :: Text) True, "pkg-revision" .= (1 :: Int), "pkg-cabal-sha256" .= ("description" :: Text), "pkg-src-sha256" .= ("archive" :: Text)]
           ]
    ]

right :: (Show e) => Either e a -> IO a
right = either (\problem -> expectationFailure (show problem) >> fail "expected Right") pure

shouldNotContainText :: Text -> Text -> Expectation
shouldNotContainText actual needle = actual `shouldSatisfy` (not . Data.Text.isInfixOf needle)
