module Kenshou.Diagnose.SelfTest.Stall
  ( deadlockedWorkersScenario,
    poolStarvedScenario,
    lockWaiterScenario,
    idleSpinnerScenario,
    healthyProgressScenario,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, waitCatch, withAsync)
import Control.Exception (bracket, finally)
import Control.Monad (forM, forever, replicateM_, void)
import Data.Int (Int32)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as PoolConfig
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Kenshou.Core.Context (ArtifactDir (DiagnosisDir), RunContext (..), artifactPath, requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (ScenarioId, parseScenarioId)
import Kenshou.Core.Knob
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario
import Kenshou.Diagnose.LockGraph (LockGraph (..))
import Kenshou.Diagnose.Pool (PoolStats (..), newPoolObserver)
import Kenshou.Diagnose.Postgres (ActivityRow (..), PostgresSnapshot (..))
import Kenshou.Diagnose.Progress (tick)
import Kenshou.Diagnose.Stall qualified as Stall
import Kenshou.Diagnose.Stall.Types
import Kenshou.Diagnose.Threads (ThreadDump (..), ThreadEntry (..), labelMe)
import System.Directory (doesFileExist)

deadlockedWorkersScenario :: Scenario
deadlockedWorkersScenario = postgresScenario "deadlocked-workers" "Proves that a two-session PostgreSQL deadlock is captured as a cycle." (stallKnobs <> [intKnob "lock.deadlock-timeout-s" "PostgreSQL deadlock timeout" 120 10 600]) runDeadlockedWorkers

poolStarvedScenario :: Scenario
poolStarvedScenario = postgresScenario "pool-starved" "Proves that a saturated pool plus an STM waiter is classified as starvation." (stallKnobs <> [intKnob "pool.size" "Connection-pool size" 2 1 8, intKnob "pool.acquisition-timeout-s" "Pool acquisition timeout" 600 10 3_600]) runPoolStarved

lockWaiterScenario :: Scenario
lockWaiterScenario = postgresScenario "lock-waiter" "Proves that an idle transaction blocking a row waiter is identified." stallKnobs runLockWaiter

idleSpinnerScenario :: Scenario
idleSpinnerScenario = postgresScenario "idle-spinner" "Proves that high query-call rate without progress is classified as idle spin." stallKnobs runIdleSpinner

healthyProgressScenario :: Scenario
healthyProgressScenario = postgresScenario "healthy-progress" "Proves that regular heartbeat progress does not produce a stall capture." stallKnobs runHealthyProgress

postgresScenario :: Text -> Text -> [KnobSpec] -> (RunContext -> IO ScenarioReport) -> Scenario
postgresScenario scenarioName summary knobs run =
  Scenario
    { id = scenarioId ("selftest/diagnose/concurrency/" <> scenarioName),
      revision = 1,
      summary,
      tier = TierSmoke,
      placement = PlaceEither,
      knobs,
      dimensions = postgresDimensions (PgFsyncOff :| [PgDurable]) (Pg17 :| [Pg18]) telemetryOff,
      phases = zeroPhases,
      requires = postgresRequirement,
      knownDefect = Nothing,
      run
    }

runDeadlockedWorkers :: RunContext -> IO ScenarioReport
runDeadlockedWorkers context = do
  let environment = requirePostgres context
      timeoutSeconds = knobInt context.knobs (name "lock.deadlock-timeout-s")
      config = captureConfig context
  withConnection environment.connectionString "kenshou-selftest-deadlock-a" \left ->
    withConnection environment.connectionString "kenshou-selftest-deadlock-b" \right -> do
      expectSession left (sql "CREATE TABLE IF NOT EXISTS diagnose_selftest (id int PRIMARY KEY, v int NOT NULL)")
      expectSession left (sql "TRUNCATE diagnose_selftest")
      expectSession left (sql "INSERT INTO diagnose_selftest VALUES (1,0),(2,0)")
      expectSession left (sql "BEGIN")
      expectSession left (sql ("SET LOCAL deadlock_timeout='" <> showText timeoutSeconds <> "s'"))
      expectSession left (sql "UPDATE diagnose_selftest SET v=v+1 WHERE id=1")
      expectSession right (sql "BEGIN")
      expectSession right (sql ("SET LOCAL deadlock_timeout='" <> showText timeoutSeconds <> "s'"))
      expectSession right (sql "UPDATE diagnose_selftest SET v=v+1 WHERE id=2")
      leftPid <- connectionPid left
      rightPid <- connectionPid right
      Stall.withWatchdog context config \watchdog -> do
        _ <- Stall.newProgress watchdog "deadlock-work" True
        withAsync (labelMe "kenshou:selftest:deadlock-a" >> expectSession left (sql "UPDATE diagnose_selftest SET v=v+1 WHERE id=2")) \leftWorker ->
          withAsync (labelMe "kenshou:selftest:deadlock-b" >> expectSession right (sql "UPDATE diagnose_selftest SET v=v+1 WHERE id=1")) \rightWorker -> do
            report <- finally (threadDelay 750_000 >> Stall.captureNow watchdog "self-test capture") (terminateBackend environment rightPid)
            void (waitCatch leftWorker)
            void (waitCatch rightWorker)
            ignoreSession left (sql "ROLLBACK")
            ignoreSession right (sql "ROLLBACK")
            let exactCycle = any ((== sort [leftPid, rightPid]) . sort) report.snapshot.graph.cycles
                workersPresent = all (unfinishedLabel report) ["kenshou:selftest:deadlock-a", "kenshou:selftest:deadlock-b"]
                failures = ["classification" | report.classification /= Deadlock] <> ["cycle" | not exactCycle] <> ["thread-dump" | not workersPresent]
            pure $ if null failures then passed else failedWith failures (reportText report)

runLockWaiter :: RunContext -> IO ScenarioReport
runLockWaiter context = do
  let environment = requirePostgres context
      config = captureConfig context
  withConnection environment.connectionString "kenshou-selftest-lock-holder" \holder ->
    withConnection environment.connectionString "kenshou-selftest-lock-waiter" \waiter -> do
      expectSession holder (sql "CREATE TABLE IF NOT EXISTS diagnose_selftest (id int PRIMARY KEY, v int NOT NULL)")
      expectSession holder (sql "TRUNCATE diagnose_selftest")
      expectSession holder (sql "INSERT INTO diagnose_selftest VALUES (1,0)")
      expectSession holder (sql "BEGIN")
      expectSession holder (sql "UPDATE diagnose_selftest SET v=v+1 WHERE id=1")
      expectSession waiter (sql "BEGIN")
      holderPid <- connectionPid holder
      Stall.withWatchdog context config \watchdog -> do
        _ <- Stall.newProgress watchdog "lock-work" True
        withAsync (labelMe "kenshou:selftest:lock-waiter" >> expectSession waiter (sql "UPDATE diagnose_selftest SET v=v+1 WHERE id=1")) \waiterThread -> do
          report <- finally (threadDelay (classificationDelayMicros context) >> Stall.captureNow watchdog "self-test capture") (ignoreSession holder (sql "ROLLBACK"))
          void (waitCatch waiterThread)
          ignoreSession waiter (sql "ROLLBACK")
          let activity = maybe [] (\(snapshot :: PostgresSnapshot) -> snapshot.activity) report.snapshot.postgres
              holderIdle = any (\(row :: ActivityRow) -> row.pid == holderPid && row.state == "idle in transaction") activity
              failures = ["classification" | report.classification /= LockWait] <> ["root-blocker" | report.snapshot.graph.roots /= [holderPid]] <> ["holder-state" | not holderIdle]
          pure $ if null failures then passed else failedWith failures (reportText report)

runPoolStarved :: RunContext -> IO ScenarioReport
runPoolStarved context = do
  let environment = requirePostgres context
      poolSize = fromIntegral (knobInt context.knobs (name "pool.size"))
      acquisitionTimeout = fromIntegral (knobInt context.knobs (name "pool.acquisition-timeout-s"))
      connectionSettings = Settings.connectionString environment.connectionString <> Settings.applicationName "kenshou-selftest-pool"
  (observePool, readPool) <- newPoolObserver "selftest" poolSize
  pool <- Pool.acquire $ PoolConfig.settings [PoolConfig.size poolSize, PoolConfig.acquisitionTimeout acquisitionTimeout, PoolConfig.staticConnectionSettings connectionSettings, PoolConfig.observationHandler observePool]
  holders <- forM [1 .. poolSize] \index -> async (labelMe ("kenshou:selftest:pool-holder-" <> show index) >> void (Pool.use pool (sql "DO $$ BEGIN PERFORM pg_sleep(60); END $$")))
  finally
    ( do
        saturated <- awaitSaturation readPool poolSize 50
        if not saturated
          then pure (failedWith ["pool-setup"] "pool did not reach the configured in-use count")
          else do
            waiter <- async (labelMe "kenshou:selftest:pool-waiter" >> void (Pool.use pool (pure ())))
            finally
              ( Stall.withWatchdog context (captureConfig context) \watchdog -> do
                  _ <- Stall.newProgress watchdog "pool-work" True
                  Stall.registerPool watchdog "selftest" readPool
                  threadDelay (classificationDelayMicros context)
                  report <- Stall.captureNow watchdog "self-test capture"
                  stats <- readPool
                  let failures = ["classification" | report.classification /= PoolStarvation] <> ["occupancy" | stats.inUse /= poolSize] <> ["wait-graph" | not (null report.snapshot.graph.cycles)]
                  pure $ if null failures then passed else failedWith failures (reportText report)
              )
              (cancel waiter >> void (waitCatch waiter))
    )
    (terminateApplications environment "kenshou-selftest-pool" >> mapM_ cancel holders >> mapM_ (void . waitCatch) holders >> Pool.release pool)

runIdleSpinner :: RunContext -> IO ScenarioReport
runIdleSpinner context = do
  let environment = requirePostgres context
  withConnection environment.connectionString "kenshou-selftest-idle-spinner" \connection -> do
    expectSession connection (sql "CREATE EXTENSION IF NOT EXISTS pg_stat_statements")
    withAsync (labelMe "kenshou:selftest:idle-spinner" >> forever (void (expectSession connection selectOne))) \spinner ->
      Stall.withWatchdog context (captureConfig context) \watchdog -> do
        _ <- Stall.newProgress watchdog "spin-work" True
        threadDelay 500_000
        report <- Stall.captureNow watchdog "self-test capture"
        cancel spinner
        let rate = report.snapshot.idleSpin.statementCallsPerSecond
            failures = ["classification" | report.classification /= IdleSpin] <> ["statement-rate" | rate < 100 && report.snapshot.idleSpin.cpuCores < 0.5]
        pure $ if null failures then passed else failedWith failures (reportText report)

runHealthyProgress :: RunContext -> IO ScenarioReport
runHealthyProgress context = do
  let deadline = fromIntegral (knobInt context.knobs (name "stall.deadline-s")) :: Double
      config = (captureConfig context) {Stall.pollIntervalSeconds = 0.1, Stall.maxCaptures = 1}
  path <- artifactPath context DiagnosisDir "stall-1.json"
  Stall.withWatchdog context config \watchdog -> do
    progress <- Stall.newProgress watchdog "healthy-work" True
    replicateM_ (ceiling (deadline * 30) :: Int) (tick progress >> threadDelay 100_000)
  captured <- doesFileExist path
  pure $ if captured then failedWith ["false-positive"] "watchdog captured despite continuous progress" else passed

captureConfig :: RunContext -> Stall.WatchdogConfig
captureConfig context =
  Stall.defaultWatchdogConfig
    { Stall.deadlineSeconds = fromIntegral (knobInt context.knobs (name "stall.deadline-s")),
      Stall.pollIntervalSeconds = 100,
      Stall.maxCaptures = 1,
      Stall.onStall = CaptureAndContinue,
      Stall.postgres = Just (requirePostgres context).connectionString,
      Stall.captureStacks = False,
      Stall.spinProbeSeconds = 0.25
    }

classificationDelayMicros :: RunContext -> Int
classificationDelayMicros context =
  (fromIntegral (knobInt context.knobs (name "stall.deadline-s")) * 1_000_000 `div` 2) + 250_000

awaitSaturation :: IO PoolStats -> Int -> Int -> IO Bool
awaitSaturation readPool expected attempts = do
  stats <- readPool
  if stats.inUse == expected
    then pure True
    else
      if attempts <= 0
        then pure False
        else threadDelay 100_000 >> awaitSaturation readPool expected (attempts - 1)

unfinishedLabel :: StallReport -> Text -> Bool
unfinishedLabel report wanted = any matches dump.entries
  where
    dump :: ThreadDump
    dump = report.snapshot.haskellThreads
    matches :: ThreadEntry -> Bool
    matches entry = entry.label == Just wanted && entry.status `notElem` ["finished", "died"]

withConnection :: Text -> Text -> (Connection.Connection -> IO value) -> IO value
withConnection connectionString applicationName = bracket acquire Connection.release
  where
    acquire = Connection.acquire (Settings.connectionString connectionString <> Settings.applicationName applicationName) >>= either (ioError . userError . show) pure

expectSession :: Connection.Connection -> Session.Session value -> IO value
expectSession connection session = Connection.use connection session >>= either (ioError . userError . show) pure

ignoreSession :: Connection.Connection -> Session.Session value -> IO ()
ignoreSession connection session = void (Connection.use connection session)

connectionPid :: Connection.Connection -> IO Int
connectionPid connection = do
  value <- expectSession connection (Session.statement () textPid)
  case reads (Text.unpack value) of
    [(pid, "")] -> pure pid
    _ -> ioError (userError ("invalid PostgreSQL backend pid " <> Text.unpack value))

terminateBackend :: PostgresEnv -> Int -> IO ()
terminateBackend environment pid =
  withConnection environment.connectionString "kenshou-selftest-cleanup" \connection ->
    ignoreSession connection (sql ("DO $$ BEGIN PERFORM pg_terminate_backend(" <> showText pid <> "); END $$"))

terminateApplications :: PostgresEnv -> Text -> IO ()
terminateApplications environment applicationName =
  withConnection environment.connectionString "kenshou-selftest-cleanup" \connection ->
    ignoreSession connection (sql ("DO $$ DECLARE backend record; BEGIN FOR backend IN SELECT pid FROM pg_stat_activity WHERE datname=current_database() AND application_name='" <> applicationName <> "' LOOP PERFORM pg_terminate_backend(backend.pid); END LOOP; END $$"))

textPid :: Statement.Statement () Text
textPid = Statement.unpreparable "SELECT pg_backend_pid()::text" Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.text)))

selectOne :: Session.Session Int32
selectOne = Session.statement () (Statement.unpreparable "SELECT 1" Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int4))))

sql :: Text -> Session.Session ()
sql statement = Session.statement () (Statement.unpreparable statement Encoders.noParams Decoders.noResult)

reportText :: StallReport -> Text
reportText report = "classification=" <> stallClassText report.classification <> ", reasons=" <> Text.intercalate "; " report.reasons

stallKnobs :: [KnobSpec]
stallKnobs = [intKnob "stall.deadline-s" "Seconds without progress before capture" 5 2 60]

postgresRequirement :: EnvRequirements
postgresRequirement = EnvRequirements (Just (PostgresRequirement [] [("shared_preload_libraries", "'pg_stat_statements'")] False)) [] False

telemetryOff :: DimensionSupport
telemetryOff =
  DimensionSupport
    (Supported (Support (TracingOff :| []) TracingOff))
    (Supported (Support (MetricsOff :| []) MetricsOff))
    NotApplicable
    NotApplicable

intKnob :: Text -> Text -> Int -> Int -> Int -> KnobSpec
intKnob knobName summary def low high = KnobSpec (name knobName) summary KnobInt (VInt (fromIntegral def)) (IntRange (fromIntegral low) (fromIntegral high)) []

name :: Text -> KnobName
name = either (error . show) id . mkKnobName

scenarioId :: Text -> ScenarioId
scenarioId = either (error . show) id . parseScenarioId

showText :: (Show value) => value -> Text
showText = Text.pack . show
