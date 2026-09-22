module Kenshou.Suite.Pgmq.Telemetry (pgmqTracer, withMetricsPoller) where

import Kenshou.Core.Context (RunContext)
import Kenshou.Core.Env.Postgres (PostgresEnv)
import Kenshou.Telemetry (TelemetryHandles (..))
import OpenTelemetry.Trace.Core (Tracer)

pgmqTracer :: TelemetryHandles -> Maybe Tracer
pgmqTracer = (.tracer)

-- The layer-specific poller is introduced with the soak milestone. Keeping the
-- adapter bracket-shaped now lets correctness scenarios compose identically.
withMetricsPoller :: TelemetryHandles -> PostgresEnv -> RunContext -> IO a -> IO a
withMetricsPoller _ _ _ action = action
