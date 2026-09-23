module Kenshou.Suite.Kiroku.Fixture.Telemetry
  ( HandlerArm (..),
    handlerArm,
    composeEventHandler,
  )
where

import Kenshou.Core.Dimension (MetricsArm (..), TracingArm (..))
import Kiroku.Metrics (KirokuMetrics, metricsEventHandler)
import Kiroku.Otel.Subscription (subscriptionTraceHandler)
import Kiroku.Store (KirokuEvent)
import OpenTelemetry.Trace.Core (Tracer)

data HandlerArm = HandlerNone | HandlerMetrics | HandlerTrace | HandlerMetricsAndTrace
  deriving stock (Eq, Show)

handlerArm :: TracingArm -> MetricsArm -> HandlerArm
handlerArm tracing metrics = case (tracing /= TracingOff, metrics /= MetricsOff) of
  (False, False) -> HandlerNone
  (False, True) -> HandlerMetrics
  (True, False) -> HandlerTrace
  (True, True) -> HandlerMetricsAndTrace

composeEventHandler :: Maybe KirokuMetrics -> Maybe Tracer -> Maybe (KirokuEvent -> IO ()) -> IO (Maybe (KirokuEvent -> IO ()))
composeEventHandler metrics tracer tap = do
  traceHandler <- traverse subscriptionTraceHandler tracer
  let downstream = combine traceHandler tap
  pure $ case metrics of
    Nothing -> downstream
    Just collector -> Just (metricsEventHandler collector downstream)
  where
    combine Nothing Nothing = Nothing
    combine (Just first) Nothing = Just first
    combine Nothing (Just second) = Just second
    combine (Just first) (Just second) = Just (\event -> first event >> second event)
