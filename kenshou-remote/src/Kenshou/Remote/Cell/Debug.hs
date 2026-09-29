module Kenshou.Remote.Cell.Debug
  ( DebugCommand (..),
    resolveDebugRole,
    remoteCommand,
    runCellDebug,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Remote.Cell.Docs (CellDescriptor (..), CellNodes (..))
import System.Directory (doesFileExist)
import System.Environment (getEnvironment, lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import System.Process (CreateProcess (..), StdStream (..), createProcess, proc, readProcessWithExitCode, waitForProcess)
import Text.Read (readMaybe)

data DebugCommand
  = DebugSsh !Text ![String]
  | DebugJournal
  | DebugTunnel !Text !Int !Int
  deriving stock (Eq, Show)

resolveDebugRole :: CellDescriptor -> Text -> Either Text Text
resolveDebugRole descriptor role = case role of
  "postgres" -> Right descriptor.instances.postgres
  "monitoring" -> Right descriptor.instances.monitoring
  "driver" -> driver 0
  _ -> case Text.stripPrefix "driver-" role >>= readMaybe . Text.unpack of
    Just index -> driver index
    Nothing -> Left "role must be postgres, monitoring, driver, or driver-N"
  where
    driver index = case drop index descriptor.instances.drivers of
      name : _ | index >= 0 -> Right name
      _ -> Left "cell descriptor has no driver at that index"

remoteCommand :: [String] -> String
remoteCommand = unwords . map quote
  where
    quote value = "'" <> concatMap escape value <> "'"
    escape '\'' = "'\\''"
    escape character = [character]

runCellDebug :: CellDescriptor -> DebugCommand -> IO (Either Text ExitCode)
runCellDebug descriptor selected = do
  scriptResult <- locateScript
  case scriptResult of
    Left problem -> pure (Left problem)
    Right script -> case arguments of
      Left problem -> pure (Left problem)
      Right args -> do
        environment <- getEnvironment
        let overrides =
              [ ("CLOUDSDK_CORE_PROJECT", Text.unpack descriptor.project),
                ("ZONE", Text.unpack descriptor.zone)
              ]
            inherited = filter (\(key, _) -> key `notElem` map fst overrides) environment
        hPutStrLn stderr ("cell debug: " <> unwords (script : args))
        (_, _, _, handle) <-
          createProcess
            (proc script args)
              { env = Just (overrides <> inherited),
                std_in = Inherit,
                std_out = Inherit,
                std_err = Inherit
              }
        Right <$> waitForProcess handle
  where
    arguments = case selected of
      DebugSsh role command -> do
        instanceName <- resolveDebugRole descriptor role
        pure (["ssh", Text.unpack instanceName, "--"] <> [remoteCommand command | not (null command)])
      DebugJournal -> do
        instanceName <- resolveDebugRole descriptor "driver"
        pure ["ssh", Text.unpack instanceName, "--", remoteCommand ["sudo", "journalctl", "-u", "cell-agent", "-n", "100", "--no-pager"]]
      DebugTunnel role remotePort localPort -> do
        instanceName <- resolveDebugRole descriptor role
        if validPort remotePort && validPort localPort
          then Right ["ssh-tunnel", Text.unpack instanceName, show remotePort, show localPort]
          else Left "tunnel ports must be between 1 and 65535"
    validPort port = port >= 1 && port <= 65535

locateScript :: IO (Either Text FilePath)
locateScript = do
  configured <- lookupEnv "KENSHOU_LTI_DIR"
  root <- case configured of
    Just value | not (null value) -> pure (Right value)
    _ -> do
      (code, output, failure) <- readProcessWithExitCode "mori" ["path", "shinzui/load-testing-infra"] ""
      pure case code of
        ExitSuccess -> case lines output of
          [path] -> Right path
          _ -> Left "mori did not return one load-testing-infra path"
        _ -> Left ("mori could not locate load-testing-infra: " <> Text.pack failure)
  case root of
    Left problem -> pure (Left problem)
    Right directory -> do
      let script = directory </> "scripts" </> "iap-ssh.sh"
      exists <- doesFileExist script
      pure if exists then Right script else Left ("cell debug needs the owner IAP script at " <> Text.pack script)
