{-# LANGUAGE FieldSelectors #-}

module Kenshou.Cli.Command.Plan (planCommand) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.List (nubBy, partition)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Kenshou.Core.Bundle (allScenarios)
import Kenshou.Core.Cli
import Kenshou.Core.Id qualified as Id
import Kenshou.Plan.Catalog (ScenarioInfo (..), decodeCatalog, fromScenario)
import Kenshou.Plan.Change
import Kenshou.Plan.Change.Cohort
import Kenshou.Plan.Change.Git
import Kenshou.Plan.Components
import Kenshou.Plan.Components.Check
import Kenshou.Plan.Selector (Selector, parseSelector, renderSelector)
import Options.Applicative
import System.Exit (ExitCode (..))
import System.IO (stderr)

data PlanOptions = PlanOptions
  { graphShow :: Bool,
    graphCheck :: Bool,
    json :: Bool,
    graphSource :: Maybe InputSource,
    catalogSource :: Maybe InputSource,
    changed :: [Text],
    cohortFrom :: Maybe Text,
    cohortTo :: Maybe Text,
    since :: Maybe Text,
    upstreamDiffs :: [Text],
    allScenariosFlag :: Bool,
    includes :: [Text],
    excludes :: [Text],
    explain :: Bool
  }

planCommand :: CliCommand
planCommand =
  CliCommand
    { name = "plan",
      description = "Select and plan verification runs",
      group = Discovery,
      hidden = False,
      parser = runPlan <$> planParser
    }

planParser :: Parser PlanOptions
planParser =
  PlanOptions
    <$> switch (long "graph-show" <> help "Print the checked-in component graph")
    <*> switch (long "graph-check" <> help "Check graph validity, build edges, and selectors")
    <*> switch (long "json" <> help "Write machine-readable JSON")
    <*> optional (option (parseInputSource <$> str) (long "graph" <> metavar "FILE" <> help "Override the component graph; use - for stdin"))
    <*> optional (option (parseInputSource <$> str) (long "catalog" <> metavar "FILE" <> help "Plan against a scenario catalog; use - for stdin"))
    <*> many (Text.pack <$> strOption (long "changed" <> metavar "COMPONENT[,COMPONENT]" <> help "Name changed components or sub-components"))
    <*> optional (Text.pack <$> strOption (long "cohort-from" <> metavar "COHORT" <> help "Baseline cohort name, file, or git object"))
    <*> optional (Text.pack <$> strOption (long "cohort-to" <> metavar "COHORT" <> help "Candidate cohort name, file, or git object"))
    <*> optional (Text.pack <$> strOption (long "since" <> metavar "REV" <> help "Map repository changes since a revision"))
    <*> many (Text.pack <$> strOption (long "upstream-diff" <> metavar "REPO=PATH@REVA..REVB" <> help "Map paths changed in an upstream checkout"))
    <*> switch (long "all" <> help "Select every catalog scenario")
    <*> many (Text.pack <$> strOption (long "select" <> metavar "SELECTOR" <> help "Keep matching scenarios"))
    <*> many (Text.pack <$> strOption (long "exclude" <> metavar "SELECTOR" <> help "Remove matching scenarios"))
    <*> switch (long "explain" <> help "Explain changes, dependency paths, and selections")

runPlan :: PlanOptions -> CliEnv -> IO ExitCode
runPlan options environment
  | stdinCount options > 1 = usage "at most one document input may use standard input"
  | options.graphShow && options.graphCheck = usage "choose only one of --graph-show or --graph-check"
  | otherwise = do
      graphResult <- loadGraph options.graphSource
      catalogResult <- loadCatalog environment options.catalogSource
      case (graphResult, catalogResult) of
        (Left err, _) -> usage err
        (_, Left err) -> usage err
        (Right graph, Right catalog)
          | options.graphShow -> showGraph options.json graph
          | options.graphCheck -> checkGraph graph catalog
          | otherwise -> planSelection options graph catalog

planSelection :: PlanOptions -> ComponentGraph -> [ScenarioInfo] -> IO ExitCode
planSelection options graph catalog = case (traverse (parseSelector) options.includes, traverse parseSelector options.excludes) of
  (Left err, _) -> usage err
  (_, Left err) -> usage err
  (Right includes, Right excludes) -> do
    gathered <- gatherChanges options graph
    case gathered of
      Left err -> usage err
      Right (changes, directSelectors, warnings)
        | null changes && null directSelectors && not options.allScenariosFlag -> usage "say what changed with --changed, --cohort-from/--cohort-to, --since, --upstream-diff, or --all"
        | otherwise -> do
            let componentSelected = if options.allScenariosFlag then selectAll catalog else selectScenarios graph catalog changes
                pathSelected = selectBySelectors Since "repository path" directSelectors catalog
                selected = applySelectors includes excludes (deduplicate (componentSelected <> pathSelected))
            if options.json
              then LazyByteString.putStrLn (Aeson.encode (selectionValue changes warnings selected))
              else renderSelection options.explain changes warnings selected
            pure ExitSuccess

gatherChanges :: PlanOptions -> ComponentGraph -> IO (Either Text ([Change], [Selector], [Warning]))
gatherChanges options graph = do
  cohortResult <- gatherCohort
  sinceResult <- maybe (pure (Right ([], [], []))) (changesSince graph ".") options.since
  upstreamResults <- traverse gatherUpstream options.upstreamDiffs
  pure do
    named <- traverse (parseRef graph) namedInputs
    (cohortChanges, cohortWarnings) <- cohortResult
    (sinceChanges, sinceSelectors, sinceWarnings) <- sinceResult
    upstream <- sequence upstreamResults
    let upstreamChanges = concatMap fst upstream
        upstreamWarnings = [Warning "ignored-upstream-paths" (Text.pack (show ignored) <> " upstream paths were outside component source roots") | (_, ignored) <- upstream, ignored > 0]
        namedChanges = [Change reference Named ("--changed " <> renderRef reference) | reference <- named]
    Right (namedChanges <> cohortChanges <> sinceChanges <> upstreamChanges, sinceSelectors, cohortWarnings <> sinceWarnings <> upstreamWarnings)
  where
    namedInputs = concatMap (filter (not . Text.null) . fmap Text.strip . Text.splitOn ",") options.changed
    gatherCohort = case (options.cohortFrom, options.cohortTo) of
      (Nothing, Nothing) -> pure (Right ([], []))
      (Just from, Just to) -> do
        old <- readCohortPackages "." (parseCohortInput from)
        new <- readCohortPackages "." (parseCohortInput to)
        pure ((uncurry (diffCohorts graph)) <$> ((,) <$> old <*> new))
      _ -> pure (Left "--cohort-from and --cohort-to must be supplied together")
    gatherUpstream raw = case parseUpstreamDiff raw of
      Left err -> pure (Left err)
      Right input -> changesFromUpstream graph input

deduplicate :: [Selected] -> [Selected]
deduplicate = nubBy (\left right -> left.scenario.id == right.scenario.id)

renderSelection :: Bool -> [Change] -> [Warning] -> [Selected] -> IO ()
renderSelection explain changes warnings selected = do
  mapM_ (Text.IO.hPutStrLn stderr . ("warning: " <>) . (.message)) warnings
  if explain
    then do
      mapM_ renderChange changes
      mapM_ renderSelected selected
      Text.IO.putStrLn ("selected " <> Text.pack (show (length selected)) <> " scenarios")
    else mapM_ (Text.IO.putStrLn . Id.renderScenarioId . (.id) . (.scenario)) selected
  where
    renderChange changeValue = Text.IO.putStrLn ("changed    " <> renderRef changeValue.ref <> "  " <> changeValue.detail)
    renderSelected selectedValue = do
      let reason = NonEmpty.head selectedValue.reasons
      Text.IO.putStrLn ("selected   " <> Id.renderScenarioId selectedValue.scenario.id <> "  via " <> Text.intercalate " <- " (fmap renderRef reason.via) <> "  selector " <> renderSelector reason.selector)

selectionValue :: [Change] -> [Warning] -> [Selected] -> Aeson.Value
selectionValue changes warnings selected =
  Aeson.object
    [ "schema" Aeson..= ("kenshou.selection/v1" :: Text),
      "changes" Aeson..= fmap (\changeValue -> Aeson.object ["component" Aeson..= renderRef changeValue.ref, "source" Aeson..= show changeValue.source, "detail" Aeson..= changeValue.detail]) changes,
      "warnings" Aeson..= fmap (.message) warnings,
      "scenarios" Aeson..= fmap ((.id) . (.scenario)) selected
    ]

loadGraph :: Maybe InputSource -> IO (Either Text ComponentGraph)
loadGraph Nothing = pure (firstGraph embeddedGraph)
loadGraph (Just source) = firstGraph . decodeGraph <$> readInputSource source

firstGraph :: Either GraphError ComponentGraph -> Either Text ComponentGraph
firstGraph = either (Left . (.errorText)) Right

loadCatalog :: CliEnv -> Maybe InputSource -> IO (Either Text [ScenarioInfo])
loadCatalog environment Nothing = pure (Right (fmap fromScenario (allScenarios environment.registry)))
loadCatalog _ (Just source) = decodeCatalog <$> readInputSource source

showGraph :: Bool -> ComponentGraph -> IO ExitCode
showGraph asJson graph = do
  if asJson
    then LazyByteString.putStrLn (Aeson.encode graph)
    else do
      let subCount = sum (fmap (length . (.subcomponents)) graph.components)
          edges = concatMap (.dependsOn) graph.components
          buildCount = length (filter ((== Build) . (.kind)) edges)
      Text.IO.putStrLn (Text.pack (show (length graph.components)) <> " components, " <> Text.pack (show subCount) <> " sub-components, " <> Text.pack (show (length edges)) <> " edges (" <> Text.pack (show buildCount) <> " build, " <> Text.pack (show (length edges - buildCount)) <> " runtime)")
      mapM_ renderComponent graph.components
  pure ExitSuccess
  where
    renderComponent componentValue = Text.IO.putStrLn (unComponentId componentValue.id <> "  " <> Text.pack (show componentValue.kind) <> "  " <> Text.intercalate "," componentValue.packages)

checkGraph :: ComponentGraph -> [ScenarioInfo] -> IO ExitCode
checkGraph graph catalog = do
  driftResult <- checkAgainstPlanJson graph "dist-newstyle/cache/plan.json"
  case driftResult of
    Left err -> usage ("cannot read Cabal plan: " <> err)
    Right drift -> do
      let lint = lintAgainstCatalog graph catalog
          (driftErrors, driftInfo) = partition isDriftError drift
          (lintErrors, lintWarnings) = partition isLintError lint
      Text.IO.putStrLn ("component graph: " <> Text.pack (show (length graph.components)) <> " components; digest " <> graphDigest graph)
      mapM_ (Text.IO.putStrLn . ("error: " <>) . Text.pack . show) driftErrors
      mapM_ (Text.IO.putStrLn . ("error: " <>) . Text.pack . show) lintErrors
      mapM_ (Text.IO.putStrLn . ("info: " <>) . Text.pack . show) driftInfo
      mapM_ (Text.IO.putStrLn . ("warning: " <>) . Text.pack . show) lintWarnings
      pure if null driftErrors && null lintErrors then ExitSuccess else ExitFailure 1

stdinCount :: PlanOptions -> Int
stdinCount options = length [() | Just InputStdin <- [options.graphSource, options.catalogSource]]

usage :: Text -> IO ExitCode
usage message = Text.IO.hPutStrLn stderr ("kenshou: " <> message) >> pure (ExitFailure 2)
