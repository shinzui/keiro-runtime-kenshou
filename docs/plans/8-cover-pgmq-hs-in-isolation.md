---
id: 8
slug: cover-pgmq-hs-in-isolation
title: "Cover pgmq-hs in isolation"
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
      at: 2026-09-22T00:33:49Z
      mode: "implement"
      note: "Started EP-8 after verifying toolkit, database, cohort, and pgmq-hs dependency prerequisites."
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-22T20:16:02Z
      mode: "implement"
      note: "Replaced the manufactured thread lease sabotage with a live concurrent PostgreSQL race and recorded its paired outcomes."
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-22T20:55:50Z
      mode: "implement"
      note: "Added durable per-batch SIGKILL accounting and separate-owner stale-ack evidence."
---

# Cover pgmq-hs in isolation

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`pgmq-hs` is the Haskell client for PGMQ, a message queue that is nothing more than a few PostgreSQL tables and SQL functions. It is the bottom of the keiro runtime's messaging stack: the shibuya PGMQ adapter and keiro's job queue (`keiro-pgmq`) are both thin layers over it, so every guarantee they advertise — a message is never lost, a crashed worker's message comes back after its lease expires, two workers never hold the same message, a FIFO group is processed in order — is only as good as what pgmq-hs and the PGMQ SQL actually do. Today pgmq-hs is tested inside one process, against a PostgreSQL with `fsync=off`, with leases expired by rewriting a timestamp rather than by waiting, and with a single-threaded benchmark. Nothing checks it across operating-system processes, under `SIGKILL`, across a PostgreSQL restart, under a saturated connection pool, or for hours.

After this plan, a maintainer can run `kenshou list --layer pgmq` and see about fifty scenarios that isolate pgmq-hs from everything above it. They can run `kenshou run pgmq/vt/concurrency/crash-redelivery-read-count --out runs` and watch a consumer process be killed five times with a real `SIGKILL` while the harness proves, from PostgreSQL's own timestamps, that the message came back no earlier than its visibility timeout, that its read counter went 1, 2, 3, 4, 5, 6, and that nothing was lost. They can run the benchmark `pgmq/effectful/benchmark/layer-ladder` and see what each layer (hand-written SQL, `pgmq-hasql`, `pgmq-effectful`) costs, run `kenshou overhead pgmq/effectful/benchmark/interpreter-tracing-overhead` and see what the OpenTelemetry-traced interpreter costs compared with the plain one, and run a soak that ends with a leak verdict for the driver and a bloat verdict for the queue and archive tables. Known upstream defects (a notification storm on partitioned queues, grouped reads that come back unsorted, partition retention that deletes unread messages, a reconciler that creates a queue over a mixed-case alias) are present as scenarios that report the defect with a link to the upstream plan without turning the run red. When the `pgmq` layer is green and a layer above it is red, the fault is above pgmq-hs; that attribution is the point of this plan.


## Progress

Milestone 1 — pgmq-hs correctness scenarios (includes the package, the shared harness and registration).

- [x] (2026-09-22 00:34Z) Verified the kernel, measurement, correctness, diagnostics, telemetry, CLI, live PostgreSQL round trip, released pgmq cohort, Hackage release, and upstream tag.
- [x] (2026-09-22 00:52Z) Created `kenshou-pgmq`, its 39-module library, `kenshou-pgmq-test`, and the 49-scenario bundle; the package and CLI build in the dev shell.
- [x] (2026-09-22 00:52Z) Registered the bundle in `kenshou-cli`; `kenshou list --layer pgmq` reports 49 registry-valid scenarios and three worker roles.
- [x] (2026-09-22 05:54Z) Wired every internal library required by `kenshou-cli` through the Nix `callCabal2nix` graph; `nix flake check` now evaluates the CLI package and passes both repository checks.
- [x] (2026-09-22 01:01Z) Implemented `Kenshou.Suite.Pgmq.Knobs` (common knob vocabulary and `resolveKnobs`) with focused default, invalid-combination, and queue-identity tests.
- [x] (2026-09-22 00:52Z) Implemented the pool, per-run queue names, setup/teardown, plain/traced effect interpreter, telemetry bracket, and pg_partman probe; live round trips pass on PostgreSQL 17 and 18.
- [x] (2026-09-22 02:28Z) Completed the dedicated-connection SQL metrics poller; live collection recorded queue-depth transitions and poll latency, while queue-name derivation remains unit tested.
- [x] (2026-09-22 00:52Z) Implemented the fact vocabulary, database-clock lease and due-time oracles, topic model, and raw LISTEN wrapper; doctored overlap, duplicate-read-count, early-delivery, and explicit-release tests pass.
- [x] (2026-09-22 01:42Z) Replaced the catalog-wide probe for all 18 correctness identifiers with contract-specific runners and added durable queue/archive conservation queries.
- [x] (2026-09-22 01:42Z) Implemented the `queue`, `send`, `read` and `ack` correctness scenarios.
- [x] (2026-09-22 01:42Z) Implemented the `vt` correctness scenarios, including real wall-clock expiry.
- [x] (2026-09-22 02:28Z) Implemented the `fifo`, `topics`, `notify`, `config` and `effectful` correctness scenarios, including W3C trace propagation and the two known-defect scenarios.
- [x] (2026-09-22 01:42Z) Ran all 18 correctness scenarios on PostgreSQL 17 and 18. Sixteen pass on both versions; `mixed-case-alias-collision` reproduces its declared non-blocking defect on both; `grouped-result-order` returned ordered vectors in these runs and reports that the declared defect did not reproduce.
- [x] (2026-09-22 04:09Z) Persisted machine-readable `kenshou.verdict/v1` artifacts for the contract checks instead of leaving their results only in summary JSON; live lifecycle evidence is in run `01a0c751-7882-7279-8f18-e79bb08a5221`.
- [x] (2026-09-22 00:52Z) Wrote the first `docs/layers/pgmq.md`, with every registered identifier, classification, known-defect link, shared knobs, and operating rules; the unit suite enforces coverage.

Milestone 2 — pgmq-hs concurrency and crash scenarios.

- [x] (2026-09-22 02:05Z) Implemented `Kenshou.Suite.Pgmq.Roles` (`pgmq-producer`, `pgmq-consumer`, `pgmq-reconciler`) with the `after-read` crash point, finite producer/consumer protocols, and real reconciliation; the roles remain registered in the bundle.
- [x] (2026-09-22 02:05Z) Replaced the catalog-wide probe for all 20 concurrency identifiers with scenario-specific runners spanning thread and process contention, `SIGKILL`, pool exhaustion, backend termination, PostgreSQL immediate shutdown, TCP reset, FIFO hazards, notification state, reconciliation, and overlapping acknowledgements.
- [x] (2026-09-22 20:15Z) Replaced the manufactured unlocked-read result with sixteen concurrent PostgreSQL reads of one row. The ordinary PGMQ path has one owner and passes; the unlocked SQL path has sixteen owners and fails with a persisted verdict.
- [x] (2026-09-22 20:25Z) Collected every worker-process read mark from its persisted control log and applied `checkLeaseIntervals` to database-clock leases; durable PostgreSQL 17 and 18 runs observed all 1,000 sends with no overlap or duplicate read count and an empty queue.
- [x] (2026-09-22 20:48Z) Ran concurrent producer and consumer processes, reconstructed all lease intervals and sent IDs from strict worker logs, and proved process-level non-vacuity with four unlocked SQL readers. PostgreSQL 18 handled 1,200 messages without overlap; the unlocked arm failed with `DuplicateReadCount`.
- [x] (2026-09-22 20:20Z) Captured each killed consumer's database read time, visibility deadline, message IDs, and read counts; verified every kill round, no early redelivery, bounded expiry lag, final delivery, and acknowledgement on PostgreSQL 17 and 18.
- [x] (2026-09-22 20:55Z) Replaced the one-batch queue-length probe with five producer processes killed at seeded delays after their persisted intents. PostgreSQL 18 observed three whole committed batches and two absent batches, including two committed batches whose `Sent` mark was interrupted; the per-batch durable-key verdict passed on PostgreSQL 17 and 18.
- [x] (2026-09-22 20:56Z) Ran the stale acknowledgement boundary through separate owner pools and recorded both database-clock leases, both delete results, the failed visibility extension, and the final empty queue in an implementation-class verdict on PostgreSQL 17 and 18.
- [x] (2026-09-22 21:10Z) Replaced the alias to deterministic redelivery with seeded consumer-process kills and restarts under continuous batch production. Short durable runs on PostgreSQL 17 and 18 passed the no-loss, interrupted-lease, bounded-duplicate, lease-interval, and drain oracles; PostgreSQL 18 processed 4,000 sends with four kills and 40 unacknowledged killed leases.
- [x] (2026-09-22 21:43Z) Ran the full ten-minute, 500/s random-kill acceptance on durable PostgreSQL 18: 300,000 sends, 120 `SIGKILL` and restart rounds, 857 unacknowledged killed leases, 300,000 handled keys, zero lease findings, and an empty final queue. Ten committed acknowledgements had no worker-side reply mark, so the oracle used durable handling and drain evidence.
- [x] (2026-09-22 21:56Z) Completed the matching ten-minute, 500/s random-kill acceptance on durable PostgreSQL 17: 300,000 sends, 120 `SIGKILL` and restart rounds, 809 unacknowledged killed leases, 300,000 handled keys, zero lease findings, and an empty final queue.
- [x] (2026-09-22 02:05Z) Implemented pool exhaustion with long polling and verified transient acquisition timeout plus same-pool recovery.
- [x] (2026-09-22 02:54Z) Added pg_partman to both dev-shell PostgreSQL majors and replaced the partition probes with live notification-storm and retention workloads; both declared defects reproduce on PostgreSQL 17 and 18 as non-blocking known defects.
- [x] (2026-09-22 21:26Z) Expanded the immediate PostgreSQL crash probe to persist the outage error, same-pool recovery time, durability setting, and committed message IDs. PostgreSQL 17 and 18 both recovered in under 0.4 seconds with all committed rows and `fsync=on`; both rejected the empty-SQLSTATE disconnect as permanent. Filed the common classifier gap as `mori://shinzui/pgmq-hs/okf/improvement-requests/concepts/IR-4` and verified backend termination, restart, and TCP reset report only their exact classifier failures as non-blocking known defects.
- [ ] Complete the backend-termination, PostgreSQL restart/crash, unlogged-queue, and network-proxy workloads and their full transient-error and conservation oracles beyond the focused probes already present.
- [x] (2026-09-22 02:05Z) Implemented and ran the FIFO concurrency scenarios (head-per-group barrier, grouped batch successor hazard, producer commit-order inversion).
- [x] (2026-09-22 03:38Z) Replaced the listener-fallback probe with a real LISTEN backend termination; PostgreSQL 17 and 18 both prove disconnected notifications do not replay and the polling fallback drains all 20 sends inside the configured bound.
- [x] (2026-09-22 21:39Z) Expanded throttle-loss-after-crash on PostgreSQL 17 and 18: after immediate shutdown the unlogged throttle state vanished and all 250 sends over five seconds notified; reconciliation reported `EnabledNotify`, restored the throttle row, and bounded the next 250 sends to six notifications. The listener saw only the canonical channel.
- [x] (2026-09-22 21:48Z) Expanded concurrent reconciliation to fifty rounds of ten declarations with eight callers. Every round's catalog converged, but reports claimed multiple creators, and both PostgreSQL majors produced SQLSTATE `23505` from FIFO index creation. Filed both defects as `mori://shinzui/pgmq-hs/okf/improvement-requests/concepts/IR-5` and verified precise non-blocking labels on PostgreSQL 17 and 18 while catalog correctness remains a separate blocking check.
- [x] (2026-09-22 21:52Z) Expanded overlapping batch acknowledgements to sixteen simultaneous callers through sixteen pool connections, with opposite identifier orders, bounded transient retries, durable deletion conservation, and a recorded deadlock rate. PostgreSQL 17 and 18 each deleted all 200 IDs exactly once and drained; both observed zero deadlocks, so the live SQLSTATE branch still needs a reproducer.
- [x] (2026-09-22 21:56Z) Moved the fifty-round reconciliation workload from eight threads to eight persistent `pgmq-reconciler` child processes with round-specific control marks. PostgreSQL 18 preserved catalog convergence in all rounds and reported 24 known FIFO index errors plus duplicate creator claims; the known-defect disposition remained precise and non-blocking.
- [x] (2026-09-22 21:56Z) The same eight-process, fifty-round reconciliation workload on durable PostgreSQL 17 converged in every round and reproduced the FIFO index race and duplicate creator reports as the precise non-blocking IR-5 defect.
- [x] (2026-09-22 22:01Z) Recorded queue depth and partition count after each partition maintenance step on durable PostgreSQL 17 and 18. Both first lost rows when the 300th send advanced retention: queue depth fell to 201, then remained 201 through 2,000 sends. Each lost all 50 leased rows and 1,799 rows overall, reproducing the declared non-blocking retention defect.
- [x] (2026-09-22 22:04Z) Paced the partitioned notification storm at 200 sends/s for five seconds and listened through the disabled phase. Durable PostgreSQL 17 and 18 each emitted 1,000 partition-channel notices, versus the throttle bound of 21, and zero notices after disabling. The known defect remains non-blocking with the throughput of both phases recorded.
- [ ] Complete the remaining deadlock-classification evidence and run every concurrency scenario on both durable PostgreSQL versions.
- [ ] Run every concurrency scenario with `pg.durability=durable` on both PostgreSQL versions; record outcomes and any new defect filed upstream.

Milestone 3 — pgmq-hs benchmarks.

- [x] (2026-09-22 02:28Z) Implemented `Kenshou.Suite.Pgmq.RawSql` and `Kenshou.Suite.Pgmq.Client`; live layer-ladder runs exercised distinct hand-written SQL, pgmq-hasql, and pgmq-effectful paths.
- [x] (2026-09-22 02:28Z) Implemented measured `layer-ladder`, `send-throughput`, and `read-ack-throughput` workloads using the shared load generator and recorder.
- [x] (2026-09-22 03:11Z) Implemented distinct poll, server long-poll, and LISTEN/NOTIFY-with-poll-fallback paths in `produce-consume-latency`; benchmark-grade PostgreSQL 18 runs passed for all three modes.
- [x] (2026-09-22 02:28Z) Implemented `invisible-backlog-read-cost`, `grouped-read-cost`, and `notify-insert-overhead`; short live runs of the grouped, send, metrics, and all three ladder paths pass.
- [x] (2026-09-22 03:42Z) Added `policies/pgmq.json`, ran fixed-rate paired A/A controls for all nine benchmarks, and proved the deliberately slowed read/ack arm is detected as a regression. Send throughput and produce-consume A/A pass; the other seven remain honestly inconclusive on tail-latency interval width despite passing individual runs and stable throughput.
- [ ] Re-run the seven locally noisy A/A controls on a quiet cell and confirm verdict `pass` without weakening the checked-in tail-latency policy.

Milestone 4 — pgmq-hs soak and telemetry arms.

- [x] (2026-09-22 02:28Z) Added functional `pgmq.trace.propagate` and `otel.semconv-stability-opt-in` knobs; live correctness runs pass under all four tracing arms, SQL metrics collection, all semantic-convention modes, and W3C context propagation.
- [x] (2026-09-22 05:03Z) Implemented `pgmq/queue/soak/steady-state` and `pgmq/queue/soak/steady-state-reduced` from one constructor, made their arrival model explicitly open-constant, and added an independently judged `series/pgmq-queue-depth.csv` sampler. Short proof run `01a0c77e-4338-7331-b80c-5110827f77b8` wrote the series, kept depth at zero after first-delivery nack churn, and drained without workload failures; its leak verdict is intentionally inconclusive because the overridden steady window was five seconds.
- [ ] Obtain a `stable` leak verdict from the full twenty-minute reduced profile. Final tracing-off run `01a0c798-5508-7549-9b0e-2fc0754328e8` kept every non-heap probe stable but still measured 96.8 MB/hour of bounded-probe live-heap growth.
- [x] (2026-09-22 02:28Z) Implemented and ran `interpreter-tracing-overhead` and `metrics-poll-overhead`. Metrics collection passed policy; tracing found `sdk-inmemory` above policy while `noop` and `sdk-otlp` passed.
- [ ] Run the reduced soak with `telemetry.tracing=sdk-otlp` and confirm the leak verdict is still `stable`. Final run `01a0c798-5508-77db-9004-674089ca9310` exported every span without loss and kept the exporter queue bounded, but the common live-heap probe still grew at 78.3 MB/hour.
- [x] (2026-09-22 02:28Z) Wrote ADR-12 through ADR-14 for database-clock leases, native SQL metrics collection, and limitation/known-defect classification; the 14-record bundle passes strict OKF validation.
- [x] (2026-09-22 05:52Z) Updated the MasterPlan progress and this retrospective; the EP-8 registry row remains `In Progress` because concurrency, benchmark A/A, and stable-heap acceptance are unresolved.


## Surprises & Discoveries

- Observation: Hackage's preferred-version endpoint and the upstream Git tags both identify `0.6.1.0` as the current pgmq-hs release, while the local Mori corpus exposes the matching release source and documentation.
  Evidence: `https://hackage.haskell.org/package/pgmq-core/preferred.json`, upstream tag `v0.6.1.0`, and `mori registry show shinzui/pgmq-hs --full` all agree on the selected cohort.

- Observation: the released effect interpreter closes over the exact stack `Eff '[Pgmq, Error PgmqRuntimeError, IOE]`; a helper polymorphic in an arbitrary tail does not type-check against the library's `runPgmq`/`runPgmqTraced` API.
  Evidence: `Kenshou.Suite.Pgmq.Harness.runOps` required the exact stack found in the Mori-located `pgmq-effectful` source. The resulting implementation builds and completed real queue round trips on PostgreSQL 17 and 18.

- Observation: terminating the backend that owns an in-flight long poll surfaces as `UnexpectedRowCountStatementError 1 1 1`, not as a connection error or SQLSTATE `57P01`. The same pool recovers and accepts a subsequent send, but `Pgmq.Effectful.isTransient` classifies the interruption as permanent because the released policy deliberately treats decode-side row-count errors as permanent.
  Evidence: run `01a0c6cd-303d-7294-a3ec-a0de837cb1fd` records the complete interrupted and recovered results in `summaries.verdicts.backend-termination-observations`; PostgreSQL logged the administrative backend termination. The documented policy is in `mori://shinzui/pgmq-hs` at `docs/design/017-transient-error-classification.md`; artifact-level design-document URIs are pending.

- Observation: resetting a live proxied PostgreSQL connection can surface as `ServerError "" "" Nothing Nothing Nothing`, with no SQLSTATE. The same proxied pool recovers after forwarding resumes, but `Pgmq.Effectful.isTransient` classifies the empty server error as permanent.
  Evidence: run `01a0c6cd-bb2d-771a-9783-75da1b115a45` records the complete reset and recovery results in `summaries.verdicts.network-partition-observations`. No existing improvement request in `mori://shinzui/pgmq-hs` covers either newly observed error shape, so this plan records the evidence without claiming that an upstream defect has been filed.

- Observation: the first short soak left a bounded tail of one-second deliberate nacks at measurement end, so judging the raw final row count misclassified normal in-flight work as bloat. Waiting one visibility interval and draining the queue makes the final bloat verdict test convergence instead of an arbitrary phase boundary.
  Evidence: run `01a0c6e5-6f29-763f-bffa-635bcbdcdf10` ended with 400 queue rows; after adding the drain, run `01a0c6e6-b6c8-75eb-8712-69d1b5f3986b` ended with zero queue rows and a bounded bloat verdict.

- Observation: the shared leak catalog requested `dead_tuples`, but the PostgreSQL sampler writes the native `n_dead_tup` column name. This made the PGMQ soak's dead-tuple probe permanently insufficient even though the series was present.
  Evidence: the first short soak reported `MissingColumn ... "dead_tuples"`; the catalog now binds `pg.dead-tuples` to `n_dead_tup`, matching `Kenshou.Measure.Sampler.Postgres`.

- Observation: the first controlled tracing-overhead run found meaningful arm-specific cost: `noop` and `sdk-otlp` passed the checked-in policy, while `sdk-inmemory` regressed with approximately 37% higher p99 and 23% more allocation per operation.
  Evidence: `runs/overhead-01a0c6ed-bfc5-7729-bf5b-3ac8db3ea7e4/overhead-report.json`. The metrics-poll study passed at `runs/overhead-01a0c6ef-8a1b-730a-9735-db121bfa73f2/overhead-report.json`.

- Observation: the dev shell's bundled pg_partman reproduces both partition hazards identically on PostgreSQL 17.11 and 18.6. The notify trigger produced 1,000 notifications for 1,000 separate inserts, all on leaf-partition channels, where the 250 ms throttle permits at most 21 over five seconds. Numeric retention removed 1,799 of 2,000 acknowledged sends, including all 50 rows leased before maintenance; the default partition stayed empty, so the result is retention rather than runway overrun.
  Evidence: PostgreSQL 17 runs `01a0c706-8745-77f6-997a-a4e569bf4349` and `01a0c706-91a7-7740-b840-0b0a06ae6adf`; PostgreSQL 18 runs `01a0c707-187b-7595-8f8e-bf52d961d61e` and `01a0c707-22d1-770e-91d6-5bb7783239fd`. All four carry `knownDefect.status=reproduced` and `blocking=false`.

- Observation: the three produce-consume wake paths produce materially different intended-start latency distributions under the same local PostgreSQL 18 fixture. Polling with two load workers recorded p50 0.37 ms and p99 0.88 ms; server long polling at a 5 ms poll interval with eight workers recorded p50 2.64 ms and p99 26.49 ms; unthrottled LISTEN/NOTIFY with eight workers recorded p50 4.69 ms and p99 17.27 ms. These are illustrative local figures, not cross-run performance claims.
  Evidence: benchmark-grade passing runs `01a0c70f-5ff7-7524-bbb8-22952cb89d60`, `01a0c70e-a7bd-723c-bc2c-e380c8e7cf02`, and `01a0c70f-803a-712e-b1ef-29e6a4bac505`, respectively.

- Observation: behavior-neutral fixed-rate A/A trials are stable in throughput but this local machine's database tail latency is too noisy for a three- or six-pair 15% p99 policy on seven of nine benchmarks. All individual arms passed; send-throughput and produce-consume controls passed the full policy, while the other controls remained inconclusive rather than creating false regressions. Increasing the rate to 1,000 operations per second worsened the layer-ladder tail instead of narrowing it, so those controls need a quieter cell rather than weakened policy.
  Evidence: `runs/aa-pgmq-send-benchmark-send-throughput.json` (comparison `01a0c717-dbbd-749f-8d40-869ce8e6383a`) and `runs/aa-pgmq-read-benchmark-produce-consume-latency.json` (comparison `01a0c723-46c7-77fc-a3ea-9a67ea9af1ae`) pass. The six-pair reports for read/ack, backlog, grouped, notify, tracing, and metrics pass throughput but remain inconclusive on p99. Comparison `01a0c732-ce15-737e-bd03-1e0820a8d1bb` correctly classifies the 5 ms handler arm as a regression with a 4.22 median-latency ratio.

- Observation: a LISTEN connection terminated by `pg_terminate_backend` loses notifications published while it is disconnected, as PostgreSQL documents, while an independent PGMQ polling fallback still drains the complete batch immediately after the fault.
  Evidence: PostgreSQL 17 run `01a0c72d-a9df-70ed-8adc-425bde540eb9` and PostgreSQL 18 run `01a0c72d-b413-701e-90db-f030e7082f48` both handled 20 of 20 messages in under 2 ms with a one-second fallback bound; a newly connected listener received none of the notifications emitted during the outage.

- Observation: the soak initially inherited the measurement toolkit's closed-loop load default, so setting only `load.rate-per-second` did not bound arrivals. The resulting invalid control drove roughly 4,800 cycles per second and accumulated almost six million spans before it was stopped.
  Evidence: aborted run `01a0c74d-8d67-7627-9f23-b663c27eced3`; the catalog now resolves both soak profiles to `load.model=open-constant` and `load.rate-per-second=500`, and `kenshou-pgmq-test` locks those defaults.

- Observation: the first correctly rate-limited twenty-minute controls still reported approximately 0.9 GB/hour of heap growth in both tracing-off and OTLP arms. The measurement recorder retained one roughly fixed-size mutable histogram per executor per ten-second interval until shutdown, so the suite's own evidence buffer grew linearly and contaminated its leak verdict. Both workloads completed 120,000 cycles at 100/s with zero failures and drained to zero; the OTLP arm exported all 359,033 ended spans with a bounded queue and no drops.
  Evidence: tracing-off run `01a0c75d-a713-7640-9a98-6188edfd810e` and OTLP run `01a0c75a-f97d-7366-9594-42105861430e` both failed only `leak-suspected`. Soak scenarios now default `measure.interval-histogram-seconds` to 86,400, bounding retained interval arrays to one or two frames while preserving their aggregate histogram.

- Observation: once queue depth was sampled independently of `telemetry.metrics`, the initial soak cycle showed a deterministic one-row-per-second backlog slope: it sent one row and could read only one, so every deliberate nack permanently consumed that cycle's service capacity. Draining after measurement made the old final-row oracle look bounded despite the positive steady-state trend.
  Evidence: stopped controls `01a0c774-14f5-7212-b48f-b0f2c303349b` and `01a0c774-14f5-76e3-a5a2-f5cdb2891a44` reached depth 300 after 270 seconds. The cycle now reads a batch and deliberately nacks selected rows only on their first delivery; short run `01a0c77e-4338-7331-b80c-5110827f77b8` returned to depth zero and the leak policy now judges the queue-depth series as a bounded probe.

- Observation: after bounding interval histograms and queue depth, both full controls still found a common harness leak: each sampler tick used `race` between its deadline and a broadcast-channel read, creating and canceling two `Async` waiters per sampler per second. Haskell thread objects and live heap rose together even though OS threads, file descriptors, connections, queue depth, and the OTLP exporter were stable.
  Evidence: OTLP run `01a0c780-1edd-74b4-8cf5-23bd06d28a70` measured 76.1 MB/hour of live-heap growth and 48.2 Haskell threads/hour; tracing-off run `01a0c780-1edd-75a0-ab90-a28f0145da20` measured 96.5 MB/hour and 418 threads/hour. Replacing the per-tick race with one `registerDelay` observed from the existing STM transaction kept focused run `01a0c794-d792-73f0-804b-21a48544a1a7` at 15 Haskell threads for 120 seconds and live heap between approximately 11.5 and 13.1 MB.

- Observation: removing the sampler waiter leak made the thread verdict stable but did not remove the common live-heap slope. The final tracing-off and OTLP controls both completed 120,000 cycles with zero operation failures, zero final queue rows, a statistically flat queue-depth series, and stable native memory, OS threads, file descriptors, and database connections. The remaining failure is not attributable to tracing because it persists with tracing disabled and the tracing-off slope is higher; the two confidence intervals do not overlap.
  Evidence: tracing-off run `01a0c798-5508-7549-9b0e-2fc0754328e8` measured 96.8 MB/hour (95% interval 86.5–116.1 MB/hour); OTLP run `01a0c798-5508-77db-9004-674089ca9310` measured 78.3 MB/hour (74.5–81.2 MB/hour). The OTLP arm exported all 360,240 ended spans, dropped none, failed none, and reached a maximum queue depth of 518.

- Observation: the common `pgmq.consumers` default is one, which made the former thread sabotage pass without any contention. A live gate now starts at least two readers together against one row. With sixteen readers, the PGMQ read has one owner and the deliberately unlocked SQL read has sixteen owners.
  Evidence: normal run `01a0cac2-3c6a-736c-a134-d92fa348283c` passed; sabotage run `01a0cac1-f7fb-72c5-a1a9-d6319b97ddfe` failed and persisted the violated ownership verdict. Both were PostgreSQL 18 durable runs with `pgmq.consumers=16`.

- Observation: the worker's `after-read` control mark can carry PGMQ's database-sourced `lastReadAt` and `visibilityTime` for every leased row. The supervisor can therefore judge each real `SIGKILL` round against the prior lease deadline without relying on its own clock or a synthesized delivery count.
  Evidence: PostgreSQL 18 run `01a0cac8-479b-7207-962e-aedbc397a545` and PostgreSQL 17 run `01a0cac6-857e-7732-a428-e881e417beff` both passed two kills across three messages, with persisted per-round IDs, read counts, and timestamps.

- Observation: a queue-empty check alone can miss duplicate process ownership. The worker control log retains every `after-read` mark, so the process scenario can reconstruct all lease intervals rather than trusting only the final queue depth.
  Evidence: PostgreSQL 18 run `01a0cacd-76b5-779f-8352-7f24bd6af032` recorded 1,000 distinct leases from four consumer processes, no lease-oracle findings, and an empty queue with strict control-log decoding; PostgreSQL 17 run `01a0cacb-d8d1-74a6-986c-4ce2489693e3` also passed.

- Observation: the process-level sabotage exposed a real PGMQ table type mismatch with the first decoder draft (`read_ct` is PostgreSQL `int4`) and a short interval when the worker control log remains locked after its final mark. Reading the correct type and retrying the log read allowed the lease oracle to judge the evidence.
  Evidence: PostgreSQL 18 normal run `01a0cada-8a1d-7575-b8fe-229030e26e45` recorded 1,200 leases from four consumers and two producers; PostgreSQL 17 run `01a0cadb-220c-779e-b3f3-181c9f1265c9` passed with four producers. Sabotage run `01a0cadf-b034-77ac-a5db-cacaf46d7d23` failed specifically on `unique-ownership`, with four observed leases of one row and a `DuplicateReadCount` finding.

- Observation: a producer killed after beginning a batch can leave the complete batch durable without reporting `Sent`, or leave no rows at all. A missing worker reply therefore cannot decide whether the transaction committed; durable keys must decide atomicity for each recorded intent.
  Evidence: PostgreSQL 18 run `01a0cae6-1e7a-7164-a87b-ffe092405b8a` recorded five intents of fifty keys each. Two killed producers left all fifty keys without a `Sent` mark, and two left zero keys; the committed control had all fifty keys and its `Sent` mark. After adding an explicit kill assertion, run `01a0cae9-8658-7459-98a0-3f0a14e3b074` passed with four recorded `SIGKILL`s, three absent batches, and one complete batch whose `Sent` mark was interrupted.

- Observation: the consumer worker originally returned when an empty read found no messages. The sustained-kill scenario exposed that finite behavior immediately: all four workers exited before the first fault, so the attempted process-group signal failed. Keeping the consumer in a bounded-sleep polling loop lets it survive an initially empty queue and later production.
  Evidence: first short run `01a0caef-8398-7656-9186-ff7d211d47ea` failed with `signalProcessGroup: permission denied` after each worker reported `done`; corrected PostgreSQL 18 run `01a0caf8-b882-735c-a4fa-b7e737eb08de` recorded four real kills, 40 unacknowledged killed leases, and complete handling of 4,000 sends. PostgreSQL 17 run `01a0caf9-1278-7574-a042-86f826f60952` also passed.

- Observation: an immediate postmaster crash can surface a failed PGMQ send as a statement error with an empty SQLSTATE, which pgmq-hs 0.6.1.0 classifies as permanent. The same pool recovered quickly, all committed messages survived, and `fsync` remained enabled. This extends the earlier TCP-reset observation to a real durable-server crash on both supported PostgreSQL majors.
  Evidence: PostgreSQL 17 run `01a0cafc-cef2-7716-aa94-78d41afa7951` recovered in 362 ms and PostgreSQL 18 run `01a0cafc-7cda-7428-b7c5-efe34a8ceb48` in 358 ms. Both failed only `outage-error-transient`. The upstream request is `mori://shinzui/pgmq-hs/okf/improvement-requests/concepts/IR-4`.

- Observation: the kernel's known-defect disposition matches exact failure labels. A declared defect with expected label `known-defect` remains blocking if the real scenario fails on `outage-error-transient`; registering the classifier's precise label preserves a non-blocking `reproduced` status while leaving durability or recovery failures blocking.
  Evidence: first declared run `01a0cb04-15ba-713e-a077-1f0367008229` reported `different-failure`; corrected restart run `01a0cb05-2162-7090-b7fc-8632c34bfc50`, backend run `01a0cb06-cfb7-742a-992b-23996a0eac86`, and proxy run `01a0cb07-2dbc-7410-98c0-640dfd87daf1` each report `reproduced`, `blocking=false`, and exit code 0 with only the classifier check red.

- Observation: the upstream IR bundle passes profile enforcement, but its strict bundle gate was already red because IR-1, IR-2, and IR-3 omit the profile-recommended `reviews` field. The new IR-4 and IR-5 include the field and contribute no new strict diagnostic.
  Evidence: `okf validate docs/improvement-requests --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce` passed with five concepts; the `--strict` variant reported only the three older files' missing review metadata.

- Observation: the full random-kill run can lose an acknowledgement's worker-side reply mark while the database has already deleted the message. The distinct handled-key set and empty durable queue remain complete, while an `Acked`-mark equality would falsely report loss.
  Evidence: PostgreSQL 18 run `01a0cb08-b297-7541-bdd6-314abcfcfd3d` handled all 300,000 sends after 120 kills, but recorded 299,990 `Acked` marks. It recorded 857 unacknowledged killed leases and no lease-interval findings. PostgreSQL 17 run `01a0cb14-dfac-71f3-b041-157ac22270c4` matched the 300,000/299,990 sent/ack-mark counts, with 809 unacknowledged killed leases and no lease findings.

- Observation: concurrent `ensureQueuesReport` callers can converge in the catalog while reporting duplicate creators, and `pgmq.create_fifo_index` can additionally raise SQLSTATE `23505` on `pg_class_relname_nsp_index` despite using `CREATE INDEX IF NOT EXISTS`.
  Evidence: PostgreSQL 18 run `01a0cb0f-51a6-75cb-a822-e07dc52ecc71` had no worker errors but eighty creation claims for ten resources in each of fifty rounds; repeat run `01a0cb13-f5ae-77cd-9b7f-e6e4e7c0f1b9` also recorded the FIFO index catalog error. Final known-defect runs `01a0cb16-e1dd-74e7-a7e2-c22c639a88d4` on PostgreSQL 18 and `01a0cb17-ec19-755c-a785-c43a43c35760` on PostgreSQL 17 each converged while recording eight and nine worker errors, respectively. The owner request is `mori://shinzui/pgmq-hs/okf/improvement-requests/concepts/IR-5`.

- Observation: eight persistent reconciler child processes can run the fifty rounds through independent pools and report each round through process control marks. The catalog converged in every round despite the same two upstream defects.
  Evidence: PostgreSQL 18 run `01a0cb1e-22a1-741a-86f0-15c4a2176cad` recorded 24 FIFO index errors; PostgreSQL 17 run `01a0cb1e-db5c-7036-91f2-cc2257618239` also reproduced the FIFO index error. Both classified only `no-worker-errors` and `one-creator-report-per-resource` under `mori://shinzui/pgmq-hs/okf/improvement-requests/concepts/IR-5`; catalog convergence and all-round completion remained blocking checks.

- Observation: retention of a partitioned queue removed unread and leased rows during repeated maintenance. The first two hundred sends remained, but the 300th send and maintenance left only 201 rows; subsequent hundred-row batches never raised that depth. The final drain handled 201 of 2,000 sends, including none of the 50 rows leased before maintenance.
  Evidence: durable PostgreSQL 18 run `01a0cb22-c860-71c6-9956-e46ac4b417af` and PostgreSQL 17 run `01a0cb23-0fa0-743a-8056-26b3946369d7` recorded the same stage depths, 1,799 lost IDs, and 50 lost leased IDs. Both reproduced the declared non-blocking defect in `mori://shinzui/pgmq-hs/plans/21-state-the-fifo-ordering-and-partitioned-retention-contracts-truthfully`.

- Observation: paced insertion established the planned five-second notification load on partitioned queues. Each insert notified on a partition channel despite the 250 ms throttle, while disabling notifications silenced the same listener entirely.
  Evidence: durable PostgreSQL 18 run `01a0cb25-adea-717e-b019-3429b6be7841` and PostgreSQL 17 run `01a0cb26-181d-71cd-96c1-aa8d73c8c159` each sent 1,000 messages in 4.997 seconds, received 1,000 partition-channel notifications against an allowance of 21, then received zero notifications during a second 1,000-message phase of about five seconds. Both reproduced the non-blocking defect in `mori://shinzui/pgmq-hs/plans/23-gate-the-notification-fail-open-on-a-real-queue-row-and-state-the-partitioned-queue-contract`.

- Observation: sixteen simultaneous `batchDeleteMessages` calls over differently ordered overlapping ID sets completed without a deadlock on both PostgreSQL majors. This proves conservation under contention but leaves the live `40P01` retry classification unexercised by this scenario.
  Evidence: PostgreSQL 18 run `01a0cb19-8e41-7745-97f5-93ae7be5ce9a` and PostgreSQL 17 run `01a0cb1a-3f68-71cb-bbdc-693222dac862` each returned all 200 deleted IDs exactly once, recorded zero deadlocks, and ended with an empty queue.


## Decision Log

- Decision: Every scenario talks to PGMQ through `pgmq-effectful` (the function `runOps` in `Kenshou.Suite.Pgmq.Harness`) unless it needs something the effect cannot express (a caller-owned transaction, hand-written SQL, a `LISTEN` connection). `pgmq-hasql` is covered transitively and by the layer ladder and the interpreter-parity scenario.
  Rationale: `runPgmq` delegates one-to-one to `Pgmq.Hasql.Sessions` (verified in `pgmq-effectful/src/Pgmq/Effectful/Interpreter.hs`), so nothing is lost, and the interpreter choice (`runPgmq` versus `runPgmqTraced`) is the only tracing seam pgmq-hs has. Routing every scenario through it lets every scenario honour the `telemetry.tracing` dimension, which is how we learn whether tracing causes problems rather than only what it costs.
  Date: 2026-09-20

- Decision: Leases are judged on the database clock. The oracle compares `Message.lastReadAt` and `Message.visibilityTime`, both produced by PostgreSQL's `clock_timestamp()` inside the read, and never compares the clocks of two harness processes.
  Rationale: No-double-lease and "not redelivered before the visibility timeout" are statements about PostgreSQL time. Using the server's own timestamps makes the oracle exact and immune to clock skew between drivers on a cell.
  Date: 2026-09-20

- Decision: `telemetry.metrics` supports only `off` and `collect` in this layer. `collect` runs a poller that calls `allQueueMetrics` at the scrape interval on a dedicated connection.
  Rationale: pgmq-hs emits no metrics and serves no endpoint; its only metrics surface is the SQL function `pgmq.metrics`, which counts the whole queue table on every call. Polling it is what an operator actually does today. `serve` and `serve-scraped` have nothing to serve until `mori://shinzui/pgmq-hs/okf/improvement-requests/concepts/IR-3` (a `pgmq-metrics` sister package) ships; add them then.
  Date: 2026-09-20

- Decision: `pgmq.read-strategy` selects the read function family (`plain`, `pop`, `grouped`, `grouped-round-robin`, `grouped-head`) and `pgmq.poll.max-seconds` selects between the immediate function (0) and its `…WithPoll` sibling (greater than 0).
  Rationale: pgmq-hs has no strategy parameter, only distinct functions; this maps two knobs onto the real choice a caller makes and mirrors the shibuya adapter's `FifoConfig.readStrategy` and `LongPolling` fields so results carry over to the layer above.
  Date: 2026-09-20

- Decision: Scenarios that need a partitioned queue probe for the `pg_partman` extension and end `errored` with a remediation message when it is absent; they are never silently skipped and never the default value of `pgmq.queue-kind`.
  Rationale: PGMQ's own schema is installed without an extension, but `pgmq.create_partitioned` calls `pg_partman`, which must be compiled into the PostgreSQL the dev shell or the cell provides. A skip would hide two of the four known defects this plan exists to show.
  Date: 2026-09-20

- Decision: Documented limitations (no fencing of stale acknowledgements, unlogged queues lose data on crash, grouped batches lease a successor with its predecessor, message identifiers follow insert order and not commit order, throttle lost after a crash until the next reconcile) are asserted as `implementation`-class invariants whose pass condition is "behaves as documented". Only behaviours with an upstream plan to change them carry a `KnownDefect`.
  Rationale: The platform owner needs to see these hazards demonstrated, but they are not regressions and must not block a release. Partition retention dropping unread rows is the one exception: it carries a `KnownDefect` because it is silent data loss that the platform owner must see on every report, even though upstream currently plans only to document it, so it will stay a reported known defect until upstream changes behaviour.
  Date: 2026-09-20

- Decision: The soak is registered twice from one constructor: `steady-state` (tier `soak`, placement `cell`, four hours) and `steady-state-reduced` (tier `extended`, placement `either`, twenty minutes).
  Rationale: The kernel gives a scenario exactly one cost tier, and the MasterPlan requires every soak to be runnable locally at a reduced duration.
  Date: 2026-09-20

- Decision: The "raw SQL" rung of the layer ladder is a hand-written `hasql` statement that calls the PGMQ SQL function directly through the same pool, as `pgmq-bench` does, not a separate libpq driver.
  Rationale: The question the ladder answers is what the pgmq-hs wrappers add (encoders, the `COALESCE` guards, decoders, effect dispatch, spans); changing the driver as well would confound it.
  Date: 2026-09-20

- Decision: The local PostgreSQL 17 and 18 fixtures use `postgresql.withPackages (ps: [ ps.pg_partman ])`; the unextended packages remain unsuitable for accepting this layer because they turn two required known-defect experiments into infrastructure errors.
  Rationale: Partitioning is part of the released PGMQ contract exercised by this plan. Keeping the extension in both runtime majors makes the matrix symmetric and lets `requirePartman` distinguish installation errors from unavailable binaries.
  Date: 2026-09-22

- Decision: Soak scenarios use the measurement toolkit's one-day interval-histogram default, while benchmarks retain ten-second frames and every scenario may still override the knob explicitly.
  Rationale: mutable interval histograms are intentionally retained until the recorder can merge and serialize them. Ten-second frames are valuable for short benchmark analysis but create a harness-owned linear heap slope during multi-hour leak checks; a day-long frame keeps the soak observer bounded without removing aggregate latency evidence.
  Date: 2026-09-22

- Decision: sampler deadlines and phase-boundary events share one STM wait using `registerDelay`; sampler loops do not create and cancel `Async` waiters on every tick.
  Rationale: a leak detector must not add live thread objects in proportion to the number of samples. The single STM wait preserves immediate phase-boundary wakeups and scheduled deadlines without a per-sample child-thread lifecycle.
  Date: 2026-09-22

- Decision: the batch-kill oracle compares each persisted producer intent against PostgreSQL's durable queue keys after the kill, with one completed control round. It treats `Sent` as proof of a complete batch but does not infer rollback from an absent `Sent` mark.
  Rationale: `SIGKILL` can interrupt the reply after PostgreSQL commits. Per-batch key conservation detects partial commits while allowing either valid outcome at that boundary.
  Date: 2026-09-22

- Decision: the random-kill duplicate allowance counts only leases held by a killed worker that worker did not acknowledge. A completed lease in the same worker does not grant a duplicate allowance.
  Rationale: this makes the bound depend on the actual crash window rather than every message a process handled before it died.
  Date: 2026-09-22

- Decision: backend termination, postmaster restart, and TCP reset keep their true failing transient-classification checks while carrying one upstream known-defect reference.
  Rationale: the observed error shapes differ, but all expose the same retry-predicate boundary. A non-blocking known defect keeps the regression visible on the released cohort without masking the durability and recovery checks in each scenario.
  Date: 2026-09-22

- Decision: concurrent reconciliation judges worker errors, final catalog convergence, and creator-report uniqueness independently, and the known-defect declaration names only the two confirmed upstream failure labels.
  Rationale: a final catalog mismatch remains a new blocking failure even when the released library reproduces its existing report or FIFO index race.
  Date: 2026-09-22


## Outcomes & Retrospective

EP-8 now contributes a registry-valid 49-scenario PGMQ layer, three worker roles, PostgreSQL 17/18 fixtures with pg_partman, contract verdict artifacts, paired benchmark policy, overhead reports, and reduced/full soak constructors. The layer has already localized two released partition defects, two transient-error classifier gaps, listener-loss semantics, and a deliberately injected handler regression without making declared known defects blocking.

The layer is not yet complete. Seven of nine A/A controls need the quieter execution environment owned by EP-17, the backend-termination and TCP-reset contracts expose error shapes that pgmq-hs 0.6.1.0 classifies as permanent, and the corrected reduced-soak controls expose a remaining common-path live-heap slope despite stable workload, queue, OS-resource, and telemetry probes. Until those acceptance items are resolved, this plan and its MasterPlan registry row remain `In Progress`.


## Context and Orientation

This repository, `keiro-runtime-kenshou`, is a verification suite for the keiro runtime, a cohort of Haskell libraries for event sourcing and messaging. The MasterPlan at `docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md` splits the work into nineteen plans. This is plan 8. It adds one cabal package, `kenshou-pgmq`, whose modules live under `Kenshou.Suite.Pgmq` and whose scenarios all have identifiers beginning `pgmq/`. It touches exactly one thing outside its package: a three-line registration in `kenshou-cli`. It must never import another layer package (`kenshou-kiroku`, `kenshou-shibuya`, `kenshou-kafka`, `kenshou-keiro`), and none of them import it; that rule is what makes a red layer attributable.

### What must already exist

When this plan was written the repository held only documents. The following plans must be implemented first; read each completed plan for exact type and function names, because this plan was drafted in parallel with them and codes against the MasterPlan's Integration Points.

`docs/plans/1-bootstrap-the-kenshou-repository-and-pin-the-runtime-cohort.md` delivers the Nix dev shell (GHC 9.12.4, cabal 3.16, PostgreSQL 18 and 17, `just`, `okf`), `cabal.project` with `packages: kenshou-*/*.cabal` (so creating the directory `kenshou-pgmq/` is enough to add the package), the pinned cohort in `cohort/released.project` (the pgmq family at 0.6.1.0, `hasql` 1.10, `hasql-pool` 1.4, `hs-opentelemetry` 1.0) and the ADR bundle `docs/adr/`.

`docs/plans/2-build-the-harness-kernel-for-scenarios-dimensions-run-specs-and-results.md` delivers `kenshou-core` and the `kenshou` executable. From it this plan consumes: `Kenshou.Core.Scenario` (a `Scenario` record with an identifier, summary, knobs, supported dimension values, tier, placement, environment requirements, an optional `KnownDefect`, and `run :: RunContext -> IO ScenarioReport`); `Kenshou.Core.Knob` (`KnobSpec`: name, type, default, allowed values); `Kenshou.Core.Dimension`; `Kenshou.Core.Bundle` (`LayerBundle` with the layer name, scenarios and worker roles); `Kenshou.Core.Env.Postgres` (a `PostgresEnv` that is either an ephemeral server or an external one, already migrated with the components the scenario asked for — this plan asks for the PGMQ component only); `Kenshou.Core.Role` (`WorkerRole`, `RoleContext`); and `RunContext`, which hands a scenario its resolved knobs and dimensions, the environment, the seed, the output directory, a logger, phase markers and a place to register summaries.

`docs/plans/4-build-the-measurement-toolkit-for-load-latency-sampling-and-comparison.md` delivers `Kenshou.Measure.*`: a latency recorder backed by an HDR histogram (a histogram with logarithmic buckets that keeps percentile error bounded across many orders of magnitude), closed-loop load generators (N workers issuing requests back to back) and open-loop generators (requests issued at a fixed rate regardless of how fast replies come, with latency measured from the intended start so that a stalled server is not hidden — the error this avoids is called coordinated omission), samplers that write `series/*.csv` (GHC runtime, process, PostgreSQL relation sizes and dead tuples for named tables), summaries, and `kenshou compare`.

`docs/plans/5-build-the-correctness-toolkit-for-ledgers-invariants-faults-and-process-control.md` delivers `Kenshou.Check.*`: a bounded-memory append-only ledger of facts written by each process; invariant checkers that each emit one `verdicts/<checker>.json` (no loss, duplicates only inside declared crash windows and within a budget, per-key order, disjoint ownership, exactly-N effects, eventual quiescence); `Kenshou.Check.Process`, which spawns worker roles as child processes of the same `kenshou` binary, talks to them over a line-delimited JSON control channel, delivers `SIGKILL` and records the instants it did; fault injectors (terminate PostgreSQL backends by `application_name`, stop, start or crash the postmaster of a durable fixture, an in-process TCP proxy that can add latency, stall, or reset connections, a lock holder); and hedgehog helpers for model-based tests.

`docs/plans/6-build-the-diagnostics-toolkit-for-memory-leaks-and-concurrency-stalls.md` delivers `Kenshou.Diagnose.*`: the leak verdict (a robust slope fitted to live bytes after major garbage collections, thread counts, file descriptors, PostgreSQL connections and named relation sizes, answering `leak-suspected`, `stable` or `insufficient-data`) and the stall watchdog fed by progress heartbeats.

`docs/plans/7-add-telemetry-arms-and-measure-observability-overhead.md` delivers `Kenshou.Telemetry.withTelemetry`, which turns the run's `telemetry.tracing` and `telemetry.metrics` dimension values into handles (`Maybe Tracer`, a tracer provider, an in-memory span exporter for assertions, trace-continuity helpers) and the `kenshou overhead` command.

### Contracts this plan relies on

A scenario identifier is `<layer>/<component>/<kind>/<name>`. Here the layer is always `pgmq`; the component is one of `queue`, `send`, `read`, `ack`, `vt`, `fifo`, `topics`, `notify`, `config`, `effectful`; the kind is `correctness`, `concurrency`, `soak` or `benchmark`. Components map onto pgmq-hs packages for change-aware selection: `config` is `pgmq-config`, `effectful` is `pgmq-effectful`, the rest are `pgmq-hasql` together with the SQL installed by `pgmq-migration`. Cost tiers are `smoke` (under one minute), `standard` (under ten), `extended` (under an hour) and `soak` (hours). Placement is `local`, `cell` or `either`. Outcomes are `passed`, `failed`, `errored`, `inconclusive` and `infrastructure-failure`, mapped to exit codes 0, 1, 4, 3 and 4. Each layer package exports exactly one `bundle :: LayerBundle`.

Dimensions are cross-cutting switches. `pg.version` is `17` or `18`. `pg.durability` is `fsync-off` (fast, the ephemeral default) or `durable` (`fsync` and `synchronous_commit` on; mandatory for benchmarks and for anything that crashes PostgreSQL, because with `fsync=off` a crash discards committed work and the test would measure the fixture, not PGMQ). `telemetry.tracing` is `off`, `noop`, `sdk-inmemory` or `sdk-otlp`. `telemetry.metrics` is `off`, `collect`, `serve` or `serve-scraped`; this layer supports only the first two (see the Decision Log). Knobs are per-scenario typed parameters named after the real configuration fields they set. Measurement never flows through the feature being toggled: latency is recorded in-process by the measurement toolkit, so a run with tracing off is still fully measured.

A run directory is `<out>/<run-id>/` containing `run-spec.json`, `run-result.json`, `manifest.json`, `samples/`, `series/`, `verdicts/`, `diagnosis/` and `logs/`. This plan writes nothing there directly; it calls the toolkits, which do.

### pgmq-hs and PGMQ, as verified in source

pgmq-hs is `mori://shinzui/pgmq-hs`, on disk at `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs` (read-only for this work). Hackage and the repository both have every library at 0.6.1.0. Upstream PGMQ is `mori://pgmq/pgmq` at `/Users/shinzui/Keikaku/hub/postgresql/pgmq-project/pgmq`; pgmq-hs vendors its SQL at `vendor/pgmq/pgmq-extension/sql/pgmq.sql` (version 1.13.0) and installs it without the PostgreSQL extension through `Pgmq.Migration.pgmqMigrations`, six migration files of which `0003` and `0006` are local overrides. Run `mori registry show shinzui/pgmq-hs --full` to find these paths again.

A PGMQ queue named `jobs` is the table `pgmq.q_jobs` with columns `msg_id` (identity), `read_ct`, `enqueued_at`, `last_read_at`, `vt`, `message` (JSONB) and `headers` (JSONB), a primary-key index on `msg_id` and an index on `vt`, plus an archive table `pgmq.a_jobs` with an extra `archived_at`. `vt` is the visibility time: a message is readable when `vt <= clock_timestamp()`. Reading is leasing: `pgmq.read(queue, vt_seconds, qty)` selects the lowest visible `msg_id`s with `FOR UPDATE SKIP LOCKED` (a row lock that makes concurrent readers skip rows another transaction is already taking, instead of waiting), then sets `vt = clock_timestamp() + vt_seconds`, increments `read_ct` and returns the rows. The interval until the new `vt` is the visibility timeout, the lease. Nothing records who holds a lease, so nothing fences a late acknowledgement. Deleting the row (`pgmq.delete`) or moving it to the archive (`pgmq.archive`) is the acknowledgement. If the consumer dies, the row simply becomes visible again when `vt` passes and is delivered again with `read_ct` one higher: delivery is at-least-once, and `read_ct` counts deliveries, not handler failures. `pgmq.pop` reads and deletes in one statement, so it has no redelivery at all.

The Haskell surface, by module. `Pgmq.Types` (package `pgmq-core`) has `QueueName` with `parseQueueName :: Text -> Either PgmqError QueueName` (non-empty, at most 47 characters, only `a-z`, `0-9`, `_`), `MessageId` (an `Int64`), `MessageBody` and `MessageHeaders` (aeson `Value`s), `Message {messageId, visibilityTime, enqueuedAt, lastReadAt :: Maybe UTCTime, readCount :: Int64, body, headers :: Maybe Value}`, `Queue {name, createdAt, isPartitioned, isUnlogged}`, the topic types `RoutingKey`, `TopicPattern`, `TopicBinding`, `RoutingMatch`, `TopicSendResult`, and `notifyChannelName :: QueueName -> Text`, which yields `pgmq.q_<name>.INSERT`. `Pgmq.Hasql.Sessions` (package `pgmq-hasql`) has one `Hasql.Session.Session` per operation, with parameter records in `Pgmq.Hasql.Statements.Types`: `createQueue`, `createUnloggedQueue`, `createPartitionedQueue (CreatePartitionedQueue {queueName, partitionInterval, retentionInterval})`, `dropQueue`; `sendMessage (SendMessage {queueName, messageBody, delay :: Maybe Int32})`, `sendMessageForLater {scheduledAt :: UTCTime}`, `batchSendMessage {messageBodies}`, `batchSendMessageForLater`, and a `…WithHeaders` variant of each; `readMessage (ReadMessage {queueName, delay :: Int32, batchSize :: Maybe Int32, conditional :: Maybe Value})`, where `delay` is the visibility timeout in seconds and `batchSize = Nothing` means one; `readWithPoll (ReadWithPollMessage {…, maxPollSeconds, pollIntervalMs})`; `pop (PopMessage {queueName, qty :: Maybe Int32})`; `deleteMessage` and `archiveMessage :: MessageQuery -> Session Bool`, `batchDeleteMessages` and `batchArchiveMessages :: BatchMessageQuery -> Session [MessageId]` (the identifiers actually affected), `deleteAllMessagesFromQueue`; `changeVisibilityTimeout (VisibilityTimeoutQuery {queueName, messageId, visibilityTimeoutOffset :: Int32}) :: Session (Maybe Message)` where `Nothing` means the row is gone, `batchChangeVisibilityTimeout`, `setVisibilityTimeoutAt`, `batchSetVisibilityTimeoutAt`; the grouped reads `readGrouped`, `readGroupedRoundRobin`, `readGroupedHead` and their `…WithPoll` siblings, all taking `ReadGrouped {queueName, visibilityTimeout, qty}`, grouping by the header `x-pgmq-group`; `createFifoIndex`, `listFifoIndexQueueNames`; the topic operations `bindTopic`, `unbindTopic`, `testRouting`, `sendTopic :: SendTopic -> Session Int32`, `batchSendTopic`; the notification operations `enableNotifyInsert (EnableNotifyInsert {queueName, throttleIntervalMs :: Maybe Int32})` (`Nothing` means 250 ms), `disableNotifyInsert`, `updateNotifyInsert`, `listNotifyInsertThrottles`; and `queueMetrics`, `allQueueMetrics`, `listQueues`. The caller owns a `Hasql.Pool.Pool`, built with `Hasql.Pool.Config.settings [size n, acquisitionTimeout t, staticConnectionSettings s]`; the hasql-pool defaults are size 3, acquisition timeout 10 s, aging 1 day, idleness 10 min. `Hasql.Connection.Settings.applicationName` sets the PostgreSQL `application_name`, which is how the fault injector finds this layer's backends, and `Hasql.Connection.Settings.other` passes any libpq keyword.

`Pgmq.Effectful` (package `pgmq-effectful`) is a dynamic `effectful` effect `Pgmq` with one constructor per operation and two interpreters, `runPgmq :: (IOE :> es, Error PgmqRuntimeError :> es) => Pool -> Eff (Pgmq : es) a -> Eff es a` and `runPgmqTraced :: … => Pool -> Tracer -> …` (or `runPgmqTracedWith` with a `TracingConfig {tracer, recordExceptions, includeMessageBodies}`). Each operation is one `Pool.use`; there is no multi-operation transaction. Errors are `PgmqRuntimeError = PgmqAcquisitionTimeout | PgmqConnectionError ConnectionError | PgmqSessionError SessionError`, and `isTransient :: PgmqRuntimeError -> Bool` is a pure classifier that answers true for acquisition timeouts, networking errors, unrecognised libpq errors, session-level connection drops, and server errors with SQLSTATE 40001, 40P01, 55P03, 57P01, 57P02, 57P03 or class 53; everything else is permanent. The shibuya adapter gates every retry on it. The traced interpreter emits one span per operation (kind Producer for sends, Consumer for reads and `pop`, Internal otherwise; names `publish <queue>`, `receive <queue>`, `pgmq.<fn> <queue>`), and reads the environment variable `OTEL_SEMCONV_STABILITY_OPT_IN` on every operation. Trace context crosses a queue only if the caller opts in with `Pgmq.Effectful.Traced.sendMessageTraced` and `readMessageWithContext`, which write and read lowercase W3C `traceparent` and `tracestate` keys in the message headers. `includeMessageBodies` is never read anywhere in the package; do not expose it as a knob. `Pgmq.Config` (package `pgmq-config`) is a declarative reconciler: `ensureQueuesReport :: [QueueConfig] -> Session [ReconcileAction]` (and `ensureQueuesReportEff` for the effect), with builders `standardQueue`, `unloggedQueue`, `partitionedQueue`, `withNotifyInsert`, `withFifoIndex`, `withTopicBinding`; it is additive, and a queue whose kind differs from the declaration is only reported as `DetectedQueueTypeDrift`.

Facts that shape the scenarios, each checked against the SQL or the pgmq-hs documents. First, `pgmq.read` returns its rows from an `UPDATE … FROM cte … RETURNING`, so SQL gives no guarantee about the order of the returned vector, for plain reads as well as grouped ones; upstream's MasterPlan 5 addresses only the grouped and head reads. Second, `pgmq.read_with_poll` is one plpgsql function that loops with `pg_sleep`, so it occupies a pool connection, and one open statement, for up to `maxPollSeconds`. Third, `pgmq.metrics` runs `count(*)` over the queue table. Fourth, message identifiers are assigned at insert, not at commit, so two producers can commit out of identifier order. Fifth, `readGrouped` can lease several messages of one group in one batch, so a successor can finish before a failed predecessor; only `readGroupedHead` (PGMQ 1.12 and later) leases at most the oldest message of each group and lets an invisible head block its group. Sixth, the throttle table `pgmq.notify_insert_throttle` is `UNLOGGED`, so crash recovery empties it; migration `0003` makes the insert trigger "fail open" (notify when the throttle row is missing) so delivery survives, at the price of unthrottled notifications until `ensureQueues` runs again, which in practice means until the application restarts. Seventh, PostgreSQL clones that trigger onto every partition of a partitioned queue, where the table name is the partition's and can never have a throttle row, so every insert notifies on a per-partition channel that `notifyChannelName` never names. Eighth, PGMQ configures `pg_partman` with `retention_keep_table = false`, so partition maintenance drops whole partitions without looking at `read_ct` or `vt`: unread and in-flight messages are deleted. Ninth, an unlogged queue's table is `UNLOGGED` and is emptied by crash recovery. Tenth, overlapping `batchDeleteMessages` calls lock rows in statement-internal order and can deadlock (SQLSTATE 40P01), which is why that code is classified transient. The design notes recording these are, in `mori://shinzui/pgmq-hs`, `docs/design/014-null-parameter-contract.md`, `docs/design/015-notification-delivery-contract.md` and `docs/design/017-transient-error-classification.md`; artifact-level `mori://` URIs for design notes are pending, so they are cited as project plus path.

The upstream work items this plan links known defects to: `mori://shinzui/pgmq-hs/masterplans/5-correct-the-fifo-grouped-read-ordering-index-and-partition-retention-contracts` with its children `mori://shinzui/pgmq-hs/plans/19-give-the-grouped-reads-a-deterministic-return-order`, `mori://shinzui/pgmq-hs/plans/20-replace-the-fifo-gin-index-with-one-the-grouped-reads-can-use` and `mori://shinzui/pgmq-hs/plans/21-state-the-fifo-ordering-and-partitioned-retention-contracts-truthfully` (none started); `mori://shinzui/pgmq-hs/masterplans/6-close-the-notification-reconciler-and-evidence-gaps-surfaced-by-the-0-6-1-0-review` with `mori://shinzui/pgmq-hs/plans/23-gate-the-notification-fail-open-on-a-real-queue-row-and-state-the-partitioned-queue-contract` and `mori://shinzui/pgmq-hs/plans/24-report-name-collisions-and-unsupported-notifications-instead-of-acting-on-them` (none started, targeting 0.7.0.0); and the review records `mori://shinzui/pgmq-hs/okf/reviews/concepts/REV-1` and `mori://shinzui/pgmq-hs/okf/reviews/concepts/REV-2`. On 2026-09-20 the local Mori registry lagged the pgmq-hs repository, so `mori path` did not yet resolve the plan, masterplan and review URIs; they are the intended canonical forms and must be used as written. When a fix lands and the `head` cohort picks it up, the known-defect scenario passes on `head` while still failing on `released`; that difference is expected and is what the cohort mechanism is for.

What pgmq-hs's own tests do not cover, and this plan does: several readers on one queue; expiry by waiting; `read_ct` across repeated crashes; pool exhaustion; connection loss or PostgreSQL restart under a live pool; large payloads; FIFO order under concurrent consumers; delayed messages at scale; soak, bloat and vacuum behaviour. Its benchmark `pgmq-bench` is single-threaded, runs with `fsync=off`, has no percentiles, and its read group's "raw SQL" case calls the hasql path by mistake; nothing is reused from it except the idea of the ladder.

### Architecture Decision Records

There is no local ADR corpus to read before `docs/plans/1-bootstrap-the-kenshou-repository-and-pin-the-runtime-cohort.md` is implemented; that plan creates `docs/adr/` as an OKF bundle (OKF, the Open Knowledge Format, is a directory of Markdown files with YAML frontmatter validated by the `okf` tool against a profile, a Dhall file that fixes required fields). When it exists, scan its filenames and read the records on layer isolation, cohort identity, measurement independence, "crash means `SIGKILL`" and contract versus implementation invariants. Cross-repository decisions that bear on this plan: `mori://shinzui/kiroku/okf/adrs/concepts/ADR-5` makes only structural checks and controlled A/B workloads authoritative performance evidence, so every figure here is a paired comparison and never a single run. `mori://shinzui/keiro/okf/adrs/concepts/ADR-44` states that only grouped-head reads batch safely under FIFO and that sorting results on the client is not a correctness mechanism; the FIFO scenarios verify exactly that boundary at the PGMQ level. `mori://shinzui/keiro/okf/adrs/concepts/ADR-45` records that partition retention drops whole partitions including unprocessed rows; the retention scenario demonstrates it. `mori://shinzui/keiro-runtime-patterns/okf/adrs/concepts/ADR-3` selects PGMQ for in-context jobs because of its lease, retry and dead-letter semantics, which is why lease accounting is the centre of this plan. `mori://shinzui/keiro/okf/adrs/concepts/ADR-25` requires worker loops to survive per-pass failures, which depends on the transient classification tested here. pgmq-hs keeps its own ADRs as plain Markdown outside an OKF bundle, so the artifact-level URI is pending: `mori://shinzui/pgmq-hs` at `docs/adr/pgmq-1.12-1.13-compatibility.md` (stock PGMQ 1.12 and 1.13 are both supported; acceptance is recorded on PostgreSQL 17.10 with pg_partman 5.4.3, and re-recording it on the PostgreSQL 18.6 its shell now ships is an unstarted upstream plan, so this suite's `pg.version=18` runs are new evidence) and `docs/adr/fifo-native-overrides-and-index-upgrade-boundary.md` (no overriding of upstream SQL functions).

Decisions of this plan that deserve a new ADR once they have survived implementation: leases and redelivery are judged on the database clock; a layer without a metrics endpoint maps `telemetry.metrics=collect` to polling its SQL metrics function; and documented limitations are asserted as implementation-class invariants while only behaviours with an upstream fix planned carry a known-defect reference. Create each with `okf id next docs/adr --profile docs/adr/profile.dhall ADR` to obtain the handle, and validate with `okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce`.


## Plan of Work

### Shared design used by every milestone

The package is `kenshou-pgmq/` with library modules under `kenshou-pgmq/src/Kenshou/Suite/Pgmq/` and a test suite `kenshou-pgmq-test` under `kenshou-pgmq/test/`. All calls into the kernel and the toolkits that are not plain type imports go through `Harness`, `Roles` and `Telemetry`, so that if a toolkit's final signature differs from what this plan assumed, the repair is confined to those modules.

`kenshou-pgmq/src/Kenshou/Suite/Pgmq/Knobs.hs` defines the common knob vocabulary once. Each knob names the real parameter it sets. `pgmq.queue-kind` (enum `standard`, `unlogged`, `partitioned`; default `standard`) chooses `createQueue`, `createUnloggedQueue` or `createPartitionedQueue`. `pgmq.partition.interval` and `pgmq.partition.retention` (text; defaults `10000` and `100000`, the SQL defaults) fill `CreatePartitionedQueue`. `pgmq.visibility-timeout-seconds` (integer at least 0; default 30) fills `ReadMessage.delay` or `ReadGrouped.visibilityTimeout`. `pgmq.batch-size` (integer 1 to 1000; default 10; declared variants 1, 10, 50, 100) fills `ReadMessage.batchSize`, `ReadGrouped.qty`, `PopMessage.qty`, and the length of `BatchSendMessage.messageBodies`. `pgmq.pool-size` (integer; default 10; variants 3, 10, 20) and `pgmq.pool.acquisition-timeout-seconds` (default 10) fill the hasql-pool settings. `pgmq.poll.max-seconds` (default 0, meaning the non-polling function with a client-side sleep when a read is empty) and `pgmq.poll.interval-ms` (default 100) fill `maxPollSeconds` and `pollIntervalMs`. `pgmq.payload-bytes` (default 256; variants 256, 4096, 65536, 1048576) sizes a padding string in the body. `pgmq.read-strategy` (enum `plain`, `pop`, `grouped`, `grouped-round-robin`, `grouped-head`; default `plain`) and `pgmq.ack-mode` (enum `delete`, `archive`, `batch-delete`, `batch-archive`; default `delete`) choose functions. Workload knobs are `pgmq.producers`, `pgmq.consumers` (threads), `pgmq.processes` (worker processes), `pgmq.message-count`, `pgmq.groups` (number of FIFO groups), `pgmq.handler-ms` (simulated work per message), `pgmq.rate-per-second`, `pgmq.duration-seconds`, `pgmq.notify.throttle-ms` and `pgmq.fifo-index` (boolean). `resolveKnobs` rejects contradictory combinations, for example `pop` with `pgmq.poll.max-seconds` above 0.

```haskell
module Kenshou.Suite.Pgmq.Knobs where

data QueueKind = Standard | Unlogged | Partitioned
data ReadStrategy = Plain | Pop | Grouped | GroupedRoundRobin | GroupedHead
data AckMode = AckDelete | AckArchive | AckBatchDelete | AckBatchArchive

data PgmqKnobs = PgmqKnobs
  { queueKind :: QueueKind
  , visibilityTimeoutSeconds :: Int32
  , batchSize :: Int32
  , poolSize :: Int
  , acquisitionTimeoutSeconds :: Int
  , pollMaxSeconds :: Int32
  , pollIntervalMs :: Int32
  , payloadBytes :: Int
  , readStrategy :: ReadStrategy
  , ackMode :: AckMode
  }

commonKnobs :: [KnobSpec]
resolveKnobs :: RunContext -> Either Text PgmqKnobs
```

`kenshou-pgmq/src/Kenshou/Suite/Pgmq/Harness.hs` owns the fixture. A scenario never opens a database by itself: it takes the `PostgresEnv` from the `RunContext` (requested with the PGMQ migration component only, so the database contains the `pgmq` schema and nothing of kiroku or keiro) and builds a pool whose connections carry `application_name = kenshou-pgmq-<role>`. Queue names are derived from the run so that reruns and external servers never collide: `kn` followed by the first eight hexadecimal characters of the run identifier, an underscore and a tag, at most 47 characters. `withScenarioQueue` creates the queue of the requested kind and drops it afterwards. `requirePartman` runs `select exists (select from pg_available_extensions where name = 'pg_partman')` and, when true, `CREATE SCHEMA IF NOT EXISTS partman; CREATE EXTENSION IF NOT EXISTS pg_partman SCHEMA partman`, as pgmq-hs's own tests do; when false the scenario ends `errored` with the message "pg_partman is not available in this PostgreSQL; add it to the dev shell's PostgreSQL (`postgresql.withPackages (ps: [ ps.pg_partman ])`) or the cell image". `runOps` is the single place the tracing arm is applied.

```haskell
module Kenshou.Suite.Pgmq.Harness where

withPgmqPool :: PostgresEnv -> Text -> PgmqKnobs -> (Pool -> IO a) -> IO a
scenarioQueueName :: RunContext -> Text -> QueueName
withScenarioQueue :: Pool -> RunContext -> PgmqKnobs -> Text -> (QueueName -> IO a) -> IO a
requirePartman :: Pool -> IO (Either Text ())

-- Nothing => runPgmq; Just tracer => runPgmqTraced
runOps ::
  Maybe Tracer -> Pool ->
  Eff '[Pgmq, Error PgmqRuntimeError, IOE] a ->
  IO (Either PgmqRuntimeError a)
runOps mTracer pool action =
  runEff . runErrorNoCallStack @PgmqRuntimeError $
    maybe (runPgmq pool) (runPgmqTraced pool) mTracer action
```

`kenshou-pgmq/src/Kenshou/Suite/Pgmq/Facts.hs` defines what processes write to the correctness ledger. Every message body is `{"k": "<run>-<producer>-<seq>", "p": <producer>, "s": <seq>, "b": "<batch>", "pad": "…"}`; `k` is the key all checkers join on. A producer writes `Intent` before a send and `Sent` after PostgreSQL acknowledged it. A consumer writes `Leased` from the returned `Message` (its `lastReadAt` and `visibilityTime` are database-clock values), `Handled` when the simulated business effect happened — flushed to the ledger before the acknowledgement is issued, so a kill between the two shows up as a duplicate and never as a loss — then `Acked` with the boolean PGMQ returned, and `Released` when it changed a visibility timeout.

```haskell
module Kenshou.Suite.Pgmq.Facts where

data PgmqFact
  = Intent   { key :: Text, batch :: Maybe Text }
  | Sent     { key :: Text, msgId :: Int64, batch :: Maybe Text, group :: Maybe Text, dueAt :: Maybe UTCTime }
  | Leased   { key :: Text, msgId :: Int64, readCount :: Int64, lastReadAt :: UTCTime, visibleAt :: UTCTime, group :: Maybe Text }
  | Handled  { key :: Text, msgId :: Int64, readCount :: Int64 }
  | Released { msgId :: Int64, newVisibleAt :: UTCTime }
  | Acked    { msgId :: Int64, mode :: AckMode, affected :: Bool }
```

`kenshou-pgmq/src/Kenshou/Suite/Pgmq/Oracle.hs` holds the layer-specific checks and adapts facts to the correctness toolkit's generic checkers. The lease rule, used throughout: for one `msgId`, order the observed `Leased` facts by `readCount`; read counts must be distinct; and for consecutive observed leases a then b, `b.lastReadAt >= a.visibleAt` unless a `Released` fact for a moved its visibility earlier, in which case the released time is used. Leases that a killed process took but never recorded only push later leases later, so the rule stays sound under crashes. The module also has SQL oracles that read the durable truth: row counts and keys in `pgmq.q_<name>` and `pgmq.a_<name>`, `max(read_ct)`, and the conservation identity "acknowledged sends = rows in queue + rows in archive + deletions".

```haskell
module Kenshou.Suite.Pgmq.Oracle where

checkLeaseIntervals :: [PgmqFact] -> LeaseFindings      -- overlaps, duplicate read counts
checkNotBeforeDue   :: [PgmqFact] -> [EarlyDelivery]    -- Leased.lastReadAt < Sent.dueAt
queueKeys, archiveKeys :: Pool -> QueueName -> IO (Set Text)
conservation :: Pool -> QueueName -> [PgmqFact] -> IO ConservationFinding
```

`kenshou-pgmq/src/Kenshou/Suite/Pgmq/Telemetry.hs` adapts the telemetry toolkit's handles to pgmq-hs, and `withPgmqRun` in `Harness.hs` is the wrapper every scenario's `run` starts with: it resolves the knobs, calls `Kenshou.Telemetry.withTelemetry` with the run's dimension values, builds the pool, starts the metrics poller when asked, and hands the scenario one record. `pgmqTracer` returns `Nothing` for `telemetry.tracing=off` and, for `noop`, `sdk-inmemory` and `sdk-otlp`, a tracer made from the toolkit's provider; that choice is what selects `runPgmq` or `runPgmqTraced` inside `runOps`. `withMetricsPoller` does nothing for `telemetry.metrics=off`; for `collect` it calls `allQueueMetrics` every `metrics.scrape-interval-ms` (the telemetry toolkit's knob) on its own connection with `application_name = kenshou-pgmq-metrics`, so that the pool-size knob keeps its meaning, and writes queue length, visible length, oldest message age and the call's own latency to `series/pgmq-metrics.csv`.

```haskell
module Kenshou.Suite.Pgmq.Telemetry where

pgmqTracer :: TelemetryHandles -> Maybe Tracer
withMetricsPoller :: TelemetryHandles -> PostgresEnv -> RunContext -> IO a -> IO a

-- in Kenshou.Suite.Pgmq.Harness
data PgmqRun = PgmqRun
  { ctx :: RunContext, knobs :: PgmqKnobs, pool :: Pool
  , tracer :: Maybe Tracer, telemetry :: TelemetryHandles }

withPgmqRun :: RunContext -> (PgmqRun -> IO ScenarioReport) -> IO ScenarioReport
```

`kenshou-pgmq/src/Kenshou/Suite/Pgmq/Listener.hs` wraps a raw `postgresql-libpq` connection that issues `LISTEN "<channel>"` (the channel contains dots and must be double-quoted) and collects notifications with arrival times, as `pgmq-hasql/test/NotifyChannelSpec.hs` does; hasql has no listen API.

Defaults for every scenario below unless it says otherwise: placement `either`; `pg.version` 17 and 18; `pg.durability` both values for correctness scenarios and `durable` only for concurrency, benchmark and soak scenarios; `telemetry.tracing` all four values; `telemetry.metrics` `off` and `collect`; environment requirement PostgreSQL with the PGMQ component; knobs are the common set plus those named. An invariant's class is `contract` (documented guarantee; a failure blocks a release) or `implementation` (how it currently behaves; a failure is reported and does not block).

### Milestone 1 — pgmq-hs correctness scenarios

Scope: the package, the harness modules above, registration in `kenshou-cli`, and eighteen single-process scenarios under `kenshou-pgmq/src/Kenshou/Suite/Pgmq/Correctness/` in the modules `Queue.hs`, `Send.hs`, `Read.hs`, `Ack.hs`, `Vt.hs`, `Fifo.hs`, `Topics.hs`, `Notify.hs`, `Config.hs` and `Effectful.hs`, each exporting `scenarios :: [Scenario]`. At the end `kenshou list --layer pgmq --kind correctness` lists them and `kenshou run` on each ends `passed`, except the two known-defect scenarios, which end with the kernel's reported, non-blocking known-defect outcome. Acceptance is the run of all eighteen on both PostgreSQL versions.

Registration is the three-line edit of Integration Point 3: in `kenshou-cli/src/Kenshou/Cli/Registry.hs` add `import Kenshou.Suite.Pgmq qualified as Pgmq` and the list element `Pgmq.bundle`; in `kenshou-cli/kenshou-cli.cabal` add `kenshou-pgmq` to `build-depends`. `kenshou-pgmq/src/Kenshou/Suite/Pgmq.hs` exports `bundle :: LayerBundle` with layer `pgmq`, the concatenation of every module's `scenarios`, and the roles from Milestone 2.

`pgmq/queue/correctness/lifecycle-by-kind` (smoke). Knob `pgmq.queue-kind`. Create the queue, confirm `listQueues` reports `isPartitioned` and `isUnlogged` correctly and that `pg_class.relpersistence` of `pgmq.q_<name>` is `u` only for unlogged; create again and expect no error; send and `deleteAllMessagesFromQueue` and expect the count sent; `dropQueue` returns `True`, after which `to_regclass` of the queue and archive tables is null and `pgmq.meta` has no row. Also accepts a 47-character name end to end (its archive index name is exactly 63 characters) and rejects 48 characters and any uppercase letter in `parseQueueName`. Oracle: all assertions hold; class `contract`. With `partitioned`, requires pg_partman.

`pgmq/send/correctness/send-variants-round-trip` (smoke). For each of the eight send functions, send hedgehog-generated JSON bodies and headers (nested objects, Unicode, large and fractional numbers) and read them back. Oracle: bodies and headers are equal as aeson values; a batch returns as many identifiers as bodies, strictly increasing, in input order, and the n-th identifier holds the n-th body; batch headers pair positionally; a row inserted by raw SQL with a NULL body reads back as `MessageBody Null` without failing the batch. Class `contract`.

`pgmq/send/correctness/delayed-and-scheduled-visibility` (standard). Knobs `pgmq.message-count` (default 50000) and `pgmq.delay-window-seconds` (default 60). Send the messages with delays spread uniformly over the window, half with `delay` and half with `sendMessageForLater`, while four readers drain. Oracle: `checkNotBeforeDue` is empty, where due time is `scheduledAt` or `enqueuedAt + delay` (class `contract`); every message is delivered exactly once; lateness (`lastReadAt - due`) is recorded as a histogram and its p99 must be under the reader poll interval plus one second (class `implementation`).

`pgmq/send/correctness/large-payload-round-trip` (standard). Knob `pgmq.payload-bytes-list` (default 1024, 65536, 1048576, 16777216). Send, read, archive, and read the archive row by SQL. Oracle: byte-for-byte equal JSON at every size through every step; class `contract`.

`pgmq/send/correctness/transactional-send-rollback` (smoke; tracing `off` only, because it uses one hasql `Session` directly). Inside one session run `BEGIN`, `Sessions.sendMessage`, a statement that fails, and `ROLLBACK`; then the same ending in `COMMIT`. Oracle: the rolled-back message is absent and the committed one present; a consumer on another connection cannot read the message before commit. Class `contract`.

`pgmq/read/correctness/read-semantics` (smoke). Oracle: `batchSize = Nothing` returns exactly one message even when a thousand are visible (the NULL-means-everything trap of design note 014); a read never returns more than `batchSize`; the set returned is exactly the lowest visible identifiers; each returned message has `readCount` one higher, `lastReadAt` set and `visibilityTime = lastReadAt + visibility timeout` within 50 ms; `conditional` returns only bodies containing the filter; `pop` with `qty = Nothing` removes one message and not the queue; `readWithPoll` on an empty queue returns empty after `maxPollSeconds` plus or minus 500 ms, and when a message is sent mid-poll returns it within `pollIntervalMs` plus 250 ms. Class `contract`.

`pgmq/read/correctness/plain-read-return-order` (standard). Shuffle the heap first: send `pgmq.message-count` (default 20000) messages, lease random subsets with a zero timeout several times so that updated row versions land out of identifier order, and `VACUUM`. Then read batches of 1000. Oracle: every returned vector is in ascending `messageId` order; class `implementation`. The fraction of unsorted batches is recorded. If it fails, file an improvement request against pgmq-hs asking for plan 19's outer `ORDER BY` to cover `readMessage` too, and attach its URI as a `KnownDefect`.

`pgmq/ack/correctness/delete-archive-semantics` (smoke). Oracle: `deleteMessage` and `archiveMessage` return `True` once and `False` on repetition and for unknown identifiers; batch forms return only the identifiers affected; an archived row keeps `msg_id`, `read_ct`, `enqueued_at`, `message` and `headers` and gains `archived_at`; `conservation` holds. Class `contract`.

`pgmq/vt/correctness/wall-clock-expiry` (smoke). Knob `pgmq.visibility-timeout-seconds` (default 2; variants 1, 2, 10). Read one message, then poll every 50 ms with a second reader. Oracle: no read succeeds while the database clock is before the first lease's `visibilityTime`, and `queueMetrics.queueVisibleLength` is 0 during that time; the message is delivered again within 300 ms after it, with `readCount = 2`; nobody rewrites `vt`, the scenario waits. Class `contract`.

`pgmq/vt/correctness/set-vt-semantics` (smoke). Oracle: `changeVisibilityTimeout` moves `visibilityTime` to now plus the offset and leaves `readCount` unchanged; offset 0 makes the message readable at once; `setVisibilityTimeoutAt` sets the absolute time; both return `Nothing` for a deleted message instead of an error; the batch forms return only existing rows; a consumer that extends its lease every half timeout for five timeouts is never redelivered to a competing reader. Class `contract`.

`pgmq/fifo/correctness/grouped-read-semantics` (smoke). Knobs `pgmq.groups` (default 5), `pgmq.fifo-index`. Oracle, sequentially with one reader: `readGrouped` fills its batch from the group with the oldest message first; `readGroupedRoundRobin` takes one message per group per layer; `readGroupedHead` returns at most one message per group and at most `qty` groups, an invisible head hides its whole group, deleting the head releases the next, and expiry redelivers the same head with `readCount + 1`; messages without the `x-pgmq-group` header form one group; `createFifoIndex` is idempotent and `listFifoIndexQueueNames` reports it. Class `contract`.

`pgmq/fifo/correctness/grouped-result-order` (standard). `KnownDefect`: `mori://shinzui/pgmq-hs/plans/19-give-the-grouped-reads-a-deterministic-return-order`. After the same heap shuffle, call `readGrouped` and `readGroupedHead` with `qty` 1000 across 200 groups. Oracle: every returned vector is ascending in `messageId`; class `contract` once the upstream plan lands. Expected today: unsorted vectors appear. The unsorted fraction is recorded; if it is zero the kernel reports that the defect did not reproduce.

`pgmq/topics/correctness/routing-model` (standard). A model-based test using the correctness toolkit's hedgehog helpers: generate bindings with `*` (exactly one segment) and `#` (zero or more segments) and routing keys, and compare against a pure matcher in `kenshou-pgmq/src/Kenshou/Suite/Pgmq/TopicModel.hs`. Oracle: `testRouting` equals the model; `sendTopic` returns the number of matching queues and each receives exactly one copy; `batchSendTopic` returns one `TopicSendResult` per queue per body; bind is idempotent and `unbindTopic` returns `False` the second time; `validateRoutingKey` agrees with `parseRoutingKey`. The seed and the shrunk counter-example go into the verdict. Class `contract`.

`pgmq/notify/correctness/channel-and-throttle` (smoke). Knob `pgmq.notify.throttle-ms` (default 250; variants 0, 250, 1000). Listen on `notifyChannelName`, send at 100 per second for 5 s. Oracle: every notification's channel equals the helper's output byte for byte; with throttle t above 0 the count is between 1 and `5000 / t + 1`; with 0 it equals the number of sends; after `disableNotifyInsert` none arrive; `updateNotifyInsert` changes the bound. Class `contract`.

`pgmq/config/correctness/reconcile-convergence` (smoke). Reconcile a list with a standard, an unlogged, a FIFO-indexed, a notifying and a topic-bound queue through both `ensureQueuesReport` and `ensureQueuesReportEff`. Oracle: the first report has one creating action per declared resource and the second only `Skipped…` actions; changing the throttle yields `UpdatedNotifyThrottle old new`; declaring an existing standard queue as unlogged yields `DetectedQueueTypeDrift` and changes nothing; both backends give equal reports. Class `contract`.

`pgmq/config/correctness/mixed-case-alias-collision` (smoke). `KnownDefect`: `mori://shinzui/pgmq-hs/plans/24-report-name-collisions-and-unsupported-notifications-instead-of-acting-on-them`. Create `Foo` by raw SQL `select pgmq.create('Foo')`, then reconcile `standardQueue foo`. Oracle: `pgmq.meta` still has exactly one row for that physical table and the report does not contain `CreatedQueue`. Expected today: a second metadata row is created over the shared table.

`pgmq/effectful/correctness/interpreter-parity-and-errors` (standard). Run one scripted sequence of every operation through plain sessions, `runPgmq` and `runPgmqTraced`. Oracle: identical observable results. Then produce real server errors and classify them with `isTransient` after `fromUsageError`: an operation on a missing queue (42P01, permanent), a backend terminated mid-call by `pg_terminate_backend` (57P01 or a connection error, transient), a deadlock built from two sessions locking two rows in opposite order (40P01, transient), `lock_timeout` expiring on a locked row (55P03, transient), a pool of size one held while a second caller waits past the acquisition timeout (`PgmqAcquisitionTimeout`, transient), and a connection as a role that does not exist (an authentication-class failure, expected permanent; ephemeral servers use trust authentication, so a wrong password would not fail — record which hasql constructor is observed). Class `contract`.

`pgmq/effectful/correctness/traced-span-contract` (smoke; tracing `sdk-inmemory` only). Oracle from the in-memory exporter: exactly one span per operation; kind and name as documented; attributes `messaging.system = pgmq`, `messaging.destination.name`, `db.operation`; a failing operation's span has error status and, by default, a recorded exception; a message sent with `sendMessageTraced` and read with `readMessageWithContext` yields a context whose trace identifier equals the producer's, checked with the telemetry toolkit's continuity helper; a caller-supplied `traceparent` header wins over the injected one. Class `contract`.

### Milestone 2 — pgmq-hs concurrency and crash scenarios

Scope: worker roles and twenty scenarios under `kenshou-pgmq/src/Kenshou/Suite/Pgmq/Concurrency/` in `Lease.hs`, `Crash.hs`, `Pool.hs`, `Outage.hs`, `Fifo.hs`, `Notify.hs`, `Retention.hs` and `Config.hs`. A crash here is a `SIGKILL` delivered to a worker process or the termination of a PostgreSQL backend or postmaster, never a Haskell exception. At the end each scenario ends with verdict files in `verdicts/` and the expected outcome. All require `pg.durability=durable`.

`kenshou-pgmq/src/Kenshou/Suite/Pgmq/Roles.hs` registers three roles. `pgmq-producer` sends keyed messages (single or batch, optional group header, optional rate) and writes `Intent` and `Sent`. `pgmq-consumer` loops read, handle (sleep `pgmq.handler-ms`, write `Handled`), acknowledge, using the configured strategy, and writes `Leased`, `Acked` and `Released`. `pgmq-reconciler` runs `ensureQueuesReport` on command. The consumer takes a `crash-point` parameter — `after-read`, `after-handled` or `mid-batch-ack` — at which it reports the point on the control channel and blocks until told to continue; the supervisor kills it there instead, which makes kill placement deterministic. Without a crash point the supervisor kills at seeded random instants.

```haskell
module Kenshou.Suite.Pgmq.Roles where

data CrashPoint = AfterRead | AfterHandled | MidBatchAck
roles :: [WorkerRole]           -- pgmq-producer, pgmq-consumer, pgmq-reconciler
```

`pgmq/read/concurrency/no-double-lease-threads` (standard). Knobs `pgmq.consumers` (default 16), `pgmq.message-count` (default 100000), `pgmq.read-strategy`, `pgmq.batch-size`, `pgmq.handler-ms` (default 0), `pgmq.sabotage` (enum `none`, `unlocked-read`; default `none`). Reader threads in one process drain a preloaded queue. Oracle: `checkLeaseIntervals` finds no overlap and no duplicate read count, fed also to the toolkit's disjoint-ownership checker; every key is handled exactly once; the queue ends empty. Class `contract`. With `unlocked-read` the readers select rows without locking or moving `vt`, and the scenario must end `failed`; that is the proof the oracle is not vacuous.

`pgmq/read/concurrency/no-double-lease-processes` (standard). Knobs `pgmq.processes` (default 4), `pgmq.consumers` per process (default 4), `pgmq.producers` (default 4), `pgmq.handler-ms` (default 5), visibility timeout default 5. Producers and consumers are separate worker processes running concurrently; a handler slower than the timeout is possible with `pgmq.handler-ms` above 5000, so legitimate re-leases occur. Oracle: as above with the interval rule doing real work, plus no loss of acknowledged sends and eventual quiescence. Class `contract`.

`pgmq/vt/concurrency/crash-redelivery-read-count` (standard). Knobs `pgmq.kills` (default 5), visibility timeout default 3, `pgmq.message-count` default 20, crash point `after-read`. For each kill the supervisor starts a consumer, waits for it to report `after-read` with the leased identifiers, kills it with `SIGKILL`, and starts the next. Oracle: for every message the j-th observed delivery has `readCount = j`, ending at kills plus one; no delivery begins before the previous lease's `visibilityTime` and each begins within one second after it; every key is handled at least once and the final handled count per key is one; nothing remains in the queue. Class `contract`.

`pgmq/ack/concurrency/random-sigkill-at-least-once` (extended). Knobs `pgmq.processes` (default 4), `pgmq.kill-interval-seconds` (default 5), `pgmq.duration-seconds` (default 600), `pgmq.rate-per-second` (default 500), crash point none. Oracle: no acknowledged send is lost; a key is handled more than once only if one of its leases overlaps a recorded kill window, and then at most once more per overlapping kill; the queue drains within two visibility timeouts after the load stops. Class `contract`.

`pgmq/send/concurrency/producer-sigkill-batch-atomicity` (standard). Producers send batches of `pgmq.batch-size` (default 50) and are killed at random. Oracle: for every batch with an `Intent`, the number of its keys in the queue is either 0 or the batch size; every batch with a `Sent` fact is complete. Class `contract`.

`pgmq/ack/concurrency/stale-ack-after-expiry` (smoke). Consumer A leases with a one-second timeout and stalls; B leases the redelivery; A then deletes. Oracle (documented limitation, class `implementation`): A's `deleteMessage` returns `True`, B's returns `False`, and B's `changeVisibilityTimeout` returns `Nothing`. The layer guide states the consequence: PGMQ has no fencing, so a handler must finish or extend within its timeout.

`pgmq/read/concurrency/pool-exhaustion-long-poll` (standard). Knobs `pgmq.pool-size` (default 4), `pgmq.pollers` (variants 3, 4, 8), `pgmq.poll.max-seconds` (default 5), `pgmq.pool.acquisition-timeout-seconds` (default 2). Pollers call `readWithPoll` on an empty queue through the pool a producer shares. Oracle: with fewer pollers than connections every send succeeds and send p99 stays within twice the no-poller baseline measured in the same run; with pollers equal to or above the pool size sends fail with `PgmqAcquisitionTimeout`, which `isTransient` accepts; `pg_stat_activity` shows each polling backend active for the whole poll; within one poll period after the pollers stop, sends succeed again. Class `contract` for classification and recovery, `implementation` for the starvation itself. The stall watchdog's pool-starvation classification is attached to the run as evidence.

`pgmq/effectful/concurrency/backend-termination-recovery` (standard). Under steady produce and consume, the fault injector terminates every backend whose `application_name` starts with `kenshou-pgmq` every `pgmq.fault.interval-seconds` (default 10) for `pgmq.duration-seconds` (default 120). Oracle: every error observed is classified transient; no error occurs more than two seconds outside a fault window; the same `Pool` value keeps working without being recreated; no acknowledged send is lost; duplicates only within fault windows (a read that committed but whose reply was lost leaves a lease nobody holds, which expires normally). Class `contract`.

`pgmq/effectful/concurrency/postgres-restart-recovery` (standard). Knob `pgmq.fault.kind` (enum `stop-start`, `immediate-crash`; default `immediate-crash`), downtime default 5 s. Oracle: every `Sent` key is present after recovery on a standard queue; errors during the outage are transient (57P01, 57P02, 57P03 or connection errors); after the server accepts connections, operations succeed within five seconds, and the recovery time is recorded; `SHOW fsync` is still `on` after the restart. Class `contract`.

`pgmq/queue/concurrency/unlogged-queue-crash-loss` (smoke). Send to an unlogged and a standard queue, crash the postmaster in immediate mode. Oracle (documented limitation, class `implementation`): the unlogged queue is empty and the standard queue complete.

`pgmq/effectful/concurrency/network-partition` (standard). The pool connects through the correctness toolkit's TCP proxy. Knobs `pgmq.fault.kind` (enum `reset`, `latency`, `blackhole`; default `reset`), `pgmq.fault.latency-ms` (default 200), `pgmq.conn.tcp-user-timeout-ms` (default 0, unset; passed as the libpq keyword `tcp_user_timeout` through `Hasql.Connection.Settings.other`), `pgmq.fault.max-block-seconds` (default 30). Oracle: on reset, errors are transient and the pool recovers when the proxy heals; on latency, no errors and latency rises by about two round trips; on blackhole, every blocked call returns within `pgmq.fault.max-block-seconds`. Class `contract` for reset and latency. The blackhole rule is class `implementation`: hasql has no statement timeout, so with the default keyword unset a call may block until the kernel gives up. If it does, record the measured block time, record which `tcp_user_timeout` value bounds it, file an improvement request against pgmq-hs asking for documented connection guidance, and attach it as a `KnownDefect`.

`pgmq/fifo/concurrency/head-per-group-barrier` (extended). Strategy `grouped-head`, `pgmq.groups` default 50, one producer per group so that identifier order is send order, `pgmq.processes` default 4 with random `SIGKILL`, batch size default 10. Oracle: for each group at most one lease is live at any database-clock instant; the first `Handled` facts of a group's keys are in ascending sequence; a successor is never leased while its predecessor is unacknowledged. Class `contract`.

`pgmq/fifo/concurrency/grouped-batch-successor-hazard` (standard). Strategy `grouped`, batch size 10, the consumer deliberately fails (leaves unacknowledged) the first message of each batch. Oracle (documented limitation of `mori://shinzui/keiro/okf/adrs/concepts/ADR-44`, class `implementation`): successors are handled before their failed predecessor; the count of such inversions is recorded and must be above zero, and zero with batch size 1.

`pgmq/fifo/concurrency/producer-commit-order-inversion` (smoke). Two producers on one group: the first inserts inside an open transaction, the second inserts and commits, a `grouped-head` consumer reads, then the first commits. Oracle (documented limitation, class `implementation`): the consumer receives the higher identifier first. The guide states the rule: per-group order needs per-group serialised producers.

`pgmq/notify/concurrency/partitioned-notify-storm` (standard; requires pg_partman). `KnownDefect`: `mori://shinzui/pgmq-hs/plans/23-gate-the-notification-fail-open-on-a-real-queue-row-and-state-the-partitioned-queue-contract`. Enable notifications with a 250 ms throttle on a partitioned queue. `LISTEN` takes exact channel names only, so enumerate the queue's partitions from `pg_inherits` and listen on `pgmq.<partition>.INSERT` for each of them as well as on `notifyChannelName`; then send 1000 messages in 5 s. Oracle: at most `5000 / 250 + 1` notifications in total. Expected today: one per insert, on a per-partition channel. Also record send throughput with and without notifications enabled.

`pgmq/notify/concurrency/throttle-lost-after-crash` (standard). Enable a 1000 ms throttle, crash the postmaster in immediate mode, send at 50 per second for 5 s, reconcile with `ensureQueuesReport`, send again. Oracle: a post-crash send reaches the listener (class `contract`: fail-open); before the reconcile `listNotifyInsertThrottles` is empty and notifications are unthrottled, and the reconcile reports `EnabledNotify` after which the count obeys the throttle bound (documented degradation of design note 015, class `implementation`).

`pgmq/notify/concurrency/listener-loss-poll-fallback` (standard). A consumer wakes on notifications and also polls every `pgmq.poll.fallback-seconds` (default 2); the injector terminates its listening backend while messages are sent. Oracle: notifications sent while disconnected never arrive (class `implementation`); every message is nevertheless handled within the fallback interval plus one second (class `contract`).

`pgmq/queue/concurrency/partition-retention-drops-unread` (standard; requires pg_partman). `KnownDefect`: `mori://shinzui/pgmq-hs/plans/21-state-the-fifo-ordering-and-partitioned-retention-contracts-truthfully`. Create a partitioned queue with `pgmq.partition.interval=100` and `pgmq.partition.retention=200` (numeric values partition by `msg_id`). Send 2000 messages in chunks of 100, running `select partman.run_maintenance('pgmq.q_<name>')` after each chunk as pg_partman's background worker would, so that partitions are made ahead of the inserts and old ones become eligible for retention; lease the first 50 messages with a long timeout and read none of the rest; then drain. Verify the partition arithmetic against the installed pg_partman version and adjust the chunking if rows land in the default partition. Oracle: every `Sent` key is eventually handled. Expected today: rows in dropped partitions, unread and leased alike, are gone; the number lost is recorded.

`pgmq/config/concurrency/concurrent-reconcile` (standard). `pgmq.processes` (default 8) `pgmq-reconciler` workers reconcile the same ten declarations at the same instant, fifty rounds with the queues dropped between rounds. Oracle: no worker reports an error (in particular no SQLSTATE 42710); the final catalog equals the declaration; across workers each resource has exactly one creating action per round. Class `contract`. Includes a partitioned declaration when pg_partman is available.

`pgmq/ack/concurrency/overlapping-batch-ack-deadlock` (standard). Sixteen workers call `batchDeleteMessages` on overlapping, differently ordered identifier sets, retrying while `isTransient`. Oracle: every failure is SQLSTATE 40P01 and classified transient; after retries the union of returned identifiers is exactly the set, each once. Class `contract`. The deadlock rate is recorded.

### Milestone 3 — pgmq-hs benchmarks

Scope: seven benchmarks under `kenshou-pgmq/src/Kenshou/Suite/Pgmq/Bench/`, the client abstraction, and a comparison policy. Benchmarks run with `pg.durability=durable` only, tier `standard`, placement `either`; figures are authoritative only from a cell, and only as paired comparisons of at least three interleaved trials through `kenshou compare`. Each benchmark marks warm-up, steady and drain phases; the measurement toolkit's PostgreSQL sampler records `pg_stat_statements` deltas and checkpoint activity. Acceptance: an A/A comparison of each benchmark gives verdict `pass`, and a deliberately slowed arm (`pgmq.handler-ms=5` on one side of `read-ack-throughput`) gives `regression`.

`kenshou-pgmq/src/Kenshou/Suite/Pgmq/RawSql.hs` holds hand-written `hasql` statements that call `pgmq.send`, `pgmq.send_batch`, `pgmq.read`, `pgmq.delete` and `pgmq.pop` with non-null parameters and decode full messages, so the comparison is fair. `kenshou-pgmq/src/Kenshou/Suite/Pgmq/Client.hs` is a record of functions with three constructors.

```haskell
module Kenshou.Suite.Pgmq.Client where

data Layer = RawSql | HasqlLayer | EffectfulLayer

data PgmqClient = PgmqClient
  { send      :: QueueName -> MessageBody -> IO MessageId
  , sendBatch :: QueueName -> [MessageBody] -> IO [MessageId]
  , readBatch :: QueueName -> Int32 -> Int32 -> IO (Vector Message)
  , delete    :: QueueName -> MessageId -> IO Bool
  , popBatch  :: QueueName -> Int32 -> IO (Vector Message)
  }

mkClient :: Layer -> Maybe Tracer -> Pool -> PgmqClient
```

`pgmq/effectful/benchmark/layer-ladder` (tracing `off` only). Knobs `pgmq.layer` (enum `raw-sql`, `hasql`, `effectful`; default `effectful`), `pgmq.op` (enum `send`, `send-batch`, `read`, `delete`, `pop`, `full-cycle`; default `full-cycle`), `pgmq.batch-size` (1, 10, 50, 100), `pgmq.payload-bytes`, `pgmq.consumers` as closed-loop workers (default 1; variant 8). Measures operations per second, p50, p99 and allocation per operation. The headline comparisons are `hasql` against `raw-sql` and `effectful` against `hasql`.

`pgmq/send/benchmark/send-throughput`. Knobs `pgmq.producers` (1, 4, 16, 64), `pgmq.batch-size`, `pgmq.payload-bytes`, `pgmq.queue-kind`, `pgmq.pool-size`. Closed loop. Measures messages per second, send latency, WAL bytes per message. Establishes the send ceiling per queue kind and the batch-size curve.

`pgmq/read/benchmark/read-ack-throughput`. A queue preloaded with `pgmq.message-count` (default 500000). Knobs `pgmq.consumers` (1, 4, 16), `pgmq.batch-size`, `pgmq.ack-mode`, `pgmq.read-strategy` (`plain`, `pop`). Measures messages per second and read and acknowledgement latencies. Establishes the cost of `archive` against `delete`, of batch acknowledgement, and of `pop`.

`pgmq/read/benchmark/produce-consume-latency`. Producers and consumers run concurrently as threads of one process so that one monotonic clock measures enqueue-to-read latency. Open-loop producers at `pgmq.rate-per-second` (default 1000; variants 100, 1000, 5000) with `pgmq.arrival` (`constant`, `poisson`). Knobs `pgmq.producers`, `pgmq.consumers`, `pgmq.batch-size`, `pgmq.pool-size`, and `pgmq.wake` (enum `poll`, `long-poll`, `notify`; default `poll`) with `pgmq.poll.interval-ms`, `pgmq.poll.max-seconds` and `pgmq.notify.throttle-ms`. Measures end-to-end latency percentiles, achieved rate, queue depth over time and connections in use. If the generator cannot hold the rate the run is `inconclusive`, never a regression. Establishes the latency of each wake-up mode and the number of connections long polling pins.

`pgmq/read/benchmark/invisible-backlog-read-cost`. Knob `pgmq.invisible-backlog` (0, 10000, 100000, 1000000) rows that are leased or delayed and therefore invisible, all with lower identifiers than a small visible tail. Measures `readMessage` latency. Establishes how a large in-flight or scheduled backlog slows every read, since the read must either walk `msg_id` order past the invisible rows or sort the visible ones.

`pgmq/fifo/benchmark/grouped-read-cost`. Knobs `pgmq.read-strategy` (the three grouped ones), `pgmq.groups` (10, 1000, 100000), `pgmq.message-count`, `pgmq.fifo-index` (false, true), `pgmq.batch-size`. Measures grouped-read latency and messages per second. Establishes evidence for `mori://shinzui/pgmq-hs/plans/20-replace-the-fifo-gin-index-with-one-the-grouped-reads-can-use`: whether the conventional GIN index changes anything.

`pgmq/notify/benchmark/notify-insert-overhead`. Knobs `pgmq.notify.mode` (enum `off`, `throttled`, `unthrottled`; default `off`), `pgmq.producers`. Measures send throughput and latency. Establishes the insert-path cost of the trigger and of PostgreSQL's database-wide notification lock at commit.

`policies/pgmq.json` names, for each benchmark, the metrics compared, their direction, a relative threshold and an absolute floor, in the format the measurement plan defines.

### Milestone 4 — pgmq-hs soak and telemetry arms

Scope: the soak under `kenshou-pgmq/src/Kenshou/Suite/Pgmq/Soak/SteadyState.hs`, two overhead benchmarks under `kenshou-pgmq/src/Kenshou/Suite/Pgmq/Bench/Overhead.hs` that exercise the telemetry adapter from the shared design under load, the finished layer guide and the ADRs. Acceptance: the reduced soak ends `passed` locally with a leak verdict of `stable`, `kenshou overhead` produces an overhead report for both dimensions, and the reduced soak with tracing exporting over OTLP is still `stable`.

Two knobs are added here for the tracing arm. `pgmq.trace.propagate` (boolean, default false) switches producers and consumers to `sendMessageTraced` and `readMessageWithContext`, so that trace context is written into and read from every message's headers. `otel.semconv-stability-opt-in` (enum `unset`, `database`, `messaging`, `database/dup`; default `unset`) sets the environment variable `OTEL_SEMCONV_STABILITY_OPT_IN`, which the traced interpreter reads on every operation.

`pgmq/queue/soak/steady-state` (tier `soak`, placement `cell`, `pgmq.duration-seconds` default 14400) and `pgmq/queue/soak/steady-state-reduced` (tier `extended`, placement `either`, default 1200) come from `mkSteadyState :: SoakProfile -> Scenario`. Producer and consumer worker processes run at `pgmq.rate-per-second` (default 500). Knobs: `pgmq.queue-kind`, `pgmq.ack-mode` (default `archive`), `pgmq.soak.nack-fraction` (default 0.01; that share of deliveries is left to expire, which churns `vt` and `read_ct`), `pgmq.poll.max-seconds` (default 2, so long-polling backends are part of the picture), `pgmq.soak.archive-purge` (boolean, default false; when true a janitor deletes archive rows older than five minutes). The samplers record, per process, live bytes after major collections, threads and file descriptors; and from PostgreSQL the sizes and dead tuples of the queue table, its two indexes and the archive table, autovacuum runs from `pg_stat_user_tables`, connection counts by `application_name`, the age of the oldest `backend_xmin` among polling backends, and queue depth from the metrics poller. Oracle: the leak verdict is `stable` for every process and for the queue table and its indexes (class `contract` for the processes, `implementation` for relation sizes); queue depth has no positive trend; the archive grows by exactly the number acknowledged (or stays bounded with the purge on); the ledger checkers report no loss and duplicates only for deliberately unacknowledged deliveries. With `partitioned` the scenario sets `pgmq.partition.interval=100000` and a retention far above the backlog, runs `partman.run_maintenance` every 60 seconds so that premade partitions always lead the insert rate, and additionally requires `QueueMetrics.defaultPartitionLength` to stay 0.

`pgmq/effectful/benchmark/interpreter-tracing-overhead` (standard). The `full-cycle` workload of the ladder, always through the effect, supporting all four tracing values, with knobs `pgmq.trace.propagate`, `otel.semconv-stability-opt-in` and the telemetry toolkit's sampler and batch-processor knobs. Run as `kenshou overhead … --arms tracing=off,noop,sdk-inmemory,sdk-otlp`. Establishes what `runPgmqTraced` costs against `runPgmq` in throughput, p99 and allocation, and whether the exporter's queue drops spans at this rate.

`pgmq/queue/benchmark/metrics-poll-overhead` (standard). The produce-consume workload at a fixed rate over a standing backlog of `pgmq.queue-depth` (100000, 1000000) with `metrics.scrape-interval-ms` (15000, 1000). Run as `kenshou overhead … --arms metrics=off,collect`. Establishes the cost of polling `pgmq.metrics`, which counts the table on each call, and records the poll's own latency against depth.

`docs/layers/pgmq.md` lists every scenario with its identifier, the question it answers in one sentence, its knobs with defaults, its tier and placement, and whether it is a contract check, a documented limitation, or a known defect with its upstream link. It closes with the operating rules the scenarios demonstrate: size the visibility timeout above the slowest handler or extend the lease; `read_ct` counts deliveries; never share a small pool between long pollers and producers; keep a poll fallback behind notifications; per-group order needs serialised producers and grouped-head reads; size partition retention above the worst backlog age.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro-runtime-kenshou`, inside the dev shell (`nix develop`, or automatically through `direnv`). Transcripts are illustrative; counts and timings will differ.

Check the dependencies before starting. The build must succeed and the self-test scenarios of every toolkit must be listed.

```bash
cabal build kenshou-core kenshou-measure kenshou-check kenshou-diagnose kenshou-telemetry kenshou-cli
cabal run kenshou -- list --layer selftest
cabal run kenshou -- run selftest/kernel/correctness/postgres-roundtrip --out runs
cabal run kenshou -- cohort show --json | jq . | grep -i -A2 pgmq
```

```text
selftest/kernel/correctness/postgres-roundtrip     smoke     either
selftest/check/concurrency/kill-and-restart-worker standard  either
...
outcome: passed
```

If a command or flag here differs from what was built (`--out`, `--layer`, `--kind`, `--arms`, `--policy`), the completed kernel and toolkit plans are authoritative; run `cabal run kenshou -- run --help` and the corresponding `--help` of `list`, `compare` and `overhead`. Then create the package and build it.

```bash
mkdir -p kenshou-pgmq/src/Kenshou/Suite/Pgmq kenshou-pgmq/test
cabal build kenshou-pgmq
cabal test kenshou-pgmq-test
cabal run kenshou -- list --layer pgmq
```

```text
pgmq/queue/correctness/lifecycle-by-kind           smoke     either
pgmq/vt/correctness/wall-clock-expiry              smoke     either
...
```

Run scenarios as they are implemented, on both PostgreSQL versions.

```bash
cabal run kenshou -- run pgmq/vt/correctness/wall-clock-expiry --out runs --dim pg.version=18
cabal run kenshou -- run pgmq/vt/correctness/wall-clock-expiry --out runs --dim pg.version=17 --set pgmq.visibility-timeout-seconds=1
cabal run kenshou -- run pgmq/fifo/correctness/grouped-result-order --out runs; echo "exit=$?"
cabal run kenshou -- run pgmq/queue/correctness/lifecycle-by-kind --out runs --set pgmq.queue-kind=partitioned
```

```text
run 0198f3c2-…  pgmq/vt/correctness/wall-clock-expiry
  lease 1: read_ct=1 visible_at=+2.000s   redelivery: read_ct=2 at +2.061s
outcome: passed
run 0198f3c4-…  pgmq/fifo/correctness/grouped-result-order
  unsorted batches: 37 of 200
known defect reproduced, non-blocking: mori://shinzui/pgmq-hs/plans/19-give-the-grouped-reads-a-deterministic-return-order
exit=0
```

The last command is also the quick check for pg_partman: it ends `errored` with the remediation message when the extension is missing. Crash scenarios, the non-vacuity proof, benchmarks, overhead and the soak:

```bash
cabal run kenshou -- run pgmq/vt/concurrency/crash-redelivery-read-count --out runs --dim pg.durability=durable
cabal run kenshou -- run pgmq/read/concurrency/no-double-lease-threads --out runs --dim pg.durability=durable --set pgmq.sabotage=unlocked-read; echo "exit=$?"
cabal run kenshou -- run pgmq/effectful/benchmark/layer-ladder --out runs/a --dim pg.durability=durable --set pgmq.layer=hasql
cabal run kenshou -- run pgmq/effectful/benchmark/layer-ladder --out runs/b --dim pg.durability=durable --set pgmq.layer=effectful
cabal run kenshou -- compare runs/a runs/b --policy policies/pgmq.json
cabal run kenshou -- overhead pgmq/effectful/benchmark/interpreter-tracing-overhead --arms tracing=off,noop,sdk-inmemory --out runs
cabal run kenshou -- run pgmq/queue/soak/steady-state-reduced --out runs --dim pg.durability=durable
```

```text
kill 5/5: SIGKILL pid 48213 at after-read (20 leased)
verdicts/lease-intervals.json: passed   verdicts/no-loss.json: passed   verdicts/read-count.json: passed (max read_ct 6)
outcome: passed
...
verdicts/lease-intervals.json: failed (overlaps: 9312)
outcome: failed
exit=1
```

Commit after each group of scenarios. Commits follow Conventional Commits and carry three trailers, for example:

```text
feat(pgmq): add visibility-timeout and lease scenarios

MasterPlan: docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md
ExecPlan: docs/plans/8-cover-pgmq-hs-in-isolation.md
Intention: intention_01m2zvy0gje40tdsdragvzr3tq
```

Before each commit run `nix fmt` (fourmolu and cabal-gild through treefmt) and `cabal test kenshou-pgmq-test`. After writing ADRs run `okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce`.


## Validation and Acceptance

Milestone 1 is accepted when `cabal test kenshou-pgmq-test` passes (including the doctored-ledger tests that make `checkLeaseIntervals` fail on an overlap, on a duplicate read count and on an early redelivery, and the topic matcher's unit tests); `kenshou list --layer pgmq --kind correctness` prints eighteen scenarios; each ends `passed` on `pg.version=17` and `18`, except `pgmq/fifo/correctness/grouped-result-order` and `pgmq/config/correctness/mixed-case-alias-collision`, which end with the kernel's non-blocking known-defect result (how that is rendered and which exit code it gets is defined by the kernel plan, not here), and the partitioned variant of `lifecycle-by-kind`, which ends `passed` with pg_partman and `errored` with the remediation text without it; and the run log of `wall-clock-expiry` shows a redelivery at or after the lease's `visibilityTime`, never before, with `read_ct=2`.

Milestone 2 is accepted when `crash-redelivery-read-count` shows five real `SIGKILL`s in its log and a maximum `read_ct` of six; `no-double-lease-threads` passes with the default and fails with `pgmq.sabotage=unlocked-read`; `pool-exhaustion-long-poll` shows acquisition timeouts only when pollers are at least the pool size; `postgres-restart-recovery` shows every acknowledged send present after an immediate-mode crash; the two pg_partman known-defect scenarios report message counts lost or notifications in excess; and each scenario has written one verdict file per checker under `verdicts/`.

Milestone 3 is accepted when every benchmark writes histograms under `samples/` and summaries in `run-result.json`; an A/A `kenshou compare` gives `pass`; the slowed arm gives `regression`; a benchmark started with `pg.durability=fsync-off` is refused by the dimension support declaration; and an over-driven `produce-consume-latency` run ends `inconclusive`.

Milestone 4 is accepted when the reduced soak ends `passed` with `diagnosis/` holding a `stable` leak verdict per process and `series/` holding relation-size, dead-tuple and queue-depth series; the same soak with `--dim telemetry.tracing=sdk-otlp` is still `stable`; `kenshou overhead` writes a `kenshou.overhead-report/v1` for tracing and for metrics; and `docs/layers/pgmq.md` lists every registered scenario, which the unit test `bundle is documented` enforces by comparing identifiers in the bundle with identifiers in the guide.

For the whole plan: `kenshou list --layer pgmq --json | jq length` prints the number of scenarios in the guide (adjust the `jq` path if the kernel's list document is not a top-level array); no module in `kenshou-pgmq` imports another layer package (`grep -r "Kenshou.Suite\.\(Kiroku\|Shibuya\|Kafka\|Keiro\)" kenshou-pgmq` prints nothing); and the only files changed outside `kenshou-pgmq/`, `docs/layers/pgmq.md`, `policies/pgmq.json` and `docs/adr/` are the two registration files in `kenshou-cli/`.


## Idempotence and Recovery

Every run gets a fresh run directory and, locally, a fresh ephemeral PostgreSQL that is destroyed afterwards, so reruns need no cleanup. Queue names embed the run identifier, so concurrent or repeated runs against an external server (a cell) never collide; scenarios drop their queues in a `finally`. After a harness crash on an external server, leftover queues can be removed with `select pgmq.drop_queue(queue_name) from pgmq.meta where queue_name ~ '^kn[0-9a-f]{8}_'`. Worker processes are spawned in a process group by the correctness toolkit, which reaps them; if the harness itself was killed, `pkill -f 'kenshou worker --role pgmq-'` removes stragglers, and ephemeral-pg sweeps abandoned clusters in its temporary root at the next start. A scenario that crashed the postmaster restarts it before teardown; if that fails the run ends `infrastructure-failure` and the fixture is discarded.

The registration edit is additive and safe to reapply. If the build breaks because a toolkit signature differs from this plan, fix `Harness.hs`, `Roles.hs` or `Telemetry.hs` only, and record the difference in Surprises & Discoveries. If pg_partman is unavailable, everything else still runs; record it and raise it with the owner of the dev shell. If a documented-limitation scenario starts failing because upstream changed behaviour for the better, invert its expectation, move it to class `contract`, and note the pgmq-hs version in the Decision Log. If a known-defect scenario passes on the `head` cohort, leave the reference in place until the `released` cohort also passes, then remove it.


## Interfaces and Dependencies

Runtime libraries, at the versions the cohort pins (do not add bounds that contradict `cohort/released.project`): `pgmq-core`, `pgmq-hasql`, `pgmq-effectful` and `pgmq-config` 0.6.1.0; `hasql` 1.10.x and `hasql-pool` 1.4.x (what the pgmq family requires; Hackage also carries hasql 2.0 and hasql-pool 1.5, which it does not accept); `effectful-core` as pinned; `hs-opentelemetry-api` 1.0; `postgresql-libpq` (at least 0.10.1, below 0.12) for `LISTEN`; `aeson`, `vector`, `text`, `time`, `containers`, `async`, `stm`, `random`. `pgmq-migration` is not a dependency of this package, because the kernel installs the schema. In-repository: `kenshou-core`, `kenshou-measure`, `kenshou-check`, `kenshou-diagnose`, `kenshou-telemetry`. Tests: `hspec`, `hspec-hedgehog`, `hedgehog`. `kenshou-pgmq.cabal` uses `default-language: GHC2024` and the repository's common warning stanza.

At the end of Milestone 1 these exist: `Kenshou.Suite.Pgmq (bundle :: LayerBundle)`; `Kenshou.Suite.Pgmq.Knobs (PgmqKnobs, QueueKind, ReadStrategy, AckMode, commonKnobs, resolveKnobs)`; `Kenshou.Suite.Pgmq.Harness (PgmqRun, withPgmqRun, withPgmqPool, scenarioQueueName, withScenarioQueue, requirePartman, runOps)`; `Kenshou.Suite.Pgmq.Telemetry (pgmqTracer, withMetricsPoller)`; `Kenshou.Suite.Pgmq.Facts (PgmqFact)`; `Kenshou.Suite.Pgmq.Oracle (checkLeaseIntervals, checkNotBeforeDue, queueKeys, archiveKeys, conservation)`; `Kenshou.Suite.Pgmq.Listener (withListener, awaitNotifications)`; `Kenshou.Suite.Pgmq.TopicModel (matches :: TopicPattern -> RoutingKey -> Bool)`; and `Kenshou.Suite.Pgmq.Correctness.{Queue,Send,Read,Ack,Vt,Fifo,Topics,Notify,Config,Effectful}`, each with `scenarios :: [Scenario]`. At the end of Milestone 2: `Kenshou.Suite.Pgmq.Roles (roles, CrashPoint)` and `Kenshou.Suite.Pgmq.Concurrency.{Lease,Crash,Pool,Outage,Fifo,Notify,Retention,Config}`. At the end of Milestone 3: `Kenshou.Suite.Pgmq.RawSql`, `Kenshou.Suite.Pgmq.Client (PgmqClient, Layer, mkClient)`, `Kenshou.Suite.Pgmq.Bench.{Ladder,Send,ReadAck,ProduceConsume,Backlog,Fifo,Notify}` and `policies/pgmq.json`. At the end of Milestone 4: `Kenshou.Suite.Pgmq.Soak.SteadyState (mkSteadyState)`, `Kenshou.Suite.Pgmq.Bench.Overhead` and `docs/layers/pgmq.md`.

What other plans consume from this one. Nothing imports `kenshou-pgmq` except `kenshou-cli`. `docs/plans/3-plan-and-select-runs-from-what-changed.md` selects `pgmq/**` when any pgmq-hs package or the PostgreSQL version changes, and can narrow to `pgmq/config/**` or `pgmq/effectful/**` using the component mapping given in Context and Orientation. `docs/plans/10-cover-shibuya-core-and-its-pgmq-and-kiroku-adapters.md` and `docs/plans/13-cover-the-keiro-outbox-inbox-and-job-queue.md` build on the facts established here — lease accounting on the database clock, `read_ct` as a delivery count, the pool-pinning of long polls, the FIFO boundary — and may copy the lease-interval rule, but they must not import this package. The services this plan needs at run time are PostgreSQL 17 and 18 from the dev shell or a cell, with pg_partman compiled in for the partitioned-queue scenarios, and, for `telemetry.tracing=sdk-otlp`, the OTLP sink the telemetry plan provides.
