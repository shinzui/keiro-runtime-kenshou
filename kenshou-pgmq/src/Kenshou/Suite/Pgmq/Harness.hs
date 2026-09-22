module Kenshou.Suite.Pgmq.Harness
  ( PgmqRun (..),
    withPgmqRun,
    withPgmqPool,
    scenarioQueueName,
    withScenarioQueue,
    requirePartman,
    runOps,
  )
where

import Control.Exception (bracket, finally)
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Eff, IOE, runEff)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Hasql.Connection.Settings qualified as Connection
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as PoolConfig
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (renderRunId)
import Kenshou.Core.Knob (knobText)
import Kenshou.Core.Scenario (ScenarioReport, failedWith)
import Kenshou.Suite.Pgmq.Knobs
import Kenshou.Suite.Pgmq.Telemetry (withMetricsPoller)
import Kenshou.Telemetry (TelemetryHandles (..), telemetrySpecFromContext, withTelemetry)
import OpenTelemetry.Trace.Core (Tracer)
import Pgmq.Effectful
  ( CreatePartitionedQueue (..),
    Pgmq,
    PgmqRuntimeError,
    QueueName,
    createPartitionedQueue,
    createQueue,
    createUnloggedQueue,
    dropQueue,
    parseQueueName,
    runPgmq,
    runPgmqTraced,
  )
import System.Environment (lookupEnv, setEnv, unsetEnv)

data PgmqRun = PgmqRun
  { ctx :: RunContext,
    knobs :: PgmqKnobs,
    pool :: Pool,
    tracer :: Maybe Tracer,
    telemetry :: TelemetryHandles
  }

withPgmqPool :: PostgresEnv -> Text -> PgmqKnobs -> (Pool -> IO a) -> IO a
withPgmqPool environment role knobs action =
  bracket
    ( Pool.acquire $
        PoolConfig.settings
          [ PoolConfig.size knobs.poolSize,
            PoolConfig.acquisitionTimeout (fromIntegral knobs.acquisitionTimeoutSeconds),
            PoolConfig.staticConnectionSettings (Connection.connectionString environment.connectionString <> Connection.applicationName ("kenshou-pgmq-" <> role))
          ]
    )
    Pool.release
    action

scenarioQueueName :: RunContext -> Text -> QueueName
scenarioQueueName context tag =
  either (error . show) id . parseQueueName $
    Text.take 47 ("kn" <> Text.take 8 (Text.filter (/= '-') (renderRunId context.runId)) <> "_" <> sanitize tag)
  where
    sanitize = Text.map (\character -> if character >= 'a' && character <= 'z' || character >= '0' && character <= '9' then character else '_') . Text.toLower

withScenarioQueue :: Pool -> RunContext -> PgmqKnobs -> Text -> (QueueName -> IO a) -> IO a
withScenarioQueue pool context knobs tag action = do
  let queue = scenarioQueueName context tag
  created <- case knobs.queueKind of
    Standard -> runOps Nothing pool (createQueue queue)
    Unlogged -> runOps Nothing pool (createUnloggedQueue queue)
    Partitioned -> do
      support <- requirePartman pool
      case support of
        Left message -> ioError (userError (Text.unpack message))
        Right () -> runOps Nothing pool (createPartitionedQueue (CreatePartitionedQueue queue "10000" "100000"))
  case created of
    Left err -> ioError (userError (show err))
    Right () -> action queue `finally` cleanup queue
  where
    cleanup queue = do
      _ <- runOps Nothing pool (dropQueue queue)
      pure ()

requirePartman :: Pool -> IO (Either Text ())
requirePartman pool = do
  available <- Pool.use pool partmanAvailable
  case available of
    Left err -> pure (Left (Text.pack (show err)))
    Right False -> pure (Left "pg_partman is not available in this PostgreSQL; add it to the dev shell's PostgreSQL or the cell image")
    Right True -> do
      installed <- Pool.use pool installPartman
      pure (either (Left . Text.pack . show) (const (Right ())) installed)

runOps :: Maybe Tracer -> Pool -> Eff '[Pgmq, Error PgmqRuntimeError, IOE] a -> IO (Either PgmqRuntimeError a)
runOps maybeTracer pool action =
  runEff . runErrorNoCallStack @PgmqRuntimeError $
    maybe (runPgmq pool) (runPgmqTraced pool) maybeTracer action

withPgmqRun :: RunContext -> (PgmqRun -> IO ScenarioReport) -> IO ScenarioReport
withPgmqRun context action = case (resolveKnobs context, telemetrySpecFromContext context) of
  (Left message, _) -> pure (failedWith ["invalid-pgmq-knobs"] message)
  (_, Left message) -> pure (failedWith ["invalid-telemetry"] message)
  (Right knobs, Right telemetrySpec) ->
    withSemconv (knobText context.knobs (knobName "otel.semconv-stability-opt-in")) $
      withTelemetry telemetrySpec \handles ->
        withMetricsPoller handles (requirePostgres context) context $
          withPgmqPool (requirePostgres context) "scenario" knobs \pool ->
            action (PgmqRun context knobs pool handles.tracer handles)

withSemconv :: Text -> IO value -> IO value
withSemconv selected action = bracket capture restore (const configure)
  where
    name = "OTEL_SEMCONV_STABILITY_OPT_IN"
    capture = lookupEnv name
    restore = maybe (unsetEnv name) (setEnv name)
    configure = do
      if selected == "unset" then unsetEnv name else setEnv name (Text.unpack selected)
      action

partmanAvailable :: Session.Session Bool
partmanAvailable =
  Session.statement () $
    Statement.preparable
      "select exists (select from pg_available_extensions where name='pg_partman')"
      Encoders.noParams
      (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.bool)))

installPartman :: Session.Session ()
installPartman =
  Session.statement () $
    Statement.unpreparable
      "create schema if not exists partman; create extension if not exists pg_partman schema partman"
      Encoders.noParams
      Decoders.noResult
