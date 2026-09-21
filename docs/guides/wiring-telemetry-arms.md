# Wiring telemetry arms into runtime scenarios

`Kenshou.Telemetry.withTelemetry` owns provider and helper lifecycles. A layer
scenario supplies the resulting `TelemetryHandles` to the component under test;
it must not initialize a global OpenTelemetry provider. The all-off arm still
uses `kenshou-measure`, so measurements never depend on the feature being
measured.

These recipes were checked against the released cohort: Keiro 0.17.0.0,
Kiroku Store 0.8.0.1, Kiroku Metrics 0.1.0.8, Kiroku OTel 0.2.0.8,
Shibuya 0.9.0.3, pgmq-hs 0.6.1.0, and kafka-effectful 0.3.1.0. Their canonical
project references are `mori://shinzui/keiro`, `mori://shinzui/kiroku`,
`mori://shinzui/shibuya`, `mori://shinzui/pgmq-hs`, and
`mori://shinzui/kafka-effectful`.

## Common lifecycle

Resolve `TelemetrySpec` from the run context and wrap the component's complete
lifecycle:

```haskell
case telemetrySpecFromContext context of
  Left message -> pure (failedWith ["invalid-telemetry-config"] message)
  Right spec -> withTelemetry spec \telemetry -> runComponent telemetry
```

Use these handle fields consistently:

- `tracer` is absent only for `telemetry.tracing=off`. The `noop` tracer exists
  but is disabled, allowing the component's traced path to be measured without
  recording spans.
- `tracerProvider` is needed by APIs that inject or extract context themselves.
- `meterProvider` lets a library create instruments under its own
  instrumentation scope. `meter` is scoped to Kenshou and is intended for
  scenario-owned instruments.
- `metricsLive` selects in-process metric collection for `collect`, `serve`, and
  `serve-scraped`.
- `servesEndpoints` selects component HTTP servers for `serve` and
  `serve-scraped`.
- `registerEndpoint` records readiness under `serve` and additionally hands the
  endpoint to the isolated scraper under `serve-scraped`. Calling it under
  `off` or `collect` is a harness error.

Start every component server before registration and keep it alive until the
scenario body ends. Endpoint names must be stable lowercase names containing
letters, digits, and hyphens because they become `series/scrape-<name>.csv`.

## Keiro

Create one `KeiroMetrics` value from a meter scoped with
`keiroInstrumentationLibrary`:

```haskell
mKeiroMetrics <- for telemetry.meterProvider \provider -> do
  meter <- getMeter provider keiroInstrumentationLibrary
  newKeiroMetrics meter
```

Pass `mKeiroMetrics` to every Keiro options record or explicit metrics argument.
Set both `metrics` and `tracer` on `RunCommandOptions` and
`WorkflowRunOptions`. Set `tracer` on `OutboxPublishOptions`. Pass
`telemetry.tracer` to `withConsumerSpan` and `withJobRuntime`; pass the same
tracer to other explicit telemetry arguments. This keeps command, workflow,
outbox, inbox, consumer, and job paths in the same arm.

Keiro's OpenTelemetry instruments use the toolkit's Prometheus reader, so set
`metrics.otel-reader=prometheus` for `serve` and `serve-scraped`. Keiro supports
all four tracing arms and all four metrics arms.

## Kiroku

Kiroku has three separate seams: synchronous event/observation handlers, event
metadata enrichment, and the metrics server. Assemble the complete handler
chain before `withStore`. Wrappers go outside a single leaf fan-out, and no
handler in the chain may block.

The following recipe was compiled as a scratch module against the released
cohort. The leaf lambda can become `composeHandlers` after that helper is
available.

```haskell
withKirokuTelemetry
  :: TelemetryHandles
  -> Text
  -> ((KirokuEvent -> IO ()) -> KirokuEvent -> IO ())
  -> [KirokuEvent -> IO ()]
  -> (KirokuStore -> IO value)
  -> IO value
withKirokuTelemetry telemetry connectionString bridge scenarioHandlers body = do
  storeVar <- newTVarIO Nothing
  metrics <-
    if telemetry.metricsLive
      then Just <$> newKirokuMetricsWith (readPosition storeVar) (readSubscribers storeVar)
      else pure Nothing
  traceHandler <- traverse subscriptionTraceHandler telemetry.tracer
  let leaf event = mapM_ ($ event) (maybeToList traceHandler <> scenarioHandlers)
      metered = maybe leaf (\collector -> metricsEventHandler collector (Just leaf)) metrics
      enrich = telemetry.tracer *> Just (\eventData -> do
        context <- getContext
        case lookupSpan context of
          Nothing -> pure eventData
          Just spanValue -> (`injectTraceContext` eventData) <$> getSpanContext spanValue)
      settings =
        defaultConnectionSettings connectionString
          & #eventHandler .~ Just (bridge metered)
          & #observationHandler .~ fmap (\collector -> metricsObservationHandler collector Nothing) metrics
          & #storeSettings . #enrichEvent .~ enrich
  withStore settings \store -> do
    atomically (writeTVar storeVar (Just store))
    case metrics of
      Just collector | telemetry.servesEndpoints ->
        withMetricsServerWithStore (defaultConfig {port = 0}) collector store [] \server -> do
          let base = "127.0.0.1:" <> Text.pack (show server.serverPort)
          telemetry.registerEndpoint
            (Endpoint "kiroku-prometheus" PrometheusText ("http://" <> base <> "/metrics/prometheus") Nothing)
          telemetry.registerEndpoint
            (Endpoint "kiroku-json" JsonDocument ("http://" <> base <> "/metrics") Nothing)
          telemetry.registerEndpoint
            (Endpoint "kiroku-push" WebSocketPush ("ws://" <> base <> "/ws")
              (Just (object ["type" .= ("subscribe_metrics" :: Text)])))
          body store
      _ -> body store

readPosition :: TVar (Maybe KirokuStore) -> STM GlobalPosition
readPosition storeVar =
  readTVar storeVar >>= maybe (pure (GlobalPosition 0)) (publisherPosition . (.publisher))

readSubscribers :: TVar (Maybe KirokuStore) -> STM Int
readSubscribers storeVar =
  readTVar storeVar >>= maybe (pure 0) (\store -> IntMap.size <$> readTVar (subscribers store.publisher))
```

The `bridge` argument is `id` for a Kiroku-only scenario or
`kirokuEventBridge mKeiroMetrics` when Keiro also consumes the events. Kiroku
supports every tracing and metrics arm.

## Shibuya

Select Shibuya's tracing interpreter from the toolkit tracer:

```haskell
runShibuyaTracing telemetry action = case telemetry.tracer of
  Nothing -> runTracingNoop action
  Just tracer -> runTracing tracer action
```

Shibuya's metrics server does not report an OS-selected port when configured
with port zero, so reserve a port first. Bracket `startMetricsServer` with
`stopMetricsServer`, wait on an HTTP endpoint, then register all three
surfaces:

```haskell
port <- reserveFreePort
bracket
  (startMetricsServer (defaultConfig {port}) (getAppMaster appHandle))
  stopMetricsServer
  \_server -> do
    let base = "127.0.0.1:" <> Text.pack (show port)
    ready <- awaitHttpReady ("http://" <> base <> "/health/live") 10_000
    unless ready (ioError (userError "Shibuya metrics server did not become ready"))
    telemetry.registerEndpoint
      (Endpoint "shibuya-prometheus" PrometheusText ("http://" <> base <> "/metrics/prometheus") Nothing)
    telemetry.registerEndpoint
      (Endpoint "shibuya-json" JsonDocument ("http://" <> base <> "/metrics") Nothing)
    telemetry.registerEndpoint
      (Endpoint "shibuya-push" WebSocketPush ("ws://" <> base <> "/ws")
        (Just (object ["type" .= ("subscribe_all" :: Text)])))
    body
```

Only enter that bracket when `servesEndpoints` is true. Shibuya's internal
counters are always active, so `off` and `collect` have the same component
behavior; they differ only in whether the toolkit has an OpenTelemetry meter.
The layer may declare all four metrics values with that equivalence documented.
Use `wsSlotLeakProbe` for connection cleanup coverage and associate a detected
regression with `mori://shinzui/shibuya/okf/reviews/concepts/REV-9`.

## pgmq-hs

Choose the interpreter at the boundary:

```haskell
runPgmqFor telemetry pool action = case telemetry.tracer of
  Nothing -> runPgmq pool action
  Just tracer -> runPgmqTraced pool tracer action
```

When `tracerProvider` is present, use `sendMessageTraced` for sends and
`readMessageWithContext` for reads so W3C context crosses the queue. Under
`off`, use the corresponding plain operations. pgmq-hs exposes no metrics arm,
so its scenarios declare all four tracing values and only
`telemetry.metrics=off`.

## kafka-effectful

Choose the traced producer and consumer interpreters when `tracer` is present:

```haskell
runProducerFor telemetry properties action = case telemetry.tracer of
  Nothing -> runKafkaProducer properties action
  Just tracer -> runKafkaProducerTraced tracer properties action

runConsumerFor telemetry properties subscription action = case telemetry.tracer of
  Nothing -> runKafkaConsumer properties subscription action
  Just tracer -> runKafkaConsumerTraced tracer properties subscription action
```

The traced interpreters inject and extract W3C context in Kafka headers. Record
ambient `OTEL_SEMCONV_STABILITY_OPT_IN` through the telemetry summary rather
than altering it inside the scenario. kafka-effectful scenarios declare all
four tracing values and only `telemetry.metrics=off` because the package has no
metrics API.

## Dimension support

Keiro and Kiroku declare every tracing and metrics value. Shibuya declares every
value, with `off` and `collect` equivalent for its built-in counters. pgmq-hs
and kafka-effectful declare every tracing value and metrics `off` only. A layer
must not advertise an arm it cannot construct faithfully; the planner can then
reject unsupported matrix cells before starting a run.
