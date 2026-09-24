module Kenshou.Env.Kafka.External (withExternalBrokers) where

import Control.Exception (bracket_)
import Control.Monad (void)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (getCurrentTime)
import Kenshou.Core.Context (RunContext)
import Kenshou.Env.Kafka.Admin (deleteRunGroups, deleteRunTopics)
import Kenshou.Env.Kafka.Spec (BrokerBackend (..), BrokerControlHooks (..), KafkaEnvSpec (..))
import Kenshou.Env.Kafka.Types
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

withExternalBrokers :: RunContext -> KafkaEnvSpec -> FilePath -> Text -> (KafkaEnv -> IO a) -> IO a
withExternalBrokers _ spec workDir prefix action = do
  control <- traverse hooks spec.controlHooks
  let env = KafkaEnv ExternalBrokers (BrokerLane spec.brokers Nothing :| []) prefix control "external" workDir
      cleanup = void (deleteRunGroups env) >> void (deleteRunTopics env)
  bracket_ (pure ()) cleanup (action env)

hooks :: BrokerControlHooks -> IO BrokerControl
hooks commands = do
  running <- newIORef True
  started <- newIORef "external-initial"
  pure
    BrokerControl
      { kill = invoke commands.killCommand >> writeIORef running False,
        stop = invoke commands.stopCommand >> writeIORef running False,
        start = do
          invoke commands.startCommand
          now <- getCurrentTime
          writeIORef started (Text.pack (show now))
          writeIORef running True,
        isRunning = readIORef running,
        generation = readIORef started
      }

invoke :: [Text] -> IO ()
invoke [] = ioError (userError "Kafka broker control hook is empty")
invoke (program : args) = do
  (code, _, errorOutput) <- readProcessWithExitCode (Text.unpack program) (fmap Text.unpack args) ""
  case code of
    ExitSuccess -> pure ()
    ExitFailure _ -> ioError (userError ("Kafka control hook failed: " <> errorOutput))
