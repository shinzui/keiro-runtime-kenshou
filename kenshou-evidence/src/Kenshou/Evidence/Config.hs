module Kenshou.Evidence.Config
  ( EvidenceDefaults (..),
    evidenceConfig,
    bundleRootKey,
    projectKey,
    dataBaseUriKey,
    resolveEvidenceDefaults,
  )
where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Cli.Config (ConfigInputs (..), loadConfigSources)
import Settei
import Settei.Env

data EvidenceDefaults = EvidenceDefaults
  { bundleRoot :: !Text,
    project :: !(Maybe Text),
    dataBaseUri :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

evidenceConfig :: Config EvidenceDefaults
evidenceConfig =
  EvidenceDefaults
    <$> required (publicSetting bundleRootKey "OKF verification bundle" textDecoder)
    <*> optional (publicSetting projectKey "GCP project for durable evidence" textDecoder)
    <*> optional (publicSetting dataBaseUriKey "GCS prefix for run data" textDecoder)

resolveEvidenceDefaults :: EnvSnapshot -> ConfigInputs -> IO (Either Text (ResolveResult EvidenceDefaults))
resolveEvidenceDefaults snapshot inputs = do
  loaded <- loadConfigSources inputs {namedSources = []}
  pure $ do
    files <- loaded
    pure (resolve defaultResolveOptions {unknownKeyPolicy = RejectUnknownKeys} ([builtIns] <> files <> [environmentSource environmentBindings snapshot] <> inputs.namedSources) evidenceConfig)

environmentBindings :: Bindings
environmentBindings =
  either
    (error . Text.unpack . renderEnvErrorsText)
    id
    ( bindings
        [ binding (EnvName "KENSHOU_EVIDENCE_BUNDLE") bundleRootKey,
          binding (EnvName "KENSHOU_GCP_PROJECT") projectKey,
          binding (EnvName "KENSHOU_EVIDENCE_DATA_BASE_URI") dataBaseUriKey
        ]
    )

builtIns :: Source
builtIns = source "kenshou built-ins" BuiltInSource (RawObject (Map.singleton "evidence" (RawObject (Map.singleton "bundle-root" (RawText "docs/verification")))))

bundleRootKey, projectKey, dataBaseUriKey :: Key
bundleRootKey = validKey "evidence.bundle-root"
projectKey = validKey "gcp.project"
dataBaseUriKey = validKey "evidence.data-base-uri"

validKey :: Text -> Key
validKey value = either (error . show) id (parseKey value)
