module Kenshou.Suite.Keiro.Queue.PollingFaults (scenario, roles) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (waitCatch, withAsync)
import Control.Concurrent.STM (atomically)
import Control.Exception (bracket)
import Control.Monad (when)
import Data.Aeson (encodeFile, object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (diffUTCTime, getCurrentTime)
import Effectful (liftIO)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Keiro.PGMQ.Codec (aesonJobCodec)
import Keiro.PGMQ.Job (Job (..), JobOrdering (..), JobOutcome (..), JobPolling (..), JobTuning (..), defaultJobTuning, defaultRetryPolicy, enqueueBatch, ensureJobQueue, jobProcessorWithContext, runJobWorkers)
import Keiro.PGMQ.Runtime (JobRuntime (..), QueueRef (..), queueRef, runJobEff, withJobRuntime)
import Kenshou.Check.Fault (Fault (..), FaultHandle (..))
import Kenshou.Check.Fault.Network (proxiedConnectionString, resetConnections, withTcpProxy)
import Kenshou.Check.Fault.Postgres (Backend (..), BackendSelector (..), CrashMode (..), LockTarget (..), crashPostmaster, holdLock, listBackends, terminateOneBackend)
import Kenshou.Check.Process (ProgressSnapshot (..), awaitMark, awaitReady, killChild, progress, roleProcess, sendCommand, spawn, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobDouble, knobInt, knobText, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..), RoleContext (..), WorkerInit (args), WorkerMessage (..), WorkerRole (..), mkRoleName)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Messaging.Verdict (recordMessagingCells)
import Kenshou.Suite.Keiro.Outbox.Workload (sourceName)
import Pgmq.Types (queueNameToText)
import Shibuya.App (SupervisionStrategy (..), waitApp)
import System.FilePath ((</>))
import System.Timeout (timeout)

name :: Text -> KnobName
name = either (error . Text.unpack) id . mkKnobName

scenario :: Scenario
scenario =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/queue/concurrency/workers-survive-transient-polling-error"),
      revision = 3,
      summary = "Requires fresh post-fault work, visible app failure and explicit app restart after polling faults.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs =
        [ KnobSpec (name "queue.fault") "Polling fault" KnobText (VText "backend-kill") (OneOf (VText "backend-kill" :| [VText "postmaster-restart", VText "proxy-reset"])) [],
          KnobSpec (name "queue.outage-seconds") "Postmaster downtime: zero for transient control or ten for explicit restart" KnobDouble (VDouble 0) (OneOf (VDouble 0 :| [VDouble 10])) [VDouble 10],
          KnobSpec (name "queue.fault-count") "Number of faults, each followed by new jobs" KnobInt (VInt 5) (IntRange 1 5) [VInt 1],
          KnobSpec (name "queue.polling") "Polling mode" KnobText (VText "poll-every") (OneOf (VText "poll-every" :| [VText "long-poll"])) [],
          KnobSpec (name "queue.supervision") "Supervision strategy" KnobText (VText "stop-all-on-failure") (OneOf (VText "stop-all-on-failure" :| [VText "ignore-failures"])) []
        ],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaPgmq] [] False)},
      knownDefect = Nothing,
      run = runScenario
    }

roles :: [WorkerRole]
roles = [WorkerRole (either (error . Text.unpack) id (mkRoleName "keiro/queue-polling-fault-worker")) "Reports every app exit and restarts only on an explicit command." worker]

worker :: RoleContext -> IO ()
worker context = case parseMaybe (withObject "polling worker" (\o -> (,,,) <$> o .: "queue" <*> o .: "connectionString" <*> o .: "polling" <*> o .: "supervision")) context.init.args of
  Nothing -> fail "invalid polling worker arguments"
  Just (queue, connection, pollingMode, supervision) -> do
    counter <- newIORef (0 :: Int)
    let tuning = defaultJobTuning {visibilityTimeout = 3, polling = if pollingMode == ("long-poll" :: Text) then LongPoll 5 100 else PollEvery 0.1}
        strategy = if supervision == ("ignore-failures" :: Text) then IgnoreFailures else StopAllOnFailure
        job = Job "queue-poll-probe" (queueRef queue) (aesonJobCodec @Text) Unordered defaultRetryPolicy
        insert = Statement.preparable "INSERT INTO kenshou_fx.queue_polling_effects (payload) VALUES ($1)" (Encoders.param (Encoders.nonNullable Encoders.text)) Decoders.noResult
        loop incarnation = do
          result <-
            withAsync
              ( withJobRuntime connection Nothing \runtime -> runJobEff runtime do
                  let handler _ payload = do
                        liftIO do
                          Pool.use runtime.runtimePool (Session.statement payload insert) >>= either (fail . show) pure
                          completed <- atomicModifyIORef' counter (\value -> (value + 1, value + 1))
                          now <- getCurrentTime
                          context.send (WrkProgress (fromIntegral completed) now)
                        pure Done
                  started <- runJobWorkers strategy 16 [jobProcessorWithContext tuning job handler]
                  case started of
                    Left err -> liftIO (fail (show err))
                    Right app -> do
                      liftIO (context.send (WrkCustom ("running-" <> Text.pack (show incarnation)) (object [])))
                      waitApp app
              )
              waitCatch
          context.send (WrkCustom ("app-exited-" <> Text.pack (show incarnation)) (object ["incarnation" .= incarnation, "result" .= show result]))
          context.receive >>= \case
            Just (CtlCustom "restart-app" _) -> loop (incarnation + 1)
            _ -> pure ()
    context.send WrkReady
    context.receive >>= \case Just CtlStart -> loop (0 :: Int); _ -> pure ()

-- Each fault has its own fresh batch. A passing warm-up cannot stand in for
-- recovery from the final fault.
runScenario :: RunContext -> IO ScenarioReport
runScenario context = do
  let postgres = requirePostgres context
      faultMode = knobText context.knobs (name "queue.fault")
      outage = knobDouble context.knobs (name "queue.outage-seconds")
      faultCount = fromIntegral (knobInt context.knobs (name "queue.fault-count")) :: Int
      pollingMode = knobText context.knobs (name "queue.polling")
      supervision = knobText context.knobs (name "queue.supervision")
      expectExit = outage >= 10
      queue = sourceName context "polling-v3"
      job = Job "queue-poll-probe" (queueRef queue) (aesonJobCodec @Text) Unordered defaultRetryPolicy
      table = "q_" <> queueNameToText job.jobQueue.physicalName
      payloads batch = [Text.pack (show index) | index <- [batch * 20 + 1 .. batch * 20 + 20 :: Int]]
      query :: Statement.Statement () a -> IO a
      query statement = withJobRuntime postgres.connectionString Nothing \runtime -> Pool.use runtime.runtimePool (Session.statement () statement) >>= either (fail . show) pure
      effects = query (Statement.preparable "SELECT payload FROM kenshou_fx.queue_polling_effects ORDER BY id" Encoders.noParams (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.text))))
      depth = query (Statement.preparable ("SELECT count(*) FROM pgmq." <> table) Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8))))
      enqueueItems items = withJobRuntime postgres.connectionString Nothing \runtime -> runJobEff runtime (enqueueBatch job items) >>= either (fail . show) (const (pure ()))
      waitBatch batch = do
        rows <- effects
        remaining <- depth
        if Set.fromList (concatMap payloads [0 .. batch]) `Set.isSubsetOf` Set.fromList rows && remaining == 0 then getCurrentTime else threadDelay 20000 >> waitBatch batch
  when (faultMode /= "postmaster-restart" && outage /= 0) (fail "outage-seconds applies only to postmaster-restart")
  endpoint <- maybe (fail "PostgreSQL TCP endpoint unavailable") (\(host, port) -> pure (Text.unpack host, fromIntegral port)) postgres.tcpEndpoint
  withJobRuntime postgres.connectionString Nothing \runtime -> do
    Pool.use runtime.runtimePool (Session.script "CREATE SCHEMA IF NOT EXISTS kenshou_fx; CREATE TABLE kenshou_fx.queue_polling_effects (id bigserial PRIMARY KEY, payload text NOT NULL)") >>= either (fail . show) pure
    runJobEff runtime (ensureJobQueue job) >>= either (fail . show) pure
  withTcpProxy (pure endpoint) \proxy -> withCheck context \check -> withSupervisor check \supervisor -> do
    let connection = (if faultMode == "proxy-reset" then proxiedConnectionString postgres proxy else postgres.connectionString) <> " application_name=kenshou_polling_fault_worker"
    child <- roleProcess check "keiro/queue-polling-fault-worker" 0 (object ["queue" .= queue, "connectionString" .= connection, "polling" .= pollingMode, "supervision" .= supervision]) >>= spawn supervisor
    awaitReady child 10000
    sendCommand child CtlStart
    awaitMark child "running-0" 30000
    enqueueItems (payloads 0)
    warmup <- timeout 10000000 (waitBatch 0)
    let exited incarnation snapshot = Map.member ("app-exited-" <> Text.pack (show incarnation)) snapshot.marks
        waitExitMark incarnation = do
          snapshot <- atomically (progress child)
          if exited incarnation snapshot then pure True else threadDelay 20000 >> waitExitMark incarnation
        waitBlocked = do
          backends <- listBackends postgres
          case [backend | backend <- backends, backend.applicationName == "kenshou_polling_fault_worker", backend.waitEventType == Just "Lock", "pgmq.read" `Text.isInfixOf` backend.query] of
            backend : _ -> pure backend
            [] -> threadDelay 20000 >> waitBlocked
        steps incarnation batch
          | batch > faultCount = pure ([], incarnation)
          | otherwise = do
              startedAt <- getCurrentTime
              (victim, injected) <- bracket (holdLock postgres (TableLock "pgmq" table)).inject (.heal) \_ -> do
                blocked <- timeout 10000000 waitBlocked
                injected <- case blocked of
                  Nothing -> pure False
                  Just backend -> case faultMode of
                    "proxy-reset" -> (> 0) <$> resetConnections proxy
                    "postmaster-restart" -> bracket (crashPostmaster postgres FastShutdown).inject (.heal) (\_ -> threadDelay (floor (outage * 1000000))) >> pure True
                    _ -> (terminateOneBackend postgres (ByPid backend.pid)).inject >> pure True
                pure (blocked, injected)
              healedAt <- getCurrentTime
              observedExit <- if expectExit then maybe False id <$> timeout 5000000 (waitExitMark incarnation) else exited incarnation <$> atomically (progress child)
              next <-
                if expectExit && observedExit
                  then do
                    sendCommand child (CtlCustom "restart-app" (object []))
                    awaitMark child ("running-" <> Text.pack (show (incarnation + 1))) 30000
                    pure (incarnation + 1)
                  else pure incarnation
              enqueueItems (payloads batch)
              recoveredAt <- timeout 5000000 (waitBatch batch)
              rows <- effects
              snapshot <- atomically (progress child)
              let stillRunning = not (exited next snapshot)
                  recovered = recoveredAt /= Nothing && stillRunning
                  timely = maybe False (\stamp -> diffUTCTime stamp healedAt <= 5) recoveredAt
                  expectedLifecycle = if expectExit then observedExit && next == incarnation + 1 else not observedExit && next == incarnation
                  observation = object ["batch" .= batch, "victimPid" .= fmap (.pid) victim, "victimQuery" .= fmap (.query) victim, "victimWait" .= fmap (.waitEventType) victim, "injected" .= injected, "startedAt" .= startedAt, "healedAt" .= healedAt, "recoveredAt" .= recoveredAt, "effectsAfter" .= rows, "appExited" .= observedExit, "restarted" .= (next /= incarnation), "stillRunning" .= stillRunning]
              (rest, finalIncarnation) <- if injected && recovered then steps next (batch + 1) else pure ([], next)
              pure ((observation, injected, recovered && timely && expectedLifecycle) : rest, finalIncarnation)
    (observations, incarnation) <- if warmup /= Nothing then steps (0 :: Int) 1 else pure ([], 0)
    rows <- effects
    remaining <- depth
    snapshot <- atomically (progress child)
    killChild supervisor child
    let allPayloads = concatMap payloads [0 .. length observations]
        injected = length [() | (_, True, _) <- observations]
        cells = [("faults-injected", length observations == faultCount && injected == faultCount), ("processing-resumed", warmup /= Nothing && length observations == faultCount && all (\(_, _, recovered) -> recovered) observations && not (exited incarnation snapshot)), ("no-loss", Set.fromList rows == Set.fromList allPayloads && remaining == 0), ("bounded-duplicates", length rows - Set.size (Set.fromList rows) <= injected)]
    encodeFile (context.outDir </> "logs/queue-polling-observations.json") (object ["schema" .= ("kenshou.queue-polling-observations/v1" :: Text), "fault" .= faultMode, "outageSeconds" .= outage, "faultCount" .= faultCount, "polling" .= pollingMode, "supervision" .= supervision, "warmupCompletedAt" .= warmup, "faults" .= [raw | (raw, _, _) <- observations], "effects" .= rows, "queueDepth" .= (remaining :: Int64), "appExitedAtEnd" .= exited incarnation snapshot])
    recordMessagingCells context (Map.fromList [("enqueued", fromIntegral (length allPayloads)), ("effects", fromIntegral (length rows)), ("distinctEffects", fromIntegral (Set.size (Set.fromList rows))), ("faults", fromIntegral injected)]) (object ["fault" .= faultMode, "faultResults" .= [raw | (raw, _, _) <- observations]]) cells
