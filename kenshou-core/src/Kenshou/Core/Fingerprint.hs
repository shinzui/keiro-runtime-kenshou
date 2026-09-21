module Kenshou.Core.Fingerprint
  ( HostFingerprint (..),
    collectHostFingerprint,
    hostValue,
    runtimeValue,
    kenshouValue,
  )
where

import Control.Exception (IOException, try)
import Data.Aeson (ToJSON (..), Value, object, (.=))
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Conc (getNumCapabilities)
import GHC.Stats (getRTSStatsEnabled)
import Kenshou.Core.Canonical (sha256Hex)
import Kenshou.Core.Version (suiteVersion)
import System.Environment (getExecutablePath, lookupEnv)
import System.Info qualified as System
import System.Process (readProcess)

data HostFingerprint = HostFingerprint
  { os :: Text,
    arch :: Text,
    kernel :: Text,
    cpuModel :: Maybe Text,
    logicalCores :: Int,
    memoryBytes :: Maybe Integer,
    hostname :: Text,
    ghc :: Text,
    capabilities :: Int,
    threaded :: Bool,
    rtsStats :: Bool,
    kenshouVersion :: Text,
    executableSha256 :: Text,
    revision :: Maybe Text,
    dirty :: Maybe Bool
  }
  deriving stock (Eq, Show)

instance ToJSON HostFingerprint where
  toJSON = hostValue

hostValue :: HostFingerprint -> Value
hostValue fingerprint =
  object
    [ "os" .= fingerprint.os,
      "arch" .= fingerprint.arch,
      "kernel" .= fingerprint.kernel,
      "cpuModel" .= fingerprint.cpuModel,
      "logicalCores" .= fingerprint.logicalCores,
      "memoryBytes" .= fingerprint.memoryBytes,
      "hostname" .= fingerprint.hostname
    ]

runtimeValue :: HostFingerprint -> Value
runtimeValue fingerprint = object ["ghc" .= fingerprint.ghc, "capabilities" .= fingerprint.capabilities, "threaded" .= fingerprint.threaded, "rtsStats" .= fingerprint.rtsStats]

kenshouValue :: HostFingerprint -> Value
kenshouValue fingerprint = object ["version" .= fingerprint.kenshouVersion, "executableSha256" .= fingerprint.executableSha256, "revision" .= fingerprint.revision, "dirty" .= fingerprint.dirty]

collectHostFingerprint :: IO HostFingerprint
collectHostFingerprint = do
  kernel <- commandText "uname" ["-r"]
  hostname <- commandText "hostname" []
  cpuModel <- optionalCommandText (if System.os == "darwin" then "sysctl" else "sh") (if System.os == "darwin" then ["-n", "machdep.cpu.brand_string"] else ["-c", "sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -1"])
  memoryBytes <- collectMemoryBytes
  capabilities <- getNumCapabilities
  rtsStats <- getRTSStatsEnabled
  executable <- getExecutablePath
  bytes <- ByteString.readFile executable
  revision <- firstPresent "KENSHOU_HARNESS_REVISION" (optionalCommandText "git" ["rev-parse", "HEAD"])
  dirtyOverride <- lookupEnv "KENSHOU_HARNESS_DIRTY"
  dirty <- case fmap Text.toCaseFold (Text.pack <$> dirtyOverride) of
    Just "true" -> pure (Just True)
    Just "false" -> pure (Just False)
    Just "1" -> pure (Just True)
    Just "0" -> pure (Just False)
    Just _ -> pure Nothing
    Nothing -> fmap (fmap (not . Text.null)) (optionalCommandText "git" ["status", "--porcelain"])
  pure
    HostFingerprint
      { os = Text.pack System.os,
        arch = Text.pack System.arch,
        kernel,
        cpuModel,
        logicalCores = capabilities,
        memoryBytes,
        hostname,
        ghc = Text.pack (show System.compilerVersion),
        capabilities,
        threaded = True,
        rtsStats,
        kenshouVersion = suiteVersion,
        executableSha256 = sha256Hex bytes,
        revision,
        dirty
      }

collectMemoryBytes :: IO (Maybe Integer)
collectMemoryBytes
  | System.os == "darwin" = optionalCommandText "sysctl" ["-n", "hw.memsize"] >>= pure . (>>= readInteger)
  | otherwise = optionalCommandText "sh" ["-c", "awk '/MemTotal:/ {print $2 * 1024}' /proc/meminfo"] >>= pure . (>>= readInteger)

firstPresent :: String -> IO (Maybe Text) -> IO (Maybe Text)
firstPresent variable fallback = lookupEnv variable >>= maybe fallback (pure . Just . Text.pack)

readInteger :: Text -> Maybe Integer
readInteger input = case reads (Text.unpack input) of [(value, "")] -> Just value; _ -> Nothing

commandText :: FilePath -> [String] -> IO Text
commandText command arguments = Text.strip . Text.pack <$> readProcess command arguments ""

optionalCommandText :: FilePath -> [String] -> IO (Maybe Text)
optionalCommandText command arguments = do
  result <- try (commandText command arguments) :: IO (Either IOException Text)
  pure (either (const Nothing) Just result)
