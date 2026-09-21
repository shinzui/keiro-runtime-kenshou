module Kenshou.Core.Env.Postgres
  ( PgSettingsSnapshot (..),
    PostgresMode (..),
    StopMode (..),
    ServerControl (..),
    PostgresEnv (..),
    EnvError (..),
    withPostgresEnv,
    withPostgresEnvKeeping,
  )
where

import Control.Exception (finally)
import Control.Monad (unless)
import Data.Aeson (ToJSON (..), object, (.=))
import Data.Char (isAlphaNum)
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Monoid (Last (..))
import Data.Text (Text)
import Data.Text qualified as Text
import EphemeralPg qualified as Pg
import Kenshou.Core.Dimension (Dimensions (..), PgDurability (..), PgVersion (..))
import Kenshou.Core.Env (PostgresRequirement (..))
import Kenshou.Core.Env.Migration (composePlan, migrateDatabase)
import Kenshou.Core.Id (RunId, renderRunId)
import Kenshou.Core.Log (Logger, Severity (Warning), logAt)
import Kenshou.Core.RunSpec (ConnectionSource (..), PostgresSpec (..))
import System.Directory (copyFile, createDirectoryIfMissing, doesFileExist)
import System.Environment (getEnv, lookupEnv, setEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Posix.User (getRealUserID)
import System.Process (readProcessWithExitCode)

data PgSettingsSnapshot = PgSettingsSnapshot
  { serverVersion :: Text,
    serverVersionNum :: Int,
    settings :: Map Text Text,
    superuser :: Bool,
    collation :: Text,
    encoding :: Text
  }
  deriving stock (Eq, Show)

data PostgresMode = PgEphemeral | PgExternal deriving stock (Eq, Show)

data StopMode = StopFast | StopImmediate deriving stock (Eq, Show)

data ServerControl = ServerControl {currentServer :: IO Pg.Database, restartServer :: IO (), stopServer :: StopMode -> IO (), startServer :: IO ()}

data PostgresEnv = PostgresEnv
  { mode :: PostgresMode,
    connectionString :: Text,
    tcpEndpoint :: Maybe (Text, Int),
    adminConnectionString :: Text,
    databaseName :: Text,
    newDatabase :: Text -> IO Text,
    snapshot :: PgSettingsSnapshot,
    control :: Maybe ServerControl
  }

newtype EnvError = EnvError Text deriving stock (Eq, Show)

instance ToJSON PgSettingsSnapshot where
  toJSON snapshot = object ["serverVersion" .= snapshot.serverVersion, "serverVersionNum" .= snapshot.serverVersionNum, "settings" .= snapshot.settings, "superuser" .= snapshot.superuser, "collation" .= snapshot.collation, "encoding" .= snapshot.encoding]

withPostgresEnv :: Logger -> FilePath -> RunId -> PostgresRequirement -> PostgresSpec -> Dimensions -> (PostgresEnv -> IO value) -> IO (Either EnvError value)
withPostgresEnv = withPostgresEnvKeeping False

withPostgresEnvKeeping :: Bool -> Logger -> FilePath -> RunId -> PostgresRequirement -> PostgresSpec -> Dimensions -> (PostgresEnv -> IO value) -> IO (Either EnvError value)
withPostgresEnvKeeping keepEnvironment logger runDirectory runId requirement postgresSpec dimensions action = case postgresSpec of
  PostgresEphemeral extraSettings -> withSelectedBinaries dimensions.pgVersion $ do
    createDirectoryIfMissing True (runDirectory </> "logs")
    uid <- getRealUserID
    let temporaryRoot = "/tmp/ephpg-kenshou-" <> show uid
    createDirectoryIfMissing True temporaryRoot
    let durabilitySettings = case dimensions.pgDurability of
          Just PgDurable -> [("fsync", "on"), ("synchronous_commit", "on"), ("full_page_writes", "on")]
          _ -> [("fsync", "off"), ("synchronous_commit", "off"), ("full_page_writes", "off")]
        settings = [("listen_addresses", "'127.0.0.1'"), ("log_min_messages", "'WARNING'"), ("log_line_prefix", "'%m [%p] %a '"), ("logging_collector", "on"), ("log_directory", "'log'"), ("log_filename", "'postgres.log'")] <> durabilitySettings <> requirement.settings <> extraSettings
        config = Pg.defaultConfig {Pg.databaseName = "kenshou_template", Pg.temporaryRoot = Last (Just temporaryRoot), Pg.postgresSettings = settings}
    started <- Pg.startCached config Pg.defaultCacheConfig
    case started of
      Left err -> pure (Left (EnvError (Text.pack (show err))))
      Right database -> do
        databaseRef <- newIORef database
        let cleanup = do
              current <- readIORef databaseRef
              let postgresLog = current.dataDirectory </> "log" </> "postgres.log"
              exists <- doesFileExist postgresLog
              if exists then copyFile postgresLog (runDirectory </> "logs" </> "postgres.log") else pure ()
              Pg.stop current
        if keepEnvironment
          then setup databaseRef database >>= either (pure . Left) (\environment -> logAt logger Warning "leaving ephemeral PostgreSQL running" [] >> fmap Right (action environment))
          else (setup databaseRef database >>= either (pure . Left) (fmap Right . action)) `finally` cleanup
  PostgresExternal source -> do
    connection <- resolveConnection source
    case connection of
      Left err -> pure (Left err)
      Right maintenanceConnection -> do
        initialSnapshot <- snapshotDatabase maintenanceConnection
        case initialSnapshot >>= validateExternal dimensions of
          Left err -> pure (Left err)
          Right () -> do
            unless (null requirement.settings) $ logAt logger Warning "external PostgreSQL settings cannot be applied" []
            withExternalDatabases keepEnvironment maintenanceConnection runId requirement action
  where
    setup databaseRef database = do
      migration <- migrateIfNeeded (Pg.connectionString database) requirement
      case migration of
        Left err -> pure (Left err)
        Right () -> do
          cloned <- runCommand "createdb" ["-h", database.socketDirectory, "-p", show database.port, "-U", Text.unpack database.user, "-T", "kenshou_template", "kenshou_run"]
          case cloned of
            Left err -> pure (Left err)
            Right () -> do
              let connection = connectionFor database "kenshou_run"
              snapshot <- snapshotDatabase connection
              pure (makeEnvironment databaseRef database connection <$> snapshot)

    makeEnvironment databaseRef database connection snapshot =
      PostgresEnv PgEphemeral connection (Just ("127.0.0.1", fromIntegral database.port)) (Pg.connectionString database) "kenshou_run" (cloneDatabase database) snapshot (Just (serverControl databaseRef))

    cloneDatabase database label = do
      let name = "kenshou_" <> label
      result <- runCommand "createdb" ["-h", database.socketDirectory, "-p", show database.port, "-U", Text.unpack database.user, "-T", "kenshou_template", Text.unpack name]
      either (ioError . userError . show) (const (pure (connectionFor database name))) result

    serverControl databaseRef = ServerControl (readIORef databaseRef) restart stopNow start
      where
        restart = do
          current <- readIORef databaseRef
          Pg.restart current >>= either (ioError . userError . show) (writeIORef databaseRef)
        stopNow mode = do
          current <- readIORef databaseRef
          let modeText = case mode of StopFast -> "fast"; StopImmediate -> "immediate"
          runCommand "pg_ctl" ["-D", current.dataDirectory, "stop", "-m", modeText, "-w"] >>= either (ioError . userError . show) pure
        start = do
          current <- readIORef databaseRef
          Pg.restart current >>= either (ioError . userError . show) (writeIORef databaseRef)

withExternalDatabases :: Bool -> Text -> RunId -> PostgresRequirement -> (PostgresEnv -> IO value) -> IO (Either EnvError value)
withExternalDatabases keepEnvironment maintenanceConnection runId requirement action = do
  counter <- newIORef (0 :: Int)
  created <- newIORef []
  let prefix = Text.take 13 (Text.filter (/= '-') (renderRunId runId))
      templateName = "kenshou_" <> prefix <> "_template"
      runName = "kenshou_" <> prefix
      remember name = modifyIORef' created (name :)
      create name template = do
        result <- psqlUnit maintenanceConnection ("create database " <> name <> maybe "" (" template " <>) template)
        case result of Left err -> pure (Left err); Right () -> remember name >> pure (Right ())
      cleanup = readIORef created >>= mapM_ (\name -> psqlUnit maintenanceConnection ("drop database if exists " <> name <> " with (force)") >> pure ())
      setup = do
        createdTemplate <- create templateName Nothing
        case createdTemplate of
          Left err -> pure (Left err)
          Right () -> do
            let templateConnection = connectionForExternal maintenanceConnection templateName
            migrated <- migrateIfNeeded templateConnection requirement
            case migrated of
              Left err -> pure (Left err)
              Right () -> do
                createdRun <- create runName (Just templateName)
                case createdRun of
                  Left err -> pure (Left err)
                  Right () -> do
                    let runConnection = connectionForExternal maintenanceConnection runName
                    snapshot <- snapshotDatabase runConnection
                    pure $ fmap (externalEnvironment counter created maintenanceConnection templateName runName runConnection) snapshot
  if keepEnvironment
    then setup >>= either (pure . Left) (fmap Right . action)
    else (setup >>= either (pure . Left) (fmap Right . action)) `finally` cleanup

externalEnvironment :: IORef Int -> IORef [Text] -> Text -> Text -> Text -> Text -> PgSettingsSnapshot -> PostgresEnv
externalEnvironment counter created maintenanceConnection templateName runName connection snapshot =
  PostgresEnv PgExternal connection (externalTcpEndpoint maintenanceConnection) maintenanceConnection runName clone snapshot Nothing
  where
    clone label = do
      number <- atomicModifyIORef' counter (\value -> let next = value + 1 in (next, next))
      let safeLabel = Text.map (\character -> if isAlphaNum character then character else '_') label
          name = "kenshou_" <> safeLabel <> "_" <> Text.pack (show number)
      result <- psqlUnit maintenanceConnection ("create database " <> name <> " template " <> templateName)
      case result of
        Left err -> ioError (userError (show err))
        Right () -> modifyIORef' created (name :) >> pure (connectionForExternal maintenanceConnection name)

resolveConnection :: ConnectionSource -> IO (Either EnvError Text)
resolveConnection (ConnLiteral value) = pure (Right value)
resolveConnection (ConnFromEnv name) = maybe (Left (EnvError ("environment variable is not set: " <> name))) (Right . Text.pack) <$> lookupEnv (Text.unpack name)

migrateIfNeeded :: Text -> PostgresRequirement -> IO (Either EnvError ())
migrateIfNeeded _ requirement | null requirement.schemas = pure (Right ())
migrateIfNeeded connection requirement = case composePlan requirement.schemas of
  Left err -> pure (Left (EnvError (Text.pack (show err))))
  Right plan -> fmap (either (Left . EnvError . Text.pack . show) Right) (migrateDatabase connection plan)

connectionFor :: Pg.Database -> Text -> Text
connectionFor database name = Text.unwords ["host=" <> Text.pack database.socketDirectory, "port=" <> Text.pack (show database.port), "dbname=" <> name, "user=" <> database.user]

snapshotDatabase :: Text -> IO (Either EnvError PgSettingsSnapshot)
snapshotDatabase connection = do
  let setting name = psql connection ("show " <> name)
  version <- setting "server_version"
  versionNumber <- setting "server_version_num"
  settingPairs <- traverse (\name -> fmap ((name,) <$>) (setting name)) fingerprintSettings
  collation <- psql connection "select datcollate from pg_database where datname=current_database()"
  encoding <- psql connection "select pg_encoding_to_char(encoding) from pg_database where datname=current_database()"
  superuser <- psql connection "select rolsuper::text from pg_roles where rolname=current_user"
  pure do
    serverVersion <- version
    numberText <- versionNumber
    serverVersionNum <- maybe (Left (EnvError "invalid server_version_num")) Right (readMaybeText numberText)
    resolvedSettings <- sequence settingPairs
    databaseCollation <- collation
    databaseEncoding <- encoding
    isSuperuser <- (== "true") . Text.toCaseFold <$> superuser
    pure (PgSettingsSnapshot serverVersion serverVersionNum (Map.fromList resolvedSettings) isSuperuser databaseCollation databaseEncoding)

fingerprintSettings :: [Text]
fingerprintSettings =
  [ "fsync",
    "synchronous_commit",
    "full_page_writes",
    "wal_level",
    "shared_buffers",
    "effective_cache_size",
    "work_mem",
    "max_connections",
    "checkpoint_timeout",
    "checkpoint_completion_target",
    "max_wal_size",
    "wal_buffers",
    "random_page_cost",
    "autovacuum",
    "shared_preload_libraries"
  ]

validateExternal :: Dimensions -> PgSettingsSnapshot -> Either EnvError ()
validateExternal dimensions snapshot = do
  case dimensions.pgVersion of
    Just Pg17 | snapshot.serverVersionNum < 170000 || snapshot.serverVersionNum >= 180000 -> Left (EnvError "external PostgreSQL does not match pg.version=17")
    Just Pg18 | snapshot.serverVersionNum < 180000 || snapshot.serverVersionNum >= 190000 -> Left (EnvError "external PostgreSQL does not match pg.version=18")
    _ -> Right ()
  let actual name = Text.toCaseFold <$> Map.lookup name snapshot.settings
  case dimensions.pgDurability of
    Just PgFsyncOff | actual "fsync" /= Just "off" || actual "synchronous_commit" /= Just "off" -> Left (EnvError "external PostgreSQL does not match pg.durability=fsync-off")
    Just PgDurable | actual "fsync" /= Just "on" || actual "synchronous_commit" == Just "off" -> Left (EnvError "external PostgreSQL does not match pg.durability=durable")
    _ -> Right ()

psql :: Text -> Text -> IO (Either EnvError Text)
psql connection query = do
  (code, output, err) <- readProcessWithExitCode "psql" ["-d", Text.unpack connection, "-Atqc", Text.unpack query] ""
  pure case code of ExitSuccess -> Right (Text.strip (Text.pack output)); _ -> Left (EnvError (Text.strip (Text.pack err)))

psqlUnit :: Text -> Text -> IO (Either EnvError ())
psqlUnit connection query = fmap (const ()) <$> psql connection query

connectionForExternal :: Text -> Text -> Text
connectionForExternal maintenanceConnection name = maintenanceConnection <> " dbname=" <> name

externalTcpEndpoint :: Text -> Maybe (Text, Int)
externalTcpEndpoint connection = do
  host <- lookupWord "host"
  portText <- lookupWord "port"
  port <- readMaybeText portText
  pure (host, port)
  where
    pairs = [(key, Text.drop 1 rest) | word <- Text.words connection, let (key, rest) = Text.breakOn "=" word, not (Text.null rest)]
    lookupWord key = lookup key pairs

runCommand :: FilePath -> [String] -> IO (Either EnvError ())
runCommand command arguments = do
  (code, _, err) <- readProcessWithExitCode command arguments ""
  pure case code of ExitSuccess -> Right (); _ -> Left (EnvError (Text.strip (Text.pack err)))

withSelectedBinaries :: Maybe PgVersion -> IO (Either EnvError value) -> IO (Either EnvError value)
withSelectedBinaries version action = do
  (original, validation) <- prepare
  case validation of
    Left err -> restore original >> pure (Left err)
    Right () -> action `finally` restore original
  where
    prepare = do
      original <- getEnv "PATH"
      let (variable, expectedMajor) = case version of Just Pg17 -> ("KENSHOU_PG17_BIN", 17 :: Int); _ -> ("KENSHOU_PG18_BIN", 18)
      binaryDirectory <- lookupEnv variable
      maybe (pure ()) (\directory -> setEnv "PATH" (directory <> ":" <> original)) binaryDirectory
      (code, output, err) <- readProcessWithExitCode "postgres" ["--version"] ""
      let versionText = Text.pack output
          matches = (" " <> Text.pack (show expectedMajor) <> ".") `Text.isInfixOf` versionText
          validation = if code == ExitSuccess && matches then Right () else Left (EnvError (Text.pack (variable <> " is unset or does not select PostgreSQL " <> show expectedMajor <> ": " <> err <> output)))
      pure (original, validation)
    restore = setEnv "PATH"

readMaybeText :: (Read value) => Text -> Maybe value
readMaybeText value = case reads (Text.unpack value) of [(parsed, "")] -> Just parsed; _ -> Nothing
