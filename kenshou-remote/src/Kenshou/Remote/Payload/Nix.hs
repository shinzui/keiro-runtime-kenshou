module Kenshou.Remote.Payload.Nix
  ( NixError (..),
    NixTools (..),
    ClosureInfo (..),
    BundleInfo (..),
    nixBuild,
    nixEvalJson,
    closureInfo,
    parseClosureInfo,
    exportBundle,
    exportBundleWith,
  )
where

import Control.Exception (IOException, displayException, try)
import Data.Aeson (FromJSON, Value (..), eitherDecodeStrict')
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Int (Int64)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Kenshou.Remote.Payload.Publish (digestFile)
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile, renameFile)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory)
import System.IO (hClose, openBinaryTempFile)
import System.Process (StdStream (..), createProcess, proc, readProcessWithExitCode, std_in, std_out, terminateProcess, waitForProcess)

data NixError
  = NixCommandFailed !FilePath ![String] !ExitCode !Text
  | NixCommandIoError !Text
  | NixInvalidOutput !Text
  deriving stock (Eq, Show)

data NixTools = NixTools
  { nixExecutable :: !FilePath,
    nixStoreExecutable :: !FilePath,
    zstdExecutable :: !FilePath
  }
  deriving stock (Eq, Show)

defaultTools :: NixTools
defaultTools = NixTools "nix" "nix-store" "zstd"

data ClosureInfo = ClosureInfo
  { storePath :: !FilePath,
    narHash :: !Text,
    closurePaths :: ![FilePath]
  }
  deriving stock (Eq, Show)

data BundleInfo = BundleInfo
  { file :: !FilePath,
    sha256 :: !Text,
    bytes :: !Int64,
    closure :: !ClosureInfo
  }
  deriving stock (Eq, Show)

nixBuild :: String -> IO (Either NixError FilePath)
nixBuild reference = do
  result <- runCommand defaultTools.nixExecutable ["build", "--no-link", "--print-out-paths", reference]
  pure do
    output <- result
    case lines (Text.unpack output) of
      [path] | "/nix/store/" `Text.isPrefixOf` Text.pack path -> Right path
      _ -> Left (NixInvalidOutput "nix build did not return exactly one store path")

nixEvalJson :: (FromJSON value) => String -> IO (Either NixError value)
nixEvalJson reference = do
  result <- runCommand defaultTools.nixExecutable ["eval", "--json", reference]
  pure do
    output <- result
    firstDecode (eitherDecodeStrict' (TextEncoding.encodeUtf8 output))

closureInfo :: FilePath -> IO (Either NixError ClosureInfo)
closureInfo = closureInfoWith defaultTools

closureInfoWith :: NixTools -> FilePath -> IO (Either NixError ClosureInfo)
closureInfoWith tools path = do
  result <- runCommand tools.nixExecutable ["path-info", "--json", "--recursive", path]
  pure do
    output <- result
    value <- firstDecode (eitherDecodeStrict' (TextEncoding.encodeUtf8 output))
    parseClosureInfo path value

parseClosureInfo :: FilePath -> Value -> Either NixError ClosureInfo
parseClosureInfo path (Object paths) = do
  root <- maybe (Left (NixInvalidOutput "closure metadata omits the requested store path")) Right (KeyMap.lookup (Key.fromText (Text.pack path)) paths)
  hash <- case root of
    Object fields -> case KeyMap.lookup "narHash" fields of
      Just (String value) | "sha256-" `Text.isPrefixOf` value -> Right value
      _ -> Left (NixInvalidOutput "closure metadata omits the root NAR hash")
    _ -> Left (NixInvalidOutput "closure metadata has a malformed root entry")
  let names = sort (map (Text.unpack . Key.toText . fst) (KeyMap.toList paths))
  if null names || any (not . Text.isPrefixOf "/nix/store/" . Text.pack) names
    then Left (NixInvalidOutput "closure metadata contains an invalid store path")
    else Right (ClosureInfo path hash names)
parseClosureInfo _ _ = Left (NixInvalidOutput "closure metadata must be a JSON object")

exportBundle :: FilePath -> FilePath -> IO (Either NixError BundleInfo)
exportBundle = exportBundleWith defaultTools

exportBundleWith :: NixTools -> FilePath -> FilePath -> IO (Either NixError BundleInfo)
exportBundleWith tools path destination = do
  closureResult <- closureInfoWith tools path
  case closureResult of
    Left problem -> pure (Left problem)
    Right closure -> do
      createDirectoryIfMissing True (takeDirectory destination)
      (temporary, handle) <- openBinaryTempFile (takeDirectory destination) ".kenshou-payload-"
      hClose handle
      exportResult <- try (exportToFile tools closure.closurePaths temporary) :: IO (Either IOException (Either NixError ()))
      case exportResult of
        Left problem -> do
          removeIfPresent temporary
          pure (Left (NixCommandIoError (Text.pack (displayException problem))))
        Right (Left problem) -> do
          removeIfPresent temporary
          pure (Left problem)
        Right (Right ()) -> do
          finished <- try @IOException do
            (sha256, size) <- digestFile temporary
            renameFile temporary destination
            pure (BundleInfo destination sha256 size closure)
          case finished of
            Left problem -> do
              removeIfPresent temporary
              pure (Left (NixCommandIoError (Text.pack (displayException problem))))
            Right bundle -> pure (Right bundle)

exportToFile :: NixTools -> [FilePath] -> FilePath -> IO (Either NixError ())
exportToFile tools paths destination = do
  let exportArgs = "--export" : paths
      compressArgs = ["-19", "-T1", "-q", "-f", "-o", destination]
  (_, exportOutput, _, exportProcess) <- createProcess (proc tools.nixStoreExecutable exportArgs) {std_out = CreatePipe}
  case exportOutput of
    Nothing -> pure (Left (NixInvalidOutput "nix-store export did not create a pipe"))
    Just pipe -> do
      compression <- try @IOException (createProcess (proc tools.zstdExecutable compressArgs) {std_in = UseHandle pipe})
      case compression of
        Left problem -> do
          hClose pipe
          terminateProcess exportProcess
          _ <- waitForProcess exportProcess
          pure (Left (NixCommandIoError (Text.pack (displayException problem))))
        Right (_, _, _, compressProcess) -> do
          hClose pipe
          compressExit <- waitForProcess compressProcess
          exportExit <- waitForProcess exportProcess
          pure case (exportExit, compressExit) of
            (ExitSuccess, ExitSuccess) -> Right ()
            (failure, _) | failure /= ExitSuccess -> Left (NixCommandFailed tools.nixStoreExecutable exportArgs failure "closure export failed")
            (_, failure) -> Left (NixCommandFailed tools.zstdExecutable compressArgs failure "bundle compression failed")

runCommand :: FilePath -> [String] -> IO (Either NixError Text)
runCommand executable arguments = do
  result <- try (readProcessWithExitCode executable arguments "") :: IO (Either IOException (ExitCode, String, String))
  pure case result of
    Left problem -> Left (NixCommandIoError (Text.pack (displayException problem)))
    Right (ExitSuccess, output, _) -> Right (Text.pack output)
    Right (failure, _, errors) -> Left (NixCommandFailed executable arguments failure (Text.pack errors))

firstDecode :: Either String value -> Either NixError value
firstDecode = either (Left . NixInvalidOutput . Text.pack) Right

removeIfPresent :: FilePath -> IO ()
removeIfPresent path = do
  exists <- doesFileExist path
  if exists then removeFile path else pure ()
