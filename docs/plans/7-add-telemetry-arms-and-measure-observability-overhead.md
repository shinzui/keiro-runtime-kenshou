---
id: 7
slug: add-telemetry-arms-and-measure-observability-overhead
title: "Add telemetry arms and measure observability overhead"
kind: exec-plan
created_at: 2026-09-20T17:15:35Z
intention: "intention_01m2zvy0gje40tdsdragvzr3tq"
master_plan: "docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-20T17:15:35Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-20T21:08:38Z
      mode: "update"
      note: "Adopted relevant Haskell Jitsurei CLI patterns and the bounded Settei configuration contract."
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-21T20:51:29Z
      mode: "implement"
      note: "Started implementation against the completed kernel, measurement, and diagnostics APIs."
---

# Add telemetry arms and measure observability overhead

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

The keiro runtime (the cohort of Haskell libraries `pgmq-hs`, `kiroku`, `shibuya`, its adapters, `kafka-effectful` and `keiro`) ships with OpenTelemetry tracing hooks, OpenTelemetry metric instruments, and two HTTP metrics servers (`kiroku-metrics` and `shibuya-metrics`). Services that are about to adopt the runtime will switch all of that on. The platform owner wants three answers before they do: what the tracing infrastructure costs, whether it causes problems of its own (stalls, leaks, lost spans, blocked shutdowns, broken traces), and what the various metrics endpoints cost when they are merely up and when they are being scraped.

After this plan, every scenario in this repository can be run under any combination of two cross-cutting switches, called dimensions: `telemetry.tracing` (`off`, `noop`, `sdk-inmemory`, `sdk-otlp`) and `telemetry.metrics` (`off`, `collect`, `serve`, `serve-scraped`). A scenario author writes one call, `Kenshou.Telemetry.withTelemetry`, receives a `Maybe Tracer`, a `Maybe Meter` and an endpoint registrar, and hands them to the component under test. A maintainer can then run one command,

```bash
kenshou overhead selftest/telemetry/benchmark/arms-on-synthetic-service \
  --arms tracing=off,noop,sdk-otlp --arms metrics=off,serve-scraped --out runs/ep7
```

and receive a `kenshou.overhead-report/v1` document that states, per arm and against the all-off baseline, the change in throughput, median and 99th-percentile latency, allocation per operation, garbage-collection share and CPU per operation, each with a confidence interval and a verdict judged against the budgets in `policies/telemetry-overhead.json`. The same run directories carry `series/scrape-*.csv` (latency and body size of every scrape) and a `telemetry` section that accounts for every span: how many ended, how many the exporter delivered, how many failed, how many were dropped, how long flush and shutdown took. Detectors turn those numbers into findings such as "18 % of spans were dropped, so this arm is cheaper than production would be" or "the event handler ran for 5 ms on the emitting thread".

Because latency and throughput are recorded in-process by the measurement toolkit and written to files, a run with every telemetry dimension `off` is still fully measured. That rule is what makes an "off" arm possible at all, and this plan records it as an architecture decision.


## Progress

Milestone 1 — Tracing arms

- [x] (2026-09-21 20:55Z) Verified the completed kernel and measurement APIs and recorded the concrete extension names below.
- [x] (2026-09-21 20:55Z) Confirmed the OpenTelemetry release against Hackage and upstream tags; added the missing `hs-opentelemetry-exporter-prometheus` and `hs-opentelemetry-otlp` 1.0.0.0 pins to both cohorts.
- [x] (2026-09-21 21:00Z) Created the `kenshou-telemetry` package skeleton, test suite, Cabal file, and manual `otlp-grpc` flag.
- [x] (2026-09-21 21:00Z) Implemented `Kenshou.Telemetry.Spec` with the shared knobs, resolved arm specification, cross-knob validation, and explicit gRPC feature rejection.
- [x] (2026-09-21 21:38Z) Implemented `Kenshou.Telemetry.Tracing`, `.Tracing.Probe` and `.Tracing.Pipeline`, including bounded retention and queue high-water accounting.
- [x] (2026-09-21 21:38Z) Implemented `Kenshou.Telemetry.Sink` and registered the worker role `selftest/telemetry-otlp-sink` under the kernel's required layer-qualified role naming contract.
- [x] (2026-09-21 21:38Z) Implemented `Kenshou.Telemetry.withTelemetry` for the four tracing arms, with timed flush and shutdown and the built-in sink isolated in a worker process.
- [x] (2026-09-21 21:38Z) Implemented the synthetic service and `selftest/telemetry/benchmark/arms-on-synthetic-service` (tracing part); registered the self-test bundle.
- [x] (2026-09-21 21:38Z) Added unit coverage for arms, propagation, probe bounds, exact failure accounting, non-blocking queue saturation, and plain/gzip OTLP; ran the scenario successfully under all four tracing arms.

Milestone 2 — Metrics arms and the harness scraper

- [x] (2026-09-21 22:28Z) Implemented `Kenshou.Telemetry.Metrics` with explicit providers, Prometheus exposition, final collection, and the periodic OTLP reader.
- [x] (2026-09-21 22:28Z) Implemented `Kenshou.Telemetry.Endpoint` with the endpoint contract, free-port reservation, and readiness polling.
- [x] (2026-09-21 22:28Z) Implemented the fixed-schedule HTTP scraper, WebSocket subscribers, slot-leak probe, and the isolated `selftest/telemetry-scraper` worker role.
- [x] (2026-09-21 22:28Z) Wrote line-flushed HTTP and WebSocket series and per-endpoint latency, body-size, failure, and skipped-tick summaries.
- [x] (2026-09-21 22:28Z) Extended the synthetic service and exercised off, collect, serve, serve-scraped, and periodic-OTLP configurations.
- [x] (2026-09-21 22:28Z) Wrote `docs/guides/wiring-telemetry-arms.md`; compiled its Kiroku recipe against the released cohort in a disposable scratch package.

Milestone 3 — The paired overhead protocol and `kenshou overhead`

- [ ] Implement `Kenshou.Telemetry.Overhead` (`planOverhead`, `executeOverhead`, `analyseOverhead`) and `.Overhead.Policy`.
- [ ] Add `policies/telemetry-overhead.json` and `schemas/kenshou.overhead-report.v1.schema.json` with golden fixtures.
- [ ] Add the `overhead` subcommand to `kenshou-cli`, with exit codes and `--resume`.
- [ ] Reconcile the comparison's compatibility-key check with varied telemetry factors.
- [ ] Run the headline command end to end and keep the transcript in this plan.

Milestone 4 — Detectors for telemetry-induced problems

- [ ] Implement `Kenshou.Telemetry.Compose` (`composeHandlers`, `timedHandler`, `slowHandler`, `asyncHandler`).
- [ ] Implement `Kenshou.Telemetry.Continuity` (trace continuity and context isolation).
- [ ] Implement `Kenshou.Telemetry.Detect` and `series/otel-pipeline.csv`; fold findings into the `telemetry` section and into overhead verdicts.
- [ ] Implement `selftest/telemetry/correctness/trace-continuity` and `selftest/telemetry/concurrency/slow-exporter-backpressure`.
- [ ] Wire the per-arm leak check hook to `kenshou-diagnose` if `docs/plans/6-build-the-diagnostics-toolkit-for-memory-leaks-and-concurrency-stalls.md` is complete; otherwise leave this item open with a note.
- [ ] Write the ADR "Results are recorded through a channel independent of the feature under test" and run strict validation.
- [ ] Distil the Decision Log into `docs/adr/`, update the MasterPlan's Progress and registry status.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The local Mori checkout has post-release OpenTelemetry changes in the OTLP modules. The exact Hackage 1.0.0.0 source has the older monolithic `OTLPExporterConfig`, so the implementation follows that released record after checking the upstream release tag. The compiled end-to-end exporter test protects this release-specific seam.

- With the selected WAI release, `lazyRequestBody` yielded an empty OTLP request body while `strictRequestBody` returned the protobuf payload. The initial exporter-side counters therefore reported success while the sink decoded zero spans; the end-to-end plain/gzip tests now catch that false-success mode.

- The scraper initially caught `SomeException` around `httpLbs`, which also caught the asynchronous exception used to cancel its worker. The test teardown exposed the resulting immortal loop. The scraper now rethrows `SomeAsyncException` and records only synchronous request failures.

- The plan's draft adapter recipe used `/ws/metrics` for both runtime servers. The released Kiroku Metrics 0.1.0.8 and Shibuya Metrics 0.9.0.3 sources expose `/ws`; Shibuya's subscription message is `subscribe_all`, while Kiroku's is `subscribe_metrics`. The compiled guide records those released interfaces.


## Decision Log

- Decision: Reconcile the drafted names to the delivered kernel as follows: telemetry dimensions are `TracingArm` and `MetricsArm` inside `Dimensions`; scenario knobs are read with `knobText`, `knobInt`, and `knobDouble` from `RunContext.knobs`; summaries use `putSummary context Telemetry`; phases use `withPhase`; worker input arrives through `RoleContext.init` and `RoleContext.receive`; and the toolkit registers one `LayerBundle` in `Kenshou.Cli.Registry.bundles`.
  Rationale: These are the compiled APIs delivered by EP-2 and EP-4. Recording them here keeps the remaining implementation and later coverage plans aligned with the actual extension seam.
  Date: 2026-09-21

- Decision: `kenshou-telemetry` depends on no runtime library (no keiro, kiroku, shibuya, pgmq or Kafka package). It provides generic handles and helpers; the component-specific wiring is written down as recipes in `docs/guides/wiring-telemetry-arms.md` and implemented inside each layer package.
  Rationale: A toolkit that imports keiro would break whenever a head cohort changes a keiro signature and would make every layer rebuild on any runtime change. The recipes are ten to twenty lines each. It also keeps the self-tests free of PostgreSQL.
  Date: 2026-09-20

- Decision: Tracer and meter providers are built explicitly with `createTracerProvider` and `createMeterProvider`, never with `initializeGlobalTracerProvider`, and the global provider is never set.
  Rationale: The global initialiser reads `OTEL_*` environment variables, so an ambient variable on a developer machine or a cell would silently change what an arm measures. Every setting comes from a knob and is recorded in the run specification. Ambient `OTEL_*` variables are recorded in the telemetry summary because some libraries read `OTEL_SEMCONV_STABILITY_OPT_IN` on every operation.
  Date: 2026-09-20

- Decision: The `sdk-inmemory` arm uses a bounded probe written here, not upstream's `inMemoryListExporter`.
  Rationale: The upstream exporter appends every span to an `IORef` list for ever. In a soak that is a leak created by the harness, and it would be blamed on tracing. The probe keeps counters for everything and retains only the most recent `otel.inmemory.retain` spans.
  Date: 2026-09-20

- Decision: The default OTLP sink is a null sink built into the `kenshou` binary and run as a child process (`kenshou worker --role telemetry-otlp-sink`); an external collector is selected with the knob `otel.endpoint`. The scraper also runs as a child process (`telemetry-scraper`).
  Rationale: A sink or a scraper inside the measured process would charge the client half of the conversation to the arm, which production does not pay. A built-in sink needs no extra software, counts what it receives (an end-to-end check on the exporter), and can misbehave on demand (delay, 503, hang, refuse), which is how "does tracing cause problems when the collector is slow or down" becomes testable. Jaeger through `process-compose.override.yaml` remains available for a human who wants to look at traces.
  Date: 2026-09-20

- Decision: `otel.exporter=grpc` is declared but only usable when `kenshou-telemetry` is built with the cabal flag `otlp-grpc`; the default build rejects it during knob validation.
  Rationale: In `hs-opentelemetry-exporter-otlp` 1.0.0.0 gRPC sits behind a manual, default-off flag `grpc` that pulls in `grapesy`. Forcing that into the cohort for every build is not justified; HTTP/protobuf is what the runtime's documentation and example applications use.
  Date: 2026-09-20

- Decision: `kenshou overhead` runs every arm as a fresh child process (`kenshou run`), in blocks that contain each arm once, with the order inside successive blocks counterbalanced, and a block with a failed run is discarded whole.
  Rationale: A fresh process removes heap and scheduler carry-over between arms. Interleaved blocks cancel slow drifts such as PostgreSQL checkpoints, which the old GCP harness measured as the dominant noise source. Discarding whole blocks keeps the pairing balanced.
  Date: 2026-09-20

- Decision: The overhead library is split into `planOverhead`, `executeOverhead` and `analyseOverhead`, and this plan does not emit a `kenshou.run-plan/v1`.
  Rationale: The run-plan format belongs to `docs/plans/3-plan-and-select-runs-from-what-changed.md`, which is not a dependency of this plan. The split lets `docs/plans/17-run-kenshou-on-leased-cells-with-payloads-submission-and-retrieval.md` ship the planned slots to a cell as a run plan and call `analyseOverhead` on what comes back.
  Date: 2026-09-20

- Decision: An arm whose spans were dropped or whose exports failed beyond a small fraction turns its comparison verdict into `inconclusive`.
  Rationale: Dropped spans are work the arm did not do, so the measured overhead understates the real one. Reporting `pass` would be wrong, and `regression` would blame the wrong thing.
  Date: 2026-09-20

- Decision: The initial budgets in `policies/telemetry-overhead.json` are provisional round numbers.
  Rationale: Nothing has ever measured these costs on this runtime. The budgets exist so that the machinery has something to judge against; they are to be tightened from the first recorded cell runs, and that change is a policy-file commit, not a code change.
  Date: 2026-09-20

- Decision: One extra series file, `series/otel-pipeline.csv`, is added beside `series/scrape-*.csv`.
  Rationale: Queue growth can only be seen over time, and the diagnostics toolkit fits slopes to series files. The MasterPlan lists `series/*.csv` as shared between the measurement toolkit and this plan and names `scrape-*.csv` as an example; the new file is reported to the MasterPlan owner as a small extension.
  Date: 2026-09-20


- Decision: Register `overhead` in the Execution command group and compose its dense option surface from the shared intent-based groups, with policy documents using EP-2's explicit `-` input convention.
  Rationale: Although the command produces a comparison, it primarily schedules and executes fresh workload arms. Reusing the CLI contract keeps its completion, help and JSON channel behavior aligned without introducing a second telemetry-specific interaction framework.
  Date: 2026-09-20


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

Milestone 1 is complete. The four tracing arms are registered and exercised through the CLI. A short controlled run produced measurements under every arm; the SDK in-memory arm ended and retained/accounted for 2,968 spans with zero drops, and the SDK OTLP arm exported 2,920 spans in eight requests with the worker sink independently receiving all 2,920. The off and noop arms produced measurements without a pipeline. The worker's stderr artifact was empty, and the telemetry summary records ambient `OTEL_*` variables without allowing them to configure the explicit provider.

Milestone 2 is complete. In the ten-second acceptance run, each HTTP endpoint produced ten successful non-empty scrapes, the WebSocket series recorded two connects and 202 frames, and all three endpoints appeared in the telemetry summary. The serve arm recorded the same endpoints without scrape files; collect recorded two live instruments and opened no endpoints; off constructed no metric provider. A periodic-OTLP collect run sent three metric requests to the isolated sink. Unit tests cover slow-endpoint tick skipping and distinguish an exhausted WebSocket-slot server from a correct server. The Kiroku adapter recipe compiled against Kiroku Store 0.8.0.1, Kiroku Metrics 0.1.0.8, and Kiroku OTel 0.2.0.8.


## Context and Orientation

This repository, `keiro-runtime-kenshou`, is a verification suite for the keiro runtime. At the time this plan was written it contained only `README.md`, `mori.dhall`, planning documents under `docs/`, and agent skills; there was no Haskell code. This plan is the seventh of nineteen child plans of `docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md`. It can start only after two others are complete, and it must check their results rather than assume them.

`docs/plans/1-bootstrap-the-kenshou-repository-and-pin-the-runtime-cohort.md` delivers the Nix development shell (GHC 9.12.4, cabal 3.16, fourmolu, cabal-gild, `just`, `jq`, `okf`), one cabal project whose `cabal.project` matches packages with the glob `kenshou-*/*.cabal` (so a new package is added by creating its directory and nothing else), the pinned cohort files `cohort/released.project` and `cohort/head.project`, and the ADR bundle `docs/adr/` with its `profile.dhall`. A cohort is the exact set of runtime package versions a build links.

`docs/plans/2-build-the-harness-kernel-for-scenarios-dimensions-run-specs-and-results.md` delivers `kenshou-core` and `kenshou-cli`. A scenario is a value with the identifier `<layer>/<component>/<kind>/<name>`, a cost tier (`smoke` under one minute, `standard` under ten, `extended` under an hour, `soak` hours), a placement (`local`, `cell`, `either`), a list of knobs (`KnobSpec`: name, type, default, allowed values), a declaration of which dimension values it supports, and a `run :: RunContext -> IO ScenarioReport` function. The `RunContext` gives the resolved knobs and dimensions, the seed, the output directory, a logger, phase markers (warm-up, steady, drain) and a place to register opaque JSON summary sections named `measurements`, `verdicts`, `diagnosis` and `telemetry`; this plan fills `telemetry`. Each package that contributes scenarios exports a `LayerBundle` (layer, scenarios, worker roles), and `kenshou-cli/src/Kenshou/Cli/Registry.hs` is the single list of bundles. A worker role is a named entry point that the same `kenshou` binary runs as a child process through the hidden subcommand `kenshou worker --role <name>`. A run writes a directory `<out>/<run-id>/` containing `run-spec.json`, `run-result.json`, `manifest.json`, `samples/`, `series/`, `verdicts/`, `diagnosis/` and `logs/`; a later run never writes into an earlier run's directory. Outcomes are `passed`, `failed`, `errored`, `inconclusive` and `infrastructure-failure`; the process exit codes are 0 for passed or pass, 1 for failed or regression, 2 for a usage error, 3 for inconclusive, 4 for errored or infrastructure-failure.

`docs/plans/4-build-the-measurement-toolkit-for-load-latency-sampling-and-comparison.md` delivers `kenshou-measure`: an in-process latency recorder (an HDR histogram is a fixed-size histogram with logarithmic buckets that answers percentile queries with bounded relative error), closed-loop and open-loop load generators, samplers that write `series/rts.csv`, `series/proc.csv` and `series/pg-*.csv`, a summary (throughput, p50/p90/p99/p99.9/max latency, error rate, allocation rate, garbage-collection productivity) and a paired comparison. A paired comparison runs a baseline and a candidate in alternating order (ABBA or BAAB) for at least three trials, computes seeded bootstrap confidence intervals, applies thresholds that have both a relative part and an absolute floor from a policy file in `policies/`, and returns one of `pass`, `regression`, `inconclusive` or `infrastructure-failure` in a `kenshou.comparison/v1` document. It first checks a compatibility key (suite version, scenario, knobs, dimensions, cohort, machine profile, schema versions). An overhead figure is exactly such a comparison between two telemetry arms, which is why this plan depends on that one.

`docs/plans/6-build-the-diagnostics-toolkit-for-memory-leaks-and-concurrency-stalls.md` is a soft dependency. It judges leaks by fitting a slope to live bytes after major garbage collections in `series/rts.csv`. If it is complete when Milestone 4 starts, the overhead report gains a per-arm leak verdict; if not, the hook stays empty.

All four were unwritten skeletons when this plan was drafted, so the names above come from the MasterPlan and the drafting briefs. The first step of Milestone 1 is to open the real modules and reconcile.

The vocabulary of this plan is OpenTelemetry's. A span is a timed record of one unit of work with a name, attributes and a parent; a trace is the tree of spans that share a trace identifier. A tracer creates spans; a tracer provider owns the configuration and hands out tracers. A span processor receives every span when it ends; the batch span processor puts ended spans in a bounded queue and a background thread sends them in batches to an exporter; the simple span processor exports spans one at a time. OTLP is the OpenTelemetry wire protocol (protobuf over HTTP on port 4318, or gRPC on 4317); a collector is a server that receives OTLP. A sampler decides at span start whether the span is recorded. W3C trace context is the pair of text headers `traceparent` and `tracestate` that carry a trace across a process boundary; a propagator writes and reads them. A meter creates metric instruments (counters, gauges, histograms); a meter provider aggregates them in process; a reader or exporter takes the aggregated values out. Prometheus text is a line-oriented exposition format that a monitoring server fetches by HTTP GET at an interval; one fetch is a scrape.

The runtime's telemetry seams were verified in the sources on 2026-09-20. For each, the canonical project URI and the path on disk are given; all of these repositories are read-only for this work.

OpenTelemetry for Haskell is `mori://iand675/hs-opentelemetry`, on disk at `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry`. Hackage carries 1.0.0.0 of `hs-opentelemetry-api`, `-sdk`, `-exporter-otlp`, `-exporter-in-memory`, `-exporter-prometheus`, `-propagator-w3c` and `-otlp`. In `api/src/OpenTelemetry/Trace/Core.hs`, `createTracerProvider :: MonadIO m => [SpanProcessor] -> TracerProviderOptions -> m TracerProvider`; a provider with an empty processor list takes a fast path in `inSpan` and `createSpan` (every span is a `Dropped` span, with no masking and no context change), which is what the `noop` arm measures. `emptyTracerProviderOptions` uses a dummy identifier generator and no propagator, so any arm that must produce real traces has to set `tracerProviderOptionsIdGenerator = defaultIdGenerator` (from `OpenTelemetry.Trace.Id.Generator.Default` in the SDK) and `tracerProviderOptionsPropagators = w3cTraceContextPropagator` (from `OpenTelemetry.Propagator.W3CTraceContext`). `shutdownTracerProvider` and `forceFlushTracerProvider` take an optional timeout in microseconds (default five seconds) and return `ShutdownSuccess | ShutdownFailure | ShutdownTimeout` and `FlushSuccess | FlushTimeout | FlushError`. In `sdk/src/OpenTelemetry/Processor/Batch/Span.hs`, `batchProcessor :: MonadIO m => BatchTimeoutConfig -> SpanExporter -> m SpanProcessor` with defaults `maxQueueSize = 2048`, `scheduledDelayMillis = 5000`, `exportTimeoutMillis = 30000`, `maxExportBatchSize = 512`. It requires the `-threaded` runtime. Ending a span never blocks: when the queue is full the span is dropped, and the drop count is private to the processor (it only logs a warning), so this plan counts drops from the outside. `simpleProcessor :: SimpleProcessorConfig -> IO SpanProcessor` in `sdk/src/OpenTelemetry/Processor/Simple/Span.hs` is, in this version, also asynchronous: it hands each span to a worker thread through a bounded queue of 2048, drops when full, exports one span per request, and its own shutdown waits for the worker without a timeout, so only the provider-level timeout bounds it. Neither processor can therefore stall the application thread; the failure modes to look for are lost spans and slow shutdown, not back-pressure. `SpanExporter` and `SpanProcessor` are plain records, so both can be wrapped. `sdk/src/OpenTelemetry/MeterProvider.hs` gives `createMeterProvider :: MaterializedResources -> SdkMeterProviderOptions -> IO (MeterProvider, SdkMeterEnv)` and `collectResourceMetrics`; `sdk/src/OpenTelemetry/MetricReader.hs` gives `forkPeriodicMetricReader` (default interval sixty seconds); `exporters/prometheus/src/OpenTelemetry/Exporter/Prometheus/WAI.hs` gives `prometheusApplication :: IO (Vector ResourceMetricsExport) -> Application`. In `exporters/otlp`, `otlpExporter :: MonadIO m => OTLPExporterConfig -> m SpanExporter` speaks HTTP/protobuf and gRPC exists only under the manual cabal flag `grpc`.

keiro is `mori://shinzui/keiro`, on disk at `/Users/shinzui/Keikaku/bokuno/keiro`, version 0.17.0.0. Tracing is switched per call site with a `Maybe Tracer`: the field `tracer` on `RunCommandOptions` (`keiro/src/Keiro/Command.hs`), `WorkflowRunOptions` (`keiro/src/Keiro/Workflow.hs`) and `OutboxPublishOptions` (`keiro/src/Keiro/Outbox/Types.hs`), and the first argument of `withConsumerSpan`. The process-manager and router `WorkerOptions` (`keiro/src/Keiro/ProcessManager.hs`) has a `metrics` field and no `tracer` field, so those workers emit no spans of their own. Metrics are OpenTelemetry instruments only: `Keiro.Telemetry.newKeiroMetrics :: MonadIO m => Meter -> m KeiroMetrics`, threaded as `Maybe KeiroMetrics`; keiro has no HTTP endpoint. `Keiro.Telemetry.kirokuEventBridge :: Maybe KeiroMetrics -> (KirokuEvent -> IO ()) -> KirokuEvent -> IO ()` is the only source of the counter `keiro.subscription.deadlettered`. In `keiro-pgmq/src/Keiro/PGMQ/Runtime.hs`, `withJobRuntime :: Text -> Maybe Tracer -> (JobRuntime -> IO a) -> IO a` selects `runTracingNoop` with `runPgmq` for `Nothing` and `runTracing` with `runPgmqTraced` for `Just`.

kiroku is `mori://shinzui/kiroku`, on disk at `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` (kiroku-store 0.8.0.1, kiroku-metrics 0.1.0.8, kiroku-otel 0.2.0.8). `ConnectionSettings` in `kiroku-store/src/Kiroku/Store/Connection.hs` has exactly one slot `eventHandler :: Maybe (KirokuEvent -> IO ())`, invoked synchronously on the emitting thread (the notifier loop, the publisher loop, a subscription worker), so a slow handler stalls that loop; it must be set before `withStore`. Three things want that slot: `Kiroku.Metrics.metricsEventHandler :: KirokuMetrics -> Maybe (KirokuEvent -> IO ()) -> KirokuEvent -> IO ()` (a wrapper with a pass-through), keiro's `kirokuEventBridge` (a wrapper), and `Kiroku.Otel.Subscription.subscriptionTraceHandler :: Tracer -> IO (KirokuEvent -> IO ())` (a leaf with no pass-through). Trace context travels in event metadata through `StoreSettings.enrichEvent :: Maybe (EventData -> IO EventData)` with `Kiroku.Otel.TraceContext.injectTraceContext :: SpanContext -> EventData -> EventData`. Because the collector must exist before the store, kiroku documents `newKirokuMetricsWith :: STM GlobalPosition -> STM Int -> IO KirokuMetrics` with a `TVar (Maybe KirokuStore)` filled after `withStore` opens. `Kiroku.Metrics.Server.withMetricsServerWithStore` serves `/metrics`, `/metrics/<name>`, `/metrics/prometheus`, `/subscriptions`, `/health`, `/health/live`, `/health/ready`, and WebSocket channels at `/ws/metrics` and `/ws/events`; the default port is 9091 and `port = 0` binds a free port reported in `serverPort`.

shibuya is `mori://shinzui/shibuya`, on disk at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya` (shibuya-core and shibuya-metrics 0.9.0.3 on Hackage). `Shibuya.Telemetry.Effect.runTracing :: IOE :> es => Tracer -> Eff (Tracing : es) a -> Eff es a` and `runTracingNoop`; the no-op interpreter sets a flag that short-circuits every tracing operation, so for shibuya `off` and `noop` are genuinely different code paths. Core counters are always on and cannot be disabled. `Shibuya.Metrics.Server.startMetricsServer :: MetricsServerConfig -> Master -> IO MetricsServer` (default port 9090, `wsPushIntervalUs = 100_000`) serves `/metrics`, `/metrics/<processor>`, `/metrics/prometheus`, the three health routes and a WebSocket upgrade on any path. Unlike kiroku it does not support `port = 0` (it reports the configured port back) and returns before the socket is bound, so callers must reserve a port and wait for readiness themselves. Its WebSocket endpoint has an open defect recorded as `mori://shinzui/shibuya/okf/reviews/concepts/REV-9` (the local Mori registry lags that repository; the record is `docs/reviews/REV-9-websocket-lifecycle-audit.md` there): an abrupt disconnect can leak a connection slot, and `enableWebSocket = False` does not block upgrades.

pgmq-hs is `mori://shinzui/pgmq-hs`, on disk at `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs` (pgmq-effectful 0.6.1.0). Tracing is an interpreter choice, `runPgmq :: Pool -> …` versus `runPgmqTraced :: Pool -> Tracer -> …`. Propagation helpers `sendMessageTraced` and `readMessageWithContext` in `pgmq-effectful/src/Pgmq/Effectful/Traced.hs` take a `TracerProvider` and use that provider's propagator, which is why `TelemetryHandles` exposes the provider and why every provider built here installs the W3C propagator. pgmq-hs emits no metrics.

kafka-effectful is `mori://shinzui/kafka-effectful`, on disk at `/Users/shinzui/Keikaku/bokuno/kafka-effectful`, version 0.3.1.0: `runKafkaProducerTraced :: Tracer -> ProducerProperties -> …` and `runKafkaConsumerTraced :: Tracer -> ConsumerProperties -> Subscription -> …`. Release 0.3.1.0 fixed a context leak in which a record without a `traceparent` was parented to the previous record's trace because an attached thread-local context was never detached. This plan keeps a generic regression check for that class of bug.

The integration contracts this plan relies on are restated here. The dimension `telemetry.tracing` takes `off` (the library is handed no tracer, which for this runtime means `Nothing` or the no-op interpreter), `noop` (a tracer from a provider with no span processors), `sdk-inmemory` (the SDK with an in-memory exporter) and `sdk-otlp` (the SDK exporting over OTLP to a collector). The dimension `telemetry.metrics` takes `off`, `collect` (instruments and collectors are live in the process but nothing is served), `serve` (the HTTP endpoints are up) and `serve-scraped` (the endpoints are also scraped by the harness at the run specification's scrape interval, which is the knob `metrics.scrape-interval-ms`). The vocabulary belongs to the kernel plan; the behaviour belongs to this plan. This plan owns the package `kenshou-telemetry` with the namespace `Kenshou.Telemetry.*`, the files `series/scrape-*.csv`, the document `kenshou.overhead-report/v1`, and the subcommand `kenshou overhead`. Every versioned document is JSON with a `schema` field and a JSON Schema under `schemas/`. Toolkit packages never depend on layer packages.

There is no relevant local ADR yet: `docs/adr/` is created by the bootstrap plan and will hold only that plan's two records when this work starts. Scan it with `ls docs/adr` before starting and read anything that mentions telemetry or measurement. Four cross-repository decisions matter here. `mori://shinzui/kiroku/okf/adrs/concepts/ADR-5` separates performance evidence into structural checks, controlled same-process A/B workloads and historical telemetry, and treats only the first two as authoritative; an overhead verdict is therefore decided by the paired runs of one invocation, never by comparing against last month's numbers. `mori://shinzui/kiroku/okf/adrs/concepts/ADR-9` (the local Mori registry lags; the record is `docs/adr/0009-published-http-and-websocket-wire-shapes-are-frozen-and-served-only-by-sister-packages.md` in kiroku) freezes the kiroku-metrics paths, JSON bodies, WebSocket frames and Prometheus names, so the scraper may hard-code `/metrics/prometheus`, `/metrics` and `/ws/metrics`. `mori://shinzui/keiro/okf/adrs/concepts/ADR-1` fixes that keiro-pgmq emits exactly one `process` span per delivery on both execution paths, which gives the continuity checker an exact expectation. `mori://shinzui/keiro/okf/adrs/concepts/ADR-40` records that keiro deliberately has no HTTP surface, which is why the harness, not keiro, serves the Prometheus exposition of keiro's meter. The protocol specification that the comparison vocabulary follows is `mori://shinzui/keiro-benchmarks/okf/improvement-requests/concepts/IR-1`.

This plan owns one new ADR, "Results are recorded through a channel independent of the feature under test" (shared with the measurement plan, which contributes the recorder). Two further decisions are candidates if they survive implementation: "telemetry helpers run out of process" and "the telemetry toolkit links no runtime library". Create each with `okf id next docs/adr --profile docs/adr/profile.dhall ADR`, and validate with `okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce`.

Three statements in the drafting research turned out to be imprecise and are corrected above: the kiroku WebSocket paths are `/ws/metrics` and `/ws/events`, not `/ws`; `subscriptionTraceHandler` returns its handler in `IO` and takes only a `Tracer`; and keiro's `Maybe Tracer` is not on every options record (`WorkerOptions` has none).


## Plan of Work

### Milestone 1 — Tracing arms

Scope: the package, the specification type, the four tracing arms, the span accounting that every later milestone reads, the OTLP null sink, and the first self-test scenario. At the end, `kenshou run selftest/telemetry/benchmark/arms-on-synthetic-service --dim telemetry.tracing=<arm>` works for all four arms, each run directory's `run-result.json` has a `telemetry` section whose span counts match the arm, and the `off` arm still has measurements. Run `cabal test kenshou-telemetry-test` and the four scenario runs shown in Concrete Steps.

Begin by reconciling. Read the two dependency plans and open `kenshou-core/src/Kenshou/Core/Scenario.hs`, `Dimension.hs`, `Knob.hs`, `Bundle.hs`, `Role.hs` and `Run.hs`, and the comparison and summary modules of `kenshou-measure`. Write down, in the Decision Log, the real names of: the dimension value types, the knob accessors on `RunContext`, the summary-registration function, the phase-marker API, how a role receives its input and how a toolkit registered its `selftest/measure/*` scenarios in `kenshou-cli/src/Kenshou/Cli/Registry.hs`. Follow that last precedent exactly for this package. Then check the cohort: `grep -n 'hs-opentelemetry' cohort/released.project cohort/head.project`. If `hs-opentelemetry-sdk`, `-exporter-otlp`, `-exporter-prometheus`, `-propagator-w3c` and `-otlp` are not constrained to `==1.0.0.0`, add them to both project files and to both `cohort/*.json` descriptors in one commit, because they become part of what every arm links.

Create `kenshou-telemetry/kenshou-telemetry.cabal` with a library and the test suite `kenshou-telemetry-test` (hspec with hspec-hedgehog), `default-language: GHC2024`, and the manual flag `otlp-grpc` (default `False`). The library depends on `kenshou-core`, `kenshou-measure`, the seven `hs-opentelemetry-*` packages named above, `wai`, `warp`, `http-client`, `http-types`, `websockets`, `wai-websockets`, `proto-lens`, `zlib`, `aeson`, `async`, `stm`, `process`, `bytestring`, `text`, `containers`, `vector`, `unordered-containers`, `time` and `uuid`. Check that the `kenshou` executable in `kenshou-cli/kenshou-cli.cabal` is built with `-threaded -rtsopts`; the batch span processor throws at start-up without the threaded runtime.

`kenshou-telemetry/src/Kenshou/Telemetry/Spec.hs` defines the arms and the specification. The Haskell constructors map one-to-one to the contract's text values.

```haskell
data TracingArm = TracingOff | TracingNoop | TracingSdkInMemory | TracingSdkOtlp
data MetricsArm = MetricsOff | MetricsCollect | MetricsServe | MetricsServeScraped

data TelemetrySpec = TelemetrySpec
  { tracing        :: TracingArm
  , metrics        :: MetricsArm
  , serviceName    :: Text                 -- scenario identifier with '/' replaced by '.'
  , sampler        :: SamplerSpec          -- otel.sampler, otel.sampler-arg
  , processor      :: ProcessorSpec        -- otel.processor and the otel.bsp.* knobs
  , exporter       :: OtlpProtocol         -- otel.exporter
  , endpoint       :: OtlpEndpoint         -- BuiltinSink SinkFault | External Text
  , compression    :: OtlpCompression      -- otel.compression
  , probeRetain    :: Int                  -- otel.inmemory.retain
  , shutdownMs     :: Int                  -- otel.shutdown-timeout-ms
  , otelReader     :: OtelReader           -- metrics.otel-reader (Milestone 2)
  , otelExportMs   :: Int                  -- metrics.otel-export-interval-ms
  , scrapeMs       :: Int                  -- metrics.scrape-interval-ms
  , wsSubscribers  :: Int                  -- metrics.ws-subscribers
  , helpers        :: HelperPlacement      -- HelperProcess FilePath | HelperInProcess
  , outDir         :: FilePath             -- the run directory
  , report         :: Value -> IO ()       -- registers the "telemetry" summary section
  }

telemetryKnobs          :: [KnobSpec]
telemetrySpecFromContext :: RunContext -> Either Text TelemetrySpec
```

`telemetryKnobs` is the list every scenario appends to its own knobs so that the names, types, defaults and allowed values are identical everywhere. The knobs are: `otel.sampler` (text; `always-on`, `always-off`, `parentbased-always-on`, `traceidratio`, `parentbased-traceidratio`; default `parentbased-always-on`, the SDK default); `otel.sampler-arg` (decimal in the closed interval zero to one; default `1.0`); `otel.processor` (text; `batch`, `simple`; default `batch`); `otel.bsp.max-queue` (integer from 1 to 1048576; default 2048); `otel.bsp.schedule-delay-ms` (integer from 10 to 60000; default 5000); `otel.bsp.max-export-batch` (integer from 1 to `otel.bsp.max-queue`; default 512); `otel.bsp.export-timeout-ms` (integer from 100 to 120000; default 30000); `otel.exporter` (text; `http-protobuf`, `grpc`; default `http-protobuf`; `grpc` is rejected with a clear message unless the package was built with the flag `otlp-grpc`); `otel.endpoint` (text; default empty, meaning "spawn the built-in sink"; otherwise a base URL such as `http://127.0.0.1:4318`); `otel.sink-fault` (text; `none`, `delay-200ms`, `delay-2000ms`, `status-503`, `hang`, `refuse`; default `none`; rejected when `otel.endpoint` is non-empty); `otel.compression` (text; `none`, `gzip`; default `none`); `otel.inmemory.retain` (integer from 0 to 1000000; default 4096); `otel.shutdown-timeout-ms` (integer from 100 to 120000; default 5000); `metrics.scrape-interval-ms` (integer from 100 to 600000; default 15000, the interval the production monitoring stack uses; the aggressive variant is 1000); `metrics.ws-subscribers` (integer from 0 to 64; default 0); `metrics.otel-reader` (text; `prometheus`, `otlp-periodic`, `none`; default `prometheus`); `metrics.otel-export-interval-ms` (integer from 1000 to 600000; default 60000, the SDK default). The defaults are the SDK's defaults on purpose: the default arm should cost what a service that follows the documentation pays. `telemetrySpecFromContext` reads the two dimensions and these knobs, sets `helpers` to `HelperProcess` with the running executable's path, and sets `report` to the kernel's registration function for the section `telemetry`.

`kenshou-telemetry/src/Kenshou/Telemetry/Tracing/Pipeline.hs` is the accounting. It never looks inside the SDK.

```haskell
data PipelineStats   -- atomic counters plus a small latency histogram from kenshou-measure
newPipelineStats    :: IO PipelineStats
countingProcessor   :: PipelineStats -> SpanProcessor        -- onStart/onEnd increment; flush/shutdown succeed
instrumentExporter  :: PipelineStats -> SpanExporter -> SpanExporter
snapshotPipeline    :: PipelineStats -> IO PipelineSnapshot
```

`instrumentExporter` wraps `spanExporterExport`: it counts the spans in the batch, times the call with the monotonic clock, and adds the spans to `exportedOk` or `exportFailed` according to the `ExportResult` (`Success` or `Failure (Maybe SomeException)`), keeping the text of the last failure. The batch processor cancels a slow export with an asynchronous exception, so the wrapper counts the batch as failed in an exception handler and rethrows; otherwise spans in an interrupted export would be miscounted as dropped. After the final flush the queue is empty, so `dropped = ended − exportedOk − exportFailed` holds exactly; while running, the same expression is the current queue depth plus drops so far, and its maximum is recorded.

`kenshou-telemetry/src/Kenshou/Telemetry/Tracing/Probe.hs` is the bounded in-memory sink. It is a `SpanProcessor` whose `spanProcessorOnEnd` reads the span's `spanHot` reference once, builds a small `SpanView` (name, kind, trace id, span id, parent span id taken from `spanParent`, attributes, start and end in nanoseconds, status), and stores it in a ring of `probeRetain` slots while counting the total.

```haskell
data SpanView = SpanView
  { name :: Text, kind :: SpanKind, traceId :: TraceId, spanId :: SpanId
  , parentSpanId :: Maybe SpanId, attributes :: HashMap Text Attribute
  , startNs :: Word64, endNs :: Word64, status :: SpanStatus }

newSpanProbe  :: Int -> IO (SpanProbe, SpanProcessor)
readSpans     :: SpanProbe -> IO [SpanView]     -- at most probeRetain, oldest first
spansSeen     :: SpanProbe -> IO Int
```

`kenshou-telemetry/src/Kenshou/Telemetry/Tracing.hs` builds the provider for an arm. For `off` there is no provider. For the other three the options are `emptyTracerProviderOptions` with `tracerProviderOptionsIdGenerator = defaultIdGenerator`, `tracerProviderOptionsPropagators = w3cTraceContextPropagator`, `tracerProviderOptionsSampler` from the knobs (`alwaysOn`, `alwaysOff`, `traceIdRatioBased x`, `parentBased (parentBasedOptions …)` from `OpenTelemetry.Trace.Sampler`), and resources `materializeResources (mkResource ["service.name" .= serviceName])`. The processor list is empty for `noop`; `[countingProcessor stats, probeProcessor]` for `sdk-inmemory`; and `[countingProcessor stats, p]` for `sdk-otlp`, where `p` is `batchProcessor cfg (instrumentExporter stats otlp)` or `simpleProcessor (SimpleProcessorConfig (instrumentExporter stats otlp) timeoutMicros)`. The OTLP exporter is created from `loadExporterEnvironmentVariables` with the record fields `otlpEndpoint`, `otlpTracesEndpoint`, `otlpCompression` and `otlpTimeout` overwritten from the specification, so that no ambient `OTEL_EXPORTER_*` variable survives. The exporter's configuration record differs slightly between modules of the upstream source tree, so confirm the field names against the version the solver picked (`cabal get hs-opentelemetry-exporter-otlp-1.0.0.0` into a scratch directory) and set only fields that exist. The tracer is `makeTracer provider "kenshou" tracerOptions`.

`kenshou-telemetry/src/Kenshou/Telemetry/Sink.hs` is the null sink: a WAI application that accepts `POST /v1/traces` and `POST /v1/metrics`, inflates gzip bodies, decodes `ExportTraceServiceRequest` with `proto-lens` (module `Proto.Opentelemetry.Proto.Collector.Trace.V1.TraceService` from `hs-opentelemetry-otlp`) to count spans, counts requests and bytes, and answers 200 with an empty protobuf body. Fault modes change the answer: a fixed delay, status 503 (which makes the exporter retry), never answering, or not listening at all. `runSinkRole` is the worker-role body: it reads one JSON object (`{"fault": "none", "decode": true}`) the way the kernel delivers role input, binds a free port with `Warp.openFreePort`, prints one line `{"ready": true, "port": N}` on standard output, serves until standard input closes, then prints one line of final statistics (`requests`, `bytes`, `spansReceived`) and exits. A line `{"fault": "<mode>"}` on standard input changes the fault mode while it runs, which `TelemetryHandles.setSinkFault` exposes to scenarios. The role name is `telemetry-otlp-sink`.

`kenshou-telemetry/src/Kenshou/Telemetry.hs` is the facade and the bracket.

```haskell
data TelemetryHandles = TelemetryHandles
  { tracer           :: Maybe Tracer
  , tracerProvider   :: Maybe TracerProvider
  , meter            :: Maybe Meter            -- Milestone 2
  , meterProvider    :: Maybe MeterProvider    -- Milestone 2
  , spans            :: Maybe SpanProbe        -- present only under sdk-inmemory
  , pipeline         :: Maybe PipelineStats    -- present under the two sdk arms
  , metricsLive      :: Bool                   -- True under collect, serve and serve-scraped
  , servesEndpoints  :: Bool                   -- True under serve and serve-scraped
  , registerEndpoint :: Endpoint -> IO ()      -- Milestone 2
  , setSinkFault     :: SinkFault -> IO ()     -- no-op unless the built-in sink is running
  , flushTelemetry   :: IO FlushReport         -- timed forceFlush of both providers
  }

withTelemetry :: TelemetrySpec -> (TelemetryHandles -> IO a) -> IO a
```

`withTelemetry` starts the sink if the arm needs one and waits for its ready line (ten seconds, then `errored`), builds the providers, runs the body, and on the way out — also when the body throws — calls `forceFlushTracerProvider` and then `shutdownTracerProvider` with the timeout `otel.shutdown-timeout-ms`, timing both with the monotonic clock and recording their results, stops the helper processes (close standard input, wait two seconds, then kill the process group), reads the sink's final statistics, builds the summary and hands it to `report`. It records every environment variable whose name starts with `OTEL_` under `ambientEnv`. It must never throw from the cleanup path: a failed shutdown is data.

The summary is the `telemetry` section of `run-result.json`. Its shape is fixed by `schemas/kenshou.telemetry-summary.v1.schema.json` (follow the file-naming convention the kernel plan used for its schemas).

```json
{
  "schema": "kenshou.telemetry-summary/v1",
  "arms": {"tracing": "sdk-otlp", "metrics": "off"},
  "settings": {"sampler": "parentbased-always-on", "samplerArg": 1.0, "processor": "batch",
               "bsp": {"maxQueue": 2048, "scheduleDelayMs": 5000, "maxExportBatch": 512, "exportTimeoutMs": 30000},
               "exporter": "http-protobuf", "endpoint": "builtin-sink", "sinkFault": "none", "compression": "none"},
  "ambientEnv": {},
  "pipeline": {"spansStarted": 80412, "spansEnded": 80412, "spansExportedOk": 80412, "spansExportFailed": 0,
               "spansDropped": 0, "exportCalls": 158, "exportLatencyNs": {"p50": 1900000, "p99": 7400000, "max": 9100000},
               "maxQueueDepth": 611, "lastExportError": null,
               "flush": {"result": "FlushSuccess", "durationMs": 14},
               "shutdown": {"result": "ShutdownSuccess", "durationMs": 31}},
  "sink": {"requests": 158, "bytes": 23110422, "spansReceived": 80412},
  "endpoints": [],
  "handlers": [],
  "findings": []
}
```

The first scenario lives in `kenshou-telemetry/src/Kenshou/Telemetry/SelfTest/Service.hs` and `SelfTest/Arms.hs`, and the bundle in `SelfTest.hs` (`selfTestBundle :: LayerBundle`, layer `selftest`, roles `telemetry-otlp-sink` and `telemetry-scraper`). The synthetic service is deliberately tiny and needs no PostgreSQL. One operation does this: if a tracer is present, open a Producer span `send synthetic` with `work.attributes-per-span` attributes and write its W3C headers into a message; push the message through an in-process bounded queue to a consumer thread; the consumer, if a tracer is present, extracts the headers and opens a Consumer span `process synthetic` as a child; it burns `work.cpu-micros` of CPU in a deterministic hashing loop; if a meter is present it adds one to a counter and records one histogram value; then it completes the operation, whose latency the measurement toolkit's closed-loop generator records. The scenario is `selftest/telemetry/benchmark/arms-on-synthetic-service`, tier `smoke`, placement `either`, supporting every value of both telemetry dimensions and ignoring the two PostgreSQL dimensions. Its own knobs are `work.cpu-micros` (integer 0 to 100000, default 1000), `work.spans-per-op` (integer 1 to 16, default 2), `work.attributes-per-span` (integer 0 to 64, default 6), `load.workers` (integer 1 to 64, default 4) and `load.duration-seconds` (integer 1 to 3600, default 10), plus `telemetryKnobs`. It establishes two things: the measurement (throughput and latency of the same work under each arm) and the invariant that the `measurements` section is non-empty and `samples/` is populated under every arm, including `off`/`off`; it fails if that does not hold, or if under an SDK arm with an always-on sampler `spansEnded` differs from operations times `work.spans-per-op` by more than the operations in flight at the end (spans that a ratio or always-off sampler rejects never reach a processor, so the check is skipped for those samplers and the sampled fraction is reported instead).

### Milestone 2 — Metrics arms and the harness scraper

Scope: the four metrics arms for OpenTelemetry meters, the endpoint registry that layers use for the runtime's own HTTP servers, the scraper and the WebSocket subscriber, and the adapter guide. At the end, running the synthetic scenario with `--dim telemetry.metrics=serve-scraped --set metrics.scrape-interval-ms=1000` produces `series/scrape-*.csv` with about ten rows per endpoint for a ten-second run and an `endpoints` summary; under `serve` the endpoints answer but the files do not exist; under `collect` nothing listens; under `off` no meter exists.

`kenshou-telemetry/src/Kenshou/Telemetry/Metrics.hs` builds the meter side. Under `off`, `meter` and `meterProvider` are `Nothing`. Under `collect`, `createMeterProvider emptyMaterializedResources defaultSdkMeterProviderOptions` gives a provider with live in-process aggregation and nothing reads it except one final `collectResourceMetrics` whose instrument count goes into the summary (proof that the instruments were live). Under `serve` and `serve-scraped` the knob `metrics.otel-reader` decides how the meter's values leave the process: `prometheus` starts a Warp server on a free port whose application is `prometheusApplication (V.fromList <$> collectResourceMetrics env)` and registers it as the endpoint `otel-prometheus`; `otlp-periodic` starts `forkPeriodicMetricReader env otlpMetrics (PeriodicMetricReaderOptions (otelExportMs * 1000))` towards the same sink as the traces (starting the sink if tracing did not); `none` leaves the meter unexported for layers whose only metrics are the runtime's HTTP servers. `TelemetryHandles.meter` is obtained with `getMeter provider` for an instrumentation library named `kenshou`; a layer that needs a meter scoped to a particular library (keiro's instruments belong to `keiroInstrumentationLibrary`) calls `getMeter` on `meterProvider` itself. Shutdown uses `shutdownMeterProvider provider (Just micros)` from `OpenTelemetry.Metric.Core`, timed and recorded like the tracer's.

`kenshou-telemetry/src/Kenshou/Telemetry/Endpoint.hs` defines what a layer announces.

```haskell
data EndpointKind = PrometheusText | JsonDocument | HealthProbe | WebSocketPush

data Endpoint = Endpoint
  { name    :: Text          -- [a-z0-9-]+, becomes part of a file name, e.g. "kiroku-prometheus"
  , kind    :: EndpointKind
  , url     :: Text          -- http://127.0.0.1:9091/metrics/prometheus or ws://127.0.0.1:9091/ws/metrics
  , wsHello :: Maybe Value   -- first client frame for WebSocketPush, e.g. {"type":"subscribe_metrics"}
  }

reserveFreePort :: IO Int                        -- bind port 0, read the port, close; for servers without port-0 support
awaitHttpReady  :: Text -> Int -> IO Bool        -- poll a URL until it answers or the deadline (ms) passes
```

`registerEndpoint` behaves by arm. Under `off` and `collect` it throws a harness error, because a layer that starts a server under those arms has broken the dimension; layers must test `servesEndpoints` first. Under `serve` it records the endpoint and performs one readiness request, so a dead endpoint makes the run `errored` instead of making the arm silently cheaper. Under `serve-scraped` it also hands the endpoint to the scraper.

`kenshou-telemetry/src/Kenshou/Telemetry/Scrape.hs` is the scraper, run as the worker role `telemetry-scraper` so that the client half of each scrape is not charged to the measured process. The parent spawns it on the first registration and sends one JSON line per endpoint on its standard input; closing standard input stops it. For HTTP kinds it issues `GET` on a fixed schedule: tick `k` is due at `t0 + k × interval`, a scrape that overruns skips the ticks it missed and records how many, and scrapes never overlap for one endpoint. It writes one file per endpoint, `series/scrape-<name>.csv`, flushing every row. Use the timestamp column convention of the measurement toolkit's `series/rts.csv` (check its header) followed by `endpoint,kind,status,latency_ns,body_bytes,skipped,error`; timestamps that cross processes are wall-clock, durations are measured with the scraper's monotonic clock. For `WebSocketPush` endpoints, and only when `metrics.ws-subscribers` is above zero, it opens that many connections with `Network.WebSockets.runClient`, sends `wsHello`, and writes `series/scrape-<name>-ws.csv` with the columns `subscriber,event,frames,bytes,gap_ns,error` after the timestamp, where `event` is `connect`, `frame`, `reject`, `close` or `error`. `wsSlotLeakProbe :: Endpoint -> Int -> IO SlotLeakResult` connects and abruptly drops `n` connections (closing the socket without a close frame), then checks that a fresh connection is still accepted; it is the generic detector for the shibuya defect named above, to be used by the shibuya coverage plan with the known-defect reference `mori://shinzui/shibuya/okf/reviews/concepts/REV-9`. After the run the parent reads the CSV files back and writes, per endpoint, the scrape count, failures, skipped ticks, p50/p99/max latency and mean and maximum body size into the summary's `endpoints` list. `runScraperInProcess` exists for unit tests only.

Extend the synthetic service so the scraper has something real to hit without any runtime dependency: besides `otel-prometheus` it serves a small JSON document at `/metrics` (endpoint `synthetic-json`) and a WebSocket push at `/ws/metrics` that sends a snapshot frame on connect and every 100 ms (endpoint `synthetic-push`), and it registers all three.

Write `docs/guides/wiring-telemetry-arms.md`. It is the contract between this toolkit and the five layer plans, and it must contain, with the verified signatures from Context and Orientation, one recipe per component. For keiro: call `newKeiroMetrics` once on a meter from `meterProvider` with `keiroInstrumentationLibrary`, pass `Maybe KeiroMetrics` to every options record and explicit argument, pass `tracer` to `RunCommandOptions`, `WorkflowRunOptions`, `OutboxPublishOptions`, `withConsumerSpan` and `withJobRuntime`, and use `metrics.otel-reader=prometheus`. For kiroku, the composition is the delicate part and the guide shows it in full:

```haskell
-- Lives in kenshou-kiroku (and, with a bridge, in kenshou-keiro); never in kenshou-telemetry.
withKirokuTelemetry
  :: TelemetryHandles
  -> Text                                                -- connection string
  -> ((KirokuEvent -> IO ()) -> KirokuEvent -> IO ())    -- outermost wrapper: `id`, or `kirokuEventBridge mKeiroMetrics`
  -> [KirokuEvent -> IO ()]                              -- the scenario's own leaf handlers (ledger taps and the like)
  -> (KirokuStore -> IO a) -> IO a
withKirokuTelemetry th connStr bridge scenarioHandlers body = do
  storeVar <- newTVarIO Nothing
  mKm <- if th.metricsLive
           then Just <$> newKirokuMetricsWith (readPosition storeVar) (readSubscribers storeVar)
           else pure Nothing
  mTrace <- traverse subscriptionTraceHandler th.tracer          -- a leaf: it has no pass-through
  let leaf    = composeHandlers (maybeToList mTrace <> scenarioHandlers)
      metered = maybe leaf (\km -> metricsEventHandler km (Just leaf)) mKm
      enrich  = th.tracer $> \ed -> do
                  ctx <- getContext                               -- OpenTelemetry.Context.ThreadLocal
                  case lookupSpan ctx of
                    Nothing -> pure ed
                    Just sp -> (`injectTraceContext` ed) <$> getSpanContext sp
      settings = defaultConnectionSettings connStr
                   & #eventHandler .~ Just (bridge metered)
                   & #observationHandler .~ fmap (`metricsObservationHandler` Nothing) mKm
                   & #storeSettings . #enrichEvent .~ enrich
  withStore settings $ \store -> do
    atomically (writeTVar storeVar (Just store))
    case mKm of
      Just km | th.servesEndpoints ->
        withMetricsServerWithStore defaultConfig{port = 0} km store [] $ \srv -> do
          let base = "127.0.0.1:" <> T.pack (show srv.serverPort)
          th.registerEndpoint (Endpoint "kiroku-prometheus" PrometheusText ("http://" <> base <> "/metrics/prometheus") Nothing)
          th.registerEndpoint (Endpoint "kiroku-json" JsonDocument ("http://" <> base <> "/metrics") Nothing)
          th.registerEndpoint (Endpoint "kiroku-push" WebSocketPush ("ws://" <> base <> "/ws/metrics")
                                 (Just (object ["type" .= ("subscribe_metrics" :: Text)])))
          body store
      _ -> body store
```

`readPosition` and `readSubscribers` are the two STM readers from kiroku's own `docs/user/metrics.md` (they read `publisherPosition` and the `subscribers` map through the `TVar (Maybe KirokuStore)` and answer zero until the store is open). `composeHandlers` arrives with Milestone 4; until then the guide's recipe uses `\e -> mapM_ ($ e) handlers` in its place. The guide states the rule the code embodies: wrappers outside, the one leaf inside, everything assembled before `withStore`, nothing in the chain may block. For shibuya: `runTracing tracer` when `tracer` is `Just`, `runTracingNoop` when `Nothing`; reserve a port with `reserveFreePort`, call `startMetricsServer defaultConfig{port = p} (getAppMaster appHandle)`, wait with `awaitHttpReady`, then register `/metrics/prometheus`, `/metrics` and the WebSocket; declare that `off` and `collect` are identical for shibuya because its counters cannot be switched off. For pgmq-hs: choose `runPgmq` or `runPgmqTraced pool tracer`, use `sendMessageTraced` and `readMessageWithContext` with `tracerProvider`, and declare support for `telemetry.metrics=off` only. For Kafka: choose `runKafkaProducerTraced` and `runKafkaConsumerTraced` or the plain interpreters, and declare `telemetry.metrics=off` only. The guide closes with the dimension-support table in prose: which values each layer declares and why.

### Milestone 3 — The paired overhead protocol and `kenshou overhead`

Scope: turning "run this scenario under these arms" into interleaved, fresh-process runs, comparing each arm with the baseline through the measurement toolkit, and emitting one report with a verdict and an exit code. At the end the headline command from Purpose runs to completion on a laptop in about two and a half minutes and writes `overhead-report.json`; identical arms give `pass`; an arm made artificially expensive gives `regression` and exit code 1.

Register `kenshou overhead` as an Execution `CliCommand`. The command line is `kenshou overhead <scenario-id> --arms <factor>=<v1>,<v2>,… [--arms …] [--mode one-factor|full] [--control] [--trials N] [--set knob=value]… [--dim name=value]… [--policy FILE] [--seed N] [--settle-seconds S] [--retries R] [--resume] [--analyse-only] [--json] --out DIR`. Follow EP-2's option-group contract: Arms for factors and mode, Parameters for `--set`/`--dim`, Methodology for policy/trials/seed/control/settling, Execution for resume/retries/analyse-only, and Output for the directory and JSON mode. `--policy -` uses `InputSource`; JSON output is the only content on standard output. A factor is `tracing` or `metrics`, shorthand for the two dimension names; repeating a value inside one factor is a usage error. The first value listed for a factor is its baseline. In mode `one-factor` (the default) the arms are the baseline cell plus one arm per non-baseline value with the other factor held at its baseline, so the headline command has four arms and three comparisons. In mode `full` the arms are the whole cross product, each compared with the baseline cell, which also exposes interactions. `--control` adds a second, identical copy of the baseline arm and compares it with the baseline like any other arm (an A/A test); if that comparison is anything but `pass`, the machine is too noisy to judge small overheads and the report's verdict is capped at `inconclusive`. `--trials` defaults to 3 and values below 3 are a usage error, because a single trial is never quoted. `--set` and `--dim` apply to every arm; if the scenario requires PostgreSQL and no `pg.durability` is given, `durable` is applied, because an `fsync-off` run is not a benchmark result. Every requested arm value must be in the scenario's declared dimension support; otherwise the command exits with code 2 and lists what is supported.

`kenshou-telemetry/src/Kenshou/Telemetry/Overhead.hs` has three entry points so that a cell can execute the slots elsewhere.

```haskell
data Arm  = Arm  { armId :: Text, dimensions :: Map Text Text, knobs :: Map Text KnobValue }
data Slot = Slot { block :: Int, position :: Int, arm :: Arm, spec :: RunSpec }

planOverhead    :: OverheadRequest -> Scenario -> Either UsageError OverheadPlan   -- pure
executeOverhead :: OverheadHooks -> OverheadPlan -> FilePath -> IO OverheadState   -- spawns `kenshou run`
analyseOverhead :: OverheadHooks -> OverheadPolicy -> OverheadPlan -> OverheadState -> FilePath -> IO OverheadReport

data OverheadHooks = OverheadHooks
  { runChild  :: RunSpec -> FilePath -> IO ExitCode            -- default: the running executable with `run`
  , compare   :: ComparisonRequest -> IO Comparison            -- kenshou-measure's paired comparison
  , leakCheck :: Maybe (FilePath -> IO (Maybe Value)) }        -- supplied by kenshou-cli when kenshou-diagnose exists
```

Ordering generalises ABBA to `k` arms. The arm list is shuffled once with the seed. Block `b` (counting from zero) uses that list rotated left by `b` positions when `b` is even and the reverse of that rotation when `b` is odd. With two arms this is exactly ABBA. Every block contains every arm once, so trial `i` of a candidate is paired with trial `i` of the baseline from the same block, a few minutes apart. Between runs the executor sleeps `--settle-seconds` (default 2). A child that exits with code 4 (errored or infrastructure-failure) is retried up to `--retries` times (default 1); if it still fails, its whole block is marked invalid and one replacement block is appended, at most `trials` replacements. Fewer than three valid blocks at the end makes every comparison `infrastructure-failure`. `state.json` in the output directory maps slots to run identifiers; it is an internal resume file, not a contract document, and `--resume` skips slots whose run directory has a complete `manifest.json`. `--analyse-only` rebuilds the report from an existing directory.

The compatibility key needs care. The measurement toolkit refuses to compare runs whose key differs, and the key includes dimensions and knobs, which is precisely what differs between arms. The comparison request therefore names the varied factors (`telemetry.tracing`, `telemetry.metrics`) and the comparison must exclude exactly those from the key check while still enforcing scenario, remaining knobs, cohort, machine profile and schema versions. If the delivered comparison API has no such parameter, add it in `kenshou-measure` as an explicit, recorded list (`variedFactors`, written into the `kenshou.comparison/v1` document), note it in this plan's Decision Log and in the MasterPlan's Surprises & Discoveries, and do not work around it by blanking the key.

The output directory is `<out>/overhead-<uuidv7>/` with `runs/<run-id>/…` (ordinary run directories), `comparisons/<candidate>-vs-<baseline>.json` (`kenshou.comparison/v1`), `state.json` and `overhead-report.json`.

```json
{
  "schema": "kenshou.overhead-report/v1",
  "id": "0199…",
  "scenario": "selftest/telemetry/benchmark/arms-on-synthetic-service",
  "mode": "one-factor",
  "baseline": {"telemetry.tracing": "off", "telemetry.metrics": "off"},
  "fixed": {"knobs": {"work.cpu-micros": 1000}, "dimensions": {}},
  "trials": 3, "seed": 7, "validBlocks": 3,
  "order": [["a2", "a0", "a3", "a1"], ["a0", "a2", "a1", "a3"], ["a3", "a1", "a2", "a0"]],
  "arms": [{"arm": "a2", "dimensions": {"telemetry.tracing": "sdk-otlp", "telemetry.metrics": "off"},
            "runs": ["0199…", "0199…", "0199…"],
            "telemetry": {"spansEnded": 241200, "spansDropped": 0, "exportFailures": 0, "shutdownMsMax": 38},
            "leak": null}],
  "comparisons": [{"candidate": "a2", "baseline": "a0", "factor": "telemetry.tracing", "from": "off", "to": "sdk-otlp",
                   "comparison": "comparisons/a2-vs-a0.json", "verdict": "pass", "degraded": false,
                   "deltas": {"throughput": {"relative": -0.061, "ci95": [-0.074, -0.049], "unit": "ops/s"},
                              "latency.p50": {"relative": 0.058}, "latency.p99": {"relative": 0.112},
                              "alloc.bytes-per-op": {"relative": 0.31}, "gc.cpu-fraction": {"absolute": 0.012},
                              "cpu.seconds-per-op": {"relative": 0.066}}}],
  "findings": [],
  "verdict": "pass",
  "policy": {"path": "policies/telemetry-overhead.json", "sha256": "…"},
  "cohort": {},
  "algorithm": {"name": "kenshou-overhead", "version": 1}
}
```

The metric identifiers under `deltas` are the ones the measurement toolkit's summary emits; map the six listed here to its names during reconciliation and keep the list in the schema. The report's verdict is the worst comparison verdict in the order `infrastructure-failure`, `regression`, `inconclusive`, `pass`, and the exit code follows the contract (4, 1, 3, 0). Without `--json` the command prints one line per comparison and the verdict.

`policies/telemetry-overhead.json` holds the budgets. Its `default` member and each member of `transitions` is a policy object in exactly the form the measurement toolkit reads (per metric: direction, maximum relative change, absolute floor), keyed by `"<dimension>:<from>-><to>"`.

```json
{
  "schema": "kenshou.overhead-policy/v1",
  "maxDegradedSpanFraction": 0.01,
  "default": {"throughput": {"direction": "higher-is-better", "maxRelative": 0.05, "absoluteFloor": 50}},
  "transitions": {
    "telemetry.tracing:off->noop":         {"throughput": {"maxRelative": 0.02}, "latency.p99": {"maxRelative": 0.05, "absoluteFloorNs": 50000}},
    "telemetry.tracing:off->sdk-inmemory": {"throughput": {"maxRelative": 0.10}, "latency.p99": {"maxRelative": 0.15, "absoluteFloorNs": 100000}},
    "telemetry.tracing:off->sdk-otlp":     {"throughput": {"maxRelative": 0.15}, "latency.p99": {"maxRelative": 0.25, "absoluteFloorNs": 200000}},
    "telemetry.metrics:off->collect":      {"throughput": {"maxRelative": 0.02}},
    "telemetry.metrics:off->serve":        {"throughput": {"maxRelative": 0.03}},
    "telemetry.metrics:off->serve-scraped": {"throughput": {"maxRelative": 0.03}, "latency.p99": {"maxRelative": 0.10, "absoluteFloorNs": 100000}}
  }
}
```

Adapt the inner field names to the measurement toolkit's policy schema. The CLI part is `kenshou-cli/src/Kenshou/Cli/Overhead.hs` (an `optparse-applicative` parser and a thin `main` that fills `OverheadHooks`), one new `build-depends` entry and one new command in the CLI's command list.

### Milestone 4 — Detectors for telemetry-induced problems

Scope: answering "does it cause problems". At the end, two more self-test scenarios pass, each proving that a detector fires on a doctored situation and stays quiet on a healthy one; every run's `telemetry` section carries a `findings` list; overhead comparisons are marked degraded when an arm lost spans; and the ADR exists and validates.

`kenshou-telemetry/src/Kenshou/Telemetry/Compose.hs` is for single-slot, synchronous callback seams such as kiroku's `eventHandler`.

```haskell
composeHandlers :: [a -> IO ()] -> a -> IO ()                      -- in order, no exception handling, no allocation when empty
timedHandler    :: HandlerStats -> Text -> (a -> IO ()) -> a -> IO ()   -- records the duration of every call
slowHandler     :: Int -> a -> IO ()                               -- injector: threadDelay micros
asyncHandler    :: Int -> (a -> IO ()) -> IO (a -> IO (), IO AsyncHandlerStats)  -- bounded queue, drop newest on full, drained by one thread
```

`composeHandlers` deliberately does not catch exceptions: hiding a failure of the runtime's own handler would be the harness changing the behaviour under test. `asyncHandler` is the remedy the kiroku documentation recommends for handlers that may block, and its drop counter makes the cost of that remedy visible.

`kenshou-telemetry/src/Kenshou/Telemetry/Continuity.hs` works on `SpanView`s from the probe, so it needs the `sdk-inmemory` arm.

```haskell
data SpanSelector = SpanSelector { nameIs :: Maybe Text, kindIs :: Maybe SpanKind, hasAttr :: [(Text, Attribute)] }

checkContinuity :: SpanSelector -> SpanSelector -> (SpanView -> Maybe Text) -> [SpanView] -> ContinuityResult
  -- producer selector, consumer selector, correlation key (for example the message id attribute);
  -- every consumer span must share its producer's trace id and have the producer's span id as parent
checkIsolation  :: SpanSelector -> (SpanView -> Bool) -> [SpanView] -> IsolationResult
  -- consumer spans for which the predicate says "arrived without trace context" must be roots
```

Both results carry counts and the first ten counter-examples. They are the helpers the layers use to assert that a consumer span is a child of the producer span across PGMQ headers, kiroku event metadata and Kafka headers.

`kenshou-telemetry/src/Kenshou/Telemetry/Detect.hs` turns a finished run's numbers into findings of the form `{detector, status: fired | quiet | not-applicable, severity: info | degraded | failure, evidence}`. `span-drop` fires when `spansDropped` is above zero and is `degraded` above the policy's `maxDegradedSpanFraction`. `export-failure` fires on any failed export and quotes the last error. `shutdown-blocked` fires when flush or shutdown returned a timeout or took longer than `otel.shutdown-timeout-ms`. `queue-growth` reads `series/otel-pipeline.csv`, which a sampler thread in `withTelemetry` writes once a second under the SDK arms (columns after the timestamp: `spans_started,spans_ended,exported_ok,export_failed,queue_depth,export_calls`), and fires when the queue depth stayed above ninety percent of `otel.bsp.max-queue` for more than ten consecutive samples. `handler-stall` fires when a `timedHandler`'s 99th-percentile duration exceeds five milliseconds. `endpoint-failure` fires when more than one percent of scrapes failed or were skipped. `context-leak` and `trace-discontinuity` fire from the two continuity results when a scenario supplies them through `recordContinuity`. `analyseOverhead` aggregates findings per arm: a `degraded` finding sets `degraded: true` on that arm's comparisons and turns a `pass` or `regression` into `inconclusive`; a `failure` finding on a correctness scenario is the scenario's business, not the report's. When `leakCheck` is present it is called once per arm on the longest run and its result stored under `leak`.

`selftest/telemetry/correctness/trace-continuity` (tier `smoke`, placement `either`, supports `telemetry.tracing=sdk-inmemory` only and `telemetry.metrics=off` only, knob `messages` integer 10 to 100000 default 1000) runs the synthetic producer and consumer three times in one run. Intact: both checks must report zero violations. Broken propagation: the producer strips `traceparent` from every tenth message; `checkContinuity` must report exactly those messages. Leaky consumer: a deliberately wrong consumer attaches the extracted context to the thread and never detaches it, re-creating the kafka-effectful bug fixed in 0.3.1.0, and every message without a `traceparent` follows one with it; `checkIsolation` must report exactly those. The scenario passes only if the detectors are quiet on the first and exact on the other two; this is the non-vacuity proof.

`selftest/telemetry/concurrency/slow-exporter-backpressure` (tier `smoke`, placement `either`, supports `telemetry.tracing=sdk-otlp` only, knobs `phase-seconds` integer 2 to 600 default 8 and `handler.delay-micros` integer 0 to 1000000 default 5000) has two parts. The exporter part runs the synthetic service with `otel.bsp.max-queue=256`, `otel.bsp.max-export-batch=128`, `otel.bsp.schedule-delay-ms=200` and `otel.bsp.export-timeout-ms=2000`, first against a healthy sink and then, after `setSinkFault Hang`, against a sink that never answers, measuring throughput in each phase. It passes if throughput in the second phase is at least eighty percent of the first (ending a span must not block the application), `span-drop` and `export-failure` fire, `spansExportedOk` equals the sink's `spansReceived` (the sink is the independent witness that the accounting is right), the maximum queue depth never exceeded 256 plus one export batch, and shutdown returned within `otel.shutdown-timeout-ms` plus one second with `shutdown-blocked` fired. The handler part drives a synthetic emitter that calls a composed handler synchronously from its own loop, as kiroku's publisher does: with `slowHandler handler.delay-micros` inside `timedHandler`, the emitter's rate must fall to at most 1.2 divided by the delay and `handler-stall` must fire; with the same slow handler behind `asyncHandler 1024`, the rate must recover to at least eighty percent of the unhandled rate, `handler-stall` must stay quiet, and the drop counter must be above zero. The guide gains a section telling the kiroku coverage plan how to repeat this against a real store.

Finish with the ADR. Allocate its handle with `okf id next`, write the context (the old GCP harness scraped throughput from the metrics endpoint, so a metrics-off arm was impossible), the decision (latency, throughput and resource series are recorded in-process by the measurement toolkit and written to files; helpers that would perturb the measured process run out of process; no verdict ever reads a number from a tracer, a meter or an endpoint under test), the consequences, and cite `mori://shinzui/kiroku/okf/adrs/concepts/ADR-5`. Add a log entry with `okf log add` and run strict validation.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro-runtime-kenshou`, inside the development shell (`nix develop`, or automatically through `direnv`). Scratch output goes to `runs/ep7`; make sure `runs/` is ignored by git (add it to `.gitignore` if the kernel plan did not).

Check the starting state before writing any code.

```bash
ls kenshou-core kenshou-cli kenshou-measure docs/adr
cabal build all
cabal run kenshou -- list --json | jq -r '.[].id' | grep '^selftest/'
cabal run kenshou -- compare --help
grep -n 'hs-opentelemetry' cohort/released.project cohort/head.project
```

The scenario list must contain the kernel's and the measurement toolkit's self-tests, for example:

```text
selftest/kernel/correctness/always-pass
selftest/kernel/correctness/postgres-roundtrip
selftest/measure/benchmark/sleep-service
selftest/measure/benchmark/regression-injected
```

If any of this is missing, stop: a hard dependency is incomplete. The exact flag spellings of `kenshou list` and `kenshou run` are the kernel plan's; adjust the commands below if they differ.

After Milestone 1:

```bash
cabal test kenshou-telemetry-test
for arm in off noop sdk-inmemory sdk-otlp; do
  cabal run kenshou -- run selftest/telemetry/benchmark/arms-on-synthetic-service \
    --dim telemetry.tracing=$arm --dim telemetry.metrics=off --out runs/ep7/m1
done
for d in runs/ep7/m1/*/; do
  jq -c '{t: .summaries.telemetry.arms.tracing, ended: .summaries.telemetry.pipeline.spansEnded,
          dropped: .summaries.telemetry.pipeline.spansDropped, sink: .summaries.telemetry.sink.spansReceived,
          measured: (.summaries.measurements != null)}' "$d/run-result.json"
done
```

Expected shape (numbers are illustrative; the path to the summaries inside `run-result.json` is the kernel's):

```text
{"t":"off","ended":null,"dropped":null,"sink":null,"measured":true}
{"t":"noop","ended":null,"dropped":null,"sink":null,"measured":true}
{"t":"sdk-inmemory","ended":79640,"dropped":0,"sink":null,"measured":true}
{"t":"sdk-otlp","ended":78212,"dropped":0,"sink":78212,"measured":true}
```

After Milestone 2:

```bash
cabal run kenshou -- run selftest/telemetry/benchmark/arms-on-synthetic-service \
  --dim telemetry.tracing=off --dim telemetry.metrics=serve-scraped \
  --set metrics.scrape-interval-ms=1000 --set metrics.ws-subscribers=2 --out runs/ep7/m2
ls runs/ep7/m2/*/series/ | grep scrape
head -3 runs/ep7/m2/*/series/scrape-otel-prometheus.csv
```

The first column follows the measurement toolkit's timestamp convention; `t_wall_ns` below is illustrative.

```text
scrape-otel-prometheus.csv
scrape-synthetic-json.csv
scrape-synthetic-push-ws.csv
t_wall_ns,endpoint,kind,status,latency_ns,body_bytes,skipped,error
1790000000123456789,otel-prometheus,prometheus-text,200,1841000,2210,0,
1790000001123501234,otel-prometheus,prometheus-text,200,1502000,2263,0,
```

After Milestone 3:

```bash
cabal run kenshou -- overhead selftest/telemetry/benchmark/arms-on-synthetic-service \
  --arms tracing=off,noop,sdk-otlp --arms metrics=off,serve-scraped \
  --set metrics.scrape-interval-ms=1000 --seed 7 --out runs/ep7/m3
echo "exit=$?"
```

```text
overhead 0199…  scenario selftest/telemetry/benchmark/arms-on-synthetic-service  4 arms x 3 blocks = 12 runs
tracing  off -> noop            throughput -0.4% [-1.3, +0.5]   p99 +0.9%   pass
tracing  off -> sdk-otlp        throughput -6.1% [-7.4, -4.9]   p99 +11.2%  pass
metrics  off -> serve-scraped   throughput -0.7% [-1.6, +0.2]   p99 +1.4%   pass
verdict: pass   report: runs/ep7/m3/overhead-0199…/overhead-report.json
exit=0
```

After Milestone 4:

```bash
cabal run kenshou -- run selftest/telemetry/correctness/trace-continuity \
  --dim telemetry.tracing=sdk-inmemory --out runs/ep7/m4; echo "exit=$?"
cabal run kenshou -- run selftest/telemetry/concurrency/slow-exporter-backpressure \
  --dim telemetry.tracing=sdk-otlp --out runs/ep7/m4; echo "exit=$?"
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
just verify
```

Both runs must print `exit=0`. Commit after each milestone, and more often when a module with its tests is complete. Commits follow Conventional Commits, for example `feat(telemetry): add tracing arms and the OTLP null sink`, and every commit carries these three trailers:

```text
MasterPlan: docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md
ExecPlan: docs/plans/7-add-telemetry-arms-and-measure-observability-overhead.md
Intention: intention_01m2zvy0gje40tdsdragvzr3tq
```


## Validation and Acceptance

Milestone 1 is accepted when `cabal test kenshou-telemetry-test` passes with tests that show, at least: under `off` both tracer fields are `Nothing`; under `noop` `tracerIsEnabled` is `False` and a span opened with the tracer reaches no processor; under `sdk-inmemory` a parent and child span have non-zero, equal trace identifiers and the child's `parentSpanId` is the parent's `spanId`, and injecting inside a span yields a `traceparent` header (the propagator is installed); after ten times `probeRetain` spans the probe holds `probeRetain` views and `spansSeen` is exact; with an exporter that fails every second batch, `spansEnded = spansExportedOk + spansExportFailed + spansDropped`; with a queue of 8 and a blocked exporter, ending 10 000 spans takes under one second and `spansDropped` is above zero; the sink counts the spans of a gzip and of a plain request and honours each fault mode. The four scenario runs behave as in the transcript: the `off` run has measurements and no pipeline; under `sdk-otlp` the sink's `spansReceived` equals `spansExportedOk`.

Milestone 2 is accepted when, for one ten-second run with a one-second interval, each `scrape-*.csv` has between eight and eleven data rows with status 200 and non-zero `body_bytes`, the summary's `endpoints` list has three entries with latency percentiles, the WebSocket file shows two `connect` events and about a hundred `frame` events per subscriber; when the same scenario under `serve` has the `endpoints` list but no `scrape-*.csv`; when under `collect` no port is opened (the scenario asserts `servesEndpoints` is `False` and the summary's instrument count is above zero); and when a unit test shows the scraper recording `skipped` for an endpoint that answers more slowly than the interval, and `wsSlotLeakProbe` firing against a deliberately leaky test server and staying quiet against a correct one. `docs/guides/wiring-telemetry-arms.md` exists and its kiroku recipe compiles when pasted into a scratch module that depends on kiroku (try it once and delete the scratch module).

Milestone 3 is accepted when the headline command exits 0 and writes a report that validates against `schemas/kenshou.overhead-report.v1.schema.json`; when the same command with `--control` reports `pass` for the control arm against the baseline (identical arms must not look different); when `--arms tracing=off,sdk-inmemory --set work.cpu-micros=0 --set work.spans-per-op=16 --set work.attributes-per-span=64` exits 1 with a `regression` on throughput, because sixteen fully attributed spans per operation dwarf an operation that does no other work and the in-memory probe cannot drop spans to hide it; when `--arms metrics=off,bogus` and `--arms tracing=off,off` both exit 2, the first naming the supported values; when killing the command half way and re-running it with `--resume` finishes without repeating completed runs; and when unit tests show that the block order is deterministic for a seed, contains every arm once per block, and reduces to ABBA for two arms.

Milestone 4 is accepted when both new scenarios exit 0, and each fails when its detector is disabled (flip the detector to always-quiet in a scratch edit, observe exit 1, revert); when a high-rate run (`--set work.cpu-micros=0 --dim telemetry.tracing=sdk-otlp`) shows a `span-drop` finding and the corresponding overhead comparison carries `degraded: true` and verdict `inconclusive`; and when the ADR validates under strict profile enforcement.

The plan as a whole is accepted when a person who has never seen this repository can answer the owner's three questions for the synthetic service from one `overhead-report.json`, and when the five layer plans can wire their components by following the guide without importing anything from this package beyond `Kenshou.Telemetry`, `Kenshou.Telemetry.Endpoint`, `Kenshou.Telemetry.Compose` and `Kenshou.Telemetry.Continuity`.


## Idempotence and Recovery

Every run and every overhead invocation writes into a fresh directory named by a new UUIDv7, so repeating any command is safe and never overwrites evidence. Delete `runs/ep7` at will. `kenshou overhead --resume` is the recovery path for an interrupted invocation; `--analyse-only` recomputes the report without running anything, which is also how to re-judge old runs after a policy change.

The helper processes are the main thing that can be left behind. `withTelemetry` closes their standard input and then kills their process group, also when the body throws; after a `kill -9` of `kenshou` itself, look for orphans with `pgrep -fl 'kenshou worker --role telemetry-'` and remove them with `pkill -f 'kenshou worker --role telemetry-'`. The sink and the metrics servers bind free ports chosen at run time, so a stale helper cannot make the next run fail with "address in use"; the one exception is shibuya's server, for which a port is reserved and released before use, so a rare collision shows up as a readiness timeout and an `errored` run, which is safe to repeat.

Adding constraints to the cohort files changes the solver plan for everyone; do it in a separate commit, run `cabal build all` and the link-proof test from the bootstrap plan, and revert that commit if the plan no longer resolves. If the measurement toolkit needs the `variedFactors` parameter, make that change additive (an empty list keeps today's behaviour) so that its own tests keep passing. ADR creation is safe to retry: `okf id next` only proposes a handle, and a half-written record can be deleted before it is committed.


## Interfaces and Dependencies

Libraries, all from the pinned cohort: `hs-opentelemetry-api`, `-sdk`, `-exporter-otlp`, `-exporter-prometheus`, `-propagator-w3c` and `-otlp` at 1.0.0.0 (the API the runtime libraries compile against is `^>=1.0`); `warp` and `wai` for the sink, the Prometheus exposition and the synthetic service; `http-client` for scraping; `websockets` and `wai-websockets` for the subscriber and the synthetic push endpoint (kiroku-metrics and shibuya-metrics already bring them into the build plan); `proto-lens` and `zlib` for the sink; `process` for helper processes; `kenshou-core` and `kenshou-measure` from this repository. The `kenshou` executable must be linked with `-threaded`. No runtime library is a dependency of `kenshou-telemetry`. `kenshou-cli` gains a dependency on `kenshou-telemetry`, and passes a leak-check hook only if `kenshou-diagnose` exists.

At the end of Milestone 1 these must exist: `Kenshou.Telemetry` exporting `withTelemetry :: TelemetrySpec -> (TelemetryHandles -> IO a) -> IO a`, `TelemetryHandles (..)`, `TelemetrySpec (..)`, `TracingArm (..)`, `MetricsArm (..)`, `telemetryKnobs :: [KnobSpec]` and `telemetrySpecFromContext :: RunContext -> Either Text TelemetrySpec`; `Kenshou.Telemetry.Tracing.Probe` with `SpanView (..)`, `SpanProbe`, `newSpanProbe`, `readSpans`, `spansSeen`; `Kenshou.Telemetry.Tracing.Pipeline` with `PipelineStats`, `countingProcessor`, `instrumentExporter`, `snapshotPipeline`; `Kenshou.Telemetry.Sink` with `sinkApplication` and `runSinkRole`; `Kenshou.Telemetry.SelfTest.selfTestBundle :: LayerBundle`; the schema `schemas/kenshou.telemetry-summary.v1.schema.json`; and the scenario `selftest/telemetry/benchmark/arms-on-synthetic-service`.

At the end of Milestone 2: `Kenshou.Telemetry.Metrics`; `Kenshou.Telemetry.Endpoint` with `Endpoint (..)`, `EndpointKind (..)`, `reserveFreePort`, `awaitHttpReady`; `Kenshou.Telemetry.Scrape` with `runScraperRole`, `runScraperInProcess`, `wsSlotLeakProbe`; the run-directory files `series/scrape-<name>.csv` and `series/scrape-<name>-ws.csv`; and `docs/guides/wiring-telemetry-arms.md`.

At the end of Milestone 3: `Kenshou.Telemetry.Overhead` with `planOverhead`, `executeOverhead`, `analyseOverhead`, `OverheadHooks (..)`, `OverheadReport`; `Kenshou.Telemetry.Overhead.Policy`; Execution `Kenshou.Cli.Overhead` using EP-2's `InputSource` and option-group contract; `policies/telemetry-overhead.json`; `schemas/kenshou.overhead-report.v1.schema.json`; and the subcommand `kenshou overhead` with the exit codes 0, 1, 2, 3 and 4.

At the end of Milestone 4: `Kenshou.Telemetry.Compose` with `composeHandlers`, `timedHandler`, `slowHandler`, `asyncHandler`; `Kenshou.Telemetry.Continuity` with `checkContinuity`, `checkIsolation`, `SpanSelector (..)`; `Kenshou.Telemetry.Detect`; the file `series/otel-pipeline.csv`; the two remaining self-test scenarios; and one new record in `docs/adr/`.

Other plans consume this one as follows. The five coverage plans (`docs/plans/8-cover-pgmq-hs-in-isolation.md` through `docs/plans/12-cover-the-keiro-command-processor-process-managers-and-routers.md`, and through the shared keiro package `docs/plans/13-cover-the-keiro-outbox-inbox-and-job-queue.md` and `docs/plans/14-cover-keiro-durable-execution-timers-and-sharded-subscriptions.md`) append `telemetryKnobs` to their scenarios, declare their dimension support as the guide prescribes, wrap their component in `withTelemetry`, and each deliver a "telemetry arms" milestone whose headline is a `kenshou overhead` run on one of their benchmarks. `docs/plans/3-plan-and-select-runs-from-what-changed.md` expands the two dimensions under its `telemetry-corners` policy, which means the all-off cell and the `sdk-otlp` with `serve-scraped` cell; that is how a correctness failure that appears only with telemetry on becomes visible. `docs/plans/15-verify-the-assembled-runtime-end-to-end-and-under-soak.md` measures whole-system overhead with the same command. `docs/plans/17-run-kenshou-on-leased-cells-with-payloads-submission-and-retrieval.md` sets `otel.endpoint` to the cell's collector and may ship `planOverhead`'s slots as a run plan and call `analyseOverhead` on the fetched results. `docs/plans/18-record-runs-and-attestations-in-a-historic-okf-evidence-bundle.md` may link an overhead report as a data artifact of the runs it records.


Revision note (2026-09-20): Aligned `kenshou overhead` with EP-2's `haskell-jitsurei`-based CLI contract: Execution grouping, intent-based option sections, explicit stdin for policy documents, and clean JSON output.
