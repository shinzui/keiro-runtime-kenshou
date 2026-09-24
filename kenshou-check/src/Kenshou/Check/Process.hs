module Kenshou.Check.Process
  ( ProcessSpec (..),
    ChildSignal (..),
    RestartPolicy (..),
    ProgressSnapshot (..),
    Supervisor,
    Child,
    roleProcess,
    withSupervisor,
    spawn,
    awaitReady,
    sendCommand,
    progress,
    awaitMark,
    signalChild,
    killChild,
    terminateChild,
    restartChild,
    stopGracefully,
    withRestartLoop,
    crashWindows,
    childPid,
    childProc,
    readChildMessages,
    sweepOrphans,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, async, cancel, waitCatch)
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception (SomeException, bracket, catch)
import Control.Monad (forM_, unless, void)
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as ByteString
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.IORef
import Data.Int (Int64)
import Data.List (foldl')
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Kenshou.Check.Fact
import Kenshou.Check.Ledger
import Kenshou.Check.Scenario
import Kenshou.Check.Window
import Kenshou.Core.Context (Environment (..), RunContext (..))
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (renderRunId)
import Kenshou.Core.Role
import Kenshou.Core.RunSpec (EnvironmentSpec (..))
import System.Directory (createDirectoryIfMissing)
import System.Environment (getEnvironment, getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO
import System.Posix.Signals
import System.Posix.Types (CPid)
import System.Process
import System.Timeout (timeout)

data ProcessSpec = ProcessSpec
  { proc :: !ProcId,
    executable :: !FilePath,
    args :: ![String],
    env :: ![(String, String)],
    initial :: !(Maybe ControlMessage)
  }

data ChildSignal = Term | Kill | Stop | Cont deriving stock (Eq, Ord, Show)

data RestartPolicy = RestartPolicy
  { initialBackoffMillis :: !Int,
    maxBackoffMillis :: !Int,
    multiplier :: !Double,
    maxRestarts :: !Int
  }
  deriving stock (Eq, Show)

data ProgressSnapshot = ProgressSnapshot
  { ready :: !Bool,
    count :: !Int64,
    marks :: !(Map Text Value),
    lastMessage :: !(Maybe WorkerMessage)
  }
  deriving stock (Eq, Show)

data Supervisor = Supervisor
  { environment :: !CheckEnv,
    children :: !(MVar [Child]),
    windows :: !(IORef [DisturbanceWindow])
  }

data Child = Child
  { spec :: !ProcessSpec,
    pid :: !CPid,
    input :: !Handle,
    inputLock :: !(MVar ()),
    output :: !Handle,
    errorLog :: !Handle,
    processHandle :: !ProcessHandle,
    state :: !(TVar ProgressSnapshot),
    listener :: !(Async ()),
    controlLog :: !FilePath,
    stdoutLog :: !FilePath
  }

defaultRestartPolicy :: RestartPolicy
defaultRestartPolicy = RestartPolicy 100 5000 2 50

roleProcess :: CheckEnv -> Text -> Int -> Value -> IO ProcessSpec
roleProcess environment role index arguments = do
  executable <- getExecutablePath
  roleName <- either (ioError . userError . Text.unpack) pure (mkRoleName role)
  let context = environment.context
      proc = ProcId role index 0
      instanceName = role <> "-" <> Text.pack (show index)
      postgres = fmap (\postgres -> PostgresConnInfo postgres.connectionString postgres.adminConnectionString) context.env.postgres
      workerInit = WorkerInit context.runId context.scenario roleName instanceName context.seed context.knobs context.dimensions postgres context.environmentSpec.kafka context.environmentSpec.telemetry context.outDir arguments
      appName = "kenshou-" <> Text.unpack (Text.take 8 (renderRunId context.runId)) <> "-" <> Text.unpack role <> "-" <> show index
  pure (ProcessSpec proc executable ["worker", "--role", Text.unpack role] [("PGAPPNAME", appName)] (Just (CtlInit workerInit)))

withSupervisor :: CheckEnv -> (Supervisor -> IO value) -> IO value
withSupervisor environment action = bracket acquire cleanup action
  where
    acquire = Supervisor environment <$> newMVar [] <*> newIORef []
    cleanup supervisor = readMVar supervisor.children >>= mapM_ cleanupChild

spawn :: Supervisor -> ProcessSpec -> IO Child
spawn supervisor spec = do
  let logs = supervisor.environment.context.outDir </> "logs"
      label = fileLabel spec.proc
      stderrPath = logs </> label <> ".stderr.log"
      controlPath = logs </> label <> ".control.jsonl"
      stdoutPath = logs </> label <> ".stdout.log"
  createDirectoryIfMissing True logs
  stderrHandle <- openFile stderrPath AppendMode
  baseEnvironment <- getEnvironment
  let mergedEnvironment = Map.toList (foldl' (\values (key, value) -> Map.insert key value values) (Map.fromList baseEnvironment) spec.env)
  (Just input, Just output, _, processHandle) <-
    createProcess
      (proc spec.executable spec.args)
        { std_in = CreatePipe,
          std_out = CreatePipe,
          std_err = UseHandle stderrHandle,
          env = Just mergedEnvironment,
          create_group = True
        }
  hSetBuffering input LineBuffering
  hSetBuffering output LineBuffering
  pid <- getPid processHandle >>= maybe (ioError (userError "spawned worker has no pid")) pure
  state <- newTVarIO (ProgressSnapshot False 0 Map.empty Nothing)
  inputLock <- newMVar ()
  listener <- async (listenWorker output controlPath stdoutPath state)
  let child = Child spec pid input inputLock output stderrHandle processHandle state listener controlPath stdoutPath
  modifyMVar_ supervisor.children (pure . (child :))
  appendPid supervisor child
  forM_ spec.initial (sendCommand child)
  pure child

awaitReady :: Child -> Int -> IO ()
awaitReady child timeoutMillis = awaitState timeoutMillis child (\snapshot -> snapshot.ready) "worker did not become ready"

sendCommand :: Child -> ControlMessage -> IO ()
sendCommand child message = withMVar child.inputLock \_ -> do
  LazyByteString.hPutStrLn child.input (encode message)
  hFlush child.input

progress :: Child -> STM ProgressSnapshot
progress child = readTVar child.state

awaitMark :: Child -> Text -> Int -> IO ()
awaitMark child mark timeoutMillis = awaitState timeoutMillis child (Map.member mark . (.marks)) ("worker did not report mark " <> Text.unpack mark)

signalChild :: Supervisor -> Child -> ChildSignal -> IO ()
signalChild supervisor child signal = do
  recordWindowEdge supervisor child DisturbanceStart signal
  signalProcessGroup (signalValue signal) child.pid
  case signal of
    Cont -> recordWindowEdge supervisor child DisturbanceEnd signal
    _ -> pure ()

killChild :: Supervisor -> Child -> IO ()
killChild supervisor child = do
  signalChild supervisor child Kill
  void (waitExit child)
  retireChild supervisor child

terminateChild :: Supervisor -> Child -> IO ()
terminateChild supervisor child = do
  signalChild supervisor child Term
  void (waitExit child)
  retireChild supervisor child

restartChild :: Supervisor -> Child -> IO Child
restartChild supervisor child = do
  let oldProc = child.spec.proc
      nextProc = oldProc {incarnation = oldProc.incarnation + 1}
      nextSpec = ProcessSpec nextProc child.spec.executable child.spec.args child.spec.env child.spec.initial
  replacement <- spawn supervisor nextSpec
  awaitReady replacement 10000
  recordWindowEdge supervisor replacement DisturbanceEnd Kill
  pure replacement

stopGracefully :: Supervisor -> Child -> Int -> IO ExitCode
stopGracefully supervisor child graceMillis = do
  sendCommand child (CtlStop graceMillis)
  finished <- timeout (graceMillis * 1000) (waitExit child)
  result <- case finished of
    Just code -> pure code
    Nothing -> do
      signalChild supervisor child Term
      terminated <- timeout 1000000 (waitExit child)
      case terminated of
        Just code -> pure code
        Nothing -> signalChild supervisor child Kill >> waitExit child
  retireChild supervisor child
  pure result

retireChild :: Supervisor -> Child -> IO ()
retireChild supervisor child =
  modifyMVar_ supervisor.children (pure . filter ((/= child.pid) . (.pid)))

withRestartLoop :: Supervisor -> RestartPolicy -> ProcessSpec -> (IO Child -> IO value) -> IO value
withRestartLoop supervisor _policy spec action = action (spawn supervisor spec)

crashWindows :: Supervisor -> IO [DisturbanceWindow]
crashWindows supervisor = reverse <$> readIORef supervisor.windows

childPid :: Child -> CPid
childPid = (.pid)

childProc :: Child -> ProcId
childProc child = child.spec.proc

-- The control log retains every mark, including repeated marks that the
-- progress snapshot replaces with the latest payload.
readChildMessages :: Child -> IO [WorkerMessage]
readChildMessages child = do
  contents <- ByteString.readFile child.controlLog
  pure [message | line <- ByteString.lines contents, Right message <- [eitherDecodeStrict' line]]

sweepOrphans :: FilePath -> IO [CPid]
sweepOrphans path = do
  exists <- tryRead path
  case exists of
    Nothing -> pure []
    Just contents -> fmap concat . traverse killLine $ ByteString.lines contents
  where
    killLine line = case eitherDecodeStrict' line of
      Right (PidRecord pid _ _ _) -> (signalProcess sigKILL (fromIntegral pid) >> pure [fromIntegral pid]) `catch` ignoreList
      Left _ -> pure []

data PidRecord = PidRecord Int Text Int Int

instance ToJSON PidRecord where
  toJSON (PidRecord pid role index incarnation) = object ["pid" .= pid, "role" .= role, "index" .= index, "incarnation" .= incarnation]

instance FromJSON PidRecord where
  parseJSON = withObject "PidRecord" \value -> PidRecord <$> value .: "pid" <*> value .: "role" <*> value .: "index" <*> value .: "incarnation"

listenWorker :: Handle -> FilePath -> FilePath -> TVar ProgressSnapshot -> IO ()
listenWorker output controlPath stdoutPath state = go
  where
    go = do
      done <- hIsEOF output
      unless done do
        line <- ByteString.hGetLine output
        case eitherDecodeStrict' line of
          Right message -> do
            ByteString.appendFile controlPath (line <> "\n")
            atomically (modifyTVar' state (applyMessage message))
          Left _ -> ByteString.appendFile stdoutPath (line <> "\n")
        go

applyMessage :: WorkerMessage -> ProgressSnapshot -> ProgressSnapshot
applyMessage message snapshot = case message of
  WrkReady -> snapshot {ready = True, lastMessage = Just message}
  WrkProgress count _ -> snapshot {count, lastMessage = Just message}
  WrkCustom name payload -> snapshot {marks = Map.insert name payload snapshot.marks, lastMessage = Just message}
  _ -> snapshot {lastMessage = Just message}

awaitState :: Int -> Child -> (ProgressSnapshot -> Bool) -> String -> IO ()
awaitState timeoutMillis child predicate failure = do
  result <- timeout (timeoutMillis * 1000) (atomically (readTVar child.state >>= check . predicate))
  maybe (ioError (userError failure)) pure result

recordWindowEdge :: Supervisor -> Child -> FactKind -> ChildSignal -> IO ()
recordWindowEdge supervisor child kind signal = do
  now <- wallMicros
  let label = Text.toLower (Text.pack (show signal))
      target = renderProcId child.spec.proc
      attrs = KeyMap.fromList [(Key.fromText "label", String label), (Key.fromText "target", String target), (Key.fromText "pid", Number (fromIntegral child.pid))]
  recordDurable supervisor.environment.ledger kind target 0 label attrs
  modifyIORef' supervisor.windows (DisturbanceWindow label target now (if kind == DisturbanceEnd then Just now else Nothing) :)

appendPid :: Supervisor -> Child -> IO ()
appendPid supervisor child = do
  let path = supervisor.environment.context.outDir </> "logs" </> "pids.jsonl"
      proc = child.spec.proc
  LazyByteString.appendFile path (encode (PidRecord (fromIntegral child.pid) proc.role proc.index proc.incarnation) <> "\n")

cleanupChild :: Child -> IO ()
cleanupChild child = do
  (signalProcessGroup sigKILL child.pid >> pure ()) `catch` ignoreUnit
  void (timeout 1000000 (waitExit child))
  closeChildHandles child

closeChildHandles :: Child -> IO ()
closeChildHandles child = do
  cancel child.listener
  hClose child.input `catch` ignoreUnit
  hClose child.output `catch` ignoreUnit
  hClose child.errorLog `catch` ignoreUnit

signalValue :: ChildSignal -> Signal
signalValue Term = sigTERM
signalValue Kill = sigKILL
signalValue Stop = sigSTOP
signalValue Cont = sigCONT

fileLabel :: ProcId -> FilePath
fileLabel proc = Text.unpack (Text.replace "/" "-" proc.role) <> "-" <> show proc.index <> "." <> show proc.incarnation

wallMicros :: IO Int64
wallMicros = round . (* 1000000) <$> getPOSIXTime

tryRead :: FilePath -> IO (Maybe ByteString.ByteString)
tryRead path = (Just <$> ByteString.readFile path) `catch` ignoreMaybe

waitExit :: Child -> IO ExitCode
waitExit child = do
  code <- waitForProcess child.processHandle
  void (timeout 1000000 (waitCatch child.listener))
  closeChildHandles child
  pure code

ignoreUnit :: SomeException -> IO ()
ignoreUnit _ = pure ()

ignoreList :: SomeException -> IO [CPid]
ignoreList _ = pure []

ignoreMaybe :: SomeException -> IO (Maybe value)
ignoreMaybe _ = pure Nothing
