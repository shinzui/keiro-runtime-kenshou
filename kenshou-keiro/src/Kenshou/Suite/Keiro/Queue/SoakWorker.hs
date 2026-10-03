module Kenshou.Suite.Keiro.Queue.SoakWorker (role, ProcessReport (..), withProcessWorkers) where

import Control.Concurrent.Async (race)
import Control.Monad (forM)
import Data.Aeson (Value, encode, object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.ByteString.Lazy qualified as LBS
import Data.Functor.Contravariant (contramap)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (liftIO)
import Effectful.Exception qualified as Eff
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Keiro.PGMQ.Codec (aesonJobCodec)
import Keiro.PGMQ.Job (Job (..), JobOrdering (..), JobOutcome (..), JobPolling (..), JobTuning (..), defaultJobTuning, defaultRetryPolicy, jobProcessorWithContext, runJobWorkers)
import Keiro.PGMQ.Runtime (JobRuntime (..), queueRef, runJobEff, withJobRuntime)
import Kenshou.Check.Process (awaitMark, awaitReady, childPid, readChildMessages, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (ArtifactDir (..), RunContext (..), artifactPath, declareMediaType)
import Kenshou.Core.Id (unSeed)
import Kenshou.Core.Knob (knobInt, mkKnobName)
import Kenshou.Core.Role (ControlMessage (..), PostgresConnInfo (..), RoleContext (..), WorkerInit (..), WorkerMessage (..), WorkerRole (..), mkRoleName)
import Kenshou.Diagnose.Leak (LeakReport (..), ProbeReport (..), analyseSeriesDirectory)
import Kenshou.Suite.Keiro.Messaging.SoakDiagnosis (processLeakSpec, soakLeakSpec, withRoleSamples)
import Kenshou.Suite.Keiro.Queue.Metrics qualified as Metrics
import Kenshou.Telemetry (TelemetryHandles (..), telemetrySpecFromWorker)
import Shibuya.App (SupervisionStrategy (..), getAppMaster, stopApp, waitApp)
import Shibuya.Core.Metrics (ProcessorId (..))
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))

data ProcessReport = ProcessReport
  { stopped :: !Bool,
    errors :: !Int,
    workers :: ![Value],
    childLeaks :: ![LeakReport]
  }

roleName :: Text
roleName = "keiro/queue-soak-worker"

role :: WorkerRole
role = WorkerRole (either (error . Text.unpack) id (mkRoleName roleName)) "Runs a continuous soak worker with process-local resources and native telemetry." runWorker

withProcessWorkers :: RunContext -> Text -> IO value -> IO (value, ProcessReport)
withProcessWorkers context queue action = withCheck context \check -> withSupervisor check \supervisor -> do
  children <- forM [0, 1 :: Int] \index -> do
    spec <- roleProcess check roleName index (object ["queue" .= queue])
    child <- spawn supervisor spec
    awaitReady child 10000
    sendCommand child CtlStart
    awaitMark child "started" 10000
    pure child
  value <- action
  exits <- traverse (\child -> stopGracefully supervisor child 30000) children
  messages <- concat <$> traverse readChildMessages children
  let reports = [payload | WrkCustom "finished" payload <- messages]
      reportHeld payload = parseMaybe (withObject "worker report" \fields -> (&&) <$> ((> (0 :: Int)) <$> fields .: "handled") <*> fields .: "metricsMatched") payload == Just True
      healthy = length reports == 2 && all reportHeld reports
      distinct = childPid (head children) /= childPid (children !! 1)
      duration = fromIntegral (knobInt context.knobs (either (error . show) id (mkKnobName "soak.duration-minutes"))) * 60
  leaks <- forM [0, 1 :: Int] \index -> do
    let label = "keiro-queue-soak-worker-" <> show index
    report <- analyseSeriesDirectory context.outDir (processLeakSpec ("children" </> label) (soakLeakSpec context duration)) (unSeed context.seed)
    let named = report {probes = [probe {process = Text.pack label} | probe <- report.probes]}
        file = "leak-" <> label <> ".json"
    path <- artifactPath context DiagnosisDir file
    LBS.writeFile path (encode named)
    declareMediaType context ("diagnosis" </> file) "application/json"
    pure named
  pure (value, ProcessReport (distinct && healthy && all (== ExitSuccess) exits) (length [() | WrkError _ <- messages]) reports leaks)

runWorker :: RoleContext -> IO ()
runWorker context = case (context.init.postgres, parseMaybe (withObject "soak worker" (.: "queue")) context.init.args) of
  (Just postgres, Just queue) -> do
    context.send WrkReady
    context.receive >>= \case
      Just CtlStart -> do
        let label = Text.replace "/" "-" context.init.instanceName
            directory = context.init.outDir </> "children" </> Text.unpack label
            report value = do
              createDirectoryIfMissing True (directory </> "logs")
              LBS.writeFile (directory </> "logs" </> "queue-worker-metrics.json") (encode value)
        spec <- either (fail . Text.unpack) pure (telemetrySpecFromWorker context directory)
        withRoleSamples context $ Metrics.withQueueTelemetryAt directory report spec \telemetry metrics ->
          withJobRuntime postgres.connectionString telemetry.tracer \runtime -> do
            let job = Job label (queueRef queue) (aesonJobCodec @Text) Unordered defaultRetryPolicy
                tuning = defaultJobTuning {polling = PollEvery 0.1, visibilityTimeout = 30, batchSize = 10}
                insert = Statement.preparable "INSERT INTO kenshou_fx.queue_soak_effects (payload, attempts, worker) VALUES ($1, 1, $2) ON CONFLICT (payload) DO UPDATE SET attempts = kenshou_fx.queue_soak_effects.attempts + 1" (contramap fst (Encoders.param (Encoders.nonNullable Encoders.text)) <> contramap snd (Encoders.param (Encoders.nonNullable Encoders.text))) Decoders.noResult
                counts = Statement.preparable "SELECT count(*)::integer, count(*) FILTER (WHERE payload LIKE 'dead:%')::integer FROM kenshou_fx.queue_soak_effects WHERE worker = $1" (Encoders.param (Encoders.nonNullable Encoders.text)) (Decoders.singleRow ((,) <$> Decoders.column (Decoders.nonNullable Decoders.int4) <*> Decoders.column (Decoders.nonNullable Decoders.int4)))
                handler _ payload = do
                  liftIO (Pool.use runtime.runtimePool (Session.statement (payload, label) insert) >>= either (fail . show) pure)
                  pure (if Text.isPrefixOf "dead:" payload then Dead "soak-poison" else Done)
                receiveStop =
                  context.receive >>= \case
                    Just (CtlStop _) -> pure ()
                    Nothing -> fail "queue soak controller disconnected"
                    _ -> receiveStop
            result <- runJobEff runtime do
              started <- runJobWorkers StopAllOnFailure 16 [jobProcessorWithContext tuning job handler]
              case started of
                Left err -> liftIO (fail (show err))
                Right app ->
                  ( liftIO do
                      Metrics.registerWorker telemetry metrics (fromIntegral (knobInt context.init.knobs (either (error . show) id (mkKnobName "metrics.scrape-interval-ms")))) label (getAppMaster app)
                      context.send (WrkCustom "started" (object []))
                      race receiveStop (runJobEff runtime (waitApp app)) >>= \case
                        Left () -> pure ()
                        Right outcome -> fail ("queue soak worker exited before stop: " <> show outcome)
                      snapshot <- Metrics.checkpoint metrics
                      (handled, dead) <- Pool.use runtime.runtimePool (Session.statement label counts) >>= either (fail . show) pure
                      let expected = Map.singleton (ProcessorId label) (Metrics.WorkerCounts (fromIntegral handled) (fromIntegral (handled - dead)) (fromIntegral dead) 0)
                          matched = not telemetry.metricsLive || Metrics.metricsMatch expected snapshot
                      served <- if telemetry.servesEndpoints then Metrics.probeEndpoints metrics "complete" expected else pure True
                      context.send (WrkCustom "finished" (object ["worker" .= label, "handled" .= handled, "dead" .= dead, "metricsMatched" .= (matched && served)]))
                  )
                    `Eff.finally` stopApp app
            either (fail . show) pure result
        context.send (WrkDone Nothing)
      _ -> fail "queue soak worker requires start"
  _ -> fail "queue soak worker requires PostgreSQL and a queue"
