{-# LANGUAGE FieldSelectors #-}

module Kenshou.Plan.Change.Cohort
  ( CohortInput (..),
    PackageSource (..),
    parseCohortInput,
    readCohortPackages,
    packagesFromDescriptor,
    diffCohorts,
  )
where

import Data.Aeson qualified as Aeson
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Kenshou.Core.Cohort qualified as Cohort
import Kenshou.Plan.Change
import Kenshou.Plan.Components
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

data CohortInput = CohortName Text | CohortFile FilePath | CohortGitObject Text
  deriving stock (Eq, Show)

data PackageSource = FromHackage Text | FromGit Text Text
  deriving stock (Eq, Ord, Show)

parseCohortInput :: Text -> CohortInput
parseCohortInput value
  | ":" `Text.isInfixOf` value = CohortGitObject value
  | "/" `Text.isInfixOf` value || ".json" `Text.isSuffixOf` value = CohortFile (Text.unpack value)
  | otherwise = CohortName value

readCohortPackages :: FilePath -> CohortInput -> IO (Either Text (Map Text PackageSource))
readCohortPackages root = \case
  CohortName name -> loadFile (root <> "/cohort/" <> Text.unpack name <> ".json")
  CohortFile path -> loadFile path
  CohortGitObject objectName -> do
    (code, output, err) <- readProcessWithExitCode "git" ["-C", root, "show", Text.unpack objectName] ""
    pure case code of
      ExitSuccess -> decodeBytes (Text.Encoding.encodeUtf8 (Text.pack output))
      _ -> Left (Text.strip (Text.pack err))
  where
    loadFile path = do
      descriptor <- Cohort.loadCohortDescriptor path
      pure (either (Left . Text.pack . show) (Right . packagesFromDescriptor) descriptor)
    decodeBytes bytes = case Aeson.eitherDecodeStrict' bytes of
      Left err -> Left (Text.pack err)
      Right descriptor -> Right (packagesFromDescriptor descriptor)

packagesFromDescriptor :: Cohort.CohortDescriptor -> Map Text PackageSource
packagesFromDescriptor descriptor = Map.fromList do
  component <- descriptor.descriptorComponents
  package <- component.componentPackages
  pure
    ( package.pinName,
      case component.componentSource of
        Cohort.HackageSource -> FromHackage package.pinVersion
        Cohort.GitSource gitLocation gitRevision -> FromGit gitLocation gitRevision
    )

diffCohorts :: ComponentGraph -> Map Text PackageSource -> Map Text PackageSource -> ([Change], [Warning])
diffCohorts graph old new = (changes, warnings)
  where
    packageOwners = Map.fromList [(package, componentValue.id) | componentValue <- graph.components, package <- componentValue.packages]
    names = Map.keysSet old <> Map.keysSet new
    changed = [name | name <- Set.toAscList names, Map.lookup name old /= Map.lookup name new]
    mapped = [(name, owner) | name <- changed, Just owner <- [Map.lookup name packageOwners]]
    changes =
      [ Change (ComponentRef owner Nothing) CohortDiff (name <> " " <> renderSource (Map.lookup name old) <> " -> " <> renderSource (Map.lookup name new))
      | (name, owner) <- mapped
      ]
        <> [Change (ComponentRef (ComponentId "all") Nothing) Everything ("unmapped package " <> name) | name <- changed, Map.notMember name packageOwners, name `notElem` graph.ignoredPackages]
    warnings =
      [ Warning "unmapped-package" ("unmapped package " <> name <> "; selecting everything")
      | name <- changed,
        Map.notMember name packageOwners,
        name `notElem` graph.ignoredPackages
      ]
        <> [Warning "ignored-package" ("ignored package changed: " <> name) | name <- changed, name `elem` graph.ignoredPackages]
    renderSource Nothing = "absent"
    renderSource (Just (FromHackage version)) = version
    renderSource (Just (FromGit _ revision)) = "git " <> revision
