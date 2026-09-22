module Kenshou.Suite.Pgmq.Telemetry (pgmqTracer, withMetricsPoller) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync)
import Control.Exception (SomeException, bracket, try)
import Control.Monad (forever)
import Data.Text qualified as Text
import GHC.Clock (getMonotonicTimeNSec)
import Hasql.Connection.Settings qualified as Connection
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as PoolConfig
import Kenshou.Core.Context (ArtifactDir (SeriesDir), RunContext, artifactPath, declareMediaType)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Suite.Pgmq.Knobs (PgmqKnobs (..), resolveKnobs)
import Kenshou.Telemetry (TelemetryHandles (..), TelemetrySpec (..), telemetrySpecFromContext)
import OpenTelemetry.Trace.Core (Tracer)
import Pgmq.Hasql.Sessions qualified as Sessions
import Pgmq.Hasql.Statements.Types (QueueMetrics (..))
import System.IO (BufferMode (LineBuffering), IOMode (WriteMode), hPutStrLn, hSetBuffering, withFile)

pgmqTracer :: TelemetryHandles -> Maybe Tracer
pgmqTracer = (.tracer)

withMetricsPoller :: TelemetryHandles -> PostgresEnv -> RunContext -> IO a -> IO a
withMetricsPoller handles environment context action
  | not handles.metricsLive = action
  | otherwise = case (resolveKnobs context, telemetrySpecFromContext context) of
      (Left message, _) -> ioError (userError (Text.unpack message))
      (_, Left message) -> ioError (userError (Text.unpack message))
      (Right knobs, Right spec) -> do
        path <- artifactPath context SeriesDir "pgmq-metrics.csv"
        declareMediaType context path "text/csv"
        withMetricsPool environment knobs.acquisitionTimeoutSeconds \pool ->
          withFile path WriteMode \handle -> do
            hSetBuffering handle LineBuffering
            hPutStrLn handle "monotonic_ns,poll_ms,queue,queue_length,visible_length,total_messages,oldest_age_seconds,default_partition_length"
            withAsync (forever (sample handle pool >> threadDelay (spec.scrapeMs * 1000))) (const action)
  where
    sample handle pool = do
      started <- getMonotonicTimeNSec
      result <- try @SomeException (Pool.use pool Sessions.allQueueMetrics)
      ended <- getMonotonicTimeNSec
      let elapsedMs = fromIntegral (ended - started) / 1000000 :: Double
      case result of
        Left exception -> hPutStrLn handle (csv [show ended, show elapsedMs, "<poll-error>", quote (show exception), "", "", "", ""])
        Right (Left usageError) -> hPutStrLn handle (csv [show ended, show elapsedMs, "<pgmq-error>", quote (show usageError), "", "", "", ""])
        Right (Right []) -> hPutStrLn handle (csv [show ended, show elapsedMs, "<none>", "0", "0", "0", "", ""])
        Right (Right metrics) -> mapM_ (writeMetric handle ended elapsedMs) metrics

    writeMetric handle sampledAt elapsedMs metric =
      hPutStrLn handle $
        csv
          [ show sampledAt,
            show elapsedMs,
            quote (Text.unpack metric.queueName),
            show metric.queueLength,
            show metric.queueVisibleLength,
            show metric.totalMessages,
            maybe "" show metric.oldestMsgAgeSec,
            maybe "" show metric.defaultPartitionLength
          ]

    csv = foldr1 (\left right -> left <> "," <> right)
    quote value = '"' : concatMap (\character -> if character == '"' then "\"\"" else [character]) value <> "\""

withMetricsPool :: PostgresEnv -> Int -> (Pool.Pool -> IO a) -> IO a
withMetricsPool environment acquisitionTimeoutSeconds =
  bracket
    ( Pool.acquire $
        PoolConfig.settings
          [ PoolConfig.size 1,
            PoolConfig.acquisitionTimeout (fromIntegral acquisitionTimeoutSeconds),
            PoolConfig.staticConnectionSettings (Connection.connectionString environment.connectionString <> Connection.applicationName "kenshou-pgmq-metrics")
          ]
    )
    Pool.release
