module Kenshou.Suite.Runtime.Ops
  ( OpsCall (..),
    runOps,
    opsJson,
  )
where

import Control.Concurrent.STM (atomically)
import Data.Aeson (Value, eitherDecodeStrict', toJSON)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as ByteString
import Data.IORef (atomicModifyIORef')
import Data.Map.Strict qualified as Map
import Data.Scientific (toBoundedInteger)
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Check.Process (ProgressSnapshot (..), awaitMark, awaitReady, progress, roleProcess, sendCommand, spawn, stopGracefully)
import Kenshou.Check.Scenario (CheckEnv (..))
import Kenshou.Core.Context (ArtifactDir (DiagnosisDir), RunContext (..), artifactPath, declareMediaType)
import Kenshou.Core.Role (ControlMessage (CtlStart))
import Kenshou.Suite.Runtime.Roles (OpsArgs (..), roleNameText)
import Kenshou.Suite.Runtime.System.Config (SystemConfig (..))
import Kenshou.Suite.Runtime.System.Schema (ContextName (..))
import Kenshou.Suite.Runtime.Topology (RunningSystem (..))
import System.FilePath (makeRelative)

-- | One finished operator-console invocation. The console's standard output
-- is kept in the run directory as evidence; 'output' is its decoded JSON.
data OpsCall = OpsCall
  { context :: !ContextName,
    arguments :: ![Text],
    exitCode :: !Int,
    file :: !FilePath,
    output :: !(Either Text Value)
  }
  deriving stock (Eq, Show)

-- | Run @keiro-ops --json <arguments>@ against one context as a short-lived
-- child of the harness: the @runtime/keiro-ops@ role of the same binary.
runOps :: RunningSystem -> ContextName -> [Text] -> IO OpsCall
runOps system context arguments = do
  number <- atomicModifyIORef' system.invocations \n -> (n + 1, n)
  let run = system.check.context
      label = contextLabel <> "-" <> Text.intercalate "-" (takeWhile (not . Text.isPrefixOf "--") arguments)
  file <- artifactPath run DiagnosisDir ("keiro-ops-" <> show number <> "-" <> Text.unpack label <> ".json")
  declareMediaType run (makeRelative run.outDir file) "application/json"
  process <- roleProcess system.check (roleNameText "keiro-ops") number (toJSON (OpsArgs database ("--json" : arguments) file))
  child <- spawn system.supervisor process
  awaitReady child 60000
  sendCommand child CtlStart
  awaitMark child "keiro-ops-finished" 120000
  snapshot <- atomically (progress child)
  _ <- stopGracefully system.supervisor child 5000
  let finished = Map.lookup "keiro-ops-finished" snapshot.marks
      exitCode = maybe (-1) id (finished >>= numberField "exitCode")
  output <-
    if exitCode /= 0
      then pure (Left ("keiro-ops exited " <> Text.pack (show exitCode) <> maybe "" (": " <>) (finished >>= textField "error")))
      else do
        bytes <- ByteString.readFile file
        pure case eitherDecodeStrict' bytes of
          Left problem -> Left ("keiro-ops printed unparseable JSON: " <> Text.pack problem)
          Right value -> Right value
  pure (OpsCall context arguments exitCode file output)
  where
    (database, contextLabel) = case context of
      Shop -> (system.config.shopDatabase, "shop")
      Warehouse -> (system.config.warehouseDatabase, "warehouse")
    numberField name = \case
      Aeson.Object fields -> case KeyMap.lookup (Key.fromText name) fields of
        Just (Aeson.Number n) -> toBoundedInteger n
        _ -> Nothing
      _ -> Nothing
    textField name = \case
      Aeson.Object fields -> case KeyMap.lookup (Key.fromText name) fields of
        Just (Aeson.String value) -> Just value
        _ -> Nothing
      _ -> Nothing

-- | The decoded JSON of one invocation; a failed invocation is an error.
opsJson :: RunningSystem -> ContextName -> [String] -> IO Value
opsJson system context arguments = do
  call <- runOps system context (fmap Text.pack arguments)
  either (ioError . userError . Text.unpack) pure call.output
