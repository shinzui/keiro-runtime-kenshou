module Kenshou.Cli.Config
  ( RunDefaults (..),
    runDefaultsConfig,
    runEnvironmentBindings,
    resolveRunDefaults,
  )
where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Cli.Config (ConfigInputs (..), loadConfigSources)
import Settei
import Settei.Env

data RunDefaults = RunDefaults
  { outputRoot :: Text,
    pg17Bin :: Maybe Text,
    pg18Bin :: Maybe Text
  }
  deriving stock (Eq, Show)

runDefaultsConfig :: Config RunDefaults
runDefaultsConfig =
  RunDefaults
    <$> required (publicSetting outputRootKey "Default run output directory" textDecoder)
    <*> optional (publicSetting pg17BinKey "PostgreSQL 17 binary directory" textDecoder)
    <*> optional (publicSetting pg18BinKey "PostgreSQL 18 binary directory" textDecoder)

runEnvironmentBindings :: Bindings
runEnvironmentBindings =
  either
    (error . Text.unpack . renderEnvErrorsText)
    id
    (bindings [binding (EnvName "KENSHOU_PG17_BIN") pg17BinKey, binding (EnvName "KENSHOU_PG18_BIN") pg18BinKey])

resolveRunDefaults :: EnvSnapshot -> ConfigInputs -> IO (Either Text (ResolveResult RunDefaults))
resolveRunDefaults snapshot inputs = do
  loaded <- loadConfigSources inputs
  pure $ do
    fileAndNamed <- loaded
    pure (resolve defaultResolveOptions ([builtIns] <> fileAndNamed <> [environmentSource runEnvironmentBindings snapshot]) runDefaultsConfig)

builtIns :: Source
builtIns = source "kenshou built-ins" BuiltInSource (RawObject (Map.singleton "run" (RawObject (Map.singleton "output-root" (RawText "runs")))))

outputRootKey, pg17BinKey, pg18BinKey :: Key
outputRootKey = validKey "run.output-root"
pg17BinKey = validKey "postgres.pg17-bin"
pg18BinKey = validKey "postgres.pg18-bin"

validKey :: Text -> Key
validKey value = either (error . show) id (parseKey value)
