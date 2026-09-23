---
id: 12
slug: cover-the-keiro-command-processor-process-managers-and-routers
title: "Cover the keiro command processor, process managers and routers"
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
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-23T19:31:59Z
      mode: "implement"
      note: "Verified prerequisite build, self-tests, and released cohort"
---

# Cover the keiro command processor, process managers and routers

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`keiro` is the top library of the keiro runtime. Its write side turns a command into events (the command processor), and its coordination side reacts to events by sending more commands (process managers, which keep state, and routers, which do not). Services are about to depend on three promises made by that code: a command carrying fixed event identifiers is applied at most once however often it is retried; a process manager or router that is redelivered an event, or killed half-way through reacting to it, ends up having written each target effect exactly once; and an inline projection (a read-model update made in the same database transaction as the events) is never out of step with the event log. Today those promises are checked only by single-process unit tests in which "crash" means a thrown exception and PostgreSQL runs with `fsync=off`.

After this plan a maintainer can run `kenshou list` and see a `keiro` layer, and can run about forty scenarios that test those promises with real operating-system processes, real `SIGKILL`, real PostgreSQL backend termination and a durable database; that measure command throughput and latency against pool size, writer count, snapshot policy and stream length, including the store-wide append ceiling as seen through the command path; that soak the whole write side and judge it with a leak verdict; and that repeat any of it with OpenTelemetry tracing and metrics switched on or off. Two documented limitations of keiro are encoded as known-defect scenarios so that they are reported on every run without blocking a release.

This plan also creates the `kenshou-keiro` package and owns the shared keiro fixture domain: a small bank-ledger model (accounts, a transfer saga across two account streams, a bonus router that fans out to N accounts, one inline and one asynchronous projection, seeded workload generators, a pure reference model and SQL oracles). The plans `docs/plans/13-cover-the-keiro-outbox-inbox-and-job-queue.md`, `docs/plans/14-cover-keiro-durable-execution-timers-and-sharded-subscriptions.md` and `docs/plans/15-verify-the-assembled-runtime-end-to-end-and-under-soak.md` build on it, so its modules and signatures are specified exactly here.

To see it working after the first milestone, run `cabal run kenshou -- run keiro/command/correctness/fixture-roundtrip --out runs` from the repository root and observe outcome `passed` and exit code 0. After the third milestone, run `keiro/process-manager/concurrency/sigkill-crash-windows` and observe a worker process being killed between the saga's own append and its target write, restarted, and the verdict `exactly-once-target-effects` passing.


## Progress

Milestone 1 — The keiro fixture domain

- [x] (2026-09-23T19:31:59Z) Verify the hard dependencies are complete (kernel, measurement, correctness, diagnostics, telemetry) using the checks in Concrete Steps. `nix develop --command cabal build all` succeeded; both required self-tests passed; the released cohort contains the stated keiro, keiki, kiroku and shibuya versions.
- [ ] Create `kenshou-keiro/kenshou-keiro.cabal` with the library and the `kenshou-keiro-test` suite. The package and suite build; remaining: add the Milestone 1 fixture modules and dependencies.
- [x] (2026-09-23T19:40:00Z) Write `Kenshou.Suite.Keiro.Fixture.Domain` and `.Fixture.Account`; prove `mkEventStream` accepts the account transducer for every snapshot policy variant. `cabal test kenshou-keiro-test` passes the four policy constructors.
- [ ] Write `.Fixture.Transfer` (saga, strict variant, reactive variant) and `.Fixture.Bonus` (plain and declarative router). The saga, strict variant, bonus stream, and plain router compile; reactive and declarative variants remain.
- [ ] Write `.Fixture.Projection`, `.Fixture.Runtime`, `.Fixture.Bridge`. The inline projection, store runner, and list adapter compile; asynchronous projection, complete runtime wrapper, and durable bridges remain.
- [ ] Write `.Fixture.Workload`, `.Fixture.Model`, `.Fixture.Oracle`, `.Fixture.Roles`. Workload, Model, and the account-log and balance SQL oracles are present; remaining oracle readers and Roles remain.
- [ ] Unit tests: codec round trip, model agrees with the keiki transducer, workload determinism, expected identifiers, list adapter acknowledgement log. Seven unit examples pass, including the acknowledgement log and setup/worker identifier separation; exact UUID assertions remain.
- [x] (2026-09-23T19:57:00Z) Add `Kenshou.Suite.Keiro.bundle`, the scenario `keiro/command/correctness/fixture-roundtrip`, and the three-line registration in `kenshou-cli`. The scenario passed with both 20 and 500 generated operations.
- [x] (2026-09-23T19:57:00Z) Start `docs/layers/keiro.md`; create the two ADRs named in Context and Orientation. ADR-15 and ADR-16 passed strict OKF validation.

Milestone 2 — Command processor scenarios with snapshots and projections

- [x] (2026-09-23T20:14:00Z) Command correctness: `occ-retry-and-exhaustion`, `idempotent-event-ids`, `hydration-paging`, and `controlled-rollback` pass, including retry exhaustion and the idempotency sabotage arm. The full paging matrix passed over 30 combinations and checked the independent durable log.
- [ ] Command concurrency: `identical-commands-one-batch` passes with 16 simultaneous clients; `hot-stream-contention` passes with eight writers for 30 seconds. Multi-process support for the first, `model-based-parallel-commands`, and `sigkill-idempotent-resubmission` remain.
- [ ] Snapshot correctness: `policy-matrix` passes for all five policies with durable snapshot row checks; `truncation-covering-snapshot` passes with covered, gapped, cleared, and uncovered streams. `seed-divergence-detection` remains.
- [ ] Projection scenarios: `async-dedup-and-fence`, `inline-atomicity-under-kill`, `async-at-least-once-under-kill`, and the known-defect scenario `async-apply-checkpoint-atomic`.
- [ ] Non-vacuity check with `command.sabotage=omit-event-ids` and `projection.sabotage=skip-dedup`.

Milestone 3 — Process manager scenarios

- [ ] Correctness with the list adapter: `deterministic-ids-redelivery` passes for 50 transfers and three deliveries each; its unstable-name sabotage arm fails its verdict as intended. `timers-commit-with-manager-append` passes with an unchanged deadline after redelivery and a rejected second debit. `policy-matrix`, `transient-classification`, and `order-insensitive-join` remain.
- [ ] Reactions: `reaction-schedule-modes` and the known-defect scenario `reaction-no-advance-receipt`.
- [ ] Real bridge: `retry-budget-dead-letter` including dead-letter replay.
- [ ] Multi-process: `sigkill-crash-windows`, `random-kill-exactly-once`, `topologies`.
- [x] (2026-09-23T20:34:00Z) Non-vacuity check with `pm.sabotage=unstable-manager-name` fails the durable-effect verdict as intended.

Milestone 4 — Router scenarios

- [ ] `fanout-exactly-once` passes at fanout 16 with reordered recipients, repeated recipients, and three deliveries; its unstable-name sabotage arm fails as intended. `stable-union-under-drift` and `per-target-independent-commits` remain.
- [ ] `declarative-selection-policies` (the full empty-policy by failure-policy matrix, limit, overflow, conflict).
- [ ] `dead-letter-identity-under-reordered-redelivery` (probe; file upstream if it fails).
- [ ] `sigkill-mid-fanout` with worker processes.

Milestone 5 — Write-side benchmarks, soak and telemetry arms

- [ ] Benchmarks: `throughput-latency`, `hydration-cost`, `all-stream-append-ceiling`, process-manager `dispatch-latency`, router `fanout-dispatch`.
- [ ] Soaks: `write-side-steady-state` and `seed-verification-backlog`, each registered at full and reduced duration.
- [ ] Telemetry: `keiro/telemetry/correctness/write-side-signals`; all four values of both telemetry dimensions honoured by benchmark and soak scenarios; one recorded overhead report.
- [ ] Finish `docs/layers/keiro.md`; ADR distillation pass; Outcomes & Retrospective.


## Surprises & Discoveries

- The released `Keiro.Snapshot` module does not export `StateCodec`; `Keiro.EventStream` does. The first fixture compile failed on that import, and the corrected import built under the pinned released cohort.
- The strict transfer saga initially declared a `SagaAnnounceSeen` source state despite intentionally rejecting an announcement as its first input. `mkEventStreamOrThrow` reported `possibly-dead @SagaAnnounceSeen`; building that edge only for the order-tolerant variant made both streams replay-safe.
- A process manager name also becomes part of the saga stream category. The sabotage arm initially appended a hyphen to the name, which keiro rejected as an invalid category before the oracle ran. An alphanumeric suffix keeps the manager name valid and now produces the intended failed verdict.


## Decision Log

- Decision: The shared fixture domain is a bank ledger: an `account` aggregate with a balance register, a transfer saga (process manager) whose inputs come from two different account streams, a `bonus` aggregate whose single event is fanned out by a router to N accounts, one inline and one asynchronous projection.
  Rationale: Money gives every dependent plan a conservation law to check (the sum of balances changes only by known amounts), a register-carrying keiki transducer exercises snapshots honestly (the jitsurei examples almost all use an empty register file), and the saga and the router both target the same aggregate type, which is what keiro's `ProcessManager` and `Router` records require.
  Date: 2026-09-20

- Decision: Setup operations use worker index `-1` in workload event identity seeds, while generated worker operations use nonnegative indices.
  Rationale: Setup and worker operations both start their sequence at zero; separating the worker namespace prevents fixed event identifier collisions when the first generated operation is submitted.
  Date: 2026-09-23

- Decision: An overdraft, a non-positive amount, and any command to a closed or unopened account have no matching transducer edge and therefore surface as `CommandRejected`; the only silent (no-event) edge is `CloseAccount` on an already closed account.
  Rationale: `RejectedCommandPolicy` in the process-manager and router workers is triggered by `CommandRejected`, so the fixture needs a cheap, deterministic way to produce it (credit a closed account). One silent edge is enough to exercise the `SqlCommandNoOp` path.
  Date: 2026-09-20

- Decision: keiro's `ProcessManager.handle` is a pure function of the input event and cannot read manager state, so the "order-insensitive join" is modelled observationally: the saga's own state machine accepts `ObserveDebit` and `ObserveAnnounce` in either order, and a deliberately order-sensitive variant (`strictTransferManager`) exists only to show the worker halting when that rule is broken.
  Rationale: Verified in `keiro/src/Keiro/ProcessManager.hs`: `handle :: input -> ProcessManagerAction ci targetCi`. Gating a dispatch on manager state is not expressible, so the expectation worth encoding is the one the module documentation states: every cross-stream join must be order-insensitive.
  Date: 2026-09-20

- Decision: Workers are driven three ways: a hand-built `Adapter` over a list (deterministic redelivery and ordering), the production bridge `Shibuya.Adapter.Kiroku.kirokuAdapter` (fixed retry budget of five), and a hand-built adapter over `Kiroku.Store.Subscription.Stream.subscriptionAckStream` (configurable `retryPolicy`). `kenshou-keiro` therefore depends on `shibuya-kiroku-adapter`.
  Rationale: keiro's workers drain an `Adapter` serially and finalize acknowledgements themselves; keiro has no dependency on the adapter package, but its documentation describes retry and dead-letter behaviour in terms of it. Depending on a runtime package does not break the layer rule, which forbids only imports between `kenshou-*` layer packages.
  Date: 2026-09-20

- Decision: Deterministic crash windows are reached by parking, not by throwing: the worker role blocks inside `RunCommandOptions.beforeAppend`, inside an interposed acknowledgement handle, or inside a projection that runs `pg_sleep`, tells the harness over the control channel, and the harness delivers `SIGKILL` or terminates the backend.
  Rationale: The MasterPlan requires that crash means `SIGKILL` of a process or termination of a backend. keiro's `beforeAppend` hook runs before the manager append and before every target append, which makes every interesting window addressable without modifying keiro.
  Date: 2026-09-20

- Decision: Projections use keiro's uncatalogued compatibility path (`runCommandWithProjections`, `applyAsyncProjection` with `Keiro.ReadModel.Schema.registerReadModel`), not projection catalogs or rebuild groups.
  Rationale: The MasterPlan excludes keiro's online versioned read-model rebuild machinery; the compatibility path is public, documented and sufficient to test atomicity and deduplication.
  Date: 2026-09-20

- Decision: Modules are nested component first, then evidence kind (`Kenshou.Suite.Keiro.Command.Correctness`, `.Command.Concurrency`, `.ProcessManager.Correctness`, …). Snapshot and projection scenarios live under `.Command.*` modules but use the component segments `snapshot` and `projection` in their identifiers.
  Rationale: Integration Point 1 fixes the namespaces `.Fixture.*`, `.Command.*`, `.ProcessManager.*`, `.Router.*` for this package and also says evidence kinds are module subtrees; nesting satisfies both. Separate component segments let the planner of `docs/plans/3-plan-and-select-runs-from-what-changed.md` select snapshot or projection scenarios when only those keiro modules change.
  Date: 2026-09-20

- Decision: Each soak is registered twice from one implementation: `<name>` with tier `soak`, placement `cell`, and `<name>-reduced` with tier `extended`, placement `either`.
  Rationale: A scenario declares exactly one cost tier (Integration Point 3), while every soak must run locally at a reduced duration and on a cell at full duration.
  Date: 2026-09-20

- Decision: For this layer `telemetry.metrics=serve` means the kiroku-metrics HTTP server is started on a free port against the store the keiro workers use, in addition to keiro's OpenTelemetry instruments being live; shibuya-metrics is not started.
  Rationale: keiro exposes no HTTP endpoint, and the process-manager and router workers do not run under shibuya's runner, so the only endpoint a keiro write-side service really serves is kiroku-metrics.
  Date: 2026-09-20

- Decision: Two documented limitations are encoded as known-defect scenarios: non-atomic asynchronous projection apply and checkpoint (`mori://shinzui/keiro/okf/improvement-requests/concepts/IR-10`) and the missing durable receipt for `NoAdvance` reactions (`mori://shinzui/keiro/okf/adrs/concepts/ADR-41`).
  Rationale: Both are stated in keiro's own documents; asserting the stronger property and attaching the reference keeps them visible on every run without blocking.
  Date: 2026-09-20


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This section assumes the reader knows nothing about the runtime or this repository.

The runtime pieces. An event store keeps immutable facts ("events") in named, ordered streams; `kiroku` is the house event store on PostgreSQL (`mori://shinzui/kiroku`, on disk at `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`). A stream name such as `account-42` has a category, the text before the first `-` (`account`). Each stream has a version that grows by one per event, and every event also gets a position in a store-wide ordering called `$all`; every append takes a single-row lock on `$all`, which is a documented throughput ceiling. Optimistic concurrency means a writer states the version it expects and the append fails (`WrongExpectedVersion`, or `StreamAlreadyExists` for a new stream) if another writer got there first; nobody holds a lock while deciding. `keiki` (`mori://shinzui/keiki`, `/Users/shinzui/Keikaku/bokuno/keiki`) is a pure state-machine library: a transducer has control states, typed registers (named mutable values such as a balance), and edges that consume a command, check a guard, update registers and emit events. `keiro` (`mori://shinzui/keiro`, `/Users/shinzui/Keikaku/bokuno/keiro`) joins the two.

The command processor is `keiro/src/Keiro/Command.hs`. `runCommand` hydrates (replays the stream's events through the transducer, optionally starting from a snapshot, which is a saved copy of state and registers in `keiro.keiro_snapshots`), steps the transducer with the command, encodes the emitted events with the stream's codec (the JSON encoder, decoder and upcasters for one event type) and appends at the expected version. The following facts were verified in the source and the scenarios depend on them. Runners take a `ValidatedEventStream`, obtained only from `Keiro.EventStream.Validate.mkEventStream` or `mkEventStreamOrThrow`, which run keiki's replay-safety checks; every command field that a register update reads must also appear in the emitted event or validation fails. A conflict is retried while `attemptNo <= retryLimit`, so the total number of attempts is `retryLimit + 1` and exhaustion is `RetryExhausted (retryLimit + 1) lastError`. The delay before retry k is `min 100000 (retryBackoffMicros * 2^(k-1))` microseconds plus or minus half of itself, and `0` disables it. `RunCommandOptions` has the fields `retryLimit` (default 3), `pageSize` (256, clamped to at least 1), `eventIds` (`[]`), `beforeAppend` (`pure ()`, run before every append attempt), `retryBackoffMicros` (5000), `metrics` (`Nothing`), `verifyReplayOnAppend` (`True`), `seedVerifySampleRate` (1000), `tracer` (`Nothing`) and `metadata` (`Nothing`). Caller-supplied `eventIds` are assigned to the emitted events in order; a second append of the same identifier fails with `StoreFailed (DuplicateEvent _)`, which a caller must treat as completion. `runCommandWithSqlEventsControlled` lets a callback inside the append transaction return `RollbackSqlTransaction`, giving `SqlCommandRolledBack` with nothing persisted. Snapshot seed verification runs on a fire-and-forget `async` thread and reports divergence by incrementing `keiro.snapshot.seed.divergence` and printing a JSON line with `"event":"keiro.snapshot.seed.divergence"` on standard error; it never fails the command. Snapshot rows are upserted only when the new `stream_version` is not lower than the stored one. A truncation marker (`Kiroku.Store.Lifecycle.setStreamTruncateBefore`) hides events from stream reads; hydration then needs a snapshot at version at least marker minus one, otherwise it returns `HydrationGapDetected`, and a marker above the stream head ends in `ConflictFixpoint`.

Projections are in `keiro/src/Keiro/Projection.hs`. An `InlineProjection {name, apply :: event -> RecordedEvent -> Tx.Transaction ()}` runs inside the append transaction (`runCommandWithProjections`), so events and read model commit together or not at all. An `AsyncProjection {name, readModelName, subscriptionName, applyRecorded, idempotencyKey}` is applied later by a subscription; `applyAsyncProjection` inserts a row into `keiro.keiro_projection_dedup` in the same transaction as the application and returns `AsyncApplied`, `AsyncDuplicate`, or `AsyncFenced` when the registry row in `keiro.keiro_read_models` is not `live`. The application and the subscription checkpoint are not one transaction, so a crash redelivers already applied events; deduplication absorbs them. This is the limitation tracked upstream as `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-10`.

A process manager (also called a saga) is `keiro/src/Keiro/ProcessManager.hs`: `ProcessManager {name, correlate, eventStream, streamFor, targetEventStream, targetProjections, handle}`. For one input event it appends one event to its own stream (chosen by the correlation key), schedules timers in that same transaction, and then sends each target command in its own transaction. At-least-once delivery means an event may be handed to the worker more than once, for example after a crash; the worker is made safe by deterministic identifiers: every write uses the UUID version 5 of the text `keiro:process-manager:<name>:<correlation>:<sourceEventId>:<emitIndex>` (`deterministicCommandId`; the manager's own append uses emit index `-1`, targets count from `0`), checked first with `eventAlreadyIn` and folded to `PMStateDuplicate` or `PMCommandDuplicate`. Only the first event of a target command receives the identifier, so fixture target commands emit exactly one event. `runProcessManagerWorkerWith :: WorkerOptions es msg -> RunCommandOptions -> ProcessManager … -> Adapter es msg -> (msg -> Maybe (RecordedEvent, input)) -> Eff es ()` drains a shibuya `Adapter` serially and finalizes each message's acknowledgement exactly once: success and duplicates give `AckOk`; any transient error (`isTransientStoreError`: connection loss, pool timeout, version conflict, `TransientTransactionFailure`, …) gives `AckRetry transientRetryDelay`; a group of failures that are all `CommandRejected` or `CommandAmbiguous` follows `rejectedCommandPolicy` (`RejectedHalt` by default, or `RejectedDeadLetter`, which writes `keiro.keiro_dead_letters`, or `RejectedSkip`); any other deterministic error gives `AckHalt`; an undecodable message follows `poisonPolicy` (`PoisonHalt`, `PoisonSkip`, `PoisonDeadLetter`). `WorkerOptions` defaults are `PoisonHalt`, `RejectedHalt`, `RetryDelay 5`, no metrics. Reactions (`keiro/src/Keiro/ProcessManager/Reaction.hs`) add `ReactionPlan = NoAdvance [FollowUp] | AdvanceReaction {command, followUps, onAccepted}` with timer follow-ups in mode `Rearm` (move a still scheduled timer) or `Once` (insert only if absent); a `NoAdvance` plan leaves no durable receipt, so its effects may run again.

A router (`keiro/src/Keiro/Router.hs`) has no state: `Router {name, key, resolve :: input -> Eff es [PMCommand targetCi], targetEventStream, targetProjections}`. Because `resolve` may return a different list on a later attempt, identifiers are keyed by the target stream name and the occurrence among commands to that target (`deterministicRouterCommandId`), and the durable recipient set is the union over attempts. `DeclarativeRouter` adds a `RouterSelectionContract` (`keiro/src/Keiro/Router/Selection.hs`) with `limit`, `emptyPolicy` (`EmptyAck`, `EmptyRetry`, `EmptyDeadLetter`, `EmptyHalt`) and `failurePolicy` (`FailureRetry`, `FailureDeadLetter`, `FailureHalt`); `normalizeRecipients` sorts by target, collapses exact duplicates, rejects unequal commands for one target and applies the limit after deduplication, all before any write.

The adapter seam is from `shibuya-core` 0.9.0.3 (`mori://shinzui/shibuya`, `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`): `Adapter {adapterName, source :: Stream (Eff es) (Ingested es msg), shutdown}`, `Ingested {envelope, ack :: AckHandle es, lease}`, `Envelope {messageId, cursor, partition, enqueuedAt, traceContext, headers, attempt, attributes, payload}`, `AckHandle {finalize :: AckDecision -> Eff es ()}`, `AckDecision = AckOk | AckRetry RetryDelay | AckDeadLetter DeadLetterReason | AckHalt HaltReason`. keiro's own tests and `keiro/bench/Main.hs` (function `fanoutAdapter`) build adapters by hand from a list. The production bridge is `Shibuya.Adapter.Kiroku.kirokuAdapter :: KirokuStore -> KirokuAdapterConfig -> Eff es (Adapter es RecordedEvent)` in `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/shibuya-kiroku-adapter`; it maps `AckRetry` to a kiroku `Retry`, `AckDeadLetter` to a row in `kiroku.dead_letters`, and `AckHalt` to cancelling the subscription without advancing the checkpoint (the durable position of a subscription in `kiroku.subscriptions.last_seen`). Its configuration exposes `eventTypeFilter` but not the retry budget, which stays at kiroku's default of five total deliveries; after the fifth `Retry` kiroku records the source event in `kiroku.dead_letters` with reason kind `max_attempts_exceeded` and advances. A consumer group is a static split of one subscription into N members by a hash of the originating stream; sharded subscriptions (`Keiro.Subscription.Shard.Worker.runShardedSubscriptionGroupAck`) lease those members dynamically and are covered in depth by `docs/plans/14-cover-keiro-durable-execution-timers-and-sharded-subscriptions.md`.

The model to imitate for a fixture is keiro's `jitsurei` package (`/Users/shinzui/Keikaku/bokuno/keiro/jitsurei/src/Jitsurei`): `Domain.hs` and `OrderStream.hs` show commands, events, `deriveAggregate`, the builder DSL, a hand-written `Codec`, `mkEventStreamOrThrow` and a snapshotting variant; `FulfillmentProcess.hs` shows a `ProcessManager`; `Paging.hs` and `AgentQualRouter.hs` show routers; `CreditLimit.hs` shows registers, guards and register updates. Its cabal file lists the language extensions the DSL needs. keiro's test suite (`/Users/shinzui/Keikaku/bokuno/keiro/keiro/test/Main.hs`, around `snapshotCounterEventStreamDef`) shows `defaultStateCodec` with an `Int` register.

Other terms used below. `SIGKILL` is the signal that ends a process with no chance to clean up. Terminating a backend means `pg_terminate_backend` on the PostgreSQL server process serving one connection. A closed-loop load generator sends the next request when the previous one returns; an open-loop generator sends at a fixed rate regardless, and must measure latency from the intended send time or it hides queueing (coordinated omission). A leak verdict is the diagnostics toolkit's judgement on whether live heap bytes after major garbage collections, thread counts, file descriptors or connections grow over a soak. A contract invariant is a promise the runtime documents; an implementation invariant describes how it happens to work today; only the former blocks a release. OKF is the house format for documentation bundles, and an ADR (Architecture Decision Record) is one decision in the `docs/adr/` bundle.

What this plan expects to exist. The repository contains no Haskell code today; it is created by earlier plans. Before starting, confirm that these plans are complete and read them for exact names, because they were drafted concurrently with this one: `docs/plans/1-bootstrap-the-kenshou-repository-and-pin-the-runtime-cohort.md` (cabal project with `packages: kenshou-*/*.cabal`, dev shell with PostgreSQL 18, the pinned cohort); `docs/plans/2-build-the-harness-kernel-for-scenarios-dimensions-run-specs-and-results.md` (`kenshou-core`: `Kenshou.Core.Scenario`, `.Knob`, `.Dimension`, `.Bundle` with `LayerBundle {layer, scenarios, roles}`, `.Env.Postgres` giving a migrated `PostgresEnv` for the components kiroku and keiro, `.Role` with `WorkerRole` and `RoleContext`, the `RunContext` with knobs, dimensions, seed, output directory, logger, phase markers and summary sections, and `kenshou-cli` with `Kenshou.Cli.Registry`); `docs/plans/4-build-the-measurement-toolkit-for-load-latency-sampling-and-comparison.md` (`Kenshou.Measure.*`: latency recorder, closed-loop and open-loop generators, RTS, process and PostgreSQL samplers, summaries, paired comparison); `docs/plans/5-build-the-correctness-toolkit-for-ledgers-invariants-faults-and-process-control.md` (`Kenshou.Check.*`: the bounded ledger, invariant checkers that emit `kenshou.verdict/v1` with a class of `contract` or `implementation`, `Kenshou.Check.Process` for spawning and signalling worker roles, PostgreSQL and network fault injectors, hedgehog state-machine and linearizability helpers); `docs/plans/6-build-the-diagnostics-toolkit-for-memory-leaks-and-concurrency-stalls.md` (`Kenshou.Diagnose.*`: leak verdict, stall watchdog); `docs/plans/7-add-telemetry-arms-and-measure-observability-overhead.md` (`Kenshou.Telemetry.withTelemetry` giving `Maybe Tracer`, `Maybe Meter` and an endpoint registrar, `Kenshou.Telemetry.Compose` for composing kiroku event handlers, `kenshou overhead`). Soft dependencies: `docs/plans/3-plan-and-select-runs-from-what-changed.md` maps keiro sub-components to scenario selectors, and `docs/plans/9-cover-kiroku-in-isolation.md` establishes what the store does by itself.

Contracts from the MasterPlan that this plan relies on. A scenario identifier is `<layer>/<component>/<kind>/<name>`; the layer here is `keiro`, the kinds are `correctness`, `concurrency`, `soak`, `benchmark`, and the components used are `command`, `snapshot`, `projection`, `process-manager`, `router` and `telemetry`. Tiers are `smoke` (under one minute), `standard` (under ten), `extended` (under an hour) and `soak`; placement is `local`, `cell` or `either`. A scenario may carry a known-defect reference that turns an expected failure into a reported, non-blocking outcome. The package exports exactly one `bundle :: LayerBundle`, registered by one import, one list element and one `build-depends` entry in `kenshou-cli`; that is the only edit outside `kenshou-keiro/` and `docs/`. Layer packages never import one another. Dimensions: `telemetry.tracing` takes `off`, `noop`, `sdk-inmemory`, `sdk-otlp`; `telemetry.metrics` takes `off`, `collect`, `serve`, `serve-scraped`; `pg.durability` takes `fsync-off` and `durable` (mandatory for benchmarks and crash scenarios); `pg.version` takes `17` and `18`, and keiro requires 18, so every scenario here supports only `18`. A scenario never opens a database itself; it receives a `PostgresEnv` migrated with one `pg-migrate` plan. Measurement never flows through the feature being toggled. Multi-process scenarios run worker roles as children of the same `kenshou` binary (`kenshou worker`), supervised by `Kenshou.Check.Process`. Outcomes are `passed`, `failed`, `errored`, `inconclusive`, `infrastructure-failure`, with exit codes 0, 1, 4, 3, 4.

ADR context. There is no local ADR corpus until `docs/plans/1-…` creates `docs/adr/` as a profile-governed OKF bundle; check with `ls docs/adr`. Cross-repository decisions that shape this plan: `mori://shinzui/keiro/okf/adrs/concepts/ADR-24` freezes deterministic identifiers as UUID version 5 over UTF-8 seed bytes, which is what lets the oracles compute expected identifiers; `mori://shinzui/keiro/okf/adrs/concepts/ADR-25` requires worker loops to survive per-item failures; `mori://shinzui/keiro/okf/adrs/concepts/ADR-29` defines typed domain decisions as successful outcomes; `mori://shinzui/keiro/okf/adrs/concepts/ADR-30` defines declarative router selection as bounded and target-normalized; `mori://shinzui/keiro/okf/adrs/concepts/ADR-41` defines reactions and states the `NoAdvance` limitation; `mori://shinzui/keiro/okf/adrs/concepts/ADR-3` makes snapshot compatibility a three-part discriminator; `mori://shinzui/kiroku/okf/adrs/concepts/ADR-2` and `mori://shinzui/kiroku/okf/adrs/concepts/ADR-4` define static consumer groups and monotonic checkpoints; `mori://shinzui/kiroku/okf/adrs/concepts/ADR-5` makes only structural checks and controlled paired workloads authoritative performance evidence. keiro's unstarted plan for real crash tests is `mori://shinzui/keiro/masterplans/22-make-the-test-infrastructure-exercise-real-crash-and-production-semantics` (not yet resolvable through Mori). `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-8` (atomic multi-stream commands) explains why a transfer needs a saga at all, and `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-7` explains why concurrent creation of new streams can fail with `TransientTransactionFailure`. Two decisions of this plan deserve new ADRs, created in Milestone 1 with `okf id next docs/adr --profile docs/adr/profile.dhall ADR` and validated with `okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce`: "The keiro fixture domain is a shared interface owned by `kenshou-keiro`" and "Deterministic crash windows park in library hooks and are then killed".


## Plan of Work

Every scenario below states its tier and placement in parentheses, then (where the name does not already say it) its purpose, its knobs (name, type, default, allowed values), its procedure, and its oracle with the invariant class. A knob described as a list accepts several values and the scenario evaluates each in turn inside one run. Unless stated otherwise a scenario supports `pg.version=18`, both `pg.durability` values, `telemetry.tracing` in `off` and `sdk-inmemory`, and `telemetry.metrics` in `off` and `collect`. Crash, benchmark and soak scenarios support only `pg.durability=durable`. Every scenario that opens a store accepts `kiroku.pool-size` (int, default 10, 2 to 64), which sets `ConnectionSettings.poolSize`.

### Milestone 1 — The keiro fixture domain

Scope: create the package and the fixture, prove the transducers are accepted by keiro's validation, and register one smoke scenario so the layer is visible. At the end `cabal test kenshou-keiro-test` passes, `kenshou list` shows `keiro/command/correctness/fixture-roundtrip`, and running it passes.

Create `kenshou-keiro/kenshou-keiro.cabal`: `cabal-version: 3.4`, library `kenshou-keiro`, `default-language: GHC2024`, `default-extensions: BlockArguments DeriveAnyClass DuplicateRecordFields ImportQualifiedPost MultilineStrings OverloadedLabels OverloadedRecordDot OverloadedStrings PackageImports QualifiedDo TemplateHaskell` (the set `jitsurei.cabal` uses; the keiki builder needs `QualifiedDo` and `BlockArguments`, and `deriveAggregate` needs `TemplateHaskell`). Dependencies: `base`, `aeson`, `async`, `bytestring`, `containers`, `effectful`, `effectful-core`, `generic-lens`, `lens`, `hasql`, `hasql-transaction`, `hs-opentelemetry-api`, `keiki`, `keiki-codec-json`, `keiro`, `keiro-core`, `kiroku-store`, `kiroku-metrics`, `random`, `shibuya-core`, `shibuya-kiroku-adapter`, `stm`, `streamly`, `streamly-core`, `text`, `time`, `uuid`, `vector`, and `kenshou-core`, `kenshou-measure`, `kenshou-check`, `kenshou-diagnose`, `kenshou-telemetry`; no version bounds on cohort packages, because `cohort/active.project` pins them. The test suite `kenshou-keiro-test` (`hspec`, `hspec-hedgehog`, `hedgehog`, `-threaded -rtsopts -with-rtsopts=-N`) lives in `kenshou-keiro/test/Main.hs`. The plans `docs/plans/13-…` and `docs/plans/14-…` later add modules and dependencies to this same cabal file.

`kenshou-keiro/src/Kenshou/Suite/Keiro/Fixture/Domain.hs` holds the plain types. Identifiers are `newtype AccountId = AccountId Text`, `TransferId`, `BonusId` (deriving `Generic, Eq, Ord, Show` and newtype `FromJSON, ToJSON`). Commands and events follow the jitsurei shape: one constructor per command or event, each carrying one strict record named `<Constructor>Data`, because `Keiki.Generics.TH.deriveAggregate` generates `inCtor<Constructor>`, `wire<Constructor>` and `<Constructor>TermFields` from that shape.

```haskell
data AccountState = AcctUnopened | AcctOpen | AcctClosed
  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)
  deriving anyclass (FromJSON, ToJSON)
instance CanonicalStateShape AccountState          -- from Keiki.Shape

type AccountRegs = '[ '("balance", Int), '("entries", Int)]

data AccountCommand
  = OpenAccount !OpenAccountData            -- accountId, openingBalance :: Int
  | Deposit !DepositData                    -- accountId, amount :: Int, memo :: Text
  | Withdraw !WithdrawData                  -- accountId, amount :: Int
  | DebitTransfer !DebitTransferData        -- accountId, transferId, destination :: AccountId, amount :: Int, deadlineEpochSeconds :: Int
  | AnnounceTransfer !AnnounceTransferData  -- accountId, transferId
  | CreditTransfer !CreditTransferData      -- accountId, transferId, source :: AccountId, amount :: Int
  | ConfirmTransfer !ConfirmTransferData    -- accountId, transferId
  | CreditBonus !CreditBonusData            -- accountId, bonusId, amount :: Int
  | CloseAccount !CloseAccountData          -- accountId
  deriving stock (Generic, Eq, Show)

data AccountEvent
  = AccountOpened !AccountOpenedData | Deposited !DepositedData | Withdrawn !WithdrawnData
  | TransferDebited !TransferDebitedData | TransferAnnounced !TransferAnnouncedData
  | TransferCredited !TransferCreditedData | TransferConfirmed !TransferConfirmedData
  | BonusCredited !BonusCreditedData | AccountClosed !AccountClosedData
  deriving stock (Generic, Eq, Show)
```

Each event record has exactly the fields of the command that produces it (this is what keeps keiki's hidden-input check satisfied). The same module defines the bonus aggregate (`BonusState = BonusUndeclared | BonusDeclaredState`, `BonusCommand = DeclareBonus !DeclareBonusData` with `bonusId`, `segment :: Text`, `amount :: Int`, `BonusEvent = BonusDeclared !BonusDeclaredData`, `type BonusRegs = '[]`) and the saga aggregate (`TransferSagaState = SagaIdle | SagaDebitSeen | SagaAnnounceSeen | SagaJoined`, `TransferSagaCommand = ObserveDebit !ObserveDebitData | ObserveAnnounce !ObserveAnnounceData`, `TransferSagaEvent = DebitObserved !DebitObservedData | AnnounceObserved !AnnounceObservedData`, `type TransferSagaRegs = '[]`).

`…/Fixture/Account.hs` holds the splice `deriveAggregate ''AccountCommand ''AccountRegs ''AccountEvent`, the transducer, the codec and the event streams. The transducer is built with `Keiki.Builder` exactly as `Jitsurei.CreditLimit` does. From `AcctUnopened`: `OpenAccount` with guard `openingBalance >= 0` sets `balance` to the opening balance and `entries` to 1, emits `AccountOpened`, goes to `AcctOpen`. From `AcctOpen`, every edge adds 1 to `entries`, emits its event and stays in `AcctOpen`: `Deposit`, `CreditTransfer` and `CreditBonus` require `amount > 0` and add the amount; `Withdraw` and `DebitTransfer` require `amount > 0 .&& B.reg @"balance" .>= d.amount` and subtract it; `AnnounceTransfer` and `ConfirmTransfer` leave the balance alone; `CloseAccount` requires `balance == 0`, emits `AccountClosed` and goes to `AcctClosed`. From `AcctClosed` the only edge is `CloseAccount` with `B.noEmit` staying in `AcctClosed`. The finality predicate is `(== AcctClosed)`. The codec is hand-written like `orderCodec` (`schemaVersion = 1`, event type tags equal to constructor names, `upcasters = []`).

```haskell
type AccountPhi = HsPred AccountRegs AccountCommand
type AccountEventStream = EventStream AccountPhi AccountRegs AccountState AccountCommand AccountEvent
type ValidatedAccountEventStream = ValidatedEventStream AccountPhi AccountRegs AccountState AccountCommand AccountEvent

data AccountSnapshotPolicy = SnapNever | SnapEvery !Int | SnapOnTerminal deriving stock (Eq, Show)

accountTransducer   :: SymTransducer AccountPhi AccountRegs AccountState AccountCommand AccountEvent
accountCodec        :: Codec AccountEvent
accountStateCodec   :: StateCodec (AccountState, RegFile AccountRegs)   -- defaultStateCodecWithFold @AccountRegs @AccountState (FoldVersion "kenshou-account-fold-v1") 1
accountEventStream  :: AccountSnapshotPolicy -> ValidatedAccountEventStream
accountStream        :: AccountId -> Stream AccountEventStream          -- "account-<id>"
accountCommandStream :: AccountId -> Stream AccountCommand
accountStreamName    :: AccountId -> StreamName
commandAccountId     :: AccountCommand -> AccountId
eventAccountId       :: AccountEvent -> AccountId
```

`accountEventStream SnapNever` sets `snapshotPolicy = Never` and `stateCodec = Nothing` (with a codec present keiro looks up a snapshot on every command, which would distort the "never" arm); the other two set `Every n` or `OnTerminal` with `Just accountStateCodec`. All are built with `mkEventStreamOrThrow`. If keiki's validation rejects the transducer, read the warning text, fix the edge it names (usually a command field missing from the event, or two edges for one command whose guards are not provably disjoint; use `pnot` of the first guard for the second as keiki's own `jitsurei/src/Jitsurei/LoanApplication.hs` does) and record what happened in Surprises & Discoveries.

`…/Fixture/Transfer.hs` defines the saga. A transfer has two causally independent legs issued by the client: `DebitTransfer` on the source account and `AnnounceTransfer` on the destination account. The saga consumes `TransferDebited` and `TransferAnnounced`, correlates both by the transfer identifier, and records them in either order (`SagaIdle` to `SagaDebitSeen` or `SagaAnnounceSeen`, then to `SagaJoined`). On `TransferDebited` it dispatches two target commands, `CreditTransfer` to the destination (emit index 0) and `ConfirmTransfer` to the source (emit index 1), and schedules one timer whose identifier is the UUID version 5 of `kenshou:transfer-timeout:<transferId>` and whose `fireAt` is `deadlineEpochSeconds` converted to `UTCTime`. On `TransferAnnounced` it only advances its own state.

```haskell
data TransferSignal = SignalDebited !TransferDebitedData | SignalAnnounced !TransferAnnouncedData
  deriving stock (Generic, Eq, Show)

type SagaPhi = HsPred TransferSagaRegs TransferSagaCommand
type TransferSagaEventStream = EventStream SagaPhi TransferSagaRegs TransferSagaState TransferSagaCommand TransferSagaEvent
type TransferManager =
  ProcessManager TransferSignal SagaPhi TransferSagaRegs TransferSagaState TransferSagaCommand TransferSagaEvent
                 AccountPhi AccountRegs AccountState AccountCommand AccountEvent
data ReactionSignal = ReactDebited !TransferDebitedData | ReactAnnounced !TransferAnnouncedData | ReactCredited !TransferCreditedData
  deriving stock (Generic, Eq, Show)
type TransferReaction =
  ReactiveProcessManager ReactionSignal SagaPhi TransferSagaRegs TransferSagaState TransferSagaCommand TransferSagaEvent
                         AccountPhi AccountRegs AccountState AccountCommand AccountEvent Void ()

transferManagerName   :: Text                                   -- "transferSaga"; streams "pm:transferSaga-<transferId>"
transferManager       :: ValidatedAccountEventStream -> (Stream AccountCommand -> [InlineProjection AccountEvent]) -> TransferManager
strictTransferManager :: ValidatedAccountEventStream -> TransferManager   -- name "transferSagaStrict"; no SagaIdle -> ObserveAnnounce edge
renamedTransferManager :: Text -> ValidatedAccountEventStream -> TransferManager  -- sabotage only
transferReaction      :: ValidatedAccountEventStream -> TransferReaction  -- name "transferReaction", own category
transferSagaStream    :: TransferId -> Stream TransferSagaEventStream
transferSignalTypes   :: Set EventType                          -- {"TransferDebited","TransferAnnounced"}
decodeTransferSignal  :: RecordedEvent -> Maybe (RecordedEvent, TransferSignal)
decodeReactionSignal  :: RecordedEvent -> Maybe (RecordedEvent, ReactionSignal)
transferTimeoutTimerId, transferReminderTimerId :: TransferId -> TimerId
```

The reactive variant uses its own manager name and saga category (keiro requires a drain before an existing manager switches identity family, so the two never share streams) and a `sagaHandler` whose `classifySilent` is `const (SilentNoOp ())`, because the saga has no silent edges. Its `react` is: `ReactDebited` gives `AdvanceReaction` with command `ObserveDebit`, `followUps = [FollowSchedule Rearm reminder]` (reminder due sixty seconds before the deadline) and `onAccepted = [FollowDispatch credit, FollowDispatch confirm, FollowSchedule Once timeout]` (timeout due at the deadline); `ReactAnnounced` gives `AdvanceReaction` with command `ObserveAnnounce`, `followUps = [FollowSchedule Rearm reminder']` and `onAccepted = [FollowSchedule Once timeout']`, where the primed requests reuse the same timer identifiers with a fixed far-future time; `ReactCredited` gives `NoAdvance [FollowCancel (transferTimeoutTimerId t)]`.

`…/Fixture/Bonus.hs` defines the bonus event stream (`SnapOnTerminal` is not needed; use `Never`), and the routers. `resolve` is a parameter so that scenarios can script drift; the production-like resolver reads the table `kenshou_keiro.account_directory`.

```haskell
type BonusRouter es = Router BonusDeclaredData AccountPhi AccountRegs AccountState AccountCommand AccountEvent es
type DeclarativeBonusRouter es = DeclarativeRouter BonusDeclaredData AccountPhi AccountRegs AccountState AccountCommand AccountEvent es

bonusRouterName            :: Text                              -- "bonusRouter"
bonusCommands              :: BonusDeclaredData -> [AccountId] -> [PMCommand AccountCommand]
bonusRouterWith            :: Text -> ValidatedAccountEventStream -> (BonusDeclaredData -> Eff es [AccountId]) -> BonusRouter es
directoryRecipients        :: (Store :> es) => BonusDeclaredData -> Eff es [AccountId]
bonusSelectionContract     :: EmptySelectionPolicy -> SelectionFailurePolicy -> Natural -> Either RouterSelectionFailure RouterSelectionContract
declarativeBonusRouterWith :: ValidatedAccountEventStream -> RouterSelectionContract
                           -> (BonusDeclaredData -> Eff es (Either RouterSelectionFailure [PMCommand AccountCommand])) -> DeclarativeBonusRouter es
decodeBonusDeclared        :: RecordedEvent -> Maybe (RecordedEvent, BonusDeclaredData)
bonusStream                :: BonusId -> Stream BonusEventStream   -- "bonus-<id>"
```

`…/Fixture/Projection.hs` owns the application read models in schema `kenshou_keiro` (application tables are not part of the migration ledger; create them with `Keiro.Connection.ensureProjectionSchema` and `CREATE TABLE IF NOT EXISTS`, and name them with `Keiro.Connection.qualifyTable`). `account_balance (account_id text primary key, balance bigint, entries bigint, last_version bigint, last_global_position bigint, status text)` is maintained inline. `account_activity (account_id text primary key, events_applied bigint, net_amount bigint, last_global_position bigint)` is maintained asynchronously with deliberately additive SQL (`events_applied = events_applied + 1`), so a double application is visible. `account_directory (account_id text primary key, segment text)` is written only by the harness.

```haskell
fixtureSchema              :: Text                               -- "kenshou_keiro"
ensureFixtureReadModels    :: (Store :> es) => Eff es ()          -- schema, tables, registerReadModel accountActivityReadModelName 1 "v1"
accountBalanceProjection   :: InlineProjection AccountEvent
parkingProjection          :: (AccountEvent -> Bool) -> InlineProjection AccountEvent  -- runs SELECT pg_sleep(3600) for a matching event
failingProjection          :: (AccountEvent -> Bool) -> InlineProjection AccountEvent  -- runs SELECT 1/0 for a matching event
accountActivityProjection  :: AsyncProjection                     -- idempotencyKey = (^. #eventId)
accountActivityReadModelName :: Text
runAccountActivityWorker   :: KirokuStore -> Int32 -> ProjectionSabotage -> (RecordedEvent -> AsyncApplyOutcome -> IO ()) -> IO ()
setDirectory               :: [(AccountId, Text)] -> Tx.Transaction ()
data ProjectionSabotage = NoProjectionSabotage | SkipDedup
```

`runAccountActivityWorker` subscribes with `Kiroku.Store.Subscription.withSubscription` to `Category "account"` under the name `kenshou-account-activity` with the given `batchSize`; its handler runs `runTransaction (applyAsyncProjection accountActivityProjection recorded)`, reports the outcome to the callback, and returns `Continue` for `AsyncApplied` and `AsyncDuplicate` and `Retry (RetryDelay 1)` for `AsyncFenced`.

`…/Fixture/Runtime.hs` adapts the kernel and telemetry handles to keiro.

```haskell
type KeiroEff = Eff '[Store, Error StoreError, KirokuStoreResource, IOE]
newtype KeiroRunner = KeiroRunner { run :: forall a. KeiroEff a -> IO (Either StoreError a) }
data KeiroTelemetry = KeiroTelemetry { tracer :: !(Maybe Tracer), metrics :: !(Maybe KeiroMetrics) }
data FixtureEnv = FixtureEnv { store :: !KirokuStore, runner :: !KeiroRunner, telemetry :: !KeiroTelemetry }

keiroRunner     :: KirokuStore -> KeiroRunner   -- runEff . runKirokuStoreWith store . runErrorNoCallStack . runStoreResource
keiroTelemetry  :: TelemetryHandles -> IO KeiroTelemetry          -- newKeiroMetrics when a Meter is present
fixtureSettings :: Text -> Text -> Int -> ConnectionSettings      -- conn string, application_name, pool size; projection schema on the search path
withFixtureEnv  :: ConnectionSettings -> KeiroTelemetry -> (FixtureEnv -> IO a) -> IO a
commandOptions  :: KeiroTelemetry -> RunCommandOptions            -- defaultRunCommandOptions with tracer and metrics set
workerOptions   :: KeiroTelemetry -> WorkerOptions es msg
data CommandRunner = RunnerPlain | RunnerWithSql | RunnerWithProjections ![InlineProjection AccountEvent]
data SubmitOutcome = SubmitAppended !StreamVersion | SubmitDuplicate | SubmitNoOp | SubmitRejected | SubmitFailed !CommandError
submitAccountCommand :: FixtureEnv -> ValidatedAccountEventStream -> CommandRunner -> RunCommandOptions -> Int -> EventId -> AccountCommand -> IO SubmitOutcome
submitBonusCommand   :: FixtureEnv -> RunCommandOptions -> EventId -> BonusCommand -> IO SubmitOutcome
```

`CommandRunner` selects `runCommand`, `runCommandWithSql` (with a callback that only reads the append result) or `runCommandWithProjections`; these are different append paths inside keiro (`appendToStream` against `appendToStreamTx` inside `runTransaction`), so scenarios and benchmarks name the one they mean.

`fixtureSettings` appends `application_name=<name>` to the connection string so that fault injectors can find a worker's backends. Any kiroku `eventHandler` (keiro's `kirokuEventBridge`, kiroku-metrics' `metricsEventHandler`) must be composed before `withStore` runs, using `Kenshou.Telemetry.Compose`. `submitAccountCommand` is the at-least-once client every workload uses (the `Int` is the client retry budget): it sets `eventIds = [eventId]`, folds `StoreFailed (DuplicateEvent _)` into `SubmitDuplicate` after confirming with `Keiro.ProcessManager.confirmBenignDuplicate`, and retries `RetryExhausted` and `TransientTransactionFailure` up to that budget (knob `client.retry-budget`, int, default 5, 0 to 50), counting each cause for the measurement summary.

`…/Fixture/Bridge.hs` builds adapters whose message type is always `RecordedEvent`, so one decoder serves every bridge.

```haskell
data AckRecord = AckRecord { messageId :: !MessageId, attempt :: !(Maybe Attempt), decision :: !AckDecision }
listAdapter        :: (IOE :> es) => Text -> IORef [AckRecord] -> [(RecordedEvent, Maybe Word)] -> Adapter es RecordedEvent
kirokuBridge       :: (IOE :> es) => KirokuStore -> KirokuAdapterConfig -> Eff es (Adapter es RecordedEvent)   -- Shibuya.Adapter.Kiroku.kirokuAdapter
ackStreamAdapter   :: (IOE :> es) => KirokuStore -> SubscriptionConfig -> Natural -> Eff es (Adapter es RecordedEvent)
interposeAck       :: (Envelope msg -> AckDecision -> Eff es ()) -> Adapter es msg -> Adapter es msg
sagaAdapterConfig  :: SubscriptionName -> Maybe ConsumerGroup -> KirokuAdapterConfig   -- Category "account", OnlyEventTypes transferSignalTypes
bonusAdapterConfig :: SubscriptionName -> KirokuAdapterConfig                          -- Category "bonus"
shardAckFor        :: AckDecision -> ShardAck   -- AckOk -> ShardAckOk; AckRetry d -> ShardAckRetry d; AckDeadLetter r -> ShardAckDeadLetter r; AckHalt _ -> ShardAckRetry (RetryDelay 1)
```

`ackStreamAdapter` mirrors `Shibuya.Adapter.Kiroku.Convert.toIngestedAck`: it fills the `AckItem`'s reply with `Continue`, `Retry` or `DeadLetter`, and cancels the subscription on `AckHalt`; unlike the production adapter it honours the `retryPolicy` of the configuration it is given. `interposeAck` runs an action before the original `finalize`, which is how a worker parks after all writes and before its acknowledgement.

`…/Fixture/Workload.hs` generates operations from a seed with `System.Random`'s pure `StdGen` (`mkStdGen`, split per worker), never from global state. `opCommands` expands one operation into the commands to submit with their event identifiers; a transfer expands into its two legs (`DebitTransfer` on the source, `AnnounceTransfer` on the destination) in an order chosen by the seed, and a worker only transfers between accounts it owns unless the scenario asks for contention. `…/Fixture/Model.hs` is a hand-written pure model, independent of keiki. `…/Fixture/Oracle.hs` reads durable truth with its own `hasql` connection from the `PostgresEnv`, not through the store under test.

```haskell
data WorkloadSpec = WorkloadSpec { accounts :: !Int, openingBalance :: !Int, maxAmount :: !Int, hotAccountShare :: !Double
                                 , mix :: !OpMix, memoBytes :: !Int, transferDeadlineSeconds :: !Int }
data OpMix = OpMix { deposits, withdrawals, transfers, bonuses :: !Int }
data OpAction = ActOpen !AccountId !Int | ActDeposit !AccountId !Int | ActWithdraw !AccountId !Int
              | ActTransfer !TransferId !AccountId !AccountId !Int | ActBonus !BonusId !Text !Int | ActClose !AccountId
data Op = Op { worker :: !Int, index :: !Word64, action :: !OpAction }
defaultWorkloadSpec :: WorkloadSpec
setupOps   :: WorkloadSpec -> [Op]                                  -- opens every account
workerOps  :: Word64 -> WorkloadSpec -> Int -> Int -> [Op]            -- seed, spec, worker, workers; infinite and deterministic
opCommands :: Word64 -> Op -> [(Either (Stream BonusEventStream, BonusCommand) (Stream AccountEventStream, AccountCommand), EventId)]
opEventId  :: Word64 -> Op -> Int -> EventId                          -- UUID v5 of "kenshou:op:<seed>:<worker>:<index>:<leg>"

data ModelAccount = ModelAccount { state :: !AccountState, balance :: !Int, entries :: !Int }
newtype Model = Model (Map AccountId ModelAccount)
data ModelVerdict = ModelAccepts !AccountEvent | ModelNoOp | ModelRejects
decide :: Model -> AccountCommand -> ModelVerdict
apply  :: AccountEvent -> Model -> Model
totalMoney :: Model -> Int

data LoggedEvent = LoggedEvent { streamName :: !StreamName, streamVersion :: !Int64, globalPosition :: !Int64
                               , eventId :: !EventId, eventType :: !EventType, payload :: !Value }
readCategoryLog        :: Connection -> Text -> IO [LoggedEvent]
modelFromLog           :: [LoggedEvent] -> Either Text Model
readBalanceTable       :: Connection -> IO (Map AccountId (Int64, Int64, Int64))   -- balance, entries, last_version
readActivityTable      :: Connection -> IO (Map AccountId (Int64, Int64))
readSnapshots          :: Connection -> IO (Map StreamName (Int64, Value))         -- stream_version, state JSON
readDispatchDeadLetters, readSubscriptionDeadLetters, readTimers, readCheckpoints  -- typed row readers
expectedSagaStateId    :: Text -> TransferId -> EventId -> EventId                  -- deterministicCommandId name correlation source (-1)
expectedSagaCommandId  :: Text -> TransferId -> EventId -> Int -> EventId
expectedRouterCommandId :: Text -> BonusId -> EventId -> AccountId -> Int -> EventId
```

`readCategoryLog` is one SQL statement over kiroku's own tables, which makes it independent of the read API under test:

```sql
SELECT s.stream_name, se.stream_version, g.stream_version AS global_position, e.event_id, e.event_type, e.data
FROM kiroku.streams s
JOIN kiroku.stream_events se ON se.stream_id = s.stream_id AND se.original_stream_id = s.stream_id
JOIN kiroku.events e ON e.event_id = se.event_id
JOIN kiroku.stream_events g ON g.event_id = e.event_id AND g.stream_id = 0
WHERE s.category = $1
ORDER BY s.stream_name, se.stream_version
```

Four checks built on these are reused everywhere and are named here so that verdict files are comparable across scenarios: `log-is-well-formed` (per stream, versions are 1 to n without gaps and event identifiers are unique; contract), `model-equals-log` (folding the log through `Model` never hits a rejected transition and every balance is non-negative; contract), `inline-read-model-equals-log` (`account_balance` equals the model and `last_version` equals the stream version; contract), and `money-is-conserved` (the sum of balances equals openings plus deposits plus bonuses minus withdrawals minus the amounts of transfers debited but not yet credited; contract).

`…/Fixture/Roles.hs` exports `roles :: [WorkerRole]` with four entry points: `keiro.command-writer` (runs `workerOps` through `submitAccountCommand`, closed or open loop, writes one produced fact per operation and reports acknowledged indices on the control channel), `keiro.pm-worker`, `keiro.router-worker` (each runs the corresponding keiro worker over the bridge named by its arguments, records one observed fact per acknowledgement, and can arm one parking window), and `keiro.projection-worker` (runs `runAccountActivityWorker`). `kenshou-keiro/src/Kenshou/Suite/Keiro.hs` exports `bundle :: LayerBundle` whose scenario list is the concatenation of `Command.scenarios`, `ProcessManager.scenarios` and `Router.scenarios`; the later keiro plans append their own lists and roles there. Register it in `kenshou-cli/src/Kenshou/Cli/Registry.hs` and `kenshou-cli/kenshou-cli.cabal`.

`keiro/command/correctness/fixture-roundtrip` (smoke, either). Purpose: prove the fixture end to end. Knobs: `workload.operations` (int, 500, 1 to 100000), `snapshot.policy` (enum, `every-10`; `never`, `every-1`, `every-10`, `every-100`, `on-terminal`). Procedure: create the read models, run `setupOps` and then the first N operations of `workerOps seed spec 0 1` on one thread through `runCommandWithProjections` with `accountBalanceProjection`. Oracle: the four shared checks pass, and each submit outcome equals `Model.decide` for that command (`ModelRejects` with `SubmitRejected`, and so on); contract.

### Milestone 2 — Command processor scenarios with snapshots and projections

Scope: the command runner, snapshots and both projection kinds. At the end fifteen more scenarios exist under `keiro/command`, `keiro/snapshot` and `keiro/projection` in the modules `Kenshou.Suite.Keiro.Command.Correctness`, `.Command.Concurrency`, `.Command.Snapshot`, `.Command.Projection`, with `.Command` exporting `scenarios`. Run each with `cabal run kenshou -- run <id> --out runs`, adding `--dim pg.durability=durable` for the crash scenarios. Acceptance: fourteen pass, `async-apply-checkpoint-atomic` is reported as a known defect, and the two sabotage runs fail as they should.

`keiro/command/correctness/occ-retry-and-exhaustion` (smoke, either). Knobs: `command.retry-limit` (int, 3, 0 to 16), `command.retry-backoff-micros` (int, 5000, 0 to 100000), `command.injected-conflicts` (int, 2, 0 to 32). Procedure: the `beforeAppend` hook appends one foreign `Deposit` to the same account through a second store for the first K invocations. Oracle: if K is at most the retry limit the command returns `Right`, the hook ran K + 1 times, and with metrics on `keiro.command.retries` equals K; otherwise the result is `Left (RetryExhausted (retryLimit + 1) (WrongExpectedVersion …))`, the hook ran `retryLimit + 1` times and the command's event is absent (contract). The gap before retry k is at least half of `min 100000 (base * 2^(k-1))` microseconds (implementation).

`keiro/command/correctness/idempotent-event-ids` (smoke, either). Procedure: submit the same `Deposit` twice with the same identifier, and the same `OpenAccount` twice. Oracle: the second `Deposit` is `Left (StoreFailed (DuplicateEvent _))` and the second `OpenAccount` is `Left CommandRejected`; in both cases the event exists exactly once and the stream version moved once; `keiro.command.duplicates` is 1 when metrics are on (contract). With `command.sabotage=omit-event-ids` (enum, default `none`) the scenario must fail, which proves the oracle is not vacuous.

`keiro/command/correctness/hydration-paging` (standard, either). Knobs: `command.stream-length` (int list, `0,1,255,256,257,1000`), `command.page-size` (int list, `0,1,7,256,1024`). Oracle: for every combination the command after L seeded events reports stream version L + 1 and the model's balance (contract); page size 0 behaves as 1 (implementation).

`keiro/command/correctness/controlled-rollback` (smoke, either). Procedure: `runCommandWithSqlEventsControlled` with a callback that inserts into `account_balance` and returns, in turn, `CommitSqlTransaction`, `RollbackSqlTransaction`, a SQL error (`failingProjection`), and with the silent `CloseAccount`. Oracle: `SqlCommandCommitted` leaves event and row; `SqlCommandRolledBack` leaves neither, writes no snapshot, and the same command with the same identifier then succeeds; the SQL error leaves neither; the silent command returns `SqlCommandNoOp` without calling the callback (contract).

`keiro/command/concurrency/identical-commands-one-batch` (standard, either). Knobs: `command.concurrency` (int, 16, 2 to 256), `command.processes` (int, 1, 1 to 8; above 1 uses `keiro.command-writer` roles). Procedure: N submitters released by a barrier send the same `Deposit` with one identifier. Oracle: the log holds that identifier once, the version moved by one and the balance by the amount once; exactly one submitter saw `Right`; every other saw `StoreFailed (DuplicateEvent _)` or `RetryExhausted`, and with the default retry limit the count of `RetryExhausted` is reported and expected to be zero (contract).

`keiro/command/concurrency/hot-stream-contention` (standard, either). Knobs: `command.writers` (int, 8, 2 to 128), `command.retry-limit`, `command.duration-seconds` (int, 30). Procedure: W writers deposit into one account with distinct identifiers. Oracle: shared checks; the number of `Right` results equals the number of events; every `Right` reported a distinct stream version; the final balance is the sum of accepted amounts (contract). The rates of retries and `RetryExhausted` are recorded as measurements, not judged.

`keiro/command/concurrency/model-based-parallel-commands` (standard, either). Procedure: with the hedgehog parallel state-machine helpers of `docs/plans/5-…`, generate a sequential prefix and two to four parallel branches of `OpenAccount`, `Deposit`, `Withdraw`, `CloseAccount` over three accounts, execute them with real threads, and check linearizability against `Model`: accepted commands are ordered by their stream versions, and each rejected command must be explainable at some point between its invocation and response. Knobs: `model.tests` (int, 100), `model.branches` (int, 3, 2 to 4). Oracle: no counter-example; on failure the seed and the shrunk history are written into the verdict so `kenshou run --seed` reproduces it (contract).

`keiro/command/concurrency/sigkill-idempotent-resubmission` (standard, either; durable only). Knobs: `command.processes` (int, 3), `fault.kill-interval-seconds` (int, 5), `command.duration-seconds` (int, 60), `client.resubmit-window` (int, 8). Procedure: writer roles run disjoint operation sequences and report acknowledged indices; the scenario kills a random writer at each interval and restarts it from its last acknowledged index minus the window, so operations that committed but were not acknowledged are resubmitted. Oracle: every operation index below each writer's final acknowledged index appears exactly once in the log by its `opEventId`, none is missing, and the shared checks pass at quiescence (contract).

`keiro/snapshot/correctness/policy-matrix` (standard, either). Knob: `snapshot.policy` (all five values, run as a list). Procedure: 250 single-event commands on one account, then withdraw to zero and close. Oracle from `readSnapshots`: `never` leaves no row; `every-n` leaves a row at the largest multiple of n not above the final version; `on-terminal` leaves a row only after the close, at the final version; in every row the JSON `registers.entries` equals `stream_version` and `registers.balance` equals the model's balance at that version (contract). A second pass with eight concurrent writers asserts that the row's `stream_version` sampled every 100 ms never decreases (implementation).

`keiro/snapshot/correctness/truncation-covering-snapshot` (smoke, either). Procedure: with `every-10` and 25 events (snapshot at 20): set the truncation marker to 21 and submit a deposit; set it to 22 and submit; clear it and submit; then on a `never` stream of 5 events set the marker to 3 and submit a deposit, and set it to 6 and submit `OpenAccount` (the stream then looks empty, so only an opening command passes the decision step). Oracle: marker 21 succeeds; marker 22 gives `HydrationGapDetected`; after clearing, the command succeeds; the uncovered stream gives `HydrationGapDetected` at marker 3 and `ConflictFixpoint (StreamVersion 0) (StreamAlreadyExists _)` at marker 6; `$all` still lists every event (contract).

`keiro/snapshot/correctness/seed-divergence-detection` (smoke, either). Knob: `snapshot.seed-verify-sample-rate` (int, 1; `0`, `1`). Procedure: build a snapshot, overwrite its stored balance with SQL (`jsonb_set(state, '{registers,balance}', …)` on `keiro.keiro_snapshots`), let a `keiro.command-writer` role submit one command (a role, so that its standard error is captured under `logs/`), wait up to five seconds. Oracle: with rate 1 the divergence counter becomes 1 (metrics on) and the process's standard error contains the JSON marker line, while the command itself still succeeds; with rate 0 neither appears (contract: verification is advisory and sampled).

`keiro/projection/correctness/async-dedup-and-fence` (smoke, either). Procedure: apply one recorded event twice; mark the read model rebuilding with `Keiro.ReadModel.Schema.markRebuilding` and apply another; mark it live; prune deduplication rows with `pruneAsyncProjectionDedupBefore` and apply the first event again. Oracle: outcomes are `AsyncApplied`, `AsyncDuplicate`, `AsyncFenced` (with no row written), and after pruning `AsyncApplied` again with `events_applied` now 2, which is the documented meaning of pruning (contract).

`keiro/projection/concurrency/inline-atomicity-under-kill` (standard, either; durable only). Knobs: `fault.kind` (enum list, `sigkill,backend-terminate,projection-error`), `command.duration-seconds` (int, 60). Procedure: writer roles use `accountBalanceProjection` followed by `parkingProjection` with a predicate matching a `Deposited` whose memo is `kenshou:park`; that deposit makes the transaction sleep after the append and the read-model write but before commit. The scenario finds the sleeping backend in `pg_stat_activity` by `application_name`, then kills the process or terminates the backend; `projection-error` uses `failingProjection`. Oracle: `inline-read-model-equals-log` holds at every observation and at the end, and the parked operation is either absent from both log and table or present in both (contract).

`keiro/projection/concurrency/async-at-least-once-under-kill` (standard, either; durable only). Knobs: `projection.batch-size` (int, 100, 1 to 1000), `fault.kill-interval-seconds` (int, 5), `projection.sabotage` (enum, `none`; `skip-dedup`). Procedure: one writer role and one `keiro.projection-worker`, the latter killed repeatedly. Oracle: at quiescence `account_activity` equals the model for every account (contract); the number of `AsyncDuplicate` outcomes after each restart is at most the batch size (implementation: kiroku checkpoints per batch). With `skip-dedup` the scenario must fail.

`keiro/projection/concurrency/async-apply-checkpoint-atomic` (standard, either; durable only). Known defect: `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-10`. Same procedure; the oracle is the stronger property that no event is redelivered after being applied (zero `AsyncDuplicate` outcomes). It is expected to fail today and must start passing if keiro delivers an atomic mode.

### Milestone 3 — Process manager scenarios

Scope: the saga under redelivery, policy, real retry budgets, reordering and real crashes. At the end eleven scenarios exist under `keiro/process-manager` in the modules `Kenshou.Suite.Keiro.ProcessManager.Correctness`, `.Concurrency`, `.Reaction`, with `.ProcessManager` exporting `scenarios`, and the role `keiro.pm-worker` can park in any of four crash windows. Run them as in Milestone 2. Acceptance: ten pass, `reaction-no-advance-receipt` is reported as a known defect, the run logs of `sigkill-crash-windows` show a kill and a restart for each window, and the sabotaged redelivery run fails. Knob common to all: `pm.source` (enum, default `list` unless a scenario states otherwise; `list`, `kiroku-adapter`, `ack-stream`), which picks the bridge.

`keiro/process-manager/correctness/deterministic-ids-redelivery` (smoke, either). Knobs: `pm.redeliveries` (int, 3, 1 to 20), `pm.sabotage` (enum, `none`; `unstable-manager-name`). Procedure: create 50 transfers, then feed every `TransferDebited` and `TransferAnnounced` to `runProcessManagerWorkerWith` through `listAdapter`, each delivered K times, interleaved by the seed. Oracle (verdict `exactly-once-target-effects`): for every source event the saga stream holds exactly one event with `expectedSagaStateId`, the destination holds exactly one `TransferCredited` with `expectedSagaCommandId … 0`, the source exactly one `TransferConfirmed` with index 1, nothing else was written, every acknowledgement is `AckOk`, and `money-is-conserved` holds with nothing in flight (contract). With the sabotage value, which renames the manager on each delivery, it must fail.

`keiro/process-manager/correctness/policy-matrix` (standard, either). Knobs: `pm.poison-policy` (enum list, `halt,skip,dead-letter`), `pm.rejected-command-policy` (enum list, `halt,dead-letter,skip`). Inputs per cell: a `TransferDebited` row with an undecodable payload, a transfer whose destination was closed, a normal transfer. Oracle: poison gives `AckHalt (HaltFatal "process-manager worker could not decode message")`, or the callback once and `AckOk`, or the callback once and `AckDeadLetter (InvalidPayload _)`, and `keiro.dispatch.poison` rises by one in each case. The rejected credit gives `AckHalt` under `halt` with no dead-letter row; `AckOk` under `dead-letter` with exactly one row in `keiro.keiro_dead_letters` (`dispatcher_kind = 'process-manager'`, `dispatcher_name = 'transferSaga'`, `emit_index = 0`, `error_class = 'command_rejected'`, the destination's stream name), still exactly one after redelivery; `AckOk` and no row under `skip`. In all three the saga's own event and the `TransferConfirmed` exist, which is the documented history split, and `money-is-conserved` counts the debited amount as in flight (contract).

`keiro/process-manager/correctness/transient-classification` (standard, either). Procedure: four cases. A `beforeAppend` hook that appends a foreign deposit to the destination on every invocation, with retry limit 1, produces `RetryExhausted 2 (WrongExpectedVersion …)` for the credit. A `parkingProjection` on `TransferCredited` in `targetProjections` holds the credit's transaction open while the scenario terminates that backend, which produces `ConnectionLost`. An undecodable event appended directly to the destination stream produces `HydrationDecodeFailed`. For a mixed group, the transfer empties the source, the source is closed before delivery so that `ConfirmTransfer` is rejected, and the credit fails transiently as in the first case. Oracle: `AckRetry` with the configured `pm.transient-retry-delay-seconds` (number, 5) for the first two, `AckHalt` for the third, `AckRetry` for the mixed group because transient wins over rejection (contract).

`keiro/process-manager/correctness/retry-budget-dead-letter` (standard, either; `pm.source` in `kiroku-adapter`, `ack-stream`). Knobs: `kiroku.retry-max-attempts` (int, 5, 1 to 10; honoured only by `ack-stream`), `pm.transient-retry-delay-seconds` (number, 0.2). Procedure: keep one transfer transiently failing with the conflicting `beforeAppend` hook aimed at its destination, follow it with a healthy transfer to another destination, and install `kirokuEventBridge`. Oracle: the failing event is delivered exactly N times with attempts 0 to N − 1, then `kiroku.dead_letters` holds one row for the subscription with `reason->>'kind' = 'max_attempts_exceeded'` and `attempt_count = N`, the checkpoint moves past it and the healthy transfer completes; `keiro.subscription.deadlettered` is 1 with metrics on; with `kiroku-adapter`, N is 5 whatever the knob says. After the fault is removed, `Keiro.DeadLetter.Replay.replaySubscriptionDeadLetters` with a handler that calls `runProcessManagerOnce` returns `ReplayedFresh`, a second replay returns `ReplayedDuplicate`, and the transfer's effects exist exactly once (contract).

`keiro/process-manager/correctness/order-insensitive-join` (smoke, either). Procedure: deliver `[announced, debited]` for one transfer and `[debited, announced]` for another to `transferManager`, then the first order to `strictTransferManager` under `RejectedHalt` and under `RejectedDeadLetter`. Oracle: the fixture manager reaches `SagaJoined` for both with identical target effects; the strict manager rejects `ObserveAnnounce` in `SagaIdle`, so under `RejectedHalt` the acknowledgement is `AckHalt`, and under `RejectedDeadLetter` it is `AckOk` with one dead-letter row whose `emit_index` is `-1` and no saga event for the announcement (contract: joins across streams must be order-insensitive).

`keiro/process-manager/correctness/timers-commit-with-manager-append` (smoke, either). Oracle: after a `TransferDebited` is handled, `keiro.keiro_timers` holds one row with `transferTimeoutTimerId`, `process_manager_name = 'transferSaga'`, the transfer as `correlation_id`, status `scheduled` and the derived `fire_at`; redelivery leaves one row. A second `TransferDebited` for the same transfer with a different deadline is rejected by the saga (`SagaDebitSeen` has no `ObserveDebit` edge), and because the timer write shares the rejected append's transaction the row's `fire_at` must still be the first deadline. The count of `DebitObserved` events always equals the count of timeout timers (contract). Firing timers belongs to `docs/plans/14-…`.

`keiro/process-manager/correctness/reaction-schedule-modes` (smoke, either). Procedure: run `runReactiveProcessManagerOnce` with `transferReaction` for one transfer delivered as debited then announced, and for another as announced then debited; cancel a third transfer's reminder with `Keiro.Timer.cancelTimer` between its two inputs; redeliver every accepted input once. Oracle: the timeout row keeps the time of whichever input arrived first and the later result reports `onceInserted = 0`; the reminder row carries the time of the later input (`Rearm` moves a scheduled row) except for the cancelled one, which stays `cancelled`; accepted redelivery returns `ReactionDuplicate`, reports `statementsCommitted = 0` and still completes missing dispatches under `deterministicReactionCommandId` (contract).

`keiro/process-manager/correctness/reaction-no-advance-receipt` (smoke, either). Known defect: `mori://shinzui/keiro/okf/adrs/concepts/ADR-41`. Procedure: deliver `ReactCredited` for a transfer whose timeout does not exist yet (the cancel changes nothing), then `ReactDebited` (accepted; schedules the timeout), then redeliver the same `ReactCredited` source event. Oracle: the effects of a `NoAdvance` input run at most once per source event, so the timeout is still `scheduled`. Today the redelivery cancels it, which is the documented absence of a durable receipt.

`keiro/process-manager/concurrency/sigkill-crash-windows` (standard, either; durable only; `pm.source=kiroku-adapter`). Knob: `pm.kill-window` (enum list, `before-manager-append,between-manager-and-target,between-targets,after-targets-before-ack`). Procedure: a `keiro.pm-worker` role is armed for one transfer; on the first delivery of that transfer's `TransferDebited` its `beforeAppend` hook parks at invocation 1 (before the saga append), 2 (before the credit) or 3 (before the confirmation), or `interposeAck` parks before finalizing; it reports the window on the control channel and is killed and restarted unarmed. The armed transfer uses accounts that no other operation touches, so no version conflict can add hook invocations. Oracle: `exactly-once-target-effects` for that transfer and its neighbours; in the second window the killed incarnation's saga event exists while the credit does not until the restart, which shows that the boundary is smaller than a reaction; the restarted worker's observed fact records `PMStateDuplicate` where the saga event pre-existed (contract).

`keiro/process-manager/concurrency/random-kill-exactly-once` (standard, either; durable only). Knobs: `command.rate-per-second` (int, 50), `fault.kill-interval-seconds` (int, 4), `command.duration-seconds` (int, 120), `fault.backend-terminate` (bool, true). Procedure: writers issue transfers open loop while the saga worker is killed or loses its backend at intervals. Oracle: within a quiescence deadline of 60 seconds every debited transfer is credited and confirmed exactly once, the shared checks pass, and `kiroku.dead_letters` and `keiro.keiro_dead_letters` are empty (contract).

`keiro/process-manager/concurrency/topologies` (standard, either; durable only). Knob: `pm.topology` (enum list, `duplicate-subscribers,consumer-group,sharded`), `pm.processes` (int, 2, 2 to 4). `duplicate-subscribers` runs several workers on one ungrouped subscription (a misconfiguration keiro must tolerate); `consumer-group` sets `ConsumerGroup {member, size}` per process; `sharded` runs `runShardedSubscriptionGroupAck` with a handler that calls `runProcessManagerOnce`, classifies with `decideForFailures` and maps with `shardAckFor`. Oracle: `exactly-once-target-effects` and all sagas `SagaJoined` (contract). The workload issues the two legs of each transfer in a seed-chosen order. The fraction of saga streams whose first event is `AnnounceObserved` is reported as a measurement; both orders must occur for the run to demonstrate the ordering caveat on a real bridge, and a run in which only one order occurred is `inconclusive`.

### Milestone 4 — Router scenarios

Scope: fan-out identity, drift, the declarative contract and crashes in mid fan-out. Modules: `Kenshou.Suite.Keiro.Router.Correctness`, `.Concurrency`, and `.Router` exporting `scenarios`. Knob common to all: `router.source` (enum, default `list`; `list`, `kiroku-adapter`, `ack-stream`), the router's counterpart of `pm.source`. At the end six router scenarios exist and the role `keiro.router-worker` can park in mid fan-out. Run them as in Milestone 2. Acceptance: the declarative policy matrix reports the expected acknowledgement in all twelve cells, `sigkill-mid-fanout` shows a partial fan-out before the kill and a complete one after, and the probe scenario either passes or has been filed upstream.

`keiro/router/correctness/fanout-exactly-once` (smoke, either). Knobs: `router.fanout` (int, 16, 1 to 1000), `router.redeliveries` (int, 3), `router.sabotage` (enum, `none`; `unstable-router-name`). Procedure: declare a bonus, deliver it K times through `listAdapter` with the resolved list shuffled per attempt; a second bonus resolves one account twice in one batch. Oracle: each recipient holds exactly one `BonusCredited` with `expectedRouterCommandId … 0`; the repeated account holds two, with occurrences 0 and 1, as documented; acknowledgements are `AckOk` (contract). The sabotage value must fail.

`keiro/router/correctness/stable-union-under-drift` (smoke, either). Procedure: attempt one resolves set A while a `beforeAppend` conflict makes one chosen target fail transiently (`AckRetry`); before attempt two the scripted resolver returns set B. Oracle: every member of B is credited once; every member of A that was dispatched before the failure keeps its credit even if absent from B; nobody is credited twice; the credited set equals the union of what was dispatched (contract).

`keiro/router/correctness/per-target-independent-commits` (smoke, either). Procedure: one of N recipients is closed; run under `RejectedDeadLetter`. Oracle: N − 1 credits, one dead-letter row with `dispatcher_kind = 'router'` naming the closed account's stream, `AckOk` (contract: fan-out is idempotent, not atomic).

`keiro/router/correctness/declarative-selection-policies` (standard, either). Knobs: `router.empty-policy` (enum list of the four), `router.failure-policy` (enum list of the three), `router.recipient-limit` (int, 8). Cases: empty selection; `SelectionQueryFailed`; two unequal commands for one target; limit + 1 distinct recipients; two equal commands for one target. Oracle: empty gives `AckOk`, `AckRetry`, `AckDeadLetter` or `AckHalt` according to policy; each failure gives `AckRetry`, `AckDeadLetter` or `AckHalt` according to policy with the codes `keiro.router.selection.query_failed`, `.target_conflict`, `.recipient_overflow` (and `.empty`), and no target write happened in any failing case; equal duplicates collapse to one dispatch; dispatch order is by target stream name. With `router.source=kiroku-adapter` a dead-lettered selection appears in `kiroku.dead_letters` with `reason->'detail'->>'code'` equal to the code (contract).

`keiro/router/correctness/dead-letter-identity-under-reordered-redelivery` (smoke, either). Purpose: probe a suspected weakness. Dispatch identity is keyed by target, but `keiro.keiro_dead_letters` is unique on `(dispatcher_name, source_event_id, emit_index)` and the router's emit index is the position in the resolved list. Procedure: two closed recipients, `RejectedDeadLetter`, park before the acknowledgement, kill, and let the redelivery resolve the list in reverse. Oracle: exactly one dead-letter row per rejected target, each naming its own stream (contract as operators would read it). If it fails, file a bug report in `mori://shinzui/keiro`, attach its URI as the scenario's known-defect reference, and record it in Surprises & Discoveries.

`keiro/router/concurrency/sigkill-mid-fanout` (standard, either; durable only; `router.source=kiroku-adapter`). Knobs: `router.fanout` (int, 32), `router.kill-after-targets` (int, 16). Procedure: the `keiro.router-worker` role parks in `beforeAppend` just before the append for target number k + 1, where k is the knob; the scenario first asserts that exactly k recipients are already credited, then kills and restarts. Oracle: all recipients credited exactly once at quiescence (contract).

### Milestone 5 — Write-side benchmarks, soak and telemetry arms

Scope: measurement, endurance and the two telemetry dimensions. At the end five benchmarks, two soaks (each registered at two durations) and one telemetry scenario exist in the modules `Kenshou.Suite.Keiro.Command.Bench`, `.Command.Soak`, `.ProcessManager.Bench`, `.Router.Bench` and `Kenshou.Suite.Keiro.Telemetry`. Run the benchmarks and the `-reduced` soaks locally with `--dim pg.durability=durable`, and produce one overhead report with `kenshou overhead`. Acceptance: every run directory contains `samples/`, `series/` and verdict files, the shared checks pass after every benchmark, and the short soaks end with a leak verdict. All benchmarks are tier `standard`, placement `either`, support only `pg.durability=durable` and all values of both telemetry dimensions, use the phases warm-up, steady and drain of the measurement toolkit, run the shared checks after the drain (a benchmark that corrupts data is `failed`, not fast), and are only authoritative for comparison when run on a cell as paired trials.

`keiro/command/benchmark/throughput-latency`. Knobs: `command.load-model` (enum, `closed`; `closed`, `open`), `command.writers` (int, 8, 1 to 128), `command.rate-per-second` (int, 500, open loop only), `command.processes` (int, 1), `kiroku.pool-size`, `command.runner` (enum, `plain`; `plain`, `with-sql`, `with-inline-projection`), `snapshot.policy`, `command.accounts` (int, 1000), `command.memo-bytes` (int, 64, 0 to 65536), `command.verify-replay-on-append` (bool, true), `command.duration-seconds` (int, 120). Measurements: accepted commands per second, latency percentiles per outcome, retries and client retries per second, allocation rate, and PostgreSQL wait events.

`keiro/command/benchmark/hydration-cost`. Knobs: `command.stream-length` (int list, `0,100,1000,10000`), `snapshot.policy` (list, `never,every-100`), `command.page-size` (list, `64,256,1024`). One writer measures single-command latency against streams of each length; the result shows what snapshots and page size buy.

`keiro/command/benchmark/all-stream-append-ceiling`. Knobs: `command.writers` (int list, `1,2,4,8,16,32,64`), `kiroku.pool-size` (int list, `4,10,13,32`), `command.processes` (int, 1, 1 to 8). Every writer owns its accounts, so there are no version conflicts and the only shared resource is the `$all` row. Measurements: throughput per combination and scaling efficiency relative to one writer; the summary names the knee. `TransientTransactionFailure` counts are reported separately because concurrent creation of new streams can deadlock.

`keiro/process-manager/benchmark/dispatch-latency` and `keiro/router/benchmark/fanout-dispatch`. Knobs: `pm.source` (`list`, `kiroku-adapter`), `pm.redelivery-ratio` (number, 0, 0 to 1), `router.fanout` (int list, `1,10,100,1000`), `command.rate-per-second`. Measurements: per-message handling time inside the worker, time from source append to last target append (wall clock across processes with the recorded skew bound), and the cost of a duplicate delivery relative to a fresh one.

`keiro/command/soak/write-side-steady-state` (soak, cell) and `…-reduced` (extended, either). Knobs: `soak.duration-minutes` (int, 240 and 20), `command.rate-per-second` (int, 200), `soak.kill-interval-seconds` (int, 0 meaning none), `projection.prune-interval-seconds` (int, 300), `snapshot.policy` (`every-100`). Topology: two writer processes, one saga worker, one router worker, one projection worker, one durable database. Verdicts: a leak verdict per process on live bytes after major collections, Haskell threads, file descriptors and connections by `application_name`; growth bounds for `keiro.keiro_snapshots` (at most one row per stream) and `keiro.keiro_projection_dedup` (bounded when pruning is on); both dead-letter tables empty; the shared checks and `exactly-once-target-effects` at quiescence; p99 latency of the last tenth of the run within the comparison policy of the first tenth, otherwise `inconclusive`.

`keiro/snapshot/soak/seed-verification-backlog` (soak, cell) and `…-reduced` (extended, either). Knobs: `snapshot.seed-verify-sample-rate` (int list, `0,1,1000`), `command.stream-length` (int, 10000), `command.rate-per-second` (int, 200). With rate 1 every command that hits a snapshot starts an unsupervised thread that replays the stream to the seed version on a pool connection. Verdicts: leak verdict on Haskell thread count and connections; pool acquisition timeouts are zero; command latency with rate 1 is compared against rate 0. A failure here is a finding to file upstream, after which the scenario carries the known-defect reference.

`keiro/telemetry/correctness/write-side-signals` (smoke, either; meaningful with `telemetry.tracing=sdk-inmemory` and `telemetry.metrics=collect`, and also run with both `off`). Procedure: a short mixed workload with injected conflicts, duplicates, one poison message and one rejected dispatch. Oracle: each `runCommand` produced one `Internal` span named after the stream with `keiro.stream.name`, `keiro.retry.attempt`, `keiro.events.appended` and `db.system.name = postgresql`, and `error.type` from `commandErrorClass` on failure; the counters `keiro.command.conflicts`, `.retries`, `.duplicates`, `keiro.dispatch.duplicates`, `.failed`, `.deadlettered`, `.poison`, `keiro.snapshot.read.hits` and `.misses` match the ledger's counts exactly; with both dimensions `off` nothing is exported and results are identical (contract). The number of distinct span names is reported, because it equals the number of streams.

Telemetry arms. Every scenario obtains handles from `Kenshou.Telemetry.withTelemetry` and converts them with `keiroTelemetry`; `tracer` goes into `RunCommandOptions.tracer`, `metrics` into `RunCommandOptions.metrics` and `WorkerOptions.metrics`, and `kirokuEventBridge` is installed whenever metrics are not `off`. For `serve` and `serve-scraped` the scenario starts kiroku-metrics with `withMetricsServerWithStore` on port 0 and registers the bound port. The layer's overhead comparison is `kenshou overhead keiro/command/benchmark/throughput-latency --arms tracing=off,noop,sdk-inmemory,sdk-otlp --arms metrics=off,collect,serve-scraped`, repeated for `keiro/process-manager/benchmark/dispatch-latency`; commit no results, but record in Outcomes & Retrospective that a report was produced and what it said.

Finish `docs/layers/keiro.md`: one section per component listing each scenario, its knobs and what it proves, plus how to read the shared verdicts.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro-runtime-kenshou`, inside the development shell (`nix develop`, or `direnv allow` once). Flag spellings for `kenshou list` and `kenshou run` are owned by `docs/plans/2-…`; if they differ from what is shown, use that plan's.

Check the dependencies before starting:

```bash
ls kenshou-core kenshou-measure kenshou-check kenshou-diagnose kenshou-telemetry kenshou-cli/src/Kenshou/Cli/Registry.hs docs/adr/profile.dhall
cabal build all
cabal run kenshou -- run selftest/kernel/correctness/postgres-roundtrip --out runs
cabal run kenshou -- run selftest/check/concurrency/kill-and-restart-worker --out runs
cabal run kenshou -- cohort show --json | jq .
```

Every `run` must end with outcome `passed`, and the cohort identity must list keiro 0.17.0.0, keiki 0.9.1.0, kiroku-store 0.8.0.1, shibuya-core 0.9.0.3 and a `shibuya-kiroku-adapter` (or the head cohort's commits). If a directory is missing or a self-test fails, stop: the owning plan is not complete.

Build and test the package, then see the layer:

```bash
cabal build kenshou-keiro
cabal test kenshou-keiro-test
cabal run kenshou -- list | grep 'keiro/'
cabal run kenshou -- run keiro/command/correctness/fixture-roundtrip --out runs
```

Illustrative transcript of the last command (identifiers and counts will differ):

```text
run 0199a3c2-7b1e-7d40-9c11-5e0f4a2b9d10  keiro/command/correctness/fixture-roundtrip
  verdict log-is-well-formed              passed  contract  streams=101 events=548
  verdict model-equals-log                passed  contract
  verdict inline-read-model-equals-log    passed  contract  accounts=100
  verdict money-is-conserved              passed  contract  total=1000000
outcome: passed
```

Run a crash scenario and a known-defect scenario:

```bash
cabal run kenshou -- run keiro/process-manager/concurrency/sigkill-crash-windows \
  --set pm.kill-window=between-manager-and-target --dim pg.durability=durable --out runs
cabal run kenshou -- run keiro/projection/concurrency/async-apply-checkpoint-atomic --dim pg.durability=durable --out runs
```

```text
  window between-manager-and-target reached by keiro.pm-worker pid 48211; SIGKILL delivered; restarted as pid 48240
  verdict exactly-once-target-effects     passed  contract  transfers=20 duplicates-folded=2
outcome: passed
```

The second command reports the failed verdict together with the reference `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-10` and does not block (the exact outcome label and exit code for a known defect are defined by `docs/plans/2-…`).

Prove the oracles bite, run a benchmark and a short soak, and produce the overhead report:

```bash
cabal run kenshou -- run keiro/command/correctness/idempotent-event-ids --set command.sabotage=omit-event-ids --out runs; echo "exit=$?"   # expect exit=1
cabal run kenshou -- run keiro/command/benchmark/all-stream-append-ceiling --dim pg.durability=durable --out runs
cabal run kenshou -- run keiro/command/soak/write-side-steady-state-reduced --set soak.duration-minutes=5 --dim pg.durability=durable --out runs
cabal run kenshou -- overhead keiro/command/benchmark/throughput-latency --arms tracing=off,noop,sdk-otlp --arms metrics=off,serve-scraped --out runs
```

Create the ADRs in Milestone 1 and validate the bundle:

```bash
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

Commit after each milestone at least, directly on the current branch, using Conventional Commits (for example `feat(keiro): add the ledger fixture domain`) with these trailers:

```text
MasterPlan: docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md
ExecPlan: docs/plans/12-cover-the-keiro-command-processor-process-managers-and-routers.md
Intention: intention_01m2zvy0gje40tdsdragvzr3tq
```


## Validation and Acceptance

Milestone 1 is accepted when `cabal test kenshou-keiro-test` passes with tests showing that `mkEventStream` returns `Right` for the account stream under all three policy shapes, for both saga variants and for the bonus stream; that a hedgehog property finds `Model.decide` and `Keiki.Core.stepEither accountTransducer` in agreement on acceptance, rejection and resulting balance for random command sequences; that `workerOps` is a pure function of its arguments and different workers never share an `opEventId`; that `expectedSagaCommandId` equals `Keiro.ProcessManager.deterministicCommandId` and `expectedRouterCommandId` equals `Keiro.Router.deterministicRouterCommandId`; and when `fixture-roundtrip` passes and appears in `kenshou list`.

Milestone 2 is accepted when all fifteen scenarios run to a decided outcome locally, the two sabotage runs fail with exit code 1, `inline-atomicity-under-kill` shows in `logs/` that a backend was terminated while a transaction was open and still passes, and `async-apply-checkpoint-atomic` is reported as a known defect. Milestone 3 is accepted when each of the four kill windows has been observed in a run's log with a process identifier before and after, `retry-budget-dead-letter` shows exactly five deliveries on the production adapter and the configured number on the ack-stream adapter, and the sabotaged redelivery run fails. Milestone 4 is accepted when the twelve cells of the declarative policy matrix each report the expected acknowledgement and `sigkill-mid-fanout` shows a partial fan-out before the kill and a complete one after. Milestone 5 is accepted when each benchmark writes `samples/`, `series/` and a summary with the shared checks passing, the short soaks end with leak verdicts of `stable` or a finding that has been filed, a run with both telemetry dimensions `off` is still fully measured, and an overhead report exists for the command benchmark.

The whole plan is accepted when `kenshou list` shows every scenario named in the Plan of Work, a run plan restricted to tier `smoke` and layer `keiro` passes on a laptop in a few minutes, and `docs/layers/keiro.md` describes every scenario.


## Idempotence and Recovery

Every run gets a fresh, migrated database from the kernel and writes into a new run directory, so any scenario can be repeated without cleanup. The fixture's own tables are created with `IF NOT EXISTS`. Worker processes are children of the scenario and are reaped by `Kenshou.Check.Process` through their process group; if a run is interrupted, look for strays with `pgrep -fl 'kenshou worker'` and ephemeral PostgreSQL servers with `pgrep -fl postgres`, and end them with `kill` before rerunning. A parked worker that was never killed (for example because the scenario itself crashed) holds one backend in `pg_sleep`; ending the ephemeral server removes it. When a scenario is run against an external database, it must refuse to start unless the `account`, `bonus` and saga categories are empty, because its oracles read whole categories.

If the transducer fails validation, or a signature here does not match the pinned cohort, fix the fixture and record the difference in the Decision Log; do not switch to `mkEventStreamUnchecked`. If a toolkit's real interface differs from what this plan assumes, adapt the scenario code and note it; the scenario identifiers, knobs and oracles are the contract of this plan, not the glue. If a scenario finds a real defect in keiro, do not weaken the oracle: file a bug report or improvement request in the owning repository, attach its `mori://` URI as the known-defect reference, and record it under Surprises & Discoveries and in the MasterPlan.


## Interfaces and Dependencies

Runtime libraries, at the versions the released cohort pins in `cohort/released.project`: `keiro` and `keiro-core` 0.17.0.0 (command runner, projections, process managers, routers, telemetry, connection helpers), `keiki` and `keiki-codec-json` 0.9.1.0 (transducer DSL, `deriveAggregate`, register-file JSON for snapshots), `kiroku-store` 0.8.0.1 (store, subscriptions, `subscriptionAckStream`, lifecycle), `kiroku-metrics` and `shibuya-kiroku-adapter` at the versions `docs/plans/1-…` pins, `shibuya-core` 0.9.0.3 (the `Adapter` seam and acknowledgement types; on the `head` cohort the unreleased shibuya lifecycle fix does not affect these workers, which bypass shibuya's runner), `effectful` 2.6.1.0, `streamly` 0.11.1, `hasql` 1.10 with `hasql-transaction` 1.2, `hs-opentelemetry-api` 1.0. Harness libraries: `kenshou-core`, `kenshou-measure`, `kenshou-check`, `kenshou-diagnose`, `kenshou-telemetry`. The package must not depend on `keiro-test-support` (the kernel owns databases) nor on any other `kenshou-*` layer package.

At the end of Milestone 1 these modules exist with the signatures given in the Plan of Work: `Kenshou.Suite.Keiro` (`bundle :: LayerBundle`), `Kenshou.Suite.Keiro.Fixture.Domain`, `.Fixture.Account`, `.Fixture.Transfer`, `.Fixture.Bonus`, `.Fixture.Projection`, `.Fixture.Runtime`, `.Fixture.Bridge`, `.Fixture.Workload`, `.Fixture.Model`, `.Fixture.Oracle`, `.Fixture.Roles`. At the end of Milestone 2: `Kenshou.Suite.Keiro.Command` (`scenarios :: [Scenario]`) with `.Command.Correctness`, `.Command.Concurrency`, `.Command.Snapshot`, `.Command.Projection`. Milestone 3: `Kenshou.Suite.Keiro.ProcessManager` with `.Correctness`, `.Concurrency`, `.Reaction`. Milestone 4: `Kenshou.Suite.Keiro.Router` with `.Correctness`, `.Concurrency`. Milestone 5: `.Command.Bench`, `.Command.Soak`, `.ProcessManager.Bench`, `.Router.Bench`, `Kenshou.Suite.Keiro.Telemetry`.

What other plans consume. `docs/plans/13-cover-the-keiro-outbox-inbox-and-job-queue.md` uses the account stream, `submitAccountCommand`, the workload and the oracles as the business effect behind outbox producers, inbox handlers and jobs. `docs/plans/14-cover-keiro-durable-execution-timers-and-sharded-subscriptions.md` uses the transfer timeout timers this fixture schedules, `shardAckFor`, the saga as a sharded handler, and the ledger as the side effect of workflow steps. `docs/plans/15-verify-the-assembled-runtime-end-to-end-and-under-soak.md` depends on the whole `Kenshou.Suite.Keiro.Fixture.*` tree from `kenshou-runtime` and relies on `money-is-conserved` across its two contexts. Both keiro plans extend `bundle`, `kenshou-keiro.cabal` and `docs/layers/keiro.md` rather than creating their own. A change to any exported fixture signature after Milestone 1 must update those three plans in the same change, which is the subject of the first ADR this plan creates.

Revision note (2026-09-23): Began implementation after the prerequisite build, self-tests, and cohort checks passed. Added the validated account and bonus aggregate foundation, a pure account model, deterministic workload generation, and unit checks. Milestone 1 remains in progress because the database fixture, workers, scenario registration, and ADRs are still to be implemented.

Revision note (2026-09-23): Added the first database-backed command scenario, inline balance projection, SQL log oracle, transfer saga and plain bonus router foundations, list adapter acknowledgement test, layer guide, and the two architectural decisions. Milestone 1 remains in progress for reactive/declarative variants, asynchronous projection, durable bridges, worker roles, and full fixture oracles.
