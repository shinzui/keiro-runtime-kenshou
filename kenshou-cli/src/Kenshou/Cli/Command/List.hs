module Kenshou.Cli.Command.List (listCommand) where

import Data.Aeson qualified as Aeson
import Data.Bifunctor (first)
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Kenshou.Core.Bundle
import Kenshou.Core.Cli (CliCommand (..), CliEnv (..), CliGroup (..))
import Kenshou.Core.Id
import Kenshou.Core.Role (WorkerRole (..), renderRoleName)
import Kenshou.Core.Scenario
import Kenshou.Core.Selector (parseSelector)
import Options.Applicative
import System.Exit (ExitCode (..))
import System.IO (stderr)

data ListOptions = ListOptions
  { selectors :: [Text],
    layers :: [Layer],
    kinds :: [Kind],
    maxTier :: Maybe Tier,
    placements :: [Placement],
    roles :: Bool,
    json :: Bool
  }

listCommand :: CliCommand
listCommand =
  CliCommand
    { name = "list",
      description = "List registered verification scenarios",
      group = Discovery,
      hidden = False,
      parser = runList <$> parserOptionGroup "Selection" listParser
    }

listParser :: Parser ListOptions
listParser =
  ListOptions
    <$> many (Text.pack <$> strArgument (metavar "SELECTOR" <> help "Scenario selector"))
    <*> many (option (eitherReader readLayer) (long "layer" <> metavar "LAYER" <> help "Restrict to a layer"))
    <*> many (option (eitherReader readKind) (long "kind" <> metavar "KIND" <> help "Restrict to an evidence kind"))
    <*> optional (option (eitherReader readTier) (long "max-tier" <> metavar "TIER" <> help "Maximum cost tier"))
    <*> many (option (eitherReader readPlacement) (long "placement" <> metavar "PLACEMENT" <> help "Restrict placement"))
    <*> switch (long "roles" <> help "List worker roles instead of scenarios")
    <*> switch (long "json" <> help "Write kenshou.scenario-list/v1 JSON")

runList :: ListOptions -> CliEnv -> IO ExitCode
runList options environment = case traverse parseSelector options.selectors of
  Left err -> Text.IO.hPutStrLn stderr ("kenshou: " <> err) >> pure (ExitFailure 2)
  Right selectors -> do
    let filterValue = ListFilter selectors options.layers options.kinds options.maxTier options.placements
        selected = selectScenarios environment.registry filterValue
    if options.json
      then LazyByteString.putStrLn (Aeson.encode (scenarioListDocumentFor selected (if options.roles then allRoles environment.registry else [])))
      else
        if options.roles
          then mapM_ (Text.IO.putStrLn . (\role -> renderRoleName role.name <> "  " <> role.summary)) (allRoles environment.registry)
          else mapM_ (Text.IO.putStrLn . renderScenario) selected
    pure ExitSuccess

renderScenario :: Scenario -> Text
renderScenario scenario =
  Text.intercalate "  " [renderScenarioId scenario.id, renderTier scenario.tier, renderPlacement scenario.placement, scenario.summary <> known]
  where
    known = maybe "" (const " [known defect]") scenario.knownDefect

readLayer :: String -> Either String Layer
readLayer = first Text.unpack . parseLayer . Text.pack

readKind :: String -> Either String Kind
readKind = first Text.unpack . parseKind . Text.pack

readTier :: String -> Either String Tier
readTier "smoke" = Right TierSmoke
readTier "standard" = Right TierStandard
readTier "extended" = Right TierExtended
readTier "soak" = Right TierSoak
readTier value = Left ("unknown tier " <> show value)

readPlacement :: String -> Either String Placement
readPlacement "local" = Right PlaceLocal
readPlacement "cell" = Right PlaceCell
readPlacement "either" = Right PlaceEither
readPlacement value = Left ("unknown placement " <> show value)
