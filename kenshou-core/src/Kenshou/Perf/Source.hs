{-# LANGUAGE FieldSelectors #-}

module Kenshou.Perf.Source
  ( PackageManifest (..),
    SourceSnapshot (..),
    parsePackageManifest,
    targetPackages,
    sourceSnapshot,
    descriptorForSnapshot,
    legacyDescriptorForSnapshot,
  )
where

import Control.Monad (unless)
import Data.Aeson
import Data.Char (isAsciiLower, isDigit)
import Data.List (nub, sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Kenshou.Core.Canonical (canonicalEncode, sha256Hex)
import Kenshou.Core.Cohort
import Kenshou.Perf.Request
import System.FilePath (takeDirectory)

data PackageManifest = PackageManifest
  { name :: Text,
    version :: Text,
    path :: FilePath,
    sha256 :: Text
  }
  deriving stock (Eq, Show)

data SourceSnapshot = SourceSnapshot
  { project :: Text,
    location :: Text,
    revision :: Text,
    packages :: [PackageManifest]
  }
  deriving stock (Eq, Show)

-- Source manifests are inspected without executing candidate code. Cabal will
-- perform the full syntax/bounds validation during preparation. Reject an
-- ambiguous identity here rather than guessing which declaration Cabal means.
parsePackageManifest :: FilePath -> Text -> Either Text PackageManifest
parsePackageManifest path contents = do
  name <- field "name"
  version <- field "version"
  unless (validName name && validVersion version) (Left ("invalid manifest identity: " <> Text.pack path))
  unless (safePath path) (Left "unsafe manifest path")
  pure (PackageManifest name version path (sha256Hex (Text.encodeUtf8 contents)))
  where
    field key = case [Text.strip (fst (Text.breakOn "--" rest)) | line <- Text.lines contents, let (label, value) = Text.breakOn ":" line, Text.toLower (Text.strip label) == key, let rest = Text.drop 1 value] of
      [value] | not (Text.null value) -> Right value
      _ -> Left ("missing or ambiguous " <> key <> " in " <> Text.pack path)
    validName value = not (Text.null value) && Text.all (\c -> isAsciiLower c || isDigit c || c == '-') value
    validVersion value = all (\part -> not (Text.null part) && Text.all isDigit part) (Text.splitOn "." value)

targetPackages :: PerfRequest -> CohortDescriptor -> Either Text [Text]
targetPackages request descriptor = do
  validateRequest request
  unless (nub ids == ids && nub names == names) (Left "cohort component/package IDs are not unique")
  unless (all (`elem` ids) request.targetComponents) (Left "unknown target component in cohort template")
  unless (all owns targets) (Left "all target components must belong to the request's source project")
  unless (not (null targets) && all (not . null . (.componentPackages)) targets) (Left "target components must declare packages")
  mapM_ checkSource descriptor.descriptorComponents
  pure (sort (concatMap (map (.pinName) . (.componentPackages)) targets))
  where
    ids = map (unComponentId . (.componentId)) descriptor.descriptorComponents
    names = concatMap (map (.pinName) . (.componentPackages)) descriptor.descriptorComponents
    targets = filter ((`elem` request.targetComponents) . unComponentId . (.componentId)) descriptor.descriptorComponents
    owns component = component.componentMoriUri == request.project || (request.project <> "/packages/") `Text.isPrefixOf` component.componentMoriUri
    checkSource component = case component.componentSource of
      HackageSource -> Right ()
      GitSource location revision -> unless (validLocation location && immutableRevision revision) (Left "template Git sources must be immutable HTTPS sources")

sourceSnapshot :: PerfRequest -> CohortDescriptor -> Text -> Text -> [PackageManifest] -> Either Text SourceSnapshot
sourceSnapshot request descriptor location revision manifests = do
  expected <- targetPackages request descriptor
  unless (validLocation location && immutableRevision revision) (Left "source snapshot requires immutable HTTPS revision")
  unless (revision `elem` [request.baselineRevision, request.candidateRevision]) (Left "source snapshot is not one of the requested revisions")
  unless (all sameRepository targets) (Left "target template Git source belongs to another repository")
  let selected = filter ((`elem` expected) . (.name)) manifests
  unless (sort (map (.name) selected) == expected) (Left "source revision has a missing or duplicate target package")
  mapM_ validateManifest selected
  pure (SourceSnapshot request.project location revision (sortOnName selected))
  where
    targets = filter ((`elem` request.targetComponents) . unComponentId . (.componentId)) descriptor.descriptorComponents
    sameRepository component = case component.componentSource of
      HackageSource -> True
      GitSource upstream _ -> Text.dropWhileEnd (== '/') (maybe upstream id (Text.stripSuffix ".git" upstream)) == Text.dropWhileEnd (== '/') (maybe location id (Text.stripSuffix ".git" location))
    sortOnName values = map snd (Map.toAscList (Map.fromList [(value.name, value) | value <- values]))

descriptorForSnapshot :: PerfRequest -> CohortDescriptor -> Text -> SourceSnapshot -> Either Text CohortDescriptor
descriptorForSnapshot = descriptorWithIdentity False

-- Read compatibility for previously sealed v1 preparations. New preparation
-- always uses the resolved-cohort identity; legacy names remain bound to the
-- exact retained request and independent manifests, never accepted arbitrarily.
legacyDescriptorForSnapshot :: PerfRequest -> CohortDescriptor -> Text -> SourceSnapshot -> Either Text CohortDescriptor
legacyDescriptorForSnapshot = descriptorWithIdentity True

descriptorWithIdentity :: Bool -> PerfRequest -> CohortDescriptor -> Text -> SourceSnapshot -> Either Text CohortDescriptor
descriptorWithIdentity legacy request descriptor arm snapshot = do
  expected <- targetPackages request descriptor
  unless (snapshot.project == request.project && sort (map (.name) snapshot.packages) == expected) (Left "snapshot project/package inventory differs from the request")
  unless (validLocation snapshot.location && immutableRevision snapshot.revision) (Left "snapshot source must be immutable HTTPS Git")
  unless (arm `elem` ["baseline", "candidate"]) (Left "unknown comparison arm")
  unless (snapshot.revision == if arm == "baseline" then request.baselineRevision else request.candidateRevision) (Left "snapshot revision differs from its arm")
  mapM_ validateManifest snapshot.packages
  components <- traverse replace descriptor.descriptorComponents
  let effectiveArm = if request.baselineRevision == request.candidateRevision then "aa" else arm
      resolved =
        descriptor
          { descriptorName = CohortName "perf",
            descriptorDescription = "Exact-revision performance cohort for " <> request.project <> "; template scope: " <> descriptor.descriptorDescription,
            descriptorProjectFile = "perf.project",
            descriptorComponents = components
          }
      generatedName =
        if legacy
          then "perf-" <> Text.take 16 (Text.drop 7 (requestDigest request)) <> "-" <> effectiveArm
          else "perf-" <> Text.drop 7 (sha256Hex (canonicalEncode (toJSON resolved)))
  pure
    resolved
      { descriptorName = CohortName generatedName,
        descriptorDescription = if legacy then "Exact-revision " <> effectiveArm <> " for " <> request.project <> "; template scope: " <> descriptor.descriptorDescription else resolved.descriptorDescription,
        descriptorProjectFile = Text.unpack generatedName <> ".project"
      }
  where
    replace component
      | unComponentId component.componentId `notElem` request.targetComponents = Right component
      | otherwise = do
          pins <- traverse pin component.componentPackages
          pure component {componentSource = GitSource snapshot.location snapshot.revision, componentPackages = pins}
    pin previous = case filter ((== previous.pinName) . (.name)) snapshot.packages of
      [manifest] -> pure previous {pinVersion = manifest.version, pinSubdir = let directory = takeDirectory manifest.path in if directory == "." then Nothing else Just (Text.pack directory)}
      _ -> Left "snapshot package identity mismatch"

instance ToJSON PackageManifest where
  toJSON manifest = object ["name" .= manifest.name, "version" .= manifest.version, "path" .= manifest.path, "sha256" .= manifest.sha256]

instance FromJSON PackageManifest where
  parseJSON = withObject "PackageManifest" \value -> do
    strictObject ["name", "version", "path", "sha256"] value
    manifest <- PackageManifest <$> value .: "name" <*> value .: "version" <*> value .: "path" <*> value .: "sha256"
    either (fail . Text.unpack) pure (validateManifest manifest)
    pure manifest

instance ToJSON SourceSnapshot where
  toJSON snapshot = object ["project" .= snapshot.project, "location" .= snapshot.location, "revision" .= snapshot.revision, "packages" .= snapshot.packages]

instance FromJSON SourceSnapshot where
  parseJSON = withObject "SourceSnapshot" \value -> do
    strictObject ["project", "location", "revision", "packages"] value
    snapshot <- SourceSnapshot <$> value .: "project" <*> value .: "location" <*> value .: "revision" <*> value .: "packages"
    unless (canonicalProject snapshot.project && validLocation snapshot.location && immutableRevision snapshot.revision) (fail "invalid immutable source identity")
    unless (not (null snapshot.packages) && nub (map (.name) snapshot.packages) == map (.name) snapshot.packages) (fail "invalid source package inventory")
    pure snapshot

validLocation :: Text -> Bool
validLocation location = "https://" `Text.isPrefixOf` location && Text.length location > 8 && not (Text.any (`elem` ['@', '#', '?', '\n', '\r', ' ']) location)

safePath :: FilePath -> Bool
safePath value = not (null value) && not ("/" `Text.isPrefixOf` Text.pack value) && all (`notElem` ["", ".", ".."]) (Text.splitOn "/" (Text.pack value)) && not (Text.any (`elem` ['\n', '\r', '\t', ' ', '\\']) (Text.pack value))

validateManifest :: PackageManifest -> Either Text ()
validateManifest manifest = do
  unless (not (Text.null manifest.name) && Text.all (\c -> isAsciiLower c || isDigit c || c == '-') manifest.name) (Left "invalid manifest package name")
  unless (all (\part -> not (Text.null part) && Text.all isDigit part) (Text.splitOn "." manifest.version)) (Left "invalid manifest package version")
  unless (safePath manifest.path && ".cabal" `Text.isSuffixOf` Text.pack manifest.path) (Left "unsafe manifest path")
  unless (maybe False (\digest -> Text.length digest == 64 && Text.all (\c -> c `elem` ['0' .. '9'] || c `elem` ['a' .. 'f']) digest) (Text.stripPrefix "sha256:" manifest.sha256)) (Left "invalid manifest digest")
