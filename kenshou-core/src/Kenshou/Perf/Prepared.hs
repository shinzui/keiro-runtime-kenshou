{-# LANGUAGE FieldSelectors #-}

module Kenshou.Perf.Prepared
  ( InventoryPackage (..),
    BuildInventory (..),
    PerfPrepared (..),
    PreparedArm (..),
    cabalInventory,
    compareInventories,
    inventoryDigest,
    preparedDigest,
    buildKeyFor,
    validatePrepared,
    validateArmInventories,
    renderBoundsProject,
    isolatedShibuyaCohort,
  )
where

import Control.Monad (unless)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (nub, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Canonical (canonicalEncode, sha256Hex)
import Kenshou.Core.Cohort
import Kenshou.Perf.Plan (PerfPlan (..), PerfProfile (..), PlannedProfile (..), validateProfile, workloadDigest)
import Kenshou.Perf.Request
import Kenshou.Perf.Source (SourceSnapshot, descriptorForSnapshot, legacyDescriptorForSnapshot, targetPackages)
import Kenshou.Plan.Catalog (ScenarioInfo)
import System.FilePath (makeRelative, normalise, splitDirectories)

data InventoryPackage = InventoryPackage
  {name :: Text, version :: Text, source :: Value, flags :: Map Text Bool, settings :: Value}
  deriving stock (Eq, Show)

data BuildInventory = BuildInventory
  { resolver :: Text,
    compiler :: Text,
    platform :: Text,
    toolchain :: Value,
    packages :: [InventoryPackage]
  }
  deriving stock (Eq, Show)

data PreparedArm = PreparedArm
  { descriptor :: CohortDescriptor,
    sourceLock :: Value,
    boundsInventory :: BuildInventory,
    buildInventory :: BuildInventory,
    payload :: Value,
    buildKey :: Text
  }
  deriving stock (Eq, Show)

data PerfPrepared = PerfPrepared
  { plan :: PerfPlan,
    inputs :: Value,
    harnessRevision :: Text,
    baseline :: PreparedArm,
    candidate :: PreparedArm
  }
  deriving stock (Eq, Show)

inventoryDigest :: BuildInventory -> Text
inventoryDigest = sha256Hex . canonicalEncode . toJSON

preparedDigest :: PerfPrepared -> Text
preparedDigest = sha256Hex . canonicalEncode . toJSON

buildKeyFor :: Text -> CohortDescriptor -> Value -> BuildInventory -> BuildInventory -> Text
buildKeyFor revision descriptor lock inventory bounds =
  sha256Hex
    ( canonicalEncode
        ( object
            ["harness" .= revision, "descriptorSha256" .= sha256Hex (LazyByteString.toStrict (encode descriptor)), "sourceLock" .= lock, "inventory" .= inventory, "boundsInventory" .= bounds]
        )
    )

-- Recheck the relationships inside a sealed preparation before any cell action.
-- The original files and their manifest are verified separately by the loader.
validatePrepared :: PerfPrepared -> Either Text ()
validatePrepared prepared = do
  (request, template, before, after, catalog, policies) <-
    parse
      "pinned inputs"
      ( withObject "PinnedInputs" \v -> do
          request <- v .: "request"
          harness <- v .: "harness"
          withObject
            "PinnedHarness"
            ( \h -> do
                revision <- h .: "revision"
                dirty <- h .: "dirty"
                unless (revision == prepared.harnessRevision && not dirty) (fail "pinned harness must be the clean prepared commit")
            )
            harness
          graph <- v .: "graph"
          scenarios <- v .: "scenarioCatalog"
          profiles <- v .: "profileCatalog"
          unless (sha256Hex (canonicalEncode graph) == prepared.plan.graphSha256 && sha256Hex (canonicalEncode scenarios) == prepared.plan.catalogSha256 && sha256Hex (canonicalEncode profiles) == prepared.plan.profileCatalogSha256) (fail "pinned graph/catalog digest mismatch")
          (,,,,,) request <$> v .: "template" <*> v .: "baselineSource" <*> v .: "candidateSource" <*> parseJSON scenarios <*> v .: "policies"
      )
      prepared.inputs
  unless (request == prepared.plan.request) (Left "prepared request differs from the plan")
  targets <- targetPackages request template
  baselineDescriptor <- descriptorForSnapshot request template "baseline" (before :: SourceSnapshot)
  candidateDescriptor <- descriptorForSnapshot request template "candidate" after
  legacyBaseline <- legacyDescriptorForSnapshot request template "baseline" before
  legacyCandidate <- legacyDescriptorForSnapshot request template "candidate" after
  unless ((baselineDescriptor == prepared.baseline.descriptor && candidateDescriptor == prepared.candidate.descriptor) || (legacyBaseline == prepared.baseline.descriptor && legacyCandidate == prepared.candidate.descriptor)) (Left "prepared arm descriptor differs from pinned source manifests")
  compareInventories targets prepared.baseline.boundsInventory prepared.candidate.boundsInventory
  compareInventories targets prepared.baseline.buildInventory prepared.candidate.buildInventory
  mapM_ (validateSelected catalog policies) prepared.plan.selected
  mapM_ validateArm [prepared.baseline, prepared.candidate]
  where
    parse label parser value = either (Left . ((label <> ": ") <>) . Text.pack) Right (parseEither parser value)
    validateSelected :: [ScenarioInfo] -> Map FilePath Value -> PlannedProfile -> Either Text ()
    validateSelected catalog policies selected = do
      effective <- validateProfile catalog selected.profile
      unless (toJSON effective == toJSON selected.effectiveKnobs && toJSON effective == toJSON selected.profile.knobs) (Left "prepared effective workload differs from its profile")
      policy <- maybe (Left "pinned profile policy missing") Right (Map.lookup selected.profile.policy policies)
      unless (workloadDigest selected.profile (sha256Hex (canonicalEncode policy)) == selected.workloadSha256) (Left "prepared workload/policy digest mismatch")
    validateArm arm = do
      unless (arm.buildInventory.resolver == "nix" && arm.buildInventory.platform == "x86_64-linux" && arm.buildInventory.compiler == arm.descriptor.descriptorCompiler && arm.boundsInventory.resolver == "cabal-bounds" && arm.boundsInventory.compiler == arm.descriptor.descriptorCompiler) (Left "prepared inventory compiler/platform/resolver mismatch")
      _ <-
        parse
          "prepared toolchain"
          ( withObject "Toolchain" \t -> do
              revision <- t .: "harnessRevision"
              strict <- t .: "strictBounds"
              nixpkgs <- t .: "nixpkgsRevision"
              haskellNix <- t .: "haskellNixRevision"
              unless (revision == prepared.harnessRevision && strict && immutableRevision nixpkgs && immutableRevision haskellNix) (fail "unverified or mutable prepared toolchain")
          )
          arm.buildInventory.toolchain
      expected <- parse "pinned build toolchain" (withObject "PinnedInputs" (.:? "buildToolchain")) prepared.inputs
      case expected of
        Nothing -> unless (not prepared.plan.gatingEligible) (Left "gating preparation requires a pinned build toolchain")
        Just value -> case arm.buildInventory.toolchain of
          Object actual -> unless (Object (KeyMap.delete "harnessRevision" actual) == value) (Left "actual build toolchain differs from frozen planning inputs")
          _ -> Left "actual build toolchain is not an object"
      let descriptorDigest = sha256Hex (LazyByteString.toStrict (encode arm.descriptor))
      _ <-
        parse
          "source lock"
          ( withObject "SourceLock" \v -> do
              schema <- v .: "schema"
              name <- v .: "cohort"
              digest <- v .: "descriptorSha256"
              unless (schema == ("kenshou.cohort-nix-lock/v1" :: Text) && name == arm.descriptor.descriptorName && digest == Text.drop 7 descriptorDigest) (fail "source lock does not bind its descriptor")
          )
          arm.sourceLock
      unless (arm.buildKey == buildKeyFor prepared.harnessRevision arm.descriptor arm.sourceLock arm.buildInventory arm.boundsInventory) (Left "prepared build key mismatch")
      validateArmInventories arm.descriptor arm.buildInventory arm.boundsInventory
      _ <-
        parse
          "payload identity"
          ( withObject "Payload" \v -> do
              identity <- v .: "cohortIdentity"
              harness <- v .: "harness"
              withObject
                "PayloadHarness"
                ( \h -> do
                    revision <- h .: "revision"
                    dirty <- h .: "dirty"
                    unless (revision == prepared.harnessRevision && not dirty) (fail "payload harness mismatch")
                )
                harness
              unless (null (checkCohort arm.descriptor identity) && identity.identityDescriptorSha256 == Text.drop 7 descriptorDigest && identity.identityResolver == Just "nix") (fail "payload cohort identity mismatch")
          )
          arm.payload
      pure ()

-- Run this before publication, and repeat it during offline preparation loading.
validateArmInventories :: CohortDescriptor -> BuildInventory -> BuildInventory -> Either Text ()
validateArmInventories descriptor nix bounds = do
  compareInventories [] nix nix
  compareInventories [] bounds bounds
  mapM_ strictPackage nix.packages
  let nixPackages = Map.fromList [(entry.name, entry) | entry <- nix.packages]
      cabalPackages = Map.fromList [(entry.name, entry) | entry <- bounds.packages]
  mapM_
    ( \pin -> do
        actual <- maybe (Left "cohort pin missing from Nix inventory") Right (Map.lookup pin.pinName nixPackages)
        bound <- maybe (Left "cohort pin missing from bounds inventory") Right (Map.lookup pin.pinName cabalPackages)
        unless (actual.version == pin.pinVersion && bound.version == pin.pinVersion) (Left "resolved inventory version differs from cohort pin")
    )
    (concatMap (.componentPackages) descriptor.descriptorComponents)
  mapM_
    ( \entry -> case Map.lookup entry.name cabalPackages of
        Nothing -> Right ()
        Just bound -> unless (entry.version == bound.version && entry.flags == bound.flags) (Left ("Nix package version or flags differs from bounds plan: " <> entry.name))
    )
    nix.packages
  where
    strictPackage entry =
      either
        (Left . Text.pack)
        Right
        ( parseEither
            ( withObject "PackageSettings" \s -> do
                jailbreak <- s .: "jailbreak"
                flags <- s .: "configureFlags" :: Parser [Text]
                let allowed = map ("--allow-newer=" <>) descriptor.descriptorAllowNewer
                unless (not jailbreak && all (\flag -> not ("--allow-newer" `Text.isPrefixOf` flag) || flag `elem` allowed) flags) (fail "package has unreviewed bound lifting")
            )
            entry.settings
        )

-- Cabal's plan source and revision fields are documented by the upstream
-- ProjectPlanOutput implementation. Include description revisions and all
-- resolved flags, and identify local harness packages by the clean commit.
-- Build-product IDs are excluded: relinking a dependent is expected.
cabalInventory :: FilePath -> Text -> Value -> Either Text BuildInventory
cabalInventory harnessRoot harnessRevision document = do
  unless (immutableRevision harnessRevision) (Left "bounds inventory requires a clean harness commit")
  either (Left . Text.pack) Right (parseEither parsePlan document)
  where
    parsePlan = withObject "Cabal plan" \root -> do
      compiler <- root .: "compiler-id"
      cabal <- root .: "cabal-version" :: Parser Text
      os <- root .: "os" :: Parser Text
      arch <- root .: "arch" :: Parser Text
      units <- root .: "install-plan" >>= traverse parseUnit
      let grouped = Map.fromListWith (<>) [(unit.name, [unit]) | unit <- units]
      unless (all (\values -> nub values == take 1 values) (Map.elems grouped)) (fail "ambiguous package source/version/flags in Cabal inventory")
      pure (BuildInventory "cabal-bounds" compiler (arch <> "-" <> os) (object ["cabal" .= cabal, "harnessRevision" .= harnessRevision]) (sortOn (.name) (nub units)))
    parseUnit = withObject "Cabal unit" \unit -> do
      name <- unit .: "pkg-name"
      version <- unit .: "pkg-version"
      kind <- unit .: "type" :: Parser Text
      flags <- unit .:? "flags" .!= Map.empty
      source <-
        if kind == "pre-existing"
          then pure (object ["type" .= ("boot" :: Text)])
          else do
            descriptionHash <- unit .:? "pkg-cabal-sha256" :: Parser (Maybe Text)
            sourceHash <- unit .:? "pkg-src-sha256" :: Parser (Maybe Text)
            revision <- unit .:? "pkg-revision" :: Parser (Maybe Int)
            location <- unit .: "pkg-src" >>= normalizeSource name
            pure (object ["location" .= location, "sourceSha256" .= sourceHash, "descriptionSha256" .= descriptionHash, "descriptionRevision" .= revision])
      pure (InventoryPackage name version source flags (object []))
    normalizeSource name = withObject "Cabal source" \source -> do
      kind <- source .: "type" :: Parser Text
      case kind of
        "local" -> do
          path <- source .: "path"
          let relative = makeRelative (normalise harnessRoot) (normalise path)
          unless ("kenshou-" `Text.isPrefixOf` name && not (null relative) && all (/= "..") (splitDirectories relative) && relative /= normalise path) (fail "Cabal inventory contains a local source outside the pinned harness")
          pure (object ["type" .= ("harness" :: Text), "revision" .= harnessRevision, "path" .= relative])
        "source-repo" -> do
          repo <- source .: "source-repo"
          withObject
            "Cabal Git source"
            ( \fields -> do
                location <- fields .: "location" :: Parser Text
                revision <- fields .: "tag"
                branch <- fields .:? "branch" :: Parser (Maybe Text)
                unless ("https://" `Text.isPrefixOf` location && immutableRevision revision && branch == Nothing) (fail "Cabal inventory contains a mutable Git source")
                pure (Object source)
            )
            repo
        "repo-tar" -> pure (Object source)
        _ -> fail "Cabal inventory contains an unsupported source"

compareInventories :: [Text] -> BuildInventory -> BuildInventory -> Either Text ()
compareInventories targets baseline candidate = do
  unless (not (null baseline.packages) && not (null candidate.packages)) (Left "empty resolved inventory")
  unless ((baseline.resolver, baseline.compiler, baseline.platform, baseline.toolchain) == (candidate.resolver, candidate.compiler, candidate.platform, candidate.toolchain)) (Left "compiler, platform or toolchain drift")
  let before = Map.fromList [(entry.name, entry) | entry <- baseline.packages]
      after = Map.fromList [(entry.name, entry) | entry <- candidate.packages]
  unless (Map.size before == length baseline.packages && Map.size after == length candidate.packages && Map.keys before == Map.keys after) (Left "resolved package inventory changed or contains duplicate names")
  unless (all (`Map.member` before) targets) (Left "target package missing from resolved inventory")
  mapM_ (check after) (Map.toAscList before)
  where
    check after (name, previous) = case Map.lookup name after of
      Nothing -> Left ("missing resolved package: " <> name)
      Just current
        | previous.flags /= current.flags || previous.settings /= current.settings -> Left ("resolved flags/settings changed: " <> name)
        | name `elem` targets -> Right ()
        | previous /= current -> Left ("unrelated resolved dependency changed: " <> name)
        | otherwise -> Right ()

-- | Select the existing isolated lane by its component set, not the generated
-- cohort name. Full-runtime cohorts retain their ordinary package set and flags.
isolatedShibuyaCohort :: CohortDescriptor -> Bool
isolatedShibuyaCohort descriptor =
  "shibuya" `elem` names && all (`elem` ["shibuya", "shibuya-pgmq-adapter", "pgmq-hs", "kiroku"]) names
  where
    names = map (unComponentId . (.componentId)) descriptor.descriptorComponents

-- Standalone projects never import active.project or project.local. They pin
-- every cohort package and use only already reviewed, package-scoped exceptions.
renderBoundsProject :: [FilePath] -> CohortDescriptor -> Either Text Text
renderBoundsProject harnessPackages descriptor = do
  unless (not (null harnessPackages) && all safeAtom harnessPackages) (Left "unsafe or empty harness package paths")
  unless (all scopedException descriptor.descriptorAllowNewer) (Left "blanket bound lifting is forbidden in performance preparation")
  unless (all (safeAtom . Text.unpack) (descriptor.descriptorCompiler : descriptor.descriptorIndexState : map (.pinName) pins <> map (.pinVersion) pins)) (Left "unsafe cohort project field")
  gitStanzas <- traverse gitComponent descriptor.descriptorComponents
  pure
    ( Text.unlines
        (["packages: " <> Text.intercalate ", " (map Text.pack harnessPackages), "with-compiler: " <> descriptor.descriptorCompiler, "index-state: " <> descriptor.descriptorIndexState, "tests: False", "benchmarks: False", "extra-packages: " <> Text.intercalate ", " (map (.pinName) pins), "constraints: " <> Text.intercalate ", " [pin.pinName <> " ==" <> pin.pinVersion | pin <- pins], "allow-newer: " <> (if null descriptor.descriptorAllowNewer then "none" else Text.intercalate ", " descriptor.descriptorAllowNewer)] <> laneFlags <> concat gitStanzas)
    )
  where
    laneFlags =
      if isolatedShibuyaCohort descriptor
        then ["package kenshou-cli", "  flags: -runtime-suites", "package kenshou-core", "  flags: -keiro-schema"]
        else []
    pins = concatMap (.componentPackages) descriptor.descriptorComponents
    safeAtom value = not (null value) && all (`notElem` ['\n', '\r', '\t', ' ', ',', '"']) value
    scopedException value = case Text.splitOn ":" value of
      [owner, dependency] -> all (\part -> not (Text.null part) && Text.all (\c -> c `elem` ['a' .. 'z'] || c `elem` ['0' .. '9'] || c == '-') part) [owner, dependency]
      _ -> False
    gitComponent component = case component.componentSource of
      HackageSource -> Right []
      GitSource location revision -> do
        unless ("https://" `Text.isPrefixOf` location && immutableRevision revision && safeAtom (Text.unpack location)) (Left "source project must use immutable HTTPS Git")
        let dirs = nub [maybe "." id pin.pinSubdir | pin <- component.componentPackages]
        unless (all (\path -> safeAtom (Text.unpack path) && not ("/" `Text.isPrefixOf` path) && all (/= "..") (Text.splitOn "/" path)) dirs) (Left "unsafe Git package subdirectory")
        pure ["", "source-repository-package", "  type: git", "  location: " <> location, "  tag: " <> revision, "  subdir: " <> Text.intercalate " " dirs]

instance ToJSON InventoryPackage where
  toJSON entry = object ["name" .= entry.name, "version" .= entry.version, "source" .= entry.source, "flags" .= entry.flags, "settings" .= entry.settings]

instance FromJSON InventoryPackage where
  parseJSON = withObject "InventoryPackage" \v -> do
    strictObject ["name", "version", "source", "flags", "settings"] v
    InventoryPackage <$> v .: "name" <*> v .: "version" <*> v .: "source" <*> v .: "flags" <*> v .: "settings"

instance ToJSON BuildInventory where
  toJSON inventory = object ["resolver" .= inventory.resolver, "compiler" .= inventory.compiler, "platform" .= inventory.platform, "toolchain" .= inventory.toolchain, "packages" .= sortOn (.name) inventory.packages]

instance FromJSON BuildInventory where
  parseJSON = withObject "BuildInventory" \v -> do
    strictObject ["resolver", "compiler", "platform", "toolchain", "packages"] v
    BuildInventory <$> v .: "resolver" <*> v .: "compiler" <*> v .: "platform" <*> v .: "toolchain" <*> v .: "packages"

instance ToJSON PreparedArm where
  toJSON arm = object ["descriptor" .= arm.descriptor, "sourceLock" .= arm.sourceLock, "boundsInventory" .= arm.boundsInventory, "buildInventory" .= arm.buildInventory, "payload" .= arm.payload, "buildKey" .= arm.buildKey]

instance FromJSON PreparedArm where
  parseJSON = withObject "PreparedArm" \v -> do
    strictObject ["descriptor", "sourceLock", "boundsInventory", "buildInventory", "payload", "buildKey"] v
    PreparedArm <$> v .: "descriptor" <*> v .: "sourceLock" <*> v .: "boundsInventory" <*> v .: "buildInventory" <*> v .: "payload" <*> v .: "buildKey"

instance ToJSON PerfPrepared where
  toJSON prepared = object ["schema" .= ("kenshou.perf-prepared/v1" :: Text), "plan" .= prepared.plan, "inputs" .= prepared.inputs, "harnessRevision" .= prepared.harnessRevision, "baseline" .= prepared.baseline, "candidate" .= prepared.candidate]

instance FromJSON PerfPrepared where
  parseJSON = withObject "PerfPrepared" \v -> do
    strictObject ["schema", "plan", "inputs", "harnessRevision", "baseline", "candidate"] v
    schema <- v .: "schema"
    unless (schema == ("kenshou.perf-prepared/v1" :: Text)) (fail "unsupported performance preparation schema")
    prepared <- PerfPrepared <$> v .: "plan" <*> v .: "inputs" <*> v .: "harnessRevision" <*> v .: "baseline" <*> v .: "candidate"
    unless (immutableRevision prepared.harnessRevision) (fail "invalid prepared harness revision")
    pure prepared
