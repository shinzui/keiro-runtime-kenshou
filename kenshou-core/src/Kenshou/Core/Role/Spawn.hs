module Kenshou.Core.Role.Spawn (WorkerHandle (..), withWorker) where

import Control.Exception (bracket)
import Data.Aeson (Value, eitherDecodeStrict', encode)
import Data.ByteString.Char8 qualified as ByteString
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Context (ArtifactDir (..), Environment (..), RunContext (..), artifactPath)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Role
import Kenshou.Core.RunSpec (EnvironmentSpec (..))
import System.Environment (getExecutablePath)
import System.Exit (ExitCode)
import System.IO (BufferMode (LineBuffering), Handle, IOMode (AppendMode), hClose, hFlush, hIsEOF, hSetBuffering, openFile)
import System.Posix.Types (CPid)
import System.Process
import System.Timeout (timeout)

data WorkerHandle = WorkerHandle
  { instanceName :: Text,
    pid :: CPid,
    send :: ControlMessage -> IO (),
    receive :: Int -> IO (Maybe WorkerMessage),
    waitExit :: IO ExitCode
  }

withWorker :: RunContext -> RoleName -> Text -> Value -> (WorkerHandle -> IO value) -> IO value
withWorker context roleName instanceName arguments action = do
  logPath <- artifactPath context LogsDir ("worker-" <> Text.unpack instanceName <> ".stderr.log")
  bracket (start logPath) stop (action . fst)
  where
    start logPath = do
      executable <- getExecutablePath
      errorHandle <- openFile logPath AppendMode
      (Just input, Just output, _, processHandle) <- createProcess (proc executable ["worker", "--role", Text.unpack (renderRoleName roleName)]) {std_in = CreatePipe, std_out = CreatePipe, std_err = UseHandle errorHandle}
      hSetBuffering input LineBuffering
      processId <- getPid processHandle >>= maybe (ioError (userError "worker has no process id")) pure
      let sendMessage message = LazyByteString.hPutStrLn input (encode message) >> hFlush input
          receiveMessage timeoutMillis = timeout (timeoutMillis * 1000) (readWorker output) >>= pure . joinMaybe
          workerHandle = WorkerHandle instanceName processId sendMessage receiveMessage (waitForProcess processHandle)
          postgres = fmap (\environment -> PostgresConnInfo environment.connectionString environment.adminConnectionString) context.env.postgres
          workerInit = WorkerInit context.runId context.scenario roleName instanceName context.seed context.knobs context.dimensions postgres context.environmentSpec.kafka context.environmentSpec.telemetry context.outDir arguments
      sendMessage (CtlInit workerInit)
      pure (workerHandle, (input, output, errorHandle, processHandle))
    stop (_, (input, output, errorHandle, processHandle)) = do
      sendLine input (CtlStop 2000)
      hClose input
      finished <- timeout 2000000 (waitForProcess processHandle)
      case finished of
        Just _ -> pure ()
        Nothing -> terminateProcess processHandle >> waitForProcess processHandle >> pure ()
      hClose output
      hClose errorHandle

readWorker :: Handle -> IO (Maybe WorkerMessage)
readWorker handle = do
  atEnd <- hIsEOF handle
  if atEnd then pure Nothing else either (const Nothing) Just . eitherDecodeStrict' <$> ByteString.hGetLine handle

sendLine :: Handle -> ControlMessage -> IO ()
sendLine handle message = LazyByteString.hPutStrLn handle (encode message) >> hFlush handle

joinMaybe :: Maybe (Maybe value) -> Maybe value
joinMaybe = maybe Nothing id
