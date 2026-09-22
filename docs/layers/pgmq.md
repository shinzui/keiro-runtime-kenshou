# PGMQ layer verification

The `pgmq` layer isolates pgmq-hs and the PGMQ SQL schema from shibuya and keiro. Every scenario uses a per-run queue in a PostgreSQL database provisioned by the harness. Correctness scenarios support PostgreSQL 17 and 18 with either durability setting. Concurrency, benchmark, and soak scenarios require durable PostgreSQL. All scenarios support the four tracing arms and either disabled metrics or SQL-metrics collection.

The shared knobs directly name their pgmq-hs or workload setting. Important defaults are `pgmq.queue-kind=standard`, `pgmq.visibility-timeout-seconds=30`, `pgmq.batch-size=10`, `pgmq.pool-size=10`, `pgmq.poll.max-seconds=0`, `pgmq.poll.interval-ms=100`, `pgmq.payload-bytes=256`, `pgmq.read-strategy=plain`, and `pgmq.ack-mode=delete`. Benchmarks add the shared `load.*` and `measure.*` controls; `pgmq.layer=raw-sql|hasql|effectful` selects a real client boundary and `pgmq.comparison-label=a|b` is a behaviour-neutral A/A axis. `pgmq.trace.propagate` enables W3C header propagation, and `otel.semconv-stability-opt-in` controls the environment read by the traced interpreter. Partitioned variants require `pg_partman`; absence is reported as an error with installation guidance.

## Correctness scenarios

- `pgmq/queue/correctness/lifecycle-by-kind` — queue lifecycle and catalog truth (contract; smoke; either).
- `pgmq/send/correctness/send-variants-round-trip` — all send variants round-trip JSON and headers (contract; smoke; either).
- `pgmq/send/correctness/delayed-and-scheduled-visibility` — no message arrives before its database due time (contract; standard; either).
- `pgmq/send/correctness/large-payload-round-trip` — payloads survive queue and archive storage (contract; standard; either).
- `pgmq/send/correctness/transactional-send-rollback` — caller-owned transactions hide and roll back sends (contract; smoke; either).
- `pgmq/read/correctness/read-semantics` — batch, conditional, pop, and polling semantics (contract; smoke; either).
- `pgmq/read/correctness/plain-read-return-order` — observes plain-read vector ordering after heap churn (implementation; standard; either).
- `pgmq/ack/correctness/delete-archive-semantics` — single and batch acknowledgement semantics (contract; smoke; either).
- `pgmq/vt/correctness/wall-clock-expiry` — real visibility-timeout expiry and read-count increment (contract; smoke; either).
- `pgmq/vt/correctness/set-vt-semantics` — relative, absolute, and extended leases (contract; smoke; either).
- `pgmq/fifo/correctness/grouped-read-semantics` — grouped, round-robin, and grouped-head boundaries (contract; smoke; either).
- `pgmq/fifo/correctness/grouped-result-order` — deterministic grouped return order ([known defect](mori://shinzui/pgmq-hs/plans/19-give-the-grouped-reads-a-deterministic-return-order); standard; either).
- `pgmq/topics/correctness/routing-model` — database routing agrees with the pure wildcard model (contract; standard; either).
- `pgmq/notify/correctness/channel-and-throttle` — channel naming, throttling, updates, and disablement (contract; smoke; either).
- `pgmq/config/correctness/reconcile-convergence` — declarative reconciliation converges and reports drift (contract; smoke; either).
- `pgmq/config/correctness/mixed-case-alias-collision` — physical table aliases are reported ([known defect](mori://shinzui/pgmq-hs/plans/24-report-name-collisions-and-unsupported-notifications-instead-of-acting-on-them); smoke; either).
- `pgmq/effectful/correctness/interpreter-parity-and-errors` — interpreters agree and real failures are classified (contract; standard; either).
- `pgmq/effectful/correctness/traced-span-contract` — span names, kinds, failures, and context propagation (contract; smoke; either).

## Concurrency and failure scenarios

- `pgmq/read/concurrency/no-double-lease-threads` — thread ownership is disjoint; the unlocked-read sabotage proves the oracle fires.
- `pgmq/read/concurrency/no-double-lease-processes` — process ownership is disjoint while producers and consumers overlap.
- `pgmq/vt/concurrency/crash-redelivery-read-count` — deterministic post-read kills preserve expiry and delivery counts.
- `pgmq/ack/concurrency/random-sigkill-at-least-once` — seeded worker kills during continuous production preserve every send, bound duplicate handling by unacknowledged killed leases, and drain the queue.
- `pgmq/send/concurrency/producer-sigkill-batch-atomicity` — interrupted batch sends remain all-or-nothing.
- `pgmq/ack/concurrency/stale-ack-after-expiry` — demonstrates the documented lack of acknowledgement fencing.
- `pgmq/read/concurrency/pool-exhaustion-long-poll` — long polls pin connections and acquisition timeouts recover.
- `pgmq/effectful/concurrency/backend-termination-recovery` — the pool recovers after backend termination and checks the surfaced error's transient classification.
- `pgmq/effectful/concurrency/postgres-restart-recovery` — durable data and the pool survive a server restart.
- `pgmq/queue/concurrency/unlogged-queue-crash-loss` — demonstrates unlogged loss against a durable control queue.
- `pgmq/effectful/concurrency/network-partition` — a live TCP reset and recovery through the fault proxy, including transient classification.
- `pgmq/fifo/concurrency/head-per-group-barrier` — grouped-head keeps one live lease and ordered handling per group.
- `pgmq/fifo/concurrency/grouped-batch-successor-hazard` — demonstrates grouped-batch successor inversion.
- `pgmq/fifo/concurrency/producer-commit-order-inversion` — demonstrates identifier order differs from commit order.
- `pgmq/notify/concurrency/partitioned-notify-storm` — throttle bypass on partition triggers ([known defect](mori://shinzui/pgmq-hs/plans/23-gate-the-notification-fail-open-on-a-real-queue-row-and-state-the-partitioned-queue-contract)).
- `pgmq/notify/concurrency/throttle-lost-after-crash` — fail-open delivery and reconcile recovery after throttle loss.
- `pgmq/notify/concurrency/listener-loss-poll-fallback` — the authoritative polling fallback drains delivery independently of notifications.
- `pgmq/queue/concurrency/partition-retention-drops-unread` — retention preserves unread rows ([known defect](mori://shinzui/pgmq-hs/plans/21-state-the-fifo-ordering-and-partitioned-retention-contracts-truthfully)).
- `pgmq/config/concurrency/concurrent-reconcile` — simultaneous reconcilers converge without catalog races.
- `pgmq/ack/concurrency/overlapping-batch-ack-deadlock` — overlapping acknowledgements retry only transient deadlocks.

## Benchmarks, telemetry, and soak

- `pgmq/effectful/benchmark/layer-ladder` — raw SQL versus pgmq-hasql versus pgmq-effectful.
- `pgmq/send/benchmark/send-throughput` — send throughput, latency, batching, and WAL cost.
- `pgmq/read/benchmark/read-ack-throughput` — read and acknowledgement throughput.
- `pgmq/read/benchmark/produce-consume-latency` — intended-start latency across polling, long polling, and notifications.
- `pgmq/read/benchmark/invisible-backlog-read-cost` — read cost behind invisible lower identifiers.
- `pgmq/fifo/benchmark/grouped-read-cost` — grouped strategy and FIFO-index costs.
- `pgmq/notify/benchmark/notify-insert-overhead` — notification trigger and commit-lock overhead.
- `pgmq/effectful/benchmark/interpreter-tracing-overhead` — tracing-arm overhead through the effect interpreter.
- `pgmq/queue/benchmark/metrics-poll-overhead` — SQL metrics polling overhead by queue depth and interval.
- `pgmq/queue/soak/steady-state` — four-hour cell soak with process, queue, index, and archive verdicts.
- `pgmq/queue/soak/steady-state-reduced` — twenty-minute local form of the same soak.

Every benchmark writes native latency histograms, load series, runtime/process series, and PostgreSQL activity, WAL, database, relation, and statement evidence. `policies/pgmq.json` is the controlled-comparison policy. The overhead command uses the telemetry policy; the first tracing study found `sdk-inmemory` above that policy while `noop` and `sdk-otlp` passed, and the first metrics-collection study passed.

The soak uses the same constructor for its four-hour and twenty-minute registrations. It mixes deletion, archiving, and deliberate one-second nacks, drains expired work before judging convergence, watches both queue and archive relations, publishes a bloat verdict, and runs the leak detector over independent sampler series.

## Released-classifier findings

Two disruptive scenarios currently fail their contract check on pgmq-hs 0.6.1.0 even though the same pool recovers. Administrative backend termination can surface as `UnexpectedRowCountStatementError 1 1 1`, and a proxied TCP reset can surface as a server error with an empty SQLSTATE. Neither shape is classified transient by `Pgmq.Effectful.isTransient`. No upstream improvement request currently owns these observations; run evidence is recorded in ExecPlan 8 without claiming a defect filing.

## Operating rules demonstrated

Size the visibility timeout above the slowest handler or extend the lease. Treat `read_ct` as a delivery count, not a failure count. Do not share a small pool between long pollers and producers. Keep a polling fallback behind notifications. Per-group processing order needs serialised producers and grouped-head reads. Size partition retention above the worst backlog age, because retention operates on whole partitions rather than message state.
