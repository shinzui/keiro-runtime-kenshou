{-# LANGUAGE FieldSelectors #-}

module Kenshou.Plan.Change.Git
  ( UpstreamDiff (..),
    parseUpstreamDiff,
    changesSince,
    changesFromUpstream,
  )
where

import Data.Aeson qualified as Aeson
import Data.ByteString qualified as ByteString
import Data.List (isPrefixOf, maximumBy, nub)
import Data.Ord (comparing)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Kenshou.Core.Cohort (CohortDescriptor)
import Kenshou.Plan.Change hiding (UpstreamDiff)
import Kenshou.Plan.Change qualified as Change
import Kenshou.Plan.Change.Cohort (diffCohorts, packagesFromDescriptor)
import Kenshou.Plan.Components
import Kenshou.Plan.Selector (Selector)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)

data UpstreamDiff = UpstreamDiff
  { repository :: Text,
    path :: FilePath,
    revisionA :: Text,
    revisionB :: Text
  }
  deriving stock (Eq, Show)

parseUpstreamDiff :: Text -> Either Text UpstreamDiff
parseUpstreamDiff raw = do
  let (repository, afterEquals) = Text.breakOn "=" raw
      withoutEquals = Text.drop 1 afterEquals
      (pathAndAt, revisions) = Text.breakOnEnd "@" withoutEquals
      path = Text.dropEnd 1 pathAndAt
      (revisionA, dotsAndB) = Text.breakOn ".." revisions
      revisionB = Text.drop 2 dotsAndB
  if any Text.null [repository, afterEquals, path, revisionA, dotsAndB, revisionB]
    then Left "expected REPO=PATH@REVA..REVB"
    else Right (UpstreamDiff repository (Text.unpack path) revisionA revisionB)

changesSince :: ComponentGraph -> FilePath -> Text -> IO (Either Text ([Change], [Selector], [Warning]))
changesSince graph root revision = do
  tracked <- git root ["diff", "--name-only", Text.unpack revision]
  untracked <- git root ["ls-files", "--others", "--exclude-standard"]
  case (tracked, untracked) of
    (Right trackedPaths, Right untrackedPaths) -> classifyPaths graph root revision (nub (trackedPaths <> untrackedPaths))
    (Left err, _) -> pure (Left err)
    (_, Left err) -> pure (Left err)

classifyPaths :: ComponentGraph -> FilePath -> Text -> [FilePath] -> IO (Either Text ([Change], [Selector], [Warning]))
classifyPaths graph root revision paths = do
  classified <- traverse classify paths
  pure do
    values <- sequence classified
    let changes = concatMap (\(items, _, _) -> items) values
        selectors = concatMap (\(_, items, _) -> items) values
        warnings = concatMap (\(_, _, items) -> items) values
    Right (changes, selectors, warnings)
  where
    classify path = case longestRule graph path of
      Nothing -> pure (Right ([everything ("unmapped repository path " <> Text.pack path)], [], [Warning "unmapped-path" ("unmapped repository path " <> Text.pack path <> "; selecting everything")]))
      Just rule -> case rule.effect of
        PathNothing -> pure (Right ([], [], []))
        PathAll -> pure (Right ([everything (Text.pack path)], [], []))
        PathSelectors selectors -> pure (Right ([], selectors, []))
        PathCohort -> classifyCohort path
    classifyCohort path
      | path == "cohort/active.project" || ".project" `Text.isSuffixOf` Text.pack path =
          pure (Right ([everything (Text.pack path)], [], [Warning "cohort-project-change" ("cohort project changed without a safe descriptor mapping: " <> Text.pack path)]))
      | ".json" `Text.isSuffixOf` Text.pack path = do
          oldBytes <- gitShow root (revision <> ":" <> Text.pack path)
          newBytes <- ByteString.readFile (root </> path)
          pure do
            old <- oldBytes >>= decodeDescriptor
            new <- decodeDescriptor newBytes
            let (changes, warnings) = diffCohorts graph (packagesFromDescriptor old) (packagesFromDescriptor new)
            Right (changes, [], warnings)
      | otherwise = pure (Right ([everything (Text.pack path)], [], [Warning "unknown-cohort-change" ("cannot map cohort change " <> Text.pack path)]))
    everything detail = Change (ComponentRef (ComponentId "all") Nothing) Everything detail

changesFromUpstream :: ComponentGraph -> UpstreamDiff -> IO (Either Text ([Change], Int))
changesFromUpstream graph input = do
  result <- git input.path ["diff", "--name-only", Text.unpack input.revisionA, Text.unpack input.revisionB]
  pure do
    paths <- result
    let mapped = fmap (mapUpstreamPath graph input.repository) paths
        changes = nub [change | Just change <- mapped]
        ignored = length [() | Nothing <- mapped]
    Right (changes, ignored)

mapUpstreamPath :: ComponentGraph -> Text -> FilePath -> Maybe Change
mapUpstreamPath graph repository path = do
  componentValue <- bestComponent
  let subMatches = [(prefix, subcomponentValue.id) | subcomponentValue <- componentValue.subcomponents, prefix <- subcomponentValue.pathPrefixes, prefix `isPrefixOf` path]
      reference = case subMatches of
        [] -> ComponentRef componentValue.id Nothing
        _ -> ComponentRef componentValue.id (Just (snd (maximumBy (comparing (length . fst)) subMatches)))
  pure (Change reference Change.UpstreamDiff (repository <> ":" <> Text.pack path))
  where
    candidates = [componentValue | componentValue <- graph.components, componentValue.repository == repository, any (`isPrefixOf` path) componentValue.sourceRoots]
    bestComponent = case candidates of [] -> Nothing; _ -> Just (maximumBy (comparing (maximum . (0 :) . fmap length . (.sourceRoots))) candidates)

longestRule :: ComponentGraph -> FilePath -> Maybe RepositoryPathRule
longestRule graph path = case filter ((`isPrefixOf` path) . (.prefix)) graph.repositoryPaths of
  [] -> Nothing
  rules -> Just (maximumBy (comparing (length . (.prefix))) rules)

git :: FilePath -> [String] -> IO (Either Text [FilePath])
git root arguments = do
  (code, output, err) <- readProcessWithExitCode "git" (["-C", root] <> arguments) ""
  pure case code of
    ExitSuccess -> Right (filter (not . null) (lines output))
    _ -> Left (Text.strip (Text.pack err))

gitShow :: FilePath -> Text -> IO (Either Text ByteString.ByteString)
gitShow root objectName = do
  (code, output, err) <- readProcessWithExitCode "git" ["-C", root, "show", Text.unpack objectName] ""
  pure case code of ExitSuccess -> Right (Text.Encoding.encodeUtf8 (Text.pack output)); _ -> Left (Text.strip (Text.pack err))

decodeDescriptor :: ByteString.ByteString -> Either Text CohortDescriptor
decodeDescriptor = either (Left . Text.pack) Right . Aeson.eitherDecodeStrict'
