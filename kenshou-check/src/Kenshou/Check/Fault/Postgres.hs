module Kenshou.Check.Fault.Postgres
  ( Backend (..),
    BackendSelector (..),
    LockTarget (..),
    CrashMode (..),
    listBackends,
    terminateBackends,
    terminateOneBackend,
    holdLock,
    hogConnections,
    withApplicationName,
    withStatementTimeout,
    crashPostmaster,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (replicateM)
import Data.Aeson (object, (.=))
import Data.Int (Int32, Int64)
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Check.Fault
import Kenshou.Check.Process (ProcessSpec (..))
import Kenshou.Core.Env.Postgres
import System.Exit (ExitCode (..))
import System.Posix.Signals (sigKILL, signalProcess)
import System.Process

data Backend = Backend
  { pid :: !Int32,
    applicationName :: !Text,
    state :: !Text,
    waitEventType :: !(Maybe Text),
    waitEvent :: !(Maybe Text),
    query :: !Text
  }
  deriving stock (Eq, Show)

data BackendSelector = ByApplicationName Text | ByQueryPattern Text | ByPid Int32 | AllOtherBackends
  deriving stock (Eq, Show)

data LockTarget = TableLock Text Text | RowLock Text Text | AdvisoryLock Int64
  deriving stock (Eq, Show)

data CrashMode = ImmediateShutdown | FastShutdown | KillPostmaster
  deriving stock (Eq, Show)

listBackends :: PostgresEnv -> IO [Backend]
listBackends postgres = do
  output <- psql postgres "SELECT pid, coalesce(application_name,''), coalesce(state,''), coalesce(wait_event_type,''), coalesce(wait_event,''), replace(left(query,200), E'\\t', ' ') FROM pg_stat_activity WHERE datname=current_database() AND pid<>pg_backend_pid() AND backend_type='client backend' ORDER BY pid"
  pure [Backend pid app state (nonEmpty waitType) (nonEmpty waitEvent) query | line <- Text.lines output, [pidText, app, state, waitType, waitEvent, query] <- [Text.splitOn "\x1f" line], Just pid <- [readText pidText]]

terminateBackends :: PostgresEnv -> BackendSelector -> Fault
terminateBackends postgres selector =
  Fault
    { name = "postgres-terminate-backends",
      target = "postgres",
      availability = pure Available,
      inject = do
        victims <- filter (matches selector) <$> listBackends postgres
        mapM_ (\backend -> voidPsql postgres ("SELECT pg_terminate_backend(" <> Text.pack (show backend.pid) <> ")")) victims
        pure (FaultHandle (pure ()) (object ["victims" .= fmap (.pid) victims]))
    }

terminateOneBackend :: PostgresEnv -> BackendSelector -> Fault
terminateOneBackend postgres selector =
  (terminateBackends postgres selector)
    { inject = do
        victims <- take 1 . filter (matches selector) <$> listBackends postgres
        mapM_ (\backend -> voidPsql postgres ("SELECT pg_terminate_backend(" <> Text.pack (show backend.pid) <> ")")) victims
        pure (FaultHandle (pure ()) (object ["victims" .= fmap (.pid) victims]))
    }

holdLock :: PostgresEnv -> LockTarget -> Fault
holdLock postgres target =
  Fault
    { name = "postgres-hold-lock",
      target = "postgres",
      availability = pure Available,
      inject = do
        let sql = "SELECT set_config('application_name','kenshou-fault-lock',false); BEGIN; " <> lockSql target <> "; SELECT pg_sleep(86400)"
        (_, _, _, processHandle) <- createProcess (proc "psql" ["-d", Text.unpack postgres.connectionString, "-v", "ON_ERROR_STOP=1", "-c", Text.unpack sql]) {std_out = NoStream, std_err = NoStream}
        threadDelay 100000
        let heal = voidPsql postgres "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname=current_database() AND application_name='kenshou-fault-lock'" >> void (waitForProcess processHandle)
        pure (FaultHandle heal (object ["target" .= show target]))
    }

hogConnections :: PostgresEnv -> Int -> Fault
hogConnections postgres count =
  Fault
    { name = "postgres-hog-connections",
      target = "postgres",
      availability = pure Available,
      inject = do
        handles <- replicateM count (spawnSleeper postgres)
        pure (FaultHandle (mapM_ killProcess handles) (object ["connections" .= count]))
    }

withStatementTimeout :: Int -> ProcessSpec -> ProcessSpec
withStatementTimeout millis spec = spec {env = upsert "PGOPTIONS" ("-c statement_timeout=" <> show millis) spec.env}

withApplicationName :: Text -> ProcessSpec -> ProcessSpec
withApplicationName applicationName spec = spec {env = upsert "PGAPPNAME" (Text.unpack applicationName) spec.env}

crashPostmaster :: PostgresEnv -> CrashMode -> Fault
crashPostmaster postgres mode =
  Fault
    { name = "postgres-crash-postmaster",
      target = "postgres-postmaster",
      availability = pure (maybe (Unavailable "PostgreSQL environment has no server control") (const Available) postgres.control),
      inject = case postgres.control of
        Nothing -> ioError (userError "PostgreSQL server control unavailable")
        Just control -> do
          control.stopServer (case mode of FastShutdown -> StopFast; _ -> StopImmediate)
          pure (FaultHandle control.startServer (object ["mode" .= show mode]))
    }

matches :: BackendSelector -> Backend -> Bool
matches selector backend = case selector of
  ByApplicationName pattern -> like pattern backend.applicationName
  ByQueryPattern pattern -> like pattern backend.query
  ByPid pid -> backend.pid == pid
  AllOtherBackends -> backend.applicationName /= "kenshou-fault"

like :: Text -> Text -> Bool
like pattern value
  | "%" `Text.isSuffixOf` pattern = Text.dropEnd 1 pattern `Text.isPrefixOf` value
  | otherwise = value == pattern

lockSql :: LockTarget -> Text
lockSql (TableLock schema table) = "LOCK TABLE " <> quote schema <> "." <> quote table <> " IN ACCESS EXCLUSIVE MODE"
lockSql (RowLock schema table) = "SELECT 1 FROM " <> quote schema <> "." <> quote table <> " LIMIT 1 FOR UPDATE"
lockSql (AdvisoryLock key) = "SELECT pg_advisory_xact_lock(" <> Text.pack (show key) <> ")"

quote :: Text -> Text
quote value = "\"" <> Text.replace "\"" "\"\"" value <> "\""

spawnSleeper :: PostgresEnv -> IO ProcessHandle
spawnSleeper postgres = do
  (_, _, _, handle) <- createProcess (proc "psql" ["-d", Text.unpack postgres.connectionString, "-c", "SELECT pg_sleep(86400)"]) {std_out = NoStream, std_err = NoStream}
  pure handle

psql :: PostgresEnv -> Text -> IO Text
psql postgres sql = do
  (code, output, err) <- readProcessWithExitCode "psql" ["-d", Text.unpack postgres.connectionString, "-At", "-F", "\x1f", "-v", "ON_ERROR_STOP=1", "-c", Text.unpack sql] ""
  case code of ExitSuccess -> pure (Text.stripEnd (Text.pack output)); ExitFailure _ -> ioError (userError err)

voidPsql :: PostgresEnv -> Text -> IO ()
voidPsql postgres sql = psql postgres sql >> pure ()

readText :: (Read value) => Text -> Maybe value
readText value = case reads (Text.unpack value) of [(parsed, "")] -> Just parsed; _ -> Nothing

nonEmpty :: Text -> Maybe Text
nonEmpty "" = Nothing
nonEmpty value = Just value

upsert :: (Eq key) => key -> value -> [(key, value)] -> [(key, value)]
upsert key value pairs = (key, value) : filter ((/= key) . fst) pairs

void :: IO value -> IO ()
void action = action >> pure ()

killProcess :: ProcessHandle -> IO ()
killProcess handle = do
  pid <- getPid handle
  maybe (terminateProcess handle) (signalProcess sigKILL) pid
  void (waitForProcess handle)
