module Kenshou.Check.Selftest.BackendKill (backendKillScenario) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async
import Data.Aeson (object, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Kenshou.Check.Fault (Fault (..), FaultHandle (..))
import Kenshou.Check.Fault.Postgres
import Kenshou.Check.Scenario
import Kenshou.Check.Verdict
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..))
import Kenshou.Core.Env.Postgres (PostgresEnv (..), ServerControl (..), StopMode (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.Process

backendKillScenario :: Scenario
backendKillScenario =
  Scenario
    { id = either (error . show) id (parseScenarioId "selftest/check/concurrency/postgres-backend-kill"),
      revision = 1,
      summary = "Terminates a named PostgreSQL backend and proves acknowledged rows remain durable.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = [],
      dimensions = postgresDimensions (PgFsyncOff :| [PgDurable]) (Pg18 :| [Pg17]) telemetryOff,
      phases = zeroPhases,
      requires = EnvRequirements (Just (PostgresRequirement [] [] True)) [] False,
      knownDefect = Nothing,
      run = runBackendKill
    }

runBackendKill :: RunContext -> IO ScenarioReport
runBackendKill context = withCheck context \environment -> do
  let postgres = requirePostgres context
  sql postgres "create schema if not exists kenshou_selftest; create table if not exists kenshou_selftest.items(id text primary key); insert into kenshou_selftest.items values ('before') on conflict do nothing"
  lockHandle <- (holdLock postgres (TableLock "kenshou_selftest" "items")).inject
  blockedInsert <- async (query postgres "insert into kenshou_selftest.items values ('locked') on conflict do nothing")
  threadDelay 200000
  lockBlocked <- isNothing <$> poll blockedInsert
  lockHandle.heal
  lockReleased <- either (const False) (const True) <$> waitCatch blockedInsert
  sleeper <- spawnSleeper postgres
  threadDelay 300000
  before <- listBackends postgres
  let fault = terminateOneBackend postgres (ByApplicationName "kenshou-selftest-writer")
  handle <- fault.inject
  handle.heal
  _ <- waitForProcess sleeper
  threadDelay 100000
  after <- listBackends postgres
  sql postgres "insert into kenshou_selftest.items values ('after') on conflict do nothing"
  let shouldCrash = context.dimensions.pgDurability == Just PgDurable
  crashRecovered <-
    if shouldCrash
      then case postgres.control of
        Nothing -> pure False
        Just control -> do
          control.stopServer StopImmediate
          control.startServer
          (== "1") <$> query postgres "select 1"
      else pure True
  survived <- query postgres "select count(*) from kenshou_selftest.items where id in ('before','locked','after')"
  now <- getCurrentTime
  let found = any ((== "kenshou-selftest-writer") . (.applicationName)) before
      gone = not (any ((== "kenshou-selftest-writer") . (.applicationName)) after)
      survivedHeld = survived == "3" && crashRecovered
      backendHeld = found && gone
      makeVerdict checker invariant held summary parameters = Verdict checker invariant Contract (if held then Held else Violated) Nothing summary (Map.fromList [("examined", 1), ("violations", if held then 0 else 1)]) parameters [] False [] Nothing now 0
      verdicts =
        [ makeVerdict "acknowledged-writes-survive" "no-loss" survivedHeld "Committed rows survive backend and optional postmaster crashes." (object ["survivingRows" .= survived, "postmasterCrashAttempted" .= shouldCrash, "postmasterRecovered" .= crashRecovered]),
          makeVerdict "writers-recover" "backend-recovery" backendHeld "A client backend was terminated and the database accepted a later write." (object ["victimFound" .= found, "victimGone" .= gone]),
          makeVerdict "lock-blocks-and-releases" "lock-release" (lockBlocked && lockReleased) "An access-exclusive lock blocked a writer and healing released it." (object ["blocked" .= lockBlocked, "released" .= lockReleased]),
          makeVerdict "backends-terminated" "backend-termination" backendHeld "The selected backend disappeared from pg_stat_activity." (object ["victimFound" .= found, "victimGone" .= gone])
        ]
  finishWithVerdicts environment verdicts

spawnSleeper :: PostgresEnv -> IO ProcessHandle
spawnSleeper postgres = do
  inherited <- getEnvironment
  let environment = ("PGAPPNAME", "kenshou-selftest-writer") : filter ((/= "PGAPPNAME") . fst) inherited
  (_, _, _, handle) <- createProcess (proc "psql" ["-d", Text.unpack postgres.connectionString, "-Atqc", "select pg_sleep(30)"]) {env = Just environment, std_out = NoStream, std_err = NoStream}
  pure handle

sql :: PostgresEnv -> Text -> IO ()
sql postgres statement = query postgres statement >> pure ()

query :: PostgresEnv -> Text -> IO Text
query postgres statement = do
  (code, output, err) <- readProcessWithExitCode "psql" ["-d", Text.unpack postgres.connectionString, "-Atqc", Text.unpack statement] ""
  case code of
    ExitSuccess -> pure (Text.strip (Text.pack output))
    ExitFailure _ -> ioError (userError err)

isNothing :: Maybe value -> Bool
isNothing Nothing = True
isNothing (Just _) = False

telemetryOff :: DimensionSupport
telemetryOff = DimensionSupport (Supported (Support (TracingOff :| []) TracingOff)) (Supported (Support (MetricsOff :| []) MetricsOff)) NotApplicable NotApplicable
