module Kenshou.Core.Cli.Config
  ( ConfigInputs (..),
    configInputsParser,
    loadConfigSources,
  )
where

import Data.List.NonEmpty qualified as NonEmpty
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as Text
import Options.Applicative (Parser)
import Options.Applicative qualified as Options
import Settei (Source)
import Settei.Optparse (DiagnosticMode, configPathOptions, diagnosticModeOptions)
import Settei.Yaml (readYamlSource, renderYamlErrorsText, yamlSourceOptions)

data ConfigInputs = ConfigInputs
  { paths :: [FilePath],
    namedSources :: [Source],
    diagnostic :: DiagnosticMode
  }

configInputsParser :: Parser [Maybe Source] -> Parser ConfigInputs
configInputsParser namedParser =
  ConfigInputs
    <$> Options.parserOptionGroup "Configuration" configPathOptions
    <*> (catMaybes <$> Options.parserOptionGroup "Configuration" namedParser)
    <*> Options.parserOptionGroup "Configuration diagnostics" diagnosticModeOptions

loadConfigSources :: ConfigInputs -> IO (Either Text [Source])
loadConfigSources inputs = do
  loaded <- sequence [readYamlSource (yamlSourceOptions ("configuration " <> Text.pack (show index))) path | (index, path) <- zip [1 :: Int ..] inputs.paths]
  pure $ case traverse (either (Left . renderYamlErrorsText) Right) loaded of
    Left err -> Left err
    Right sources -> Right (sources <> inputs.namedSources)
