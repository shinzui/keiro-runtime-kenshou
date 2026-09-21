{-# LANGUAGE FieldSelectors #-}

module Kenshou.Cli.Command.Plan (planCommand) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.List (partition)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Kenshou.Core.Bundle (allScenarios)
import Kenshou.Core.Cli
import Kenshou.Plan.Catalog (ScenarioInfo, decodeCatalog, fromScenario)
import Kenshou.Plan.Components
import Kenshou.Plan.Components.Check
import Options.Applicative
import System.Exit (ExitCode (..))
import System.IO (stderr)

data PlanOptions = PlanOptions
  { graphShow :: Bool,
    graphCheck :: Bool,
    json :: Bool,
    graphSource :: Maybe InputSource,
    catalogSource :: Maybe InputSource
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

runPlan :: PlanOptions -> CliEnv -> IO ExitCode
runPlan options environment
  | stdinCount options > 1 = usage "at most one document input may use standard input"
  | options.graphShow == options.graphCheck = usage "choose exactly one of --graph-show or --graph-check"
  | otherwise = do
      graphResult <- loadGraph options.graphSource
      catalogResult <- loadCatalog environment options.catalogSource
      case (graphResult, catalogResult) of
        (Left err, _) -> usage err
        (_, Left err) -> usage err
        (Right graph, Right catalog)
          | options.graphShow -> showGraph options.json graph
          | otherwise -> checkGraph graph catalog

loadGraph :: Maybe InputSource -> IO (Either Text ComponentGraph)
loadGraph Nothing = pure (firstGraph embeddedGraph)
loadGraph (Just source) = firstGraph . decodeGraph <$> readInputSource source
  where
    firstGraph = either (Left . (.errorText)) Right

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
