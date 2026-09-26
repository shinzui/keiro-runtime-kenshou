# Shibuya layer verification

The `shibuya` layer exercises the framework, its metrics server, and its PGMQ and Kiroku adapters through public service-facing APIs. Core and metrics scenarios use synthetic sources or local HTTP and WebSocket servers. Adapter scenarios use real PostgreSQL, and the process cases keep effects in a durable ledger across worker deaths. Run `kenshou list --layer shibuya --json` for the executable catalogue and `kenshou run <scenario-id> --out runs` for one case. The catalogue below reflects the 53 scenarios registered on 2026-09-26; four planned benchmarks, soaks and trace-continuity cases are still absent.

The core knobs include `shibuya.inbox-size`, `shibuya.concurrency` (`serial`, `ahead:N`, `async:N`), `shibuya.ordering`, `shibuya.strategy`, `shibuya.processor-kind`, `shibuya.messages`, `shibuya.partitions` and `shibuya.decisions`. Individual cases expose only the knobs they actually read. The leased-message bound probe additionally exposes `bound.slack` and waits for 500 ms without source pulls before sampling. PGMQ cases expose polling, batch, prefetch, visibility-timeout and pool controls; Kiroku cases expose subscription target, batch size, consumer-group size and checkpoint policy. Read the scenario definitions and checked-in run specs in `specs/` for the actual knobs before changing a workload.

## Registered scenarios

Each row gives the full CLI identifier and the behavior checked or measured. `correctness` cases assert a public or explicitly labelled implementation behavior; `concurrency` cases use scheduling gates, processes or faults to exercise the same behavior under overlap.

### core-batch (2)

| Scenario | Check |
|---|---|
| `shibuya/core-batch/concurrency/shutdown-with-partial-batches` | A graceful stop flushes partial batches; a forced stop cannot finalize after returning. |
| `shibuya/core-batch/correctness/conservation-triggers-and-decisions` | Size, timeout and flush triggers conserve deliveries while fallback, exceptions and keyed concurrency preserve acknowledgements. |

### core-ordering (4)

| Scenario | Check |
|---|---|
| `shibuya/core-ordering/concurrency/hot-key-head-of-line` | Cold partition keys continue while one hot key has slow handlers; reports the latency cost against a control run. |
| `shibuya/core-ordering/concurrency/keyed-scheduler-model` | Seeded per-key delivery histories preserve order, serialization, finalization and graceful stop boundaries. |
| `shibuya/core-ordering/concurrency/keyed-worker-failure-stops-intake` | A keyed worker exception stops the scheduler and bounds successor starts. |
| `shibuya/core-ordering/correctness/policy-matrix` | Checks source and per-partition order across every valid ordering and concurrency pair. |

### core-runner (16)

| Scenario | Check |
|---|---|
| `shibuya/core-runner/benchmark/framework-tax` | Measures bare Streamly and serial Shibuya over the same forced message list, with per-message samples. |
| `shibuya/core-runner/concurrency/adapter-shutdown-failure-does-not-skip-siblings` | A throwing adapter shutdown still shuts down sibling adapters and reports the exception to every stopper. |
| `shibuya/core-runner/concurrency/blocking-adapter-shutdown-is-bounded` | A permanently blocked adapter shutdown respects the application's total shutdown deadline. |
| `shibuya/core-runner/concurrency/finalization-failure-is-a-failure-not-a-halt` | Transient finalizer faults preserve the decision, and an exhausted retry budget triggers supervision. |
| `shibuya/core-runner/concurrency/forced-shutdown-abandons-but-never-loses` | A forced stop leaves leases for redelivery, and a replacement application eventually finalizes every message. |
| `shibuya/core-runner/concurrency/gc-liveness-with-dropped-handle` | A caller survives major collections with a live idle processor or after its AppHandle is dropped. |
| `shibuya/core-runner/concurrency/halt-strands-leased-messages` | A processor halt may strand bounded leases until expiry, but a replacement consumes the whole queue. |
| `shibuya/core-runner/concurrency/halt-wakes-idle-intake` | A halt decision wakes an idle source and lets waitApp finish within the deadline. |
| `shibuya/core-runner/concurrency/leased-but-unfinalized-upper-bound` | Bounds outstanding leases while every handler waits on a gate. |
| `shibuya/core-runner/concurrency/startup-cancellation-leaks-nothing` | Cancellation during startup and rapid start-stop cycles leave no active source or thread growth. |
| `shibuya/core-runner/concurrency/stop-all-on-failure-delivers-once` | A source failure reaches the caller once and stops siblings only under StopAllOnFailure. |
| `shibuya/core-runner/correctness/a-failed-processor-is-never-restarted` | A failed source stays stopped until an application restart resumes the broker. |
| `shibuya/core-runner/correctness/duplicate-processor-ids-are-rejected` | Rejects duplicate processor identities before either source is pulled. |
| `shibuya/core-runner/correctness/every-delivery-is-finalized-exactly-once` | Conserves a finite source and finalizes each delivery once with a bounded inbox. |
| `shibuya/core-runner/correctness/invalid-config-rejected-before-effects` | Rejects invalid inbox and ordering policies before pulling a source or shutting down an adapter. |
| `shibuya/core-runner/correctness/nonpositive-concurrency-is-rejected` | Rejects zero and negative concurrency bounds or runs at most one handler. |

### kiroku-adapter (9)

| Scenario | Check |
|---|---|
| `shibuya/kiroku-adapter/concurrency/consumer-group-is-static` | Checks four Kiroku group partitions in one app and four processes, then a dead member's static lag and restart. |
| `shibuya/kiroku-adapter/concurrency/group-acquisition-failure-strands-nothing` | Checks partial eight-member acquisition, cleanup failures, 200 cancellation boundaries, and post-failure SQL reads. |
| `shibuya/kiroku-adapter/concurrency/postgres-outage-and-reconnect` | Terminates subscription and LISTEN backends, then restarts the postmaster while a Kiroku consumer and appender continue. |
| `shibuya/kiroku-adapter/concurrency/retry-budget-resets-on-restart` | Kills a Kiroku consumer after its third retry delivery and verifies restart resets attempts before one dead letter. |
| `shibuya/kiroku-adapter/concurrency/sigkill-replay-window` | Kills Kiroku consumers after durable effects and verifies bounded replay, position order and checkpoint monotonicity. |
| `shibuya/kiroku-adapter/concurrency/two-processes-one-member` | Two Kiroku adapter processes sharing one member preserve events while reporting duplicate handler effects. |
| `shibuya/kiroku-adapter/correctness/ack-decision-mapping` | Checks retry attempts, dead-letter reason mapping, filtered delivery and persisted checkpoint progress. |
| `shibuya/kiroku-adapter/correctness/halt-and-shutdown-replay` | Restarts after handler halt and forced mid-batch stop without skipping an uncheckpointed Kiroku event. |
| `shibuya/kiroku-adapter/correctness/in-flight-depth-is-one` | Proves ack-coupled Kiroku delivery stays at depth one even with eight asynchronous Shibuya handlers. |

### metrics (9)

| Scenario | Check |
|---|---|
| `shibuya/metrics/concurrency/websocket-slot-accounting` | WebSocket churn releases slots, threads and descriptors; stopping the server twice remains safe. |
| `shibuya/metrics/correctness/counters-distinguish-retries-from-success` | Checks the documented retry counter mapping and reports whether retry and success remain indistinguishable in Prometheus. |
| `shibuya/metrics/correctness/endpoint-contract` | HTTP metrics and health routes preserve their JSON, Prometheus, state and feature-flag contracts. |
| `shibuya/metrics/correctness/live-reflects-a-stopped-master` | Liveness reports a stopped master as unavailable. |
| `shibuya/metrics/correctness/ready-not-stuck-under-sustained-load` | A processor making steady progress remains ready beyond the stuck threshold while a blocked control becomes unready. |
| `shibuya/metrics/correctness/ready-recovers-after-transient-handler-exception` | Readiness recovers after one handler exception is retried and subsequent work makes progress. |
| `shibuya/metrics/correctness/ready-reflects-a-failed-processor` | Readiness retains a failed configured processor after its source exits. |
| `shibuya/metrics/correctness/websocket-flag-gates-upgrades` | Disabling the WebSocket endpoint prevents an upgrade while the enabled endpoint still serves a snapshot. |
| `shibuya/metrics/correctness/websocket-unsubscribe-all-suppresses-updates` | Unsubscribing from a processor after subscribe-all suppresses its updates while other subscriptions remain live. |

### pgmq-adapter (13)

| Scenario | Check |
|---|---|
| `shibuya/pgmq-adapter/concurrency/backend-termination-and-the-restart-loop` | Exercises polling and acknowledgement faults with a producer, a durable effect ledger and an application restart loop. |
| `shibuya/pgmq-adapter/concurrency/dead-letter-move-is-atomic` | Checks source/DLQ conservation while backend termination and lost COMMIT responses disturb direct dead lettering. |
| `shibuya/pgmq-adapter/concurrency/handler-outlives-visibility-timeout` | Two consumer processes demonstrate overlapping effects after lease expiry and prevent them with explicit lease renewal. |
| `shibuya/pgmq-adapter/concurrency/leased-bound-versus-visibility-timeout` | Compares queued lease age and duplicate effects under five- and thirty-second visibility timeouts. |
| `shibuya/pgmq-adapter/concurrency/long-poll-pool-starvation` | Two long-polling processors share a two-connection pool while acknowledging and moving messages to a DLQ. |
| `shibuya/pgmq-adapter/concurrency/multi-process-competition` | Four consumer processes conserve grouped messages and test FIFO head ordering across a retry. |
| `shibuya/pgmq-adapter/concurrency/postgres-outage-and-the-restart-loop` | Exercises polling and acknowledgement faults with a producer, a durable effect ledger and an application restart loop. |
| `shibuya/pgmq-adapter/concurrency/prefetch-strands-until-visibility-timeout` | Prefetched but unhandled deliveries remain durable and redeliver after their visibility timeout. |
| `shibuya/pgmq-adapter/concurrency/shutdown-releases-read-chunk` | A read chunk held on the wire is released promptly when shutdown reaches the adapter first. |
| `shibuya/pgmq-adapter/concurrency/sigkill-between-handler-success-and-ack` | SIGKILL at the durable-effect gate proves bounded PGMQ redelivery and crash-local duplicates. |
| `shibuya/pgmq-adapter/correctness/ack-decision-mapping` | Checks queue, lease, archive, dead-letter and halt state for every PGMQ acknowledgement decision. |
| `shibuya/pgmq-adapter/correctness/auto-dead-letter-counts-deliveries` | Retry exhaustion and raw reads spend the same delivery budget before the handler runs. |
| `shibuya/pgmq-adapter/correctness/shutdown-latency-is-bounded-by-polling` | An idle PostgreSQL-backed adapter drains within its configured poll interval and can be stopped twice. |

## Lifecycle coverage

`Kenshou.Suite.Shibuya.Matrix` assigns each executable scenario to boundary/case cells. The counts below are derived from that source; one scenario can cover several cells. A zero is a coverage gap. The matrix currently marks no cell as inherently unreachable, so the zero cells remain work for the lifecycle milestone.

| Boundary | normal | synchronousException | cancellation | timeout | repeatedStop |
|---|---:|---:|---:|---:|---:|
| startup-registration | 1 | 2 | 1 | 0 | 1 |
| ingestion-backpressure | 2 | 1 | 1 | 2 | 0 |
| dispatch | 4 | 1 | 1 | 1 | 0 |
| keyed-ordering | 3 | 2 | 1 | 0 | 1 |
| batching | 1 | 1 | 1 | 0 | 1 |
| retry-lease | 2 | 0 | 1 | 2 | 1 |
| finalization | 1 | 1 | 2 | 1 | 0 |
| drain-cancel | 1 | 1 | 1 | 1 | 1 |
| supervision | 2 | 4 | 0 | 1 | 1 |
| metrics-health | 2 | 2 | 1 | 1 | 1 |
| metrics-websocket | 1 | 1 | 1 | 2 | 1 |
| pgmq-persistence | 2 | 3 | 2 | 3 | 2 |
| kiroku-persistence | 2 | 2 | 3 | 1 | 1 |

## Cohort observations

The released core is Shibuya 0.9.0.3. The pinned remediation line carries lifecycle fixes, and the isolated current-release line uses Hackage 0.10.0.0. The adapter versions vary independently. A known-defect outcome records only its scoped failure labels; missing conservation, failed fault injection and other unexpected failures remain blocking. The child [ExecPlan](../plans/10-cover-shibuya-core-and-its-pgmq-and-kiroku-adapters.md) has run IDs and the exact candidate cohorts.

| Finding | Historical outcome | Remediation or current outcome | Owner reference |
|---|---|---|---|
| Blocked adapter shutdown, duplicate IDs, startup cancellation and sibling cleanup | Reproduced on core 0.9.0.3 | Focused cases pass on pinned remediation | `mori://shinzui/shibuya/okf/reviews/concepts/REV-2`, `mori://shinzui/shibuya/okf/reviews/concepts/REV-3` |
| Idle-intake halt and exhausted finalizer supervision | Reproduced on core 0.9.0.3 | Focused cases pass on pinned remediation | `mori://shinzui/shibuya/okf/reviews/concepts/REV-4` |
| Keyed worker failure and nonpositive concurrency | Reproduced on core 0.9.0.3 | Focused cases pass on pinned remediation | `mori://shinzui/shibuya/okf/reviews/concepts/REV-5`, `mori://shinzui/shibuya/okf/reviews/concepts/REV-6` |
| Health readiness/liveness and WebSocket contracts | Scoped failures reproduced on metrics 0.9.0.3 | Focused cases pass on pinned remediation; full current-release CLI sweep remains open | `mori://shinzui/shibuya/okf/reviews/concepts/REV-7`, `mori://shinzui/shibuya/okf/reviews/concepts/REV-8`, `mori://shinzui/shibuya/okf/reviews/concepts/REV-9` |
| Long-poll acknowledgement stalls with a two-connection pool | Reproduced on PGMQ adapter 0.16.0.0 | Reproduced on 0.16.1.0; fixed-version acceptance remains open | `mori://shinzui/shibuya-pgmq-adapter/okf/bug-reports/concepts/BUG-1` |
| Partial Kiroku group acquisition leaks members and replaces the primary exception | Reproduced on adapter 0.5.1.2 | Passes on 0.5.1.3 on PostgreSQL 18 | `mori://shinzui/shibuya/okf/reviews/concepts/REV-13` |

The retry and success Prometheus counters remain indistinguishable in the measured release; the [local finding](../findings/14-shibuya-retry-and-success-counters-are-indistinguishable.md) records that documented limitation. The transient-handler readiness probe reproduces a sticky failed state tracked by `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-7`. Two processes claiming one Kiroku member each process every event, so the [local guard finding](../findings/16-shibuya-kiroku-same-member-duplicate-work.md) recommends exposing the store guard. The Kiroku live all-streams crash probe permits a 1,000-event publisher replay window and reports the observed replay separately from contract loss checks.

## Framework benchmark

`framework-tax` runs one serial Streamly drain or Shibuya application over the same fully forced list of 100,000 or 1,000,000 messages per pass. Both arms update one counter and record one sample per message; Shibuya's sample runs from source delivery through acknowledgement. The measurement toolkit writes message and pass histograms, throughput, p50/p99/p99.9, RTS series and an allocation-per-message figure. The steady phase ends after a completed pass count. Its aggregate pass sample threshold is one because each pass contains at least 1,000 messages, which the scenario checks separately. The in-process driver is CPU-bound by design, so this case disables the toolkit's driver CPU saturation gate and records that choice. Local runs are indicative; cell placement is needed for authoritative comparisons.

Three interleaved 100,000-message local pairs, with matching seeds per pair, passed and produced a `kenshou.comparison/v1` result under `policies/shibuya-framework-tax.json`. The verdict was `inconclusive`: the measured Shibuya p99 exceeded the strict reference limit, but the three-pair confidence interval was wider than the policy permits. The two 1,000,000-message arms also passed with complete histograms. The result measures framework overhead and does not establish a production performance budget. The run IDs and comparison ID are recorded in the child ExecPlan.

## Sizing and recovery

The gated synthetic broker observed 105 outstanding leases under `inboxSize=100`, `async:4`, against `inboxSize + 3n + bound.slack = 114`. A one-slot serial run observed 3 against 6; an eight-slot `ahead:4` run with zero slack observed 13 against 20. All three finalized 1,000 messages after the gate opened. The bound describes the core's single-message processor pipeline at the tested settings.

For the PGMQ adapter, estimate the time a lease can wait inside the pipeline as `(inboxSize + 3n + prefetchBufferSize × batchSize) × handlerSeconds / n`, then measure the actual tail under load. The measured five-second visibility timeout produced duplicate effects; the 30-second control drained without duplicates. In the tested setup the arithmetic yielded 7.6 seconds while observed safe-arm latency reached about 8.1 seconds. Choose the visibility timeout above the measured tail with operating margin, or renew the lease for a handler that can outlive it.

Shibuya does not automatically restart a failed processor. An application restart loop waits for the app's processors to finish, stops the app, rebuilds adapters and processors, and starts a new app with the same durable queue or subscription identity. The PGMQ and Kiroku fault scenarios check eventual conservation through this pattern. Handlers should tolerate duplicate deliveries inside the measured crash window.

## Remaining acceptance

The lifecycle matrix has uncovered cells and the isolated current-release CLI sweep for the core and metrics cases is incomplete. Four Shibuya benchmarks, four soak pairs, trace-continuity cases, overhead comparisons, and upstream finding audit described by the ExecPlan remain to be implemented and run. The framework-tax comparison needs a controlled cell rerun to narrow its confidence interval. PostgreSQL 18 is the first repair-and-rerun checkpoint; PostgreSQL 17 compatibility acceptance follows the MasterPlan's later pass.
