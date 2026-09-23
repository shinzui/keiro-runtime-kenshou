---
id: 10
slug: cover-shibuya-core-and-its-pgmq-and-kiroku-adapters
title: "Cover shibuya core and its PGMQ and kiroku adapters"
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
      at: 2026-09-23T13:35:35Z
      mode: "implement"
      note: "Started implementation and verified harness prerequisites"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-23T17:13:47Z
      mode: "implement"
      note: "Added concurrent adapter shutdown failure scenario and matrix tags"
---

# Cover shibuya core and its PGMQ and kiroku adapters

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Shibuya is the message-processing framework of the keiro runtime: it pulls messages from a source (an "adapter"), runs a handler on each, and tells the source what to do with the message afterwards. Services link it together with an adapter for PGMQ (a message queue made of PostgreSQL tables) and an adapter for kiroku (the PostgreSQL event store). Shibuya's own tests run in one process against in-memory mock sources, its adapters' tests never kill a process or restart PostgreSQL, and no benchmark anywhere measures an adapter end to end. An upstream lifecycle audit found defects in the historical 0.9.0.3 release. Hackage now publishes 0.10.0.0, which includes the lifecycle remediation; the suite must test the current release as well as preserve the historical regression comparison.

After this plan a maintainer can, from this repository, run `kenshou list --layer shibuya` and see every shibuya scenario, organised by the upstream audit's own vocabulary of lifecycle boundaries and fault cases. They can reproduce a known lifecycle defect against the historical 0.9.0.3 cohort, then run the same check against Hackage 0.10.0.0 and see it pass. They can kill a PGMQ consumer process with a real `SIGKILL` between the handler's success and the acknowledgement and see that nothing is lost, that the duplicate arrives within one visibility timeout, and that the redelivery silently consumed one unit of the retry budget. They can measure what the framework costs over a bare stream, what each adapter costs against a real durable PostgreSQL, what tracing and the metrics endpoints cost, and whether an hours-long run leaks. Everything is exercised through shibuya's public API exactly as a service would use it.


## Progress

Milestone 1 — shibuya core lifecycle, ordering, batching and metrics-truthfulness scenarios (no database).

- [x] (2026-09-23 13:38Z) Verify the hard dependencies are complete (kernel, measurement, correctness, diagnostics, telemetry) with the checks in Concrete Steps, and read their finished plans for exact signatures. `nix develop -c cabal build all`, the self-test list, `kill-and-restart-worker`, and `leaking-worker` all passed.
- [x] (2026-09-23 13:42Z) Create `kenshou-shibuya/kenshou-shibuya.cabal` with the library and the `kenshou-shibuya-test` suite; `nix develop -c cabal build kenshou-shibuya kenshou` succeeds on the released cohort.
- [x] (2026-09-23 13:42Z) Implement the `Kenshou.Suite.Shibuya.Cohort` capability probe and review references; linked-core unit checks pass on the released cohort.
- [x] (2026-09-23 13:48Z) Cross-check the capability probe against the resolved head cohort and run the unit checks there; the pinned head build and four package tests pass.
- [x] (2026-09-23 13:56Z) Finish `Kenshou.Suite.Shibuya.Knobs`: common specifications and all five parsers are present, with example and generated round-trip tests.
- [ ] Complete `Kenshou.Suite.Shibuya.Matrix`: thirteen boundaries and five cases enumerate sixty-five cells; the eight registered scenarios have tested tags, while the remaining scenario tags, justified exclusions, and complete sixty-five-cell coverage assertion remain.
- [ ] Implement `Kenshou.Suite.Shibuya.Fixture.SyntheticAdapter`, `.Handlers`, `.App`, `.RestartLoop` with unit tests. The synthetic broker covers lease expiry, retry redelivery, stale finalization, scripted finalizer faults, throwing or blocking shutdowns, and a one-shot source fault followed by adapter replacement. `RestartLoop` waits for `waitApp`, stops the old application, applies a bounded backoff, and rebuilds processors until its restart limit or stop request. `Handlers` provides scripted decisions and delays, a gate, per-delivery start/end facts, and active/high-water counts, including cancellation cleanup. Its seeded-delay convenience function, the telemetry/metrics app helper, and the broker's ledger writer remain (20 package tests pass).
- [ ] Implement the `core-runner` scenarios (fifteen) and the `shibuya-core-worker` and `shibuya-gc-probe` worker roles. Eight scenarios exist: invalid configuration, duplicate processor IDs, idle-intake halt, finite-source conservation, nonpositive concurrency, explicit restart after source failure, a measured unfinalized-lease bound, and concurrent adapter shutdown failure. The other seven and both roles remain.
- [ ] Implement the `core-ordering` scenarios (four). The policy matrix now checks all seven valid ordering/concurrency pairs with 16 uniform partition keys; the model, hot-key, and worker-failure scenarios remain.
- [ ] Implement the `core-batch` correctness and concurrency scenarios (two).
- [ ] Implement the `metrics` scenarios (eight) including the free-port allocation for `startMetricsServer`.
- [x] (2026-09-23 13:42Z) Register the initial `bundle` in `kenshou-cli`; `kenshou list --layer shibuya` displays the two implemented scenarios.
- [ ] Expand the registered bundle to all twenty-nine Milestone 1 scenarios and their roles; nine are registered now.
- [x] (2026-09-23 17:16Z) Add the concurrent adapter shutdown failure scenario and its matrix tags. The package's 20 tests pass; the released run reproduces a nonblocking known defect, the pinned head run passes, and the active cohort is restored to released.
- [x] (2026-09-23 17:24Z) Verify current Hackage and upstream releases, and add `cohort/shibuya-current.project` as an isolated release lane. All 20 Shibuya package tests pass with `shibuya-core` 0.10.0.0; the current `shibuya-metrics` 0.10.0.0, PGMQ adapter 0.16.1.0 and kiroku adapter 0.5.1.3 build in that lane.
- [ ] Make every Shibuya scenario executable in the isolated current-release lane and run the cohort-sensitive scenarios there. The lane currently builds and tests the package and adapters but does not include the full `kenshou` CLI, whose other layer packages still resolve through the historical runtime cohort.
- [ ] Run every Milestone 1 scenario on the released cohort and on the head cohort; record the observed outcome of each cohort-sensitive scenario in Surprises & Discoveries.
- [x] (2026-09-23 16:12Z) Re-run `nix develop -c cabal test kenshou-shibuya-test` after the ordering addition (20 examples, 0 failures) and `nix develop -c just cohort-check` on the restored released cohort; both passed and the working tree is clean.

Milestone 2 — PGMQ adapter scenarios.

- [ ] Implement `Kenshou.Suite.Shibuya.Fixture.Pgmq` (queue naming, producers, pools through the fault proxy, SQL oracles) with unit tests.
- [ ] Implement worker roles `shibuya-pgmq-consumer` and `shibuya-pgmq-producer`.
- [ ] Implement the PGMQ adapter correctness scenarios (three).
- [ ] Implement the PGMQ adapter concurrency and crash scenarios (eight).
- [ ] Run them with `pg.durability=durable` on `pg.version` 17 and 18 and record outcomes.

Milestone 3 — kiroku adapter scenarios.

- [ ] Implement `Kenshou.Suite.Shibuya.Fixture.Kiroku` (store, appenders, SQL oracles on `subscriptions` and `kiroku.dead_letters`) with unit tests.
- [ ] Implement worker roles `shibuya-kiroku-consumer` and `shibuya-kiroku-appender`.
- [ ] Implement the kiroku adapter correctness scenarios (three).
- [ ] Implement the kiroku adapter concurrency and crash scenarios (six).
- [ ] Run them with `pg.durability=durable` on `pg.version` 17 and 18 and record outcomes, including the measured replay window per subscription shape.

Milestone 4 — shibuya benchmarks, soak and telemetry arms.

- [ ] Implement the five benchmark scenarios and run three paired trials of each locally.
- [ ] Implement the four soak pairs (short and full) and run each short variant to a leak verdict.
- [ ] Implement the two trace-continuity scenarios and confirm every scenario honours `telemetry.tracing` and `telemetry.metrics`.
- [ ] Run `kenshou overhead` on the two designated benchmarks and add the shibuya entries to `policies/telemetry-overhead.json`.
- [ ] Write `docs/layers/shibuya.md` (scenario catalogue, knobs, what each proves, the boundary matrix, the cohort table).
- [ ] File upstream improvement requests or bug reports for defects found that have no upstream record, and attach their URIs as known-defect references.
- [ ] Create the ADRs named in Context and Orientation, validate the ADR bundle, and complete Outcomes & Retrospective.


## Surprises & Discoveries

- The host shell does not contain `ghc-9.12.4`; all Cabal commands in this implementation need `nix develop -c`. The full build and both prerequisite worker self-tests passed inside that shell on 2026-09-23.
- The local upstream shibuya checkout now declares `shibuya-core` 0.10.0.0, while both checked-in cohorts still pin 0.9.0.3; the PGMQ and kiroku adapter checkouts similarly declare 0.16.1.0 and 0.5.1.3 versus cohort pins 0.16.0.0 and 0.5.1.2. The implementation targets the checked-in cohort contract and must test both pins explicitly. The plan's claim that the upstream head has the same package version was true of its pinned head commit, not the checkout's current tip.
- The released-core duplicate-ID scenario reproduced REV-3-F2: `runApp` accepted duplicate IDs and pulled a source. The run result `runs/01a0ce7f-e937-746a-a328-322fbf03641b/run-result.json` records `knownDefect.status = reproduced` and `blocking = false`. The invalid-configuration scenario passed on the same cohort.
- The first idle-intake halt probe returned promptly in `async:4` on both cohorts despite the released-core REV-4-F1 finding. It confirmed the source reached its idle wait, but the handler returned at nearly the same instant. Holding the handler for 100 ms after intake became idle allowed the concurrent reader to block: released run `runs/01a0ce88-b274-730f-96fb-4f1885a978a1/run-result.json` has `waitAppCompleted=false`, `idleSourceReached=true`, `finalized=1`, `cleanupCompleted=true`, `knownDefect.status=reproduced`, `blocking=false`; pinned head run `runs/01a0ce89-5800-7116-b189-6ce02ca8bcb3/run-result.json` passes with no known-defect annotation. The extra wait is a fixture scheduling gate, not part of the measured wait deadline.
- The synthetic broker's 20 ms lease can expire repeatedly while a first handler sleeps for 100 ms. Its lease unit test therefore checks conservation, at least one stale-finalization rejection, and consistency between redeliveries and expiry events rather than assuming exactly one redelivery.
- The nonpositive-concurrency scenario reproduced released-core REV-6-F1 with `async:0`, `async:-1`, and `ahead:0` in `runs/01a0cef6-3380-73e2-8d50-b7d23e92f7b0/run-result.json` (`blocking=false`), while the pinned head passed in `runs/01a0cef5-4e99-7258-a77c-42e7158a15f7/run-result.json`. The finite-source conservation scenario, including ten scripted handler exceptions that cause retries, passed on both cohorts (`runs/01a0cef7-82f6-72a4-90b6-2aed25657d1b/run-result.json` and `runs/01a0cef8-0f4b-764f-b5cb-51e781f737e8/run-result.json`).
- With all six startup validation arms in place, the released-cohort invalid-configuration run `runs/01a0cefa-0cbb-717d-9127-ebb649cbd9fa/run-result.json` passed. The mixed ordinary and batch duplicate-ID run `runs/01a0cefa-42e2-730d-8528-20619beecaa7/run-result.json` reproduced REV-3-F2 as a nonblocking known defect.
- A broker source fault is now one-shot, so a replacement adapter can resume the same queue after the first application has stopped. The failed-processor scenario observed no automatic restart for five seconds, then finalized all 200 messages after an explicit application restart on both cohorts: `runs/01a0cefd-2ff4-754e-9744-4be706afc5ea/run-result.json` (released) and `runs/01a0cefd-e19d-7065-a4b0-6bc16af6ae76/run-result.json` (head).
- With 1,000 published messages, inbox size 100 and `async:4` handlers blocked on a gate, the broker measured 105 leased but unfinalized messages against the implementation bound of 114; after opening the gate all 1,000 were finalized. Released-cohort evidence: `runs/01a0cf05-0613-7078-a258-3169943ec976/run-result.json`.
- The ordering policy matrix passed all seven valid policy pairs on released and pinned head in `runs/01a0cf08-d088-7295-a9f2-a63cefd1bb67/run-result.json` and `runs/01a0cf09-726b-713d-b861-a0b91b22ff6e/run-result.json`. The unfinalized-lease bound also passed on head in `runs/01a0cf09-a436-738b-8897-e48842e8c035/run-result.json`.
- The concurrent shutdown failure run `runs/01a0cf42-ee54-7550-8915-1d58145162eb/run-result.json` observed the released core deliver the scripted exception to all eight stop callers but call `shutdown` eight times on the throwing adapter and zero times on either sibling. It is `knownDefect.status=reproduced`, `blocking=false`. The pinned head run `runs/01a0cf43-8916-75c6-ad09-d1286f4704ff/run-result.json` passed. An initial run had `different-failure` because its expected-failure token named the review rather than the scenario's failure key; this was corrected before the cited runs.
- Hackage now lists `shibuya-core` and `shibuya-metrics` 0.10.0.0, `shibuya-pgmq-adapter` 0.16.1.0 and `shibuya-kiroku-adapter` 0.5.1.3. The upstream `v0.10.0.0` tag resolves to commit `694daf72f32db673bd6ae0d00867ce9ca565a3c7`. The original `released` cohort remains a 0.9.0.3 historical baseline. Its `keiro-pgmq` 0.17.0.0 dependency requires `shibuya-core ^>=0.9.0.0`, so simply changing that cohort's Shibuya constraint to 0.10.0.0 would make it unsolvable. The separate `cohort/shibuya-current.project` selects only `kenshou-core` and `kenshou-shibuya`, and builds against the four current Shibuya packages. `nix develop -c cabal --project-file=cohort/shibuya-current.project test kenshou-shibuya-test` passed 20 examples; the same project file built all three adapter/metrics packages.


## Decision Log

- Decision: Scenario code is black-box and cohort-portable. It imports only names that exist with the same type in both shibuya-core 0.9.0.3 from Hackage and the repository head, and uses no C preprocessor conditions on runtime versions. The single exception is `Shibuya.Internal.Runner.KeyedScheduler.runKeyedScheduler`, whose signature is identical in both.
  Rationale: The two cores carry the same version number (0.9.0.3), so `MIN_VERSION_shibuya_core` cannot tell them apart, and a cabal flag set from `cohort/head.project` would make this plan edit a file owned by `docs/plans/1-bootstrap-the-kenshou-repository-and-pin-the-runtime-cohort.md`. Head-only names (`totalShutdownTimeout`, `getLifecycleSnapshot`, `ProcessorFailure`, `InvalidConcurrency`, `DuplicateProcessorId`) are therefore never referenced; behaviour is observed through `waitApp`, return values, exceptions rendered as text, metrics and the ledger.
  Date: 2026-09-20

- Decision: Cohort-sensitive known defects are decided by a pure capability probe of the linked library, `isLeft (validatePolicy Unordered (Async 0))`, evaluated when the layer bundle is built. On the released core the probe is `False` and the affected scenarios carry their `KnownDefect`; on a remediated core the probe is `True`, the scenarios carry no `KnownDefect`, and a failure blocks. The kernel (`docs/plans/2-build-the-harness-kernel-for-scenarios-dimensions-run-specs-and-results.md`) also offers a declarative alternative, `KnownDefect.appliesTo :: CohortScope` with conditions such as `ResolvedFromHackage "shibuya-core"`, which distinguishes the released and head cohorts by where the package was resolved from even though both report version 0.9.0.3. Use the declarative scope wherever "released versus head" is the real condition, because it is recorded in the run result; keep the capability probe as the cross-check that the scope and the linked code agree, and fail the unit test when they disagree.
  Rationale: Integration Point 3 gives a scenario one optional, static known-defect reference with no notion of "applies to this cohort only". The `kenshou` binary is built per cohort, so a probe of the linked code is exact, needs nothing from the kernel, and cannot drift from the truth the way a version comparison would. All four headline fixes landed in one upstream commit (`28a11e0`) that also changed `validatePolicy`, which is what makes one probe sufficient.
  Date: 2026-09-20

- Decision: The upstream audit's lifecycle boundaries and fault cases are reused as cell tags on scenarios, with a unit test that every cell is covered or has a recorded reason, rather than generating one scenario per cell. This plan covers 13 of the 14 in-scope boundaries; `kafka-persistence` belongs to `docs/plans/11-cover-the-kafka-transport-edge-with-a-disposable-broker.md`.
  Rationale: Sixty-five mechanical scenarios would hide the interesting ones and could not each carry a precise oracle; tags keep the vocabulary and the coverage accounting while letting a scenario that needs one fault prove several cells.
  Date: 2026-09-20

- Decision: Core scenarios use a purpose-built in-memory broker (`SyntheticAdapter`) instead of `Shibuya.Adapter.Mock`.
  Rationale: The upstream mock is a finite list with no lease, no redelivery, no idle period and a no-op `shutdown`. Idle-source halts, stranded leases, blocking or throwing shutdowns and finalizer faults — the audit's actual findings — cannot be expressed with it.
  Date: 2026-09-20

- Decision: The metrics and health truthfulness scenarios are delivered in Milestone 1 rather than with the telemetry arms in Milestone 4, and the milestone is described as "core lifecycle, ordering, batching and metrics-truthfulness scenarios (no database)".
  Rationale: They are correctness scenarios about two of the audit's boundaries, need no PostgreSQL, and share the application fixture built in Milestone 1. Milestone 4 stays about cost and duration.
  Date: 2026-09-20

- Decision: `kenshou-shibuya` carries its own small PGMQ and kiroku fixtures instead of importing `kenshou-pgmq` or `kenshou-kiroku`.
  Rationale: Integration Point 1 forbids layer packages from importing one another. The duplication is a few hundred lines and buys independent builds and attributable failures.
  Date: 2026-09-20

- Decision: Each soak is registered as a pair sharing one implementation: `<name>` (tier `soak`, placement `cell`, default four hours) and `<name>-reduced` (tier `extended`, placement `either`, default twenty minutes).
  Rationale: Integration Point 3 gives a scenario exactly one tier, while every soak must be runnable locally at reduced duration and on a cell at full duration.
  Date: 2026-09-20

- Decision: The harness allocates a free TCP port for shibuya-metrics itself and never passes port 0.
  Rationale: `startMetricsServer` hands `config.port` to warp and echoes it back in `MetricsServer.serverPort`, so an operating-system-assigned port cannot be discovered, and a bind failure surfaces only on the server's `Async`.
  Date: 2026-09-20

- Decision: The kiroku adapter's crash replay budget is declared per subscription shape: `batchSize` for catch-up, category and consumer-group deliveries, and 1000 (`publisherBatchSize`) for the live phase of a non-group `AllStreams` subscription.
  Rationale: Verified in kiroku-store: the checkpoint is saved at the tail of each delivered batch, and live `AllStreams` batches come from the in-process publisher, which fetches up to 1000 events regardless of the subscription's `batchSize`. A flat "at most 100" budget would produce false failures.
  Date: 2026-09-20

- Decision: Use `shibuya/core-runner/correctness/invalid-config-rejected-before-effects` as the invalid-configuration scenario identifier.
  Rationale: The originally drafted name's final segment has 51 characters, while `Kenshou.Core.Id.mkSegment` enforces a 48-character limit. Shortening this one name preserves the kernel's established identifier contract.
  Date: 2026-09-23

- Decision: The `halt-wakes-idle-intake` handler waits until the adapter has entered its idle source pull, then allows 100 ms for the concurrent reader to block before returning `AckHalt`. The serial arm skips this gate because it cannot pull the next item while its single handler runs.
  Rationale: An immediate halt completed on both cohorts and did not force the interleaving that REV-4-F1 describes. With this gate, the released core times out and the pinned head completes; the verdict records source-idle reach, finalization, wait completion, and cleanup independently.
  Date: 2026-09-23

- Decision: Keep the existing full-runtime `released` cohort as a historical 0.9.0.3 regression baseline while testing Hackage 0.10.0.0 in `cohort/shibuya-current.project`. Treat the old `head` cohort as a pinned remediation comparison, not as the latest release.
  Rationale: The checked-in keiro 0.17 packages constrain Shibuya below 0.10, so the full cohort cannot be upgraded by changing one pin. The isolated project compiles the suite against the actual current release and its current PGMQ and kiroku adapters without bypassing keiro's declared bounds. A later full-runtime cohort refresh must update the wider dependency set or obtain a compatible keiro release.
  Date: 2026-09-23


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This repository, `keiro-runtime-kenshou`, is a verification suite for the keiro runtime, a cohort of Haskell libraries. It is driven by the MasterPlan `docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md`. This plan is child plan 10 and creates one cabal package, `kenshou-shibuya`, holding every scenario for the layer called `shibuya`. When this plan starts, the repository already contains what its hard dependencies deliver: the build and the pinned cohorts (`docs/plans/1-bootstrap-the-kenshou-repository-and-pin-the-runtime-cohort.md`), the harness kernel in `kenshou-core` and the `kenshou` executable in `kenshou-cli` (`docs/plans/2-build-the-harness-kernel-for-scenarios-dimensions-run-specs-and-results.md`), and the four toolkits `kenshou-measure`, `kenshou-check`, `kenshou-diagnose` and `kenshou-telemetry` (`docs/plans/4-build-the-measurement-toolkit-for-load-latency-sampling-and-comparison.md`, `docs/plans/5-build-the-correctness-toolkit-for-ledgers-invariants-faults-and-process-control.md`, `docs/plans/6-build-the-diagnostics-toolkit-for-memory-leaks-and-concurrency-stalls.md`, `docs/plans/7-add-telemetry-arms-and-measure-observability-overhead.md`). Those plans were drafted at the same time as this one; the Haskell in this plan that touches their types is written against the MasterPlan's Integration Points and is illustrative in its exact names. Before writing code, read the completed toolkit plans and use their signatures.

### What shibuya is, and the words this plan uses

An adapter is a record `Adapter es msg` with three fields: `adapterName`, `source` (a streamly stream of leased messages) and `shutdown` (an action that must make `source` end). A lease means the source has handed the message to this consumer and will not hand it to another for some time. Each stream element is an `Ingested es msg` carrying an `Envelope` (message id, optional partition key, optional zero-based `attempt`, optional trace headers, payload), an `AckHandle` whose single function `finalize :: AckDecision -> Eff es ()` tells the source the outcome, and an optional `Lease` with `leaseExtend`. A handler is `Message es msg -> Eff es AckDecision`. The four decisions are `AckOk` (done), `AckRetry (RetryDelay d)` (deliver again after `d`), `AckDeadLetter reason` (give up and park the message where operators can find it, the "dead-letter" destination) and `AckHalt reason` (stop this processor). Delivery is at-least-once everywhere: a message is never lost but may be delivered more than once, so handlers must be idempotent. The framework never retries or dead-letters by itself; the handler decides and the adapter's `finalize` performs it.

`Shibuya.App.runApp :: AppConfig -> [(ProcessorId, QueueProcessor es)] -> Eff es (Either AppError (AppHandle es))` starts one processor per entry and returns immediately; `waitApp` blocks until every processor is done; `stopAppGracefully :: ShutdownConfig -> AppHandle es -> Eff es Bool` calls every adapter's `shutdown`, waits up to `drainTimeout` (default 30 s) for in-flight work, force-stops the rest and returns whether the drain was clean; `stopApp` does the same with defaults. The `Tracing` effect is mandatory in the stack and is interpreted by `runTracing tracer` (on) or `runTracingNoop` (every operation short-circuits). `AppConfig` has `strategy` (`IgnoreFailures`, the default, or `StopAllOnFailure`, under which one processor's failure reaches the thread that called `runApp` as an asynchronous `ExceptionInLinkedThread` and stops the siblings) and `inboxSize` (default 100, must be at least 1). Inside a processor an ingester thread pulls `source` into a bounded inbox of `inboxSize` messages; a full inbox blocks the pull, which is the backpressure. A `QueueProcessor` also carries an `OrderingPolicy` (`StrictInOrder`, `PartitionedInOrder`, `Unordered`) and a `Concurrency` (`Serial`, `Ahead n`, `Async n`); `mkProcessor` defaults to `Unordered` and `Serial`. `StrictInOrder` with `Ahead` or `Async` is rejected. `PartitionedInOrder` with `Ahead n` or `Async n` runs through the keyed scheduler: at most `n` handlers, messages with the same `Just` partition key strictly first-in-first-out including their acknowledgement, a pending buffer of `2n` that blocks the reader when full. A `BatchingProcessor` groups messages by a `BatchKey` computed from the envelope, emits a batch at `batchSize` (default 100), after `batchTimeout` (default 1 s) or on drain, and resolves one decision per message from the `BatchAck` the batch handler returns. A handler that throws is finalized as `AckRetry (RetryDelay 0)`. A `finalize` that throws is retried with the same decision after 10 ms, 50 ms and 250 ms (four attempts, a constant in `Shibuya.Internal.Runner.Finalize`).

Head-of-line blocking means work that could proceed waits behind work that cannot. `SIGKILL` is the operating-system signal that ends a process with no chance to clean up; in this suite "crash" always means `SIGKILL` of a process or termination of a PostgreSQL backend, never a thrown exception. A ledger is an append-only file of facts ("message 17 handed to handler in process 3 at time t") written by every participating process and merged afterwards; an oracle is the exact rule that turns ledgers and database state into pass or fail. An invariant of class `contract` is promised by the component's documentation and blocks a release when broken; one of class `implementation` describes how the current code happens to behave and is reported without blocking. A known defect is a scenario outcome that is expected to fail because upstream already recorded the problem; it is reported, never hidden, and does not block. A cohort is the exact set of runtime package versions a build links: `released` is what services get from Hackage today, `head` replaces chosen components with pinned upstream commits.

### Where the code under test lives

All three repositories are read-only for this plan. Locate them with `mori registry show <project> --full` rather than searching the filesystem, and never read `/nix/store`.

Shibuya core and its metrics server are `mori://shinzui/shibuya` at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`, packages `shibuya-core` and `shibuya-metrics` (both 0.9.0.3) plus the unpublished `shibuya-core-bench`. Read `shibuya-core/src/Shibuya/App.hs`, `Policy.hs`, `Batch.hs`, `Core/Metrics.hs`, `Internal/Runner/Supervised.hs`, `Internal/Runner/KeyedScheduler.hs`, `Internal/Runner/Batcher.hs`, `Internal/Runner/Halt.hs`; `shibuya-metrics/src/Shibuya/Metrics/{Config,Server,Health,WebSocket,Prometheus}.hs`; `docs/architecture/CONCURRENCY.md`; and the audit under `docs/audits/lifecycle-release/` (`coverage.md`, `findings.json`, `performance-budgets.json`) with the reviews `docs/reviews/REV-1` to `REV-16`. The PGMQ adapter is `mori://shinzui/shibuya-pgmq-adapter` at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`, package `shibuya-pgmq-adapter` 0.16.0.0, modules `Shibuya.Adapter.Pgmq`, `.Config`, `.Convert` and the hidden `.Internal`. The kiroku adapter is `mori://shinzui/kiroku/packages/shibuya-kiroku-adapter` at `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/shibuya-kiroku-adapter`, version 0.5.1.2, modules `Shibuya.Adapter.Kiroku` and `.Convert`; the machinery it wraps is in `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Subscription/{Stream,Worker,EventPublisher,Types}.hs`. The PGMQ client is `mori://shinzui/pgmq-hs` at `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs` (0.6.1.0). One consequence of combining them: `shibuya-kiroku-adapter` bounds `effectful-core` below 2.7 and `shibuya-pgmq-adapter` requires `^>=2.6.1.0`, so this package solves to effectful-core 2.6.x, which the released cohort already pins.

Most of keiro does not use shibuya's runner — keiro's process-manager and router workers drain an adapter serially and finalize themselves, and only `keiro-pgmq` calls `runApp`. Shibuya's guarantees therefore have to be established here, at the shibuya layer, and cannot be inferred from the keiro layer.

### Historical remediation and the current release

The comparison below describes the historical 0.9.0.3 tag and the pinned remediation commit, both of which retain that version number. It predates the 0.10.0.0 Hackage release. The current released `shibuya-core` and `shibuya-metrics` are 0.10.0.0 at upstream tag `v0.10.0.0`; `cohort/shibuya-current.project` builds this suite with them and the latest released PGMQ and kiroku adapters. Every cohort-sensitive fix must also pass there. The older `released` cohort is now a regression baseline, not the latest release.

The Hackage release is tag `v0.9.0.3` (commit `7512b5c692af1c005392e4445cfa26a9be41f9ea`). The repository head on 2026-09-20 is `81501f8e9d073a34cfa2fe986403ce956255eb75`, still labelled version 0.9.0.3, and contains the unreleased commit `28a11e0` ("make lifecycle termination exception safe") followed by five performance commits: `37d547a` reworks the keyed scheduler, and `2a16c52`, `3095be3`, `a26d606` and `81501f8` rework the intake and halt wake-up path again, which is one more reason to re-verify the head rather than trust the fix commit. `shibuya-metrics` is byte-for-byte identical at the tag and at head. The head's CHANGELOG lists the breaking changes: `ShutdownConfig` gains `totalShutdownTimeout` (default 60 s; at the tag the record has only `drainTimeout`), `PolicyError` gains `InvalidConcurrency` and `ConcurrencyCapacityOverflow`, `ConfigError` gains `DuplicateProcessorId`, and exhausted finalization throws a new `ProcessorFailure` instead of being treated as a graceful halt. Because a record literal `ShutdownConfig {drainTimeout = 5}` compiles at the tag and is a missing-strict-field error at head, scenario code always writes `defaultShutdownConfig {drainTimeout = 5}`, which compiles on both. The upstream ledger `findings.json` still marks the fixed findings `open` because the upstream plan has not closed its last milestone; the code, not the ledger, is the truth, and these scenarios are how this repository checks it.

The findings split three ways, verified by reading both revisions. Present at the released tag and fixed only at head, so expressed here as a `KnownDefect` on the released core that must pass on head: REV-4-F1 (a handler's `AckHalt` in `Ahead`, `Async`, partitioned or batch mode does not wake an idle intake, because the halt flag was an `IORef` checked outside the blocking STM wait — the processor hangs until the next message arrives), REV-4-F2 (exhausted finalization is converted to a requested halt and reported as graceful completion, invisible under `StopAllOnFailure`), REV-5-F1 (a keyed worker's failure is returned only when the input ends, so an unending source defers it forever), REV-6-F1 (`Async 0` or a negative bound is accepted and removes the concurrency limit; the audit observed 20 simultaneous handlers), REV-2-F1 and REV-3-F1 (one throwing `adapter.shutdown` skips the remaining adapters and the supervisor cleanup), REV-2-F2 and REV-3-F2 (duplicate processor ids silently drop a handle), REV-2-C1 and REV-3-F3 (startup cancellation can leak the supervisor), and REV-2-A1 (no total shutdown deadline, so a blocking `shutdown` hangs `stopAppGracefully`). Open on both cohorts, so a `KnownDefect` everywhere: REV-7-F1, REV-8-F1, REV-8-F2, REV-9-F1, REV-9-F2, REV-9-F3 (metrics and health), REV-15-L1 (unbounded batch-key accumulators), REV-11-F1 (PGMQ adapter) and REV-13-F1 (kiroku adapter). Already fixed in 0.9.0.3 and kept as regression guards: REV-1-F1, REV-16-F1 and REV-16-F2 (garbage-collection liveness and single failure delivery).

Upstream references used as `KnownDefect` targets are the review records `mori://shinzui/shibuya/okf/reviews/concepts/REV-2` through `REV-9`, `REV-11`, `REV-13` and `REV-15`, with the finding key (for example `REV-4-F1`) in the note. The request that tracks the core and metrics fixes is `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-6`; the fix plans are `mori://shinzui/shibuya/plans/38-make-core-processor-ownership-and-termination-exception-safe`, `mori://shinzui/shibuya/plans/39-make-metrics-health-and-websocket-lifecycle-reporting-trustworthy`, `mori://shinzui/shibuya/plans/41-verify-pgmq-acknowledgement-and-dead-letter-recovery-under-faults` and `mori://shinzui/shibuya/plans/43-make-kiroku-subscription-ownership-exception-safe`, under `mori://shinzui/shibuya/masterplans/6-comprehensive-lifecycle-remediation-and-release-assurance`. The shibuya repository itself writes the review and request URIs in this form, but on 2026-09-20 the local Mori registry lags that repository: `mori registry concepts --id IR-6` and `--id REV-4` return nothing for shibuya (IR-1 to IR-5 do resolve), and `mori path` does not resolve plan or masterplan URIs. They are the intended canonical URIs and are used as written.

### The audit's matrix, reused

`docs/audits/lifecycle-release/coverage.md` in the shibuya repository defines fourteen in-scope lifecycle boundaries, each with five mandatory cases. The boundary identifiers in `findings.json` are `startup-registration`, `ingestion-backpressure`, `dispatch`, `keyed-ordering`, `batching`, `retry-lease`, `finalization`, `drain-cancel`, `supervision`, `metrics-health`, `metrics-websocket`, `kafka-persistence`, `pgmq-persistence` and `kiroku-persistence`. The case identifiers are `normal` (the ordinary successful path), `synchronousException` (a failure thrown by user, adapter or infrastructure code), `cancellation` (the operation is interrupted at an ownership boundary), `timeout` (the declared bounded wait is proven) and `repeatedStop` (a second stop or terminal signal is safe and duplicates no effect). This plan uses those strings verbatim and covers every boundary except `kafka-persistence`.

### Facts about the core, verified in source, that scenarios rely on

There is no processor restart. `docs/architecture/CONCURRENCY.md` says so under "Current Limitations", and supervision is used only for isolation: a failed or halted processor stays dead for the life of the `AppHandle`. Restarting is the application's loop, so this plan ships that loop as a fixture and tests it. When a handler returns `AckHalt`, intake stops, in-flight handlers finish, and the processor exits; the ingester is then cancelled and whatever sits in the inbox or in streamly's buffers is never finalized, so those messages stay leased until the source's lease expires. The most messages one processor can hold leased but unfinalized is, by reading `processUntilDrained`, about `inboxSize` plus `2n` (streamly's output buffer or the scheduler's pending buffer) plus `n` running handlers plus whatever the adapter prefetched; with the default inbox of 100 that number, multiplied by the handler time and divided by `n`, must stay below the source's lease or messages expire while merely queued. In a batching processor the bound does not hold at all: the batcher drains the inbox into `Map BatchKey Accum`, one accumulator per distinct key with no cap, so with high key cardinality both memory and the leased-but-unfinalized count grow with arrival rate times `batchTimeout`. In the keyed scheduler, `popStartable` scans the pending buffer for the first item whose key is idle; a hot key can fill all `2n` pending slots and then the reader blocks, stalling every other key.

Shibuya's in-process metrics cannot be switched off. `StreamStats.processed` counts `AckOk` and `AckRetry` alike (documented in `docs/architecture/METRICS.md`), `failed` counts `AckDeadLetter` and handler exceptions, and `AckHalt` counts as neither and sets the state to `Failed`. `Processing` carries the time the current burst began, not the last activity, so a processor under sustained concurrent load whose in-flight count never returns to zero looks "stuck" after `stuckThreshold` (REV-7-F1). A processor that exits unregisters from the metrics map, so `/health/ready` can answer ready with zero processors (REV-8-F1), and `/health/live` only proves a `TVar` can be read, so it answers alive after `stopMaster` (REV-8-F2). `shibuya-metrics` serves `GET /metrics`, `/metrics/:processorId`, `/metrics/prometheus` (families `shibuya_messages_received_total`, `shibuya_messages_processed_total`, `shibuya_messages_failed_total`, `shibuya_processor_state` with 1 idle, 2 processing, 3 failed, 4 stopped, and `shibuya_processor_in_flight`, label `processor`), `/health`, `/health/live`, `/health/ready` and a WebSocket at `/ws`. `MetricsServerConfig` defaults are `port = 9090`, `enableJSON`, `enablePrometheus` and `enableWebSocket` all `True`, `wsPushIntervalUs = 100_000`, `wsMaxConnections = 100`, `livenessTimeoutMicros = 1_000_000`, `stuckThreshold = 60`. The WebSocket handler acquires a connection slot and releases it only at the end of a `finally` block that first sends a `Goodbye` frame, so a send on an already closed connection skips the release (REV-9-F1), and `websocketsOr` accepts upgrades before the `enableWebSocket` flag is consulted (REV-9-F2).

### Facts about the PGMQ adapter

`pgmqAdapter :: PgmqAdapterEnv -> PgmqAdapterConfig -> Eff es (Either PgmqConfigError (Adapter es Value))` needs the `Pgmq`, `Error PgmqRuntimeError`, `IOE` and `Tracing` effects. A visibility timeout (VT) is PGMQ's lease: a read hides the row until `vt` and increments `read_ct`. `defaultConfig` gives `visibilityTimeout = 30`, `batchSize = 1`, `polling = StandardPolling {pollInterval = 1}` (the alternative `LongPolling {maxPollSeconds, pollIntervalMs}` holds a pool connection for the whole poll), `pollRetry` and `ackRetry` of five attempts with backoff from 0.1 s doubling to at most 5 s and only for transient errors, `deadLetterConfig = Nothing`, `haltVisibilityTimeout = Nothing`, `maxRetries = 3`, `fifoConfig = Nothing`, `prefetchConfig = Nothing` (`defaultPrefetchConfig` buffers 4 batches). `AckOk` deletes the row; `AckRetry d` sets the VT offset to `d` rounded up to whole seconds, so `RetryDelay 0` is immediately visible and sub-second delays become one second; `AckDeadLetter` archives when no dead-letter target is configured, and otherwise sends the dead-letter body and deletes the source row in one PostgreSQL transaction on `env.pool`; `AckHalt` parks the message for `haltVisibilityTimeout` or the VT. Before the handler ever runs, `mkIngested` dead-letters any message whose `readCount > maxRetries` with reason `MaxRetriesExceeded`, and `readCount` counts deliveries, not handler failures: crash redeliveries and lease expiries spend the budget. There is no lease heartbeat; a handler that outlives the VT must call `leaseExtend` itself. On `shutdown` the adapter releases the chunk it just read, but chunks already sitting in the prefetch buffer stay invisible until their VT expires (upstream finding REV-11-A1). A poll that exhausts `pollRetry` (about 1.5 s of waiting with the defaults) throws out of `source`, which kills the processor for good. REV-11-F1 is the concern that a commit whose confirmation is lost, followed by the acknowledgement retry, can write a second dead-letter copy. Queue tables are `pgmq.q_<queue>` and `pgmq.a_<queue>` with columns `msg_id`, `read_ct`, `enqueued_at`, `last_read_at`, `vt`, `message`, `headers`; queue names must match `[a-z0-9_]{1,47}`.

### Facts about the kiroku adapter

`kirokuAdapter :: KirokuStore -> KirokuAdapterConfig -> Eff es (Adapter es RecordedEvent)` wraps kiroku-store's ack-coupled `subscriptionAckStream`: the subscription worker hands over one event and blocks until the handler's decision arrives, so the effective in-flight depth is one per subscription or group member whatever concurrency the core is given. A checkpoint is the stored position a subscription resumes from; it lives in table `subscriptions` of schema `kiroku`, columns `subscription_name`, `consumer_group_member`, `last_seen`, written with `GREATEST` so it never moves backwards. `defaultKirokuAdapterConfig` gives `batchSize = 100`, `bufferSize = 256`, `queueCapacity = 16`, `consumerGroup = Nothing`, `missingCheckpointPolicy = FromBeginning`, all event types. `AckOk` continues and the checkpoint is saved only after the last event of the delivered batch; `AckRetry d` redelivers the same event after `d` with `attempt` incremented, and at five deliveries (`retryMaxAttempts`, not settable through the adapter, held in memory and reset by a restart) the event is dead-lettered; `AckDeadLetter` inserts into `kiroku.dead_letters` and advances the checkpoint in one statement; `AckHalt` cancels the subscription without advancing, so the event replays on restart. A consumer group is a static hash partition of streams over `size` members with no rebalancing (`mori://shinzui/kiroku/okf/adrs/concepts/ADR-2`); `kirokuConsumerGroupProcessors` builds one `PartitionedInOrder`/`Serial` processor per member named `<name>-member-<m>`; the startup guard that stops two processes from owning one member is left off by the adapter. REV-13-F1 is that group acquisition is not exception safe and can strand already-opened subscriptions.

### What exists upstream and what does not

Shibuya's 212 core examples use mocks in one process; `shibuya-metrics` has no test suite at all; the PGMQ adapter's chaos tests inject faults only at the effect level and never compete across processes; the kiroku adapter has no crash, outage or two-owners test. The only benchmarks are `shibuya-core-bench` (framework tax against streamly, concurrency sweeps, and the `lifecycle-load` executable whose scenario vocabulary — partitions `NoPartitions`, `UniformPartitions n`, `HotKeyPartitions n`, `HighCardinalityPartitions`; decisions `AllAckOk`, `RetryEvery n`, `DeadLetterEvery n` — this plan reuses for knob values), a PGMQ bench that never calls `pgmqAdapter` or `runApp`, an `endurance-test` executable judged on "memory growth below two times", and kiroku's `kiroku-shibuya-overhead`, which builds an inline adapter over the non-acknowledging `subscriptionStream` and so never measures the per-event acknowledgement round trip. No end-to-end adapter throughput or latency figure against a durable PostgreSQL exists anywhere.

### Contracts from the MasterPlan this plan relies on

Integration Point 1: the package is `kenshou-shibuya`, namespace `Kenshou.Suite.Shibuya.*`, with the evidence kinds as module subtrees `.Correctness.*`, `.Concurrency.*`, `.Soak.*`, `.Bench.*`; it depends on the kernel and toolkits and never on another layer package; `cabal.project` picks it up through the glob `kenshou-*/*.cabal`. Integration Point 2: `kenshou cohort show --json` prints the resolved cohort identity, which every run result embeds. Integration Point 3: scenario identifiers are `<layer>/<component>/<kind>/<name>` with layer `shibuya`, components `core-runner`, `core-ordering`, `core-batch`, `pgmq-adapter`, `kiroku-adapter`, `metrics`, and kinds `correctness`, `concurrency`, `soak`, `benchmark`; tiers are `smoke` (under one minute), `standard` (under ten), `extended` (under an hour), `soak` (hours); placement is `local`, `cell` or `either`; the package exports one `bundle :: LayerBundle`, registered by one import, one list element in `kenshou-cli/src/Kenshou/Cli/Registry.hs` and one `build-depends` entry in `kenshou-cli/kenshou-cli.cabal` — the only files outside the package this plan edits, besides `docs/layers/shibuya.md`, `policies/telemetry-overhead.json` and new ADRs. Integration Point 4: the dimensions are `telemetry.tracing` (`off`, `noop`, `sdk-inmemory`, `sdk-otlp`), `telemetry.metrics` (`off`, `collect`, `serve`, `serve-scraped`), `pg.durability` (`fsync-off`, `durable`; `durable` is mandatory for benchmarks and crash scenarios) and `pg.version` (`17`, `18`); knobs are named after the configuration fields they set; latency and throughput are always recorded in-process by the measurement toolkit, never through the feature being toggled. Integration Point 5: outcomes are `passed`, `failed`, `errored`, `inconclusive`, `infrastructure-failure`, and a run writes `verdicts/<checker>.json`, `samples/`, `series/` and `diagnosis/` under its run directory. Integration Point 7: a scenario asks the kernel for a `PostgresEnv` migrated with the components it names (`Pgmq` installs PGMQ 1.13 without the PostgreSQL extension; `Kiroku` installs the event store). Integration Point 8: crash scenarios run their workers as child processes of the same binary through `kenshou worker`, as named roles registered in the bundle, supervised by `Kenshou.Check.Process`.

From the toolkits this plan consumes: the latency recorder, closed-loop and open-loop load generators (open loop measures from the intended send time so that a stalled consumer cannot hide its own delay, the error known as coordinated omission), samplers and paired comparison from `Kenshou.Measure.*`; the ledger, the checkers (no loss, duplicates only inside declared crash windows and under a declared budget, per-key order, global order, exactly-N effects, eventual quiescence, monotonic checkpoints, disjoint ownership, SQL oracles), process control with `SIGKILL`, the PostgreSQL faults (terminate backends by `application_name`, stop and start the postmaster of a durable fixture), the in-process TCP proxy and the model-based helpers from `Kenshou.Check.*`; the leak verdict (a slope fitted to live bytes after major garbage collections, and to thread, descriptor and connection counts) and the stall watchdog from `Kenshou.Diagnose.*`; and `Kenshou.Telemetry.withTelemetry`, which yields a `Maybe Tracer`, in-memory exporter handles, an endpoint registrar for the scraper and a WebSocket subscriber.

### Architecture decisions

There is no local ADR corpus relevant to this plan yet: `docs/adr/` is created by `docs/plans/1-bootstrap-the-kenshou-repository-and-pin-the-runtime-cohort.md` as a profile-governed OKF bundle (OKF is a directory of Markdown files with YAML frontmatter validated by the `okf` tool). Scan its filenames before starting and read the records on layer isolation, cohort identity, crash semantics and invariant classes if they exist by then. Cross-repository decisions that shape this plan: `mori://shinzui/kiroku/okf/adrs/concepts/ADR-2` (consumer groups are static hash partitions) and `mori://shinzui/kiroku/okf/adrs/concepts/ADR-4` (checkpoint initialization is explicit; replay after a halt is intended) define what the kiroku adapter scenarios assert; `mori://shinzui/kiroku/okf/adrs/concepts/ADR-5` makes only structural checks and controlled paired workloads authoritative for performance, which is why benchmark verdicts here come from paired trials. The shibuya repository keeps its ADRs outside an OKF bundle, so the artifact-level URI is pending; the relevant records are in project `mori://shinzui/shibuya` at `docs/adr/0002-require-candidate-bound-machine-checkable-release-evidence.md` (the precedent for the boundary matrix and candidate-bound evidence) and `docs/adr/0003-make-processor-termination-and-shutdown-outcomes-explicit.md` (the head-only lifecycle semantics the cohort-sensitive scenarios expect).

Three decisions of this plan deserve new ADRs when implemented: cohort-sensitive known defects are decided by a capability probe of the linked library at registration time; layer code compiles unchanged against every cohort and never branches on runtime versions with the preprocessor; and the shibuya layer adopts the upstream audit's boundary and case vocabulary as its coverage contract. Allocate each handle with `okf id next docs/adr --profile docs/adr/profile.dhall ADR` and validate with `okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce`.


## Plan of Work

Every scenario below states its identifier, purpose, knobs, procedure, oracle with the invariant's class, tier, placement and the matrix cells it covers. Unless stated otherwise a scenario supports every value of `telemetry.tracing` and `telemetry.metrics`, has placement `either`, and a database scenario supports `pg.version` 17 and 18 (default 18) and both `pg.durability` values, except that crash, outage and benchmark scenarios support only `durable`. The shared core knobs are `shibuya.inbox-size` (integer, default 100, at least 1; `AppConfig.inboxSize`), `shibuya.concurrency` (text, default `serial`; `serial`, `ahead:<n>` or `async:<n>`, where the parser deliberately accepts zero and negative `n`), `shibuya.ordering` (`strict-in-order`, `partitioned-in-order`, `unordered`; default `unordered`), `shibuya.strategy` (`ignore-failures`, `stop-all-on-failure`; default `ignore-failures`), `shibuya.processor-kind` (`single`, `batch`; default `single`), `shibuya.drain-timeout-seconds` (decimal, default 30), `shibuya.messages` (integer), `shibuya.handler-delay-micros` (integer, default 0), `shibuya.partitions` (`none`, `uniform:<n>`, `hot-key:<n>`, `high-cardinality`; default `none`) and `shibuya.decisions` (`all-ok`, `retry-every:<n>`, `dead-letter-every:<n>`, `throw-every:<n>`; default `all-ok`).

### Milestone 1 — shibuya core lifecycle, ordering, batching and metrics-truthfulness scenarios (no database)

Scope: create the package, its shared modules and fixtures, and the twenty-nine scenarios of components `core-runner` (fifteen), `core-ordering` (four), `core-batch` (two) and `metrics` (eight) that need no PostgreSQL. At the end `kenshou list --layer shibuya` prints them, each runs with `kenshou run <id> --out runs`, the cohort-sensitive ones fail as known defects on the released cohort and pass on the head cohort, and `cabal test kenshou-shibuya-test` passes. Acceptance is the pair of transcripts in Concrete Steps.

Create `kenshou-shibuya/kenshou-shibuya.cabal` with `cabal-version: 3.4`, `default-language: GHC2024`, default extensions `OverloadedRecordDot`, `OverloadedStrings`, `DuplicateRecordFields`, `NoFieldSelectors`, `LambdaCase`, `-Wall`, a library over `src` and a test suite `kenshou-shibuya-test` (`hspec`, `hspec-hedgehog`, `-threaded`). Library dependencies: `kenshou-core`, `kenshou-measure`, `kenshou-check`, `kenshou-diagnose`, `kenshou-telemetry`, `shibuya-core`, `shibuya-metrics`, `effectful-core`, `streamly`, `streamly-core`, `stm`, `unliftio`, `async`, `aeson`, `text`, `bytestring`, `containers`, `time`, `random`, `network`, `http-client`, `websockets`, `hs-opentelemetry-api`; Milestones 2 and 3 add `shibuya-pgmq-adapter`, `pgmq-core`, `pgmq-hasql`, `pgmq-effectful`, `hasql`, `hasql-pool`, `hasql-transaction`, `shibuya-kiroku-adapter`, `kiroku-store`, `uuid`. No version bounds on runtime packages: the cohort's `constraints` pin them.

`kenshou-shibuya/src/Kenshou/Suite/Shibuya/Cohort.hs` holds the probe and the references.

```haskell
module Kenshou.Suite.Shibuya.Cohort where

import Data.Either (isLeft)
import Shibuya.Policy (Concurrency (..), OrderingPolicy (..), validatePolicy)

-- | Which lifecycle line of shibuya-core this binary was linked against.
data CoreLine = CoreReleased0903 | CoreLifecycleRemediated
  deriving stock (Eq, Show)

-- | Pure: the released core accepts Async 0, a remediated core rejects it.
coreLine :: CoreLine
coreLine
  | isLeft (validatePolicy Unordered (Async 0)) = CoreLifecycleRemediated
  | otherwise = CoreReleased0903

-- | Keep the reference only while linked against the released core.
knownOnReleasedCore :: KnownDefect -> Maybe KnownDefect
knownOnReleasedCore d = case coreLine of
  CoreReleased0903 -> Just d
  CoreLifecycleRemediated -> Nothing

rev :: Int -> Text -> KnownDefect -- review N, finding key in the note, IR-6 and the fix plan cited
```

Every scenario also writes `coreLine` and the resolved versions of `shibuya-core`, `shibuya-metrics` and both adapters into its report, so a reader of a run directory sees which line produced the verdict. If a known-defect scenario unexpectedly passes on the released core, the outcome is `passed` with the note "known defect did not reproduce", which is a prompt to re-examine the reference, not an error.

`Kenshou/Suite/Shibuya/Knobs.hs` declares the knob specifications above and the parsers `parseConcurrency`, `parseOrdering`, `parseStrategy`, `parsePartitions`, `parseDecisions :: Text -> Either Text _`, with hedgehog round-trip properties. `Kenshou/Suite/Shibuya/Matrix.hs` declares `data Boundary` (thirteen constructors rendered with the audit's identifiers), `data LifecycleCase` (`Normal`, `SynchronousException`, `Cancellation`, `Timeout`, `RepeatedStop`, rendered `normal`, `synchronousException`, `cancellation`, `timeout`, `repeatedStop`), `type Cell = (Boundary, LifecycleCase)`, a table `cellsOf :: ScenarioId -> [Cell]` and `uncovered :: [(Cell, Text)]` giving a reason for each cell no black-box scenario can reach (for example `startup-registration/timeout`: startup has no bounded wait). The unit test `MatrixSpec` fails unless all sixty-five cells appear in exactly one of the two.

`Kenshou/Suite/Shibuya/Fixture/SyntheticAdapter.hs` is an in-memory broker with leases, built only from shibuya's public `Adapter`, `Ingested`, `AckHandle` and `mkEnvelope`.

```haskell
data FinalizerOutcome = FinalizeSucceeds | FinalizeThrows !Text
data ShutdownBehaviour = ShutdownEndsSource | ShutdownThrows !Text | ShutdownBlocksForever

data SyntheticConfig = SyntheticConfig
  { leaseSeconds :: !(Maybe NominalDiffTime)             -- Nothing: leases never expire
  , finalizerScript :: !(MessageId -> Int -> FinalizerOutcome) -- by finalize attempt, from 1
  , shutdownBehaviour :: !ShutdownBehaviour
  , sourceFault :: !(Maybe (Int, Text))                  -- throw from `source` after N yields
  }

newSyntheticBroker :: SyntheticConfig -> LedgerWriter -> IO SyntheticBroker
publish :: SyntheticBroker -> Maybe Text -> ByteString -> IO MessageId -- partition key, payload
closeInput :: SyntheticBroker -> IO ()      -- the source ends once drained; otherwise it idles forever
syntheticAdapter :: (IOE :> es) => SyntheticBroker -> Adapter es ByteString

data BrokerStats = BrokerStats
  { published, yielded, sourcePulls, finalizedOk, retried, deadLettered, halted
  , redeliveries, shutdownCalls, leasedUnfinalized, leasedUnfinalizedHighWater :: !Int }
brokerStats :: SyntheticBroker -> IO BrokerStats
```

The broker redelivers a message after `AckRetry d` once `d` has elapsed with `attempt` incremented, redelivers any message still unfinalized when its lease expires, records every yield, handler start, handler end and `finalize` call (with attempt number and thread) in the ledger, and makes a second effective `finalize` of one delivery visible as a fact. `Fixture/Handlers.hs` provides scripted handlers (decision by script, fixed or seeded delay, a gate the scenario opens, a concurrent-handler high-water mark). `Fixture/App.hs` provides `runTracingArm :: (IOE :> es) => TelemetryHandles -> Eff (Tracing : es) a -> Eff es a` (`off` maps to `runTracingNoop`; `noop` maps to `runTracing` with a tracer from a provider that has no span processors, which exercises the enabled code path with non-recording spans; the two SDK values map to `runTracing` with the toolkit's tracer) and `withMetricsArm :: TelemetryHandles -> MetricsKnobs -> Master -> IO a -> IO a` (`off` and `collect` start nothing and are recorded as identical for shibuya, whose counters cannot be disabled; `serve` calls `startMetricsServer` on a port found by binding port 0 on a probe socket, closing it and retrying up to five times if the server's `Async` has already failed, then waits for `GET /health/live` to answer; `serve-scraped` also registers `/metrics`, `/metrics/prometheus` and `/health/ready` with the toolkit's scraper; knob `shibuya-metrics.ws-subscribers`, default 0, attaches that many WebSocket subscribers at `shibuya-metrics.ws-push-interval-us`, default 100000). `Fixture/RestartLoop.hs` is the application-level restart the framework does not have.

```haskell
data RestartPolicy = RestartPolicy { initialBackoff, maxBackoff :: !NominalDiffTime, maxRestarts :: !(Maybe Int) }

-- | Build adapters, runApp, waitApp; when every processor is done (finished, halted or
-- failed) stop the app, back off and start again. Keys on waitApp returning, never on an
-- exception, because the released core reports some failures as graceful completion.
runWithRestartLoop ::
  (IOE :> es, Tracing :> es) =>
  RestartPolicy -> STM Bool {- stop requested -} -> (Int -> Eff es [(ProcessorId, QueueProcessor es)]) -> AppConfig -> Eff es Int
```

`Kenshou/Suite/Shibuya/Roles.hs` registers the worker roles: `shibuya-core-worker` (runs a synthetic-broker application described by the role's JSON arguments, reporting facts over the control channel, so that soak sampling sees only the system under test) and `shibuya-gc-probe`. `Kenshou/Suite/Shibuya.hs` exports `bundle :: LayerBundle` with `layer = "shibuya"`.

The `core-runner` scenarios.

`shibuya/core-runner/correctness/every-delivery-is-finalized-exactly-once` proves the basic promise across configurations. Knobs: the shared core knobs, `shibuya.messages` default 10000. Procedure: publish, close the input, `runApp`, `waitApp`. Oracle (contract): every delivery has exactly one effective `finalize`; a throwing handler's delivery is finalized `AckRetry (RetryDelay 0)`; `StreamStats.received` equals deliveries; with `shibuya.inbox-size=1` the run still completes (backpressure liveness). Tier smoke. Cells: `dispatch/normal`, `finalization/normal`, `ingestion-backpressure/normal`, `dispatch/synchronousException`, `retry-lease/normal`.

`shibuya/core-runner/correctness/invalid-config-rejected-before-effects` feeds `inboxSize` 0, `StrictInOrder` with `Async 2`, a batching processor with `PartitionedInOrder` and `Ahead 2`, and batch configurations with size 0, timeout 0 and tick 0. Oracle (contract): `runApp` returns `Left`, `sourcePulls` and `shutdownCalls` stay 0. Tier smoke. Cells: `startup-registration/normal`, `startup-registration/synchronousException`.

`shibuya/core-runner/correctness/duplicate-processor-ids-are-rejected` starts two processors, one ordinary and one batching, under one id. Oracle (contract): the result is `Left` (tested with `isLeft`, since the constructor is head-only) and neither source is pulled. Known defect on the released core: REV-3, keys REV-2-F2 and REV-3-F2. Tier smoke. Cell: `startup-registration/synchronousException`.

`shibuya/core-runner/correctness/nonpositive-concurrency-is-rejected` runs 40 messages through a 200 ms handler for each of `async:0`, `async:-1`, `ahead:0`. Oracle (contract): either `runApp` returns `Left` before any pull, or the concurrent-handler high-water mark is at most 1. Known defect on the released core: REV-6, key REV-6-F1. Tier smoke. Cell: `dispatch/synchronousException`.

`shibuya/core-runner/concurrency/halt-wakes-idle-intake` is the headline cohort scenario. Knobs: `shibuya.concurrency`, `shibuya.ordering`, `shibuya.processor-kind`, `shibuya.halt-deadline-ms` (integer, default 2000). Procedure: the broker yields exactly one message and then idles without ending; the handler returns `AckHalt (HaltFatal "kenshou")`; the scenario calls `waitApp` under the deadline, with the stall watchdog armed so that a hang leaves a thread dump in `diagnosis/`. Oracle (contract): `waitApp` returns within the deadline in every mode. On the released core `serial` passes and every other mode hangs. Known defect on the released core: REV-4, key REV-4-F1. The plan-level matrix runs `serial`, `ahead:4`, `async:4`, `partitioned-in-order` with `async:4`, and `batch`. Tier smoke. Cells: `dispatch/timeout`, `keyed-ordering/timeout`, `batching/timeout`.

`shibuya/core-runner/concurrency/finalization-failure-is-a-failure-not-a-halt`. Knobs: `synthetic.finalizer-failures` (integer, default -1 meaning permanent; 1 to 3 mean transient), `shibuya.strategy`. Procedure: two processors, A's finalizer fails per the script for one message, B runs an idle unending source; `runApp` is called from a dedicated thread so that an exception linked to the caller can be observed and counted. Oracle for transient failures (contract): processing continues and the delivery has one effective `finalize` with the same decision on every attempt; (implementation) attempts are separated by at least 10, 50 and 250 ms. Oracle for a permanent failure under `stop-all-on-failure` (contract): the thread that called `runApp` receives exactly one asynchronous exception whose rendering contains `ExceptionInLinkedThread`, within 2 s of the fourth attempt, and B stops. On the released core no exception arrives, `waitApp` for A returns normally and B keeps running. Known defect on the released core: REV-4, key REV-4-F2. Tier smoke. Cells: `finalization/synchronousException`, `finalization/timeout`, `supervision/synchronousException`.

`shibuya/core-runner/concurrency/adapter-shutdown-failure-does-not-skip-siblings` runs three processors whose first adapter's `shutdown` throws, then calls `stopAppGracefully` from eight threads at once. Oracle (contract): every adapter's `shutdownCalls` is at least 1, the original exception reaches each caller, and within 1 s of the call returning no source is still being pulled; (implementation) each `shutdownCalls` equals exactly 1. Known defect on the released core: REV-3, keys REV-2-F1 and REV-3-F1. Tier smoke. Cells: `drain-cancel/synchronousException`, `drain-cancel/repeatedStop`, `ingestion-backpressure/repeatedStop`, `dispatch/repeatedStop`, `finalization/repeatedStop`, `supervision/repeatedStop`.

`shibuya/core-runner/concurrency/blocking-adapter-shutdown-is-bounded` uses `ShutdownBlocksForever`. Oracle (contract): `stopAppGracefully` returns within 60 s plus 5 s, the default total deadline on a remediated core, which cannot be shortened without the head-only field. On the released core it never returns; the scenario gives up at 70 s. Known defect on the released core: REV-2, key REV-2-A1. Tier standard. Cell: `drain-cancel/timeout`.

`shibuya/core-runner/concurrency/forced-shutdown-abandons-but-never-loses` blocks handlers on a gate, sets `shibuya.drain-timeout-seconds=1` and `synthetic.lease-seconds=3`, stops the application and then runs the restart loop. Oracle (contract): `stopAppGracefully` returns `False` within 1 s plus slack; no `finalize` fact is recorded after it returns; every published message is eventually finalized `AckOk`; duplicates are confined to deliveries in flight at the stop. Tier smoke. Cells: `dispatch/cancellation`, `finalization/cancellation`, `drain-cancel/normal`, `drain-cancel/cancellation`, `ingestion-backpressure/timeout`, `retry-lease/timeout`.

`shibuya/core-runner/concurrency/startup-cancellation-leaks-nothing` cancels the thread calling `runApp` at a seeded random delay in 500 iterations, then performs 200 rapid start-and-stop cycles. Oracle (contract): one second after each cancellation `sourcePulls` has stopped increasing, and the Haskell thread count returns to its baseline at the end. Known defect on the released core: REV-3, keys REV-2-C1 and REV-3-F3; the upstream evidence is source-only, so "did not reproduce" is an acceptable released result. Tier standard. Cells: `startup-registration/cancellation`, `startup-registration/repeatedStop`.

`shibuya/core-runner/correctness/a-failed-processor-is-never-restarted` makes the source throw after `synthetic.fail-after` messages (default 100) under `ignore-failures`. Oracle part one (implementation, the documented limitation): for `observe-seconds` (default 5) `sourcePulls` stays constant and `waitApp` has returned. Oracle part two (contract): under `runWithRestartLoop` every published message is finalized `AckOk`, with duplicates only among deliveries unfinalized at the failure. Tier smoke. Cells: `ingestion-backpressure/synchronousException`, `supervision/normal`.

`shibuya/core-runner/concurrency/halt-strands-leased-messages` floods 1000 messages with `shibuya.inbox-size=100`, halts on the tenth, and uses `synthetic.lease-seconds=5`. Oracle (contract): after the lease expires and the restart loop runs, every message is finalized — none is lost; (implementation) the number of deliveries leased but never finalized at processor exit, reported as the figure `strandedAtHalt`, is at most `inboxSize + 3n + 2`. The report states the operational meaning: a halt delays up to that many messages by one full lease. Tier smoke. Cell: `ingestion-backpressure/cancellation`.

`shibuya/core-runner/concurrency/leased-but-unfinalized-upper-bound` blocks all handlers on a gate against an unlimited source and reads `leasedUnfinalizedHighWater` once pulls have been quiet for 500 ms. Oracle (implementation): the high-water mark is at most `inboxSize + 3n + bound.slack` (`bound.slack` default 2) for `single` processors; for `batch` processors only the figure is reported, because the accumulators are unbounded. Tier smoke. Cell: `ingestion-backpressure/normal`.

`shibuya/core-runner/concurrency/stop-all-on-failure-delivers-once` and `shibuya/core-runner/concurrency/gc-liveness-with-dropped-handle` are regression guards for defects fixed in 0.9.0.3 and must pass on both cohorts. The first throws from processor A's source: under `stop-all-on-failure` the caller receives exactly one `ExceptionInLinkedThread` and B stops, under `ignore-failures` B completes, and a finite stream's end or an `AckHalt` in A never stops B (contract). The second runs in the `shibuya-gc-probe` child process, because reachability tests are only valid when nothing else retains the handle: the application finishes, halts or fails, the handle is dropped, `performMajorGC` runs 50 times, and the role must exit 0 without `ExceptionInLinkedThread` or `BlockedIndefinitelyOnSTM` in its log (contract). Tier smoke. Cells: `supervision/synchronousException`, `supervision/cancellation`, `supervision/timeout`.

The `core-ordering` scenarios.

`shibuya/core-ordering/correctness/policy-matrix` runs every valid pair of `shibuya.ordering` and `shibuya.concurrency` with `shibuya.partitions=uniform:16` and a seeded handler delay. Oracle (contract): `strict-in-order` gives handler starts and finalizations in source order; `partitioned-in-order` gives, per `Just` key, handler intervals that never overlap and occur in source order with finalizations in the same order, while `Nothing`-keyed messages are unconstrained; every concurrent mode keeps the handler high-water mark at most `n` and, for non-vacuity, above 1. Tier smoke. Cells: `dispatch/normal`, `keyed-ordering/normal`.

`shibuya/core-ordering/concurrency/keyed-scheduler-model` is model-based: seeded random key distributions, handler delays, decisions, handler exceptions and a graceful stop at a random instant, checked against a pure model of per-key queues with the correctness toolkit's support. Oracle (contract): per-key order and non-overlap, global running at most `n`, exactly one effective `finalize` per delivery, and no delivery started after the stop returned. The seed and the shrunk counter-example go into the verdict so `kenshou run --seed` replays it. Knob `model.cases` default 200. Tier standard. Cells: `keyed-ordering/synchronousException`, `keyed-ordering/cancellation`, `keyed-ordering/repeatedStop`.

`shibuya/core-ordering/concurrency/hot-key-head-of-line` runs `partitioned-in-order` with `async:4`, a hot key whose handler takes 100 ms interleaved with 63 cold keys whose handler takes 1 ms, and a control run without the hot key. Oracle (contract): per-key order holds, nothing is lost, and cold keys keep progressing (no cold message waits longer than `hol.starvation-seconds`, default 30); (implementation) the figure `headOfLineFactor`, cold-key p99 time from publish to handler start divided by the control's, is reported, and above `hol.alert-factor` (default 10) the report recommends filing an upstream improvement request. No upstream record exists for this behaviour today. Tier smoke.

`shibuya/core-ordering/concurrency/keyed-worker-failure-stops-intake` is the one scenario that imports `Shibuya.Internal.Runner.KeyedScheduler`. It calls `runKeyedScheduler 4 8 key action stream` over an unending stream whose first item throws. Oracle (implementation — the review bounds production reachability, since the runner normally translates handler and finalizer exceptions): the call rethrows within 1 s and at most 12 successors start after the failure. Known defect on the released core: REV-5, key REV-5-F1. Tier smoke. Cell: `keyed-ordering/synchronousException`.

The `core-batch` scenarios.

`shibuya/core-batch/correctness/conservation-triggers-and-decisions`. Knobs: `shibuya.batch.size` (default 100), `shibuya.batch.timeout-ms` (default 1000), `shibuya.batch.tick-interval-ms` (optional), `shibuya.batch.key-cardinality` (default 1), `shibuya.concurrency`. Oracle (contract): every message appears in exactly one batch; order within a key is preserved inside and across batches; a `TriggerSize` batch holds exactly `batchSize`; a `TriggerTimeout` batch is emitted no later than timeout plus tick plus 100 ms after its first message; the end of input flushes with `TriggerFlush`; ids missing from `BatchAck.decisions` receive `fallback`; a throwing batch handler finalizes every member `AckRetry (RetryDelay 0)`; batches sharing a key never overlap under `ahead` or `async`; each delivery has one effective `finalize`. Tier smoke. Cells: `batching/normal`, `batching/synchronousException`.

`shibuya/core-batch/concurrency/shutdown-with-partial-batches` stops the application while batches are accumulating, once with a generous and once with a tiny drain timeout, and calls stop twice. Oracle (contract): with a generous timeout every partial batch is flushed and finalized before the stop returns `True`; with a tiny timeout no `finalize` is recorded after the stop returns; the second stop is harmless. Tier smoke. Cells: `batching/cancellation`, `batching/repeatedStop`, `retry-lease/cancellation`.

The `metrics` scenarios. All of them start shibuya-metrics regardless of the `telemetry.metrics` dimension, because the server is the subject, so they declare support for `serve` and `serve-scraped` only. Each is a known defect on both cohorts unless noted, and each keeps a control check that the truthful case is reported truthfully so that the scenario is not vacuous.

`shibuya/metrics/correctness/endpoint-contract` is the black-box suite the package lacks (REV-8-L2): every route's status and shape, 404 for an unknown processor, the five Prometheus families and the state encoding, and that `enableJSON=False` and `enablePrometheus=False` turn their routes into 404. Oracle (contract); passes on both cohorts. Tier smoke. Cell: `metrics-health/normal`.

`shibuya/metrics/correctness/counters-distinguish-retries-from-success` drives one processor whose every delivery ends `AckRetry` and one whose every delivery ends `AckOk`. Oracle part one (implementation, the documented mapping): `processed` counts `AckOk` and `AckRetry`, `failed` counts `AckDeadLetter` and exceptions, `AckHalt` counts as neither. Oracle part two (contract of truthfulness): the two processors must be distinguishable through `/metrics/prometheus`; they are not, so this fails. Known defect: REV-7, key REV-7-A2 (counters describe decisions, not outcomes); no upstream request asks for a separate retry counter, so Milestone 4 files one and replaces the reference. Tier smoke. Cell: `metrics-health/normal`.

`shibuya/metrics/correctness/ready-not-stuck-under-sustained-load` sets `shibuya-metrics.stuck-threshold-seconds=3` and keeps `async:8` handlers busy for 10 s so the in-flight count never reaches zero. Oracle (contract): `/health/ready` answers 200 throughout, and a control processor whose handler really blocks for 10 s is reported stuck. Known defect: REV-7, key REV-7-F1. A second verdict in the same run checks that one handler exception under this load does not leave readiness at 503 once processing continues; source reading suggests the `Failed` state is sticky while in-flight stays above zero, there is no upstream record, and a failure here is filed upstream in Milestone 4. Tier smoke. Cell: `metrics-health/timeout`.

`shibuya/metrics/correctness/ready-reflects-a-failed-processor` fails a processor's source and polls `/health/ready`. Oracle (contract): readiness is not 200 while a configured processor has failed. Known defect: REV-8, key REV-8-F1. `shibuya/metrics/correctness/live-reflects-a-stopped-master` calls `stopApp` and polls `/health/live`. Oracle (contract): liveness is not 200 after the master stopped. Known defect: REV-8, key REV-8-F2. Both tier smoke. Cells: `metrics-health/synchronousException`, `metrics-health/cancellation`, `metrics-health/repeatedStop`.

`shibuya/metrics/concurrency/websocket-slot-accounting` sets `shibuya-metrics.ws-max-connections=8`, then opens and closes three times that many connections in each of three ways — a clean close frame, an abrupt socket close, and a close before the first frame is read — and finally opens one more. Oracle (contract): the final connection is accepted, and thread and descriptor counts return to baseline. Known defect: REV-9, key REV-9-F1. Tier smoke. Cells: `metrics-websocket/normal`, `metrics-websocket/synchronousException`, `metrics-websocket/cancellation`, `metrics-websocket/repeatedStop`.

`shibuya/metrics/correctness/websocket-flag-gates-upgrades` starts the server with `enableWebSocket=False`. Oracle (contract): an upgrade request to `/ws` is refused. Known defect: REV-9, key REV-9-F2. `shibuya/metrics/correctness/websocket-unsubscribe-all-suppresses-updates` subscribes to all, unsubscribes from every processor, and keeps traffic flowing. Oracle (contract): no `update` frame arrives for 2 s. Known defect: REV-9, key REV-9-F3. Both tier smoke. Cell: `metrics-websocket/timeout`.

### Milestone 2 — PGMQ adapter scenarios

Scope: the eleven scenarios of component `pgmq-adapter` against a real PostgreSQL, with worker processes, real `SIGKILL`, backend termination, postmaster restarts and the network proxy. At the end they pass, or fail as the documented known defect, on `pg.version` 17 and 18 with `pg.durability=durable`.

`Kenshou/Suite/Shibuya/Fixture/Pgmq.hs` requests a `PostgresEnv` with component `Pgmq`, derives per-run queue names `ks_<8 hex digits of the run id>_<suffix>` (within PGMQ's `[a-z0-9_]{1,47}` rule), builds `hasql-pool` pools either directly or through the correctness toolkit's TCP proxy with `application_name` set per role, runs the stack as `runEff . runError @PgmqRuntimeError . runTracingArm handles . pgmqArm pool` (where `pgmqArm` is `runPgmq` for tracing `off` and `runPgmqTraced pool tracer` otherwise), and exposes SQL oracles: `queueRows`, `archiveRows`, `dlqCopiesByOriginalId` (from `message->>'original_message_id'`, which requires `includeMetadata = True`) and `readCounts`. Handlers record their effect by inserting `(msg_id, delivery_read_ct, process, at)` into a table `kenshou_effects` created by the fixture, which is the durable truth for "the handler succeeded". Knobs, named after `PgmqAdapterConfig`: `pgmq-adapter.visibility-timeout-seconds` (default 30), `pgmq-adapter.batch-size` (default 1), `pgmq-adapter.polling` (`standard:<seconds>` or `long:<maxPollSeconds>:<pollIntervalMs>`, default `standard:1`), `pgmq-adapter.max-retries` (default 3), `pgmq-adapter.prefetch-buffer-size` (default 0 meaning off; 4 is upstream's `defaultPrefetchConfig`), `pgmq-adapter.fifo-read-strategy` (`none`, `throughput-optimized`, `round-robin`, `head-per-group`; default `none`), `pgmq-adapter.dead-letter` (`archive`, `direct-queue`, `topic-route`; default `archive`), `pgmq-adapter.halt-visibility-timeout-seconds` (optional), `pgmq-adapter.pool-size` (default 10), `pgmq-adapter.lease-extend` (`off`, `on`; default `off`) and `workers` (default 1). Roles: `shibuya-pgmq-consumer` runs `pgmqAdapter` under `runWithRestartLoop` and can pause at a named gate (`after-effect-before-return`) until the harness answers; `shibuya-pgmq-producer` sends at a given open-loop rate with sequence numbers and an `x-pgmq-group` header when FIFO is on.

`shibuya/pgmq-adapter/correctness/ack-decision-mapping`. Oracle (contract): `AckOk` removes the row; `AckRetry d` leaves it with `vt` within one second of now plus `d` rounded up to whole seconds, `RetryDelay 0` makes it readable at once, and the redelivery has `read_ct` one higher and `attempt = read_ct - 1`; `AckDeadLetter` with `archive` moves the row to `pgmq.a_<queue>`; with `direct-queue` or `topic-route` the dead-letter body carries `original_message`, `dead_letter_reason`, `dead_letter_reason_code`, `dead_letter_reason_detail` and the metadata keys, and the source row is gone; `AckHalt` sets `vt` to now plus the halt timeout and ends the processor; an invalid configuration returns the matching `PgmqConfigError`. Tier smoke. Cells: `pgmq-persistence/normal`, `retry-lease/normal`.

`shibuya/pgmq-adapter/correctness/auto-dead-letter-counts-deliveries`. Procedure A: a handler that always answers `AckRetry 0`. Oracle (contract): the handler runs at most `maxRetries` times, the message reaches the dead-letter destination exactly once with code `max_retries_exceeded`, and `onAutoDeadLetter` fires once. Procedure B: before the adapter starts, the fixture reads the message `maxRetries + 1` times with a raw `pgmq.read` and a one-second VT, so no handler ever failed. Oracle (implementation, the documented hazard): the handler is never invoked and the message is dead-lettered. With `pgmq-adapter.max-retries=0` every message is dead-lettered unseen. Tier smoke. Cell: `pgmq-persistence/timeout`.

`shibuya/pgmq-adapter/correctness/shutdown-latency-is-bounded-by-polling` stops an idle application. Oracle (contract): `stopAppGracefully` returns `True` within the poll interval, or `maxPollSeconds` for long polling, plus one second; the figure is recorded. Tier smoke. Cell: `pgmq-persistence/repeatedStop`.

`shibuya/pgmq-adapter/concurrency/sigkill-between-handler-success-and-ack` is the crash window nobody tests today. Procedure: the consumer role inserts its effect row, reports `effect-done <msg_id>` and waits at the gate; the harness sends `SIGKILL` at that instant for `kills` messages (default 20) and lets the rest pass; the role is restarted each time; a second variant kills at seeded random instants instead. Oracle (contract): every message has at least one effect row; duplicate effects exist only for messages in flight at a kill and number at most the kills that hit that message; each redelivery begins no later than the VT plus the poll interval plus two seconds after the killed read, which is the "one visibility timeout" duplicate window; (implementation) each redelivery's `read_ct` is one higher, and a message killed `maxRetries` times is dead-lettered although its handler never failed — reported as `budgetBurnedByCrashes`. Knobs include `pgmq-adapter.visibility-timeout-seconds` default 5 here. `durable` only. Tier standard. Cells: `pgmq-persistence/cancellation`, `finalization/cancellation`.

`shibuya/pgmq-adapter/concurrency/multi-process-competition` runs `workers=4` consumer processes and a producer on one queue. Oracle (contract): from the merged lease ledger no message has two overlapping handler intervals (handler time is far below the VT, so none can legitimately expire), nothing is lost, and the queue drains; the per-process share is reported. With `pgmq-adapter.fifo-read-strategy=head-per-group` the per-group order of effects holds across processes and across an injected `AckRetry` (contract, the adapter's documented barrier); with `throughput-optimized` or `round-robin`, `pgmq-adapter.batch-size` above 1 and `async:4`, order inversions are counted and reported as the documented limitation (implementation). Tier standard. Cell: `pgmq-persistence/normal`.

`shibuya/pgmq-adapter/concurrency/handler-outlives-visibility-timeout` uses a 2 s VT, a 5 s handler and two consumer processes. Oracle with `pgmq-adapter.lease-extend=off` (implementation, documenting that there is no heartbeat): at least one message shows overlapping handler intervals in two processes and none is lost. Oracle with `on`, where the handler calls `leaseExtend` every third of the VT (contract): no overlapping intervals at all. Tier smoke. Cells: `retry-lease/timeout`, `retry-lease/synchronousException`.

`shibuya/pgmq-adapter/concurrency/leased-bound-versus-visibility-timeout` turns the core's bound into sizing evidence. Procedure: compute `pipelineSeconds = (inboxSize + 3n + prefetchBufferSize × batchSize) × handlerSeconds / n`; run an unsafe configuration (VT 5 s, inbox 100, `async:4`, prefetch 4 × batch 10, 200 ms handler, giving about 7.6 s) and the default-shaped safe one (VT 30 s). Oracle (contract): nothing is lost in either; in the safe configuration, with no fault injected, duplicate effects are zero; (implementation) the unsafe configuration's duplicates are reported as `expiredWhileQueued` together with the longest observed time between read and handler start. Tier standard. Cell: `ingestion-backpressure/timeout`.

`shibuya/pgmq-adapter/concurrency/prefetch-strands-until-visibility-timeout` stops an application running with batch 2, buffer 4 and a 400 ms handler, then restarts it. Oracle (contract): nothing is lost and every message is eventually processed; (implementation, upstream's accepted assumption REV-11-A1) the rows read but neither handled nor released number at most `bufferSize × batchSize` plus one chunk, each becomes readable again no later than one VT after the stop, and each returns with `read_ct` one higher; the control without prefetch shows the undispatched chunk readable immediately. Tier smoke. Cell: `pgmq-persistence/repeatedStop`.

`shibuya/pgmq-adapter/concurrency/dead-letter-move-is-atomic` dead-letters 10000 messages to a direct queue while the PostgreSQL fault injector terminates the consumer's backends at seeded instants, then repeats with the proxy resetting the client connection immediately after forwarding a frame that contains `COMMIT` (if the proxy of `docs/plans/5-build-the-correctness-toolkit-for-ledgers-invariants-faults-and-process-control.md` offers no byte-pattern trigger, inject resets at random and raise the message count). Oracle one (contract): sampled every 200 ms and at the end, every message id is in exactly one of the source queue and the dead-letter queue. Oracle two (contract): dead-letter copies per original id are at most one. Oracle two is the known defect: REV-11, key REV-11-F1, fix plan 41, on both cohorts. Tier standard. Cell: `pgmq-persistence/synchronousException`.

`shibuya/pgmq-adapter/concurrency/postgres-outage-and-the-restart-loop` injects, while a producer and consumer are active, the fault chosen by knob `outage.fault`: `terminate-backends` (the consumer's backends are terminated once, a transient error) or `postmaster-restart` (the default: the postmaster of the durable fixture is stopped for `outage-seconds`, default 10), once during polling and once with the gate holding a message at its acknowledgement. Oracle (contract): with the restart loop, every message is processed and duplicates are confined to deliveries in flight at the fault; with `terminate-backends` the fault is absorbed by `pollRetry` and `ackRetry` and no processor exits, while the ten-second restart exhausts the poll budget, ends `source` and is recovered only by the restart loop. Second verdict (contract): when the acknowledgement cannot be written for longer than the retry budgets, under `stop-all-on-failure` the caller is told with an exception; on the released core the processor ends as if halted and no exception arrives, which is REV-4-F2 seen through a real adapter and is why the restart loop keys on `waitApp`. Known defect for the second verdict on the released core: REV-4, key REV-4-F2. `durable` only. Tier standard. Cells: `pgmq-persistence/synchronousException`, `supervision/synchronousException`.

`shibuya/pgmq-adapter/concurrency/long-poll-pool-starvation` runs as many long-polling processors as `pgmq-adapter.pool-size` (2) with `long:5:100`. Oracle (contract): every acknowledgement and every transactional dead-letter move completes without `PgmqAcquisitionTimeout` reaching the processor; (implementation) acknowledgement latency up to `maxPollSeconds` is reported and the stall watchdog's classification is attached. Tier smoke. Cell: `pgmq-persistence/timeout`.

### Milestone 3 — kiroku adapter scenarios

Scope: the nine scenarios of component `kiroku-adapter`. `Kenshou/Suite/Shibuya/Fixture/Kiroku.hs` requests a `PostgresEnv` with component `Kiroku`, opens the store with `withStore (defaultConnectionSettings connStr)`, appends with `appendToStream` to streams in a per-run category `ks<8 hex>` with a sequence number and the stream name in the payload, names subscriptions `ks-<run id>-<suffix>`, and exposes SQL oracles `checkpointOf` (reading `last_seen` from `kiroku.subscriptions` by `subscription_name` and `consumer_group_member`) and `deadLettersOf` (from `kiroku.dead_letters`, columns `global_position`, `event_id`, `reason`, `attempt_count`). Handlers record effects in `kenshou_effects (global_position, event_id, member, process, at)`. Knobs, named after `KirokuAdapterConfig`: `kiroku-adapter.batch-size` (default 100; also 1 and 10), `kiroku-adapter.buffer-size` (default 256), `kiroku-adapter.queue-capacity` (default 16), `kiroku-adapter.target` (`all-streams`, `category`; default `category`), `kiroku-adapter.group-size` (default 0 meaning no group), `kiroku-adapter.missing-checkpoint-policy` (`from-beginning`, `from-current-head`, `fail-if-missing`; default `from-beginning`). Roles: `shibuya-kiroku-consumer` (one `kirokuAdapter` member, or a whole group through `kirokuConsumerGroupProcessors`, under the restart loop, with the same gate) and `shibuya-kiroku-appender`.

`shibuya/kiroku-adapter/correctness/ack-decision-mapping`. Oracle (contract): `AckOk` for a whole batch advances `last_seen` to the batch's last position; `AckRetry d` redelivers the same event no earlier than `d` later with `attempt` one higher, and the fifth delivery that still asks for a retry produces one `kiroku.dead_letters` row with `attempt_count = 5` and lets the next event through; `AckDeadLetter` produces one row whose reason follows the mapping (`PoisonPill` to poison, `InvalidPayload` to invalid, `MaxRetriesExceeded` to max-attempts, `ApplicationFailure code detail` to other with `code` and `detail`) and advances the checkpoint past the event in the same statement; filtered events never reach the handler yet the checkpoint passes them. Tier smoke. Cells: `kiroku-persistence/normal`, `retry-lease/normal`.

`shibuya/kiroku-adapter/correctness/halt-and-shutdown-replay` halts on event k and restarts, then stops mid-batch and restarts. Oracle (contract, per `mori://shinzui/kiroku/okf/adrs/concepts/ADR-4` and upstream's accepted assumption REV-13-A1): the halting event is delivered again after the restart; events acknowledged after the last checkpoint are replayed, never skipped; the replay is at most one delivered batch; `last_seen` never decreases. Tier smoke. Cells: `kiroku-persistence/repeatedStop`, `kiroku-persistence/cancellation`.

`shibuya/kiroku-adapter/correctness/in-flight-depth-is-one` runs a non-group adapter under `async:8` with gated handlers. Oracle (implementation, the documented ack-coupling): the concurrent-handler high-water mark is exactly 1 and at most one delivery is ever leased but unfinalized. Tier smoke. Cell: `dispatch/normal`.

`shibuya/kiroku-adapter/concurrency/sigkill-replay-window` kills the consumer role at the gate and at seeded random instants (`kills` default 20) while appenders run, across `kiroku-adapter.batch-size` 1, 10 and 100 and both targets, in catch-up and in live phases. Oracle (contract): no event lacks an effect; the effects of one member form increasing runs of global position, each new run beginning at or below the previous run's end plus one (at-least-once and in order); `last_seen`, sampled every 200 ms, never decreases; duplicates occur only in kill windows. Duplicate budget per kill (implementation): `batchSize` for catch-up, `category` and group deliveries, and 1000 for the live phase of a non-group `all-streams` subscription, whose batches come from the in-process publisher; the largest observed replay is reported as `maxReplayAfterKill` per shape. `durable` only. Tier standard. Cell: `kiroku-persistence/cancellation`.

`shibuya/kiroku-adapter/concurrency/consumer-group-is-static` runs a group of four, first in one process through `kirokuConsumerGroupProcessors` and then as four processes. Oracle (contract, `mori://shinzui/kiroku/okf/adrs/concepts/ADR-2`): every stream's events are handled by exactly one member, the members' sets are disjoint and their union is everything, and order holds per stream. Then one member is killed and left dead for `observe-seconds` (default 20). Oracle (implementation, the documented absence of rebalancing): its partition's lag grows, no other member handles its streams, and after a restart it resumes from its own checkpoint with no loss. `memberConcurrency` other than `Serial` and a group size below 1 are rejected. Tier standard. Cell: `kiroku-persistence/normal`.

`shibuya/kiroku-adapter/concurrency/two-processes-one-member` starts two processes on the same subscription name and member; the adapter leaves kiroku's startup guard off and offers no way to enable it. Oracle (contract): nothing is lost and `last_seen` never decreases; (implementation) the duplicate factor, about two effects per event, is reported as the cost of the missing guard, with a recommendation to file an upstream request to expose `consumerGroupGuard`. Tier smoke. Cell: `kiroku-persistence/synchronousException`.

`shibuya/kiroku-adapter/concurrency/retry-budget-resets-on-restart` feeds a poison event to a handler that always retries and kills the process after the third delivery. Oracle (contract): the event is dead-lettered exactly once and the checkpoint then advances; (implementation) `attempt` restarts at zero and the total deliveries are at most five times one plus the restart count; the figure is reported. Tier smoke. Cell: `retry-lease/repeatedStop`.

`shibuya/kiroku-adapter/concurrency/postgres-outage-and-reconnect` terminates the subscription's backends (including the `LISTEN` connection, found by `application_name`) and then restarts the postmaster for ten seconds. Oracle (contract): either the subscription reconnects by itself and continues from its cursor, or `source` ends with the worker's exception and the restart loop resumes it; in both cases nothing is lost, order holds and `last_seen` never decreases. `durable` only. Tier standard. Cells: `kiroku-persistence/synchronousException`, `kiroku-persistence/timeout`.

`shibuya/kiroku-adapter/concurrency/group-acquisition-failure-strands-nothing` cancels the thread building an eight-member group at seeded instants in 200 iterations and, in a second phase, terminates backends during construction. Oracle (contract): five seconds after each failure, `pg_stat_activity` shows no connection left under the role's `application_name` beyond the pool's idle ones, the read statement's call count in `pg_stat_statements` has stopped growing, and the thread count is back at baseline. Known defect on both cohorts: REV-13, key REV-13-F1, fix plan 43. Tier standard. Cell: `kiroku-persistence/cancellation`.

### Milestone 4 — shibuya benchmarks, soak and telemetry arms

Scope: five benchmarks, four soak pairs, two trace-continuity scenarios, the overhead comparisons, the layer guide and the upstream filings. Benchmarks support `pg.durability=durable` only, run at least three paired trials, and are authoritative only on a cell; a laptop run is labelled indicative. Every latency is recorded in-process by the measurement toolkit from the intended send time.

`shibuya/core-runner/benchmark/framework-tax` compares, through the knob `bench.arm` (`streamly`, `shibuya`), a bare `Stream.fold Fold.drain (Stream.mapM handler source)` with `runApp` in `serial` mode over the synthetic broker and a no-op handler, for `shibuya.messages` 100000 and 1000000. Measurements: throughput, nanoseconds and allocated bytes per message, maximum live bytes. It reproduces upstream's `Bench.Framework` comparison under this suite's paired protocol; the environment value is forced to normal form before it enters the pipeline, because upstream found that a lazily forced benchmark environment can nest `atomically`. No database. Tier standard.

`shibuya/core-ordering/benchmark/concurrency-sweep` uses a handler sleeping `shibuya.handler-delay-micros` (1000 and 5000) under open-loop arrivals for `serial`, `ahead:n`, `async:n` and partitioned `async:n` with `n` in 2, 5, 10, 20 and `shibuya.partitions` in `uniform:16`, `hot-key:16`, `high-cardinality`. Measurements: throughput, publish-to-finalize latency at p50, p99 and p99.9, allocation rate. This is the first designated overhead benchmark. Tier standard.

`shibuya/core-batch/benchmark/batch-size-and-timeout` sweeps `shibuya.batch.size` 1, 10, 100, 1000 and `shibuya.batch.timeout-ms` 10, 100, 1000 at a fixed open-loop rate and reports throughput and the latency batching adds. Tier standard.

`shibuya/pgmq-adapter/benchmark/end-to-end-throughput-latency` is producer to queue to adapter to `runApp` to a no-op handler to `AckOk`, with latency from the intended send to the completed `finalize`. Knobs: `pgmq-adapter.batch-size` 1, 10, 50, 100; `pgmq-adapter.polling` `standard:1` and `long:5:100`; `pgmq-adapter.prefetch-buffer-size` 0 and 4; `shibuya.concurrency` `serial`, `async:4`, `async:16`; `pgmq-adapter.pool-size` default 10; `payload-bytes` 256 and 16384; `bench.arm` `raw-client` (a hand loop of `readMessage` and `deleteMessage` through `pgmq-hasql`) or `adapter`, the difference being the adapter's tax against a real database. This is the second designated overhead benchmark. Tier standard; placement `either`.

`shibuya/kiroku-adapter/benchmark/end-to-end-throughput-latency` is appender to store to subscription to handler to `AckOk` with `bench.arm` in `subscribe-callback`, `ack-stream` (draining `subscriptionAckStream` by hand) and `adapter`, which measures the per-event acknowledgement round trip that upstream's bench leaves out. Knobs: `kiroku-adapter.batch-size` 1, 10, 100; `kiroku-adapter.group-size` 0 and 4; `phase` `catch-up` or `live`; `shibuya.concurrency` `serial` and `async:8`, where flat throughput is the expected finding. Store pool size 10, per the suite's methodology rule. Tier standard.

The soaks, each registered by a helper `soakPair :: SoakSpec -> [Scenario]` as `<name>` (tier `soak`, placement `cell`, `soak.duration-seconds` 14400) and `<name>-reduced` (tier `extended`, placement `either`, 1200). All run the system under test in worker roles so that the sampled runtime statistics belong to it alone, and all are judged by the diagnostics toolkit's leak verdict on live bytes after major collections, thread count, descriptors and PostgreSQL connections, plus the correctness ledgers.

`shibuya/core-batch/soak/high-cardinality-batch-keys` gives every message a fresh batch key at a fixed rate with `shibuya.batch.size=100`. With `shibuya.batch.timeout-ms=1000` the verdict must be `stable` and the plateau is reported as bytes per pending key, the "supported memory envelope" upstream asks for; with `3600000` the expected verdict is `leak-suspected`, and the broker's `leasedUnfinalized` climbs past `inboxSize`, showing that backpressure is gone as well. Oracle (contract): pending batch state is bounded by configured capacity. Known defect on both cohorts: REV-15, key REV-15-L1.

`shibuya/pgmq-adapter/soak/steady-consume` runs an open-loop producer and two consumer processes with a `SIGKILL` every `soak.kill-interval-seconds` (default 300) and a backend termination every 420 s. Oracle (contract): the leak verdict is `stable` for every process; no loss; duplicates only in crash windows; queue depth has no upward slope; the sizes and dead tuples of `pgmq.q_*` and `pgmq.a_*` stay within the declared growth bound. It replaces upstream's `endurance-test` criterion of "memory growth below two times".

`shibuya/kiroku-adapter/soak/steady-subscribe` runs appenders and a four-member group in two processes with the same kill schedule. Oracle (contract): `stable` verdicts, no loss, per-stream order, monotonic checkpoints, bounded lag, and `kiroku.dead_letters` growing only by the injected poison events.

`shibuya/metrics/soak/scrape-and-websocket-churn` runs a busy application with `telemetry.metrics=serve-scraped` at a one-second scrape interval and continuous WebSocket connect-and-drop churn. Oracle (contract): `stable` verdicts and a WebSocket slot count that returns to zero. Known defect on both cohorts: REV-9, key REV-9-F1.

Telemetry arms. Every scenario that calls `runApp` does so through `Fixture.App`, so both dimensions are honoured everywhere with the mappings given in Milestone 1. `shibuya/pgmq-adapter/correctness/trace-continuity` and `shibuya/kiroku-adapter/correctness/trace-continuity` support only `telemetry.tracing=sdk-inmemory`. They produce messages that each carry their own W3C `traceparent` (in PGMQ's JSON headers, and in the kiroku event's `metadata` object), process them under `async:8` for PGMQ, and assert from the in-memory exporter (contract): one span of kind Consumer named `<processorId> process` per delivery; its parent is that delivery's own producer context and never another message's; `messaging.system` is `shibuya` for PGMQ, whose adapter adds no attributes, and `kiroku` for kiroku; `shibuya.ack.decision` matches the decision; a PGMQ dead-letter copy carries the consumer's `traceparent` with the producer's moved to `x-shibuya-upstream-traceparent`. A companion run with tracing `off` asserts that the dead-letter headers are forwarded verbatim. Tier smoke.

The overhead comparisons are `kenshou overhead shibuya/core-ordering/benchmark/concurrency-sweep --arms tracing=off,noop,sdk-inmemory,sdk-otlp --arms metrics=off,serve,serve-scraped` and the same for `shibuya/pgmq-adapter/benchmark/end-to-end-throughput-latency`, plus one run with `shibuya-metrics.ws-subscribers=10` at the default 100 ms push interval. Add shibuya entries to `policies/telemetry-overhead.json`, seeded from upstream's `performance-budgets.json` as starting limits (throughput no more than 5 percent down, p99 no more than 10 percent up, allocated bytes per message no more than 5 percent up for `off` against `noop`) and marked provisional until a cell run calibrates them.

Finally write `docs/layers/shibuya.md`: what the layer isolates, the scenario catalogue by component with knobs and what each proves, the 13 by 5 matrix rendered from `Kenshou.Suite.Shibuya.Matrix`, the cohort table (finding, released outcome, head outcome, reference), the sizing rule from the leased-bound scenarios, and the restart-loop pattern. For each defect observed without an upstream record — the retry-counting gap, sticky `Failed` readiness, hot-key head-of-line if above the alert factor, the unexposed consumer-group guard, the 1000-event live replay window — file an improvement request or bug report in the owning repository through its own process, then put the resulting `mori://` URI on the scenario.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro-runtime-kenshou`, inside the development shell (`nix develop`, or `direnv` through `.envrc`). Flag spellings of `kenshou` come from `docs/plans/2-build-the-harness-kernel-for-scenarios-dimensions-run-specs-and-results.md`, and the `jq` paths below assume a plausible shape for the cohort identity that `docs/plans/1-bootstrap-the-kenshou-repository-and-pin-the-runtime-cohort.md` defines; where they differ, follow those plans and correct this section.

Check the hard dependencies before writing anything.

```bash
ls kenshou-core kenshou-measure kenshou-check kenshou-diagnose kenshou-telemetry kenshou-cli cohort
cabal build all
cabal run kenshou -- cohort show --json | jq '.components[] | select(.packages[]? | startswith("shibuya"))'
cabal run kenshou -- list --layer selftest
cabal run kenshou -- run selftest/check/concurrency/kill-and-restart-worker --out runs
cabal run kenshou -- run selftest/diagnose/soak/leaking-worker --out runs
grep -n "threaded" kenshou-cli/kenshou-cli.cabal
```

Expect every directory to exist, the build to succeed, the cohort to show `shibuya-core 0.9.0.3` from Hackage with `shibuya-pgmq-adapter 0.16.0.0` and `shibuya-kiroku-adapter`, the self-test scenarios of all four toolkits in the list, both self-test runs to exit 0, and `-threaded` among the executable's options (`stopAppGracefully` uses `registerDelay`, which needs the threaded runtime). If any of this is missing, stop and finish the dependency first.

Build and test the package as it grows, then register it.

```bash
cabal build kenshou-shibuya
cabal test kenshou-shibuya-test
cabal run kenshou -- list --layer shibuya
```

```text
shibuya/core-batch/concurrency/shutdown-with-partial-batches        smoke     either
shibuya/core-batch/correctness/conservation-triggers-and-decisions  smoke     either
shibuya/core-runner/concurrency/halt-wakes-idle-intake              smoke     either  known-defect REV-4-F1
...
```

The transcript is illustrative; on the head cohort the `known-defect` annotation of the cohort-sensitive scenarios is absent. Now the headline demonstration on the released cohort.

```bash
cabal run kenshou -- run shibuya/core-runner/concurrency/halt-wakes-idle-intake --set shibuya.concurrency=serial --out runs
cabal run kenshou -- run shibuya/core-runner/concurrency/halt-wakes-idle-intake --set shibuya.concurrency=async:4 --out runs
```

```text
scenario  shibuya/core-runner/concurrency/halt-wakes-idle-intake
cohort    released   shibuya-core 0.9.0.3 (hackage)   core-line released-0.9.0.3
verdict   halt-wakes-intake   FAILED   waitApp did not return within 2000 ms (mode async:4); thread dump in diagnosis/
outcome   failed — known defect mori://shinzui/shibuya/okf/reviews/concepts/REV-4 (REV-4-F1), non-blocking
```

The first command passes. The second reports the known defect with the exit code the kernel assigns to that outcome. Switch to the head cohort with the mechanism `docs/plans/1-bootstrap-the-kenshou-repository-and-pin-the-runtime-cohort.md` documents (expected to be `just use-cohort head`), confirm that the pinned shibuya commit contains the fix, rebuild and rerun.

```bash
just use-cohort head
cabal build all
cabal run kenshou -- cohort show --json | jq -r '.components[] | select(.packages[]? == "shibuya-core") | .revision'
git -C /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya merge-base --is-ancestor 28a11e0 "$(cabal run -v0 kenshou -- cohort show --json | jq -r '.components[] | select(.packages[]? == "shibuya-core") | .revision')" && echo fix-included
cabal run kenshou -- run shibuya/core-runner/concurrency/halt-wakes-idle-intake --set shibuya.concurrency=async:4 --out runs
just use-cohort released
```

```text
cohort    head   shibuya-core 81501f8 (git)   core-line lifecycle-remediated
verdict   halt-wakes-intake   PASSED   waitApp returned after 3 ms (mode async:4)
outcome   passed
```

Database scenarios, benchmarks, soaks and overhead follow the same shape.

```bash
cabal run kenshou -- run shibuya/pgmq-adapter/concurrency/sigkill-between-handler-success-and-ack --dim pg.durability=durable --dim pg.version=18 --out runs
cabal run kenshou -- run shibuya/kiroku-adapter/concurrency/sigkill-replay-window --set kiroku-adapter.batch-size=10 --dim pg.durability=durable --out runs
cabal run kenshou -- run shibuya/pgmq-adapter/benchmark/end-to-end-throughput-latency --set pgmq-adapter.batch-size=10 --dim pg.durability=durable --out runs
cabal run kenshou -- run shibuya/core-batch/soak/high-cardinality-batch-keys-reduced --out runs
cabal run kenshou -- overhead shibuya/core-ordering/benchmark/concurrency-sweep --arms tracing=off,noop,sdk-inmemory,sdk-otlp --arms metrics=off,serve,serve-scraped --out runs
```

Commit after each scenario family with a Conventional Commits message and the three trailers, for example:

```text
feat(shibuya): add core-runner lifecycle scenarios with cohort-sensitive known defects

MasterPlan: docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md
ExecPlan: docs/plans/10-cover-shibuya-core-and-its-pgmq-and-kiroku-adapters.md
Intention: intention_01m2zvy0gje40tdsdragvzr3tq
```

When ADRs are added, run the validation command from Context and Orientation before committing.


## Validation and Acceptance

Milestone 1 is accepted when `cabal test kenshou-shibuya-test` passes (including `MatrixSpec`, which accounts for all sixty-five cells, the parser properties, and the synthetic broker's lease and redelivery tests); the same package tests pass with `cabal --project-file=cohort/shibuya-current.project test kenshou-shibuya-test`; `kenshou list --layer shibuya` shows the twenty-nine Milestone 1 scenarios; on the historical 0.9.0.3 cohort every scenario either passes or fails as a known defect with its reference printed, and specifically `halt-wakes-idle-intake` passes for `serial` and is a known defect for `ahead:4`, `async:4`, partitioned and batch; on the pinned remediation and current 0.10.0.0 cohorts the eight cohort-sensitive scenarios (`duplicate-processor-ids-are-rejected`, `nonpositive-concurrency-is-rejected`, `halt-wakes-idle-intake` in every mode, `finalization-failure-is-a-failure-not-a-halt`, `adapter-shutdown-failure-does-not-skip-siblings`, `blocking-adapter-shutdown-is-bounded`, `startup-cancellation-leaks-nothing`, `keyed-worker-failure-stops-intake`) all pass with no known-defect annotation, the two regression guards pass on all cohorts, and the metrics scenarios keep their annotations where the defects remain. Non-vacuity is part of acceptance: each checker used must be shown by a unit test to fail on a doctored ledger, and every known-defect scenario's control check must pass.

Milestone 2 is accepted when the eleven PGMQ scenarios run on PostgreSQL 17 and 18 with `pg.durability=durable`; the kill scenario's verdict file lists each kill instant, the redelivery delay of each killed message (all within the VT plus the poll interval plus two seconds) and `budgetBurnedByCrashes`; `multi-process-competition` shows zero overlapping leases across four processes; the atomic-move verdict passes and the duplicate-copy verdict is either passed or the REV-11-F1 known defect; and after every run no `kenshou worker` process and no queue with the run's prefix remains.

Milestone 3 is accepted when the nine kiroku scenarios run on both PostgreSQL versions; `sigkill-replay-window` reports `maxReplayAfterKill` per shape, within `batchSize` for catch-up, category and group shapes and within 1000 for live non-group `all-streams`; sampled checkpoints never decrease in any scenario; and `consumer-group-is-static` shows the dead member's lag growing while the other three progress.

Milestone 4 is accepted when each benchmark yields three paired trials with a summary (throughput, p50, p99, p99.9, allocation rate) and `kenshou compare` between two `bench.arm` values returns a verdict; each short soak finishes with a leak verdict file under `diagnosis/`, `stable` everywhere except the two known-defect soaks; both `kenshou overhead` invocations emit a `kenshou.overhead-report/v1` with per-arm deltas; the trace-continuity scenarios pass; and `docs/layers/shibuya.md` exists and matches `kenshou list --layer shibuya --json`. For the whole plan, a newcomer can reproduce the released-then-head demonstration in Concrete Steps from a clean checkout and obtain the two different outcomes.


## Idempotence and Recovery

Every scenario derives its queue names, category, subscription names and `application_name` values from the run identifier, so runs never collide and rerunning is always safe. With an ephemeral `PostgresEnv` the kernel discards the whole server; with an external server, as on a cell, each database scenario's cleanup drops its `ks_<run>` queues and their dead-letter queues, deletes its rows from `kiroku.subscriptions` and `kiroku.dead_letters`, and drops `kenshou_effects`, inside a `finally` that also runs when the scenario errors. Worker roles are spawned in a process group by `Kenshou.Check.Process`; if the harness itself is killed, find leftovers with `pgrep -fl "kenshou worker"` and end them with `pkill -f "kenshou worker"`. A postmaster stopped by an outage scenario is restarted in the scenario's `finally`; if a run dies in between, the next run gets a fresh ephemeral server, and on an external server the scenario refuses to run unless the environment reports that postmaster control is available. Metrics servers bind harness-chosen free ports and are stopped with `stopMetricsServer`; a lost port race is retried up to five times.

Switching cohorts rewrites only `cohort/active.project`; always finish with `just use-cohort released` and `cabal build all`, and never commit the file pointing at `head`. If the head cohort fails to build because upstream moved, that is the cohort plan's problem: record it in Surprises & Discoveries, run the released cohort only, and leave the head acceptance items unchecked rather than weakening them. If a hard dependency's API differs from the illustrative signatures here, adapt `Fixture/*` and `Roles.hs` only — scenario modules talk to the toolkits through those — and note the change in the Decision Log. If a scenario hangs on the released cohort (several are expected to), its internal deadline ends it and the stall watchdog's dump lands in `diagnosis/`; a hang past the deadline is a harness bug to fix before continuing. Registration in `kenshou-cli` is a three-line additive edit; to back out, remove the import, the list element and the `build-depends` entry.


## Interfaces and Dependencies

Runtime libraries, at the versions the released cohort pins: `shibuya-core` 0.9.0.3 and `shibuya-metrics` 0.9.0.3 (`mori://shinzui/shibuya`), `shibuya-pgmq-adapter` 0.16.0.0 (`mori://shinzui/shibuya-pgmq-adapter`), `shibuya-kiroku-adapter` 0.5.1.2 and `kiroku-store` 0.8.0.1 (`mori://shinzui/kiroku`; confirm the adapter's version on Hackage, since the MasterPlan lists it without one), `pgmq-core`, `pgmq-hasql` and `pgmq-effectful` 0.6.1.0 (`mori://shinzui/pgmq-hs`), `effectful-core` 2.6.x (forced below 2.7 by the kiroku adapter), `streamly` 0.11 with `streamly-core` 0.3, `hasql` 1.10, `hasql-pool` 1.4, `hasql-transaction` 1.2, `hs-opentelemetry-api` 1.0. The head cohort replaces shibuya with a commit that must contain `28a11e0`. Harness libraries: `kenshou-core`, `kenshou-measure`, `kenshou-check`, `kenshou-diagnose`, `kenshou-telemetry`. Test libraries: `hspec`, `hspec-hedgehog`, `hedgehog`. Client libraries for the metrics scenarios: `http-client`, `websockets`, `network`.

At the end of Milestone 1 these modules and signatures exist in `kenshou-shibuya/src`.

```haskell
module Kenshou.Suite.Shibuya (bundle) where
bundle :: LayerBundle                              -- layer "shibuya", all scenarios, all roles

module Kenshou.Suite.Shibuya.Cohort
data CoreLine = CoreReleased0903 | CoreLifecycleRemediated
coreLine :: CoreLine
knownOnReleasedCore :: KnownDefect -> Maybe KnownDefect
rev :: Int -> Text -> KnownDefect

module Kenshou.Suite.Shibuya.Knobs
coreKnobs :: [KnobSpec]
parseConcurrency :: Text -> Either Text Concurrency
parseOrdering :: Text -> Either Text OrderingPolicy
parseStrategy :: Text -> Either Text SupervisionStrategy

module Kenshou.Suite.Shibuya.Matrix
data Boundary; data LifecycleCase; type Cell = (Boundary, LifecycleCase)
cellsOf :: ScenarioId -> [Cell]
uncovered :: [(Cell, Text)]

module Kenshou.Suite.Shibuya.Fixture.SyntheticAdapter   -- as specified in Milestone 1
module Kenshou.Suite.Shibuya.Fixture.Handlers
module Kenshou.Suite.Shibuya.Fixture.App
runTracingArm :: (IOE :> es) => TelemetryHandles -> Eff (Tracing : es) a -> Eff es a
withMetricsArm :: TelemetryHandles -> MetricsKnobs -> Master -> IO a -> IO a
module Kenshou.Suite.Shibuya.Fixture.RestartLoop
runWithRestartLoop :: (IOE :> es, Tracing :> es) => RestartPolicy -> STM Bool -> (Int -> Eff es [(ProcessorId, QueueProcessor es)]) -> AppConfig -> Eff es Int
module Kenshou.Suite.Shibuya.Roles
roles :: [WorkerRole]
```

Scenario modules follow the kind subtrees: `Kenshou.Suite.Shibuya.Correctness.{CoreRunner,CoreOrdering,CoreBatch,Metrics,PgmqAdapter,KirokuAdapter,TraceContinuity}`, `Kenshou.Suite.Shibuya.Concurrency.{CoreRunner,CoreOrdering,CoreBatch,Metrics,PgmqAdapter,KirokuAdapter}`, `Kenshou.Suite.Shibuya.Bench.{Core,PgmqAdapter,KirokuAdapter}` and `Kenshou.Suite.Shibuya.Soak.{CoreBatch,PgmqAdapter,KirokuAdapter,Metrics}`, each exporting `scenarios :: [Scenario]`. Milestone 2 adds `Kenshou.Suite.Shibuya.Fixture.Pgmq` (`withPgmqFixture`, `runPgmqStack`, `queueRows`, `archiveRows`, `dlqCopiesByOriginalId`, `readCounts`) and the roles `shibuya-pgmq-consumer` and `shibuya-pgmq-producer`. Milestone 3 adds `Kenshou.Suite.Shibuya.Fixture.Kiroku` (`withKirokuFixture`, `checkpointOf`, `deadLettersOf`) and the roles `shibuya-kiroku-consumer` and `shibuya-kiroku-appender`. Milestone 4 adds `soakPair :: SoakSpec -> [Scenario]`, the `bench.arm` knob and the shibuya entries in `policies/telemetry-overhead.json`.

What other plans take from this one. Nothing is imported by another layer package. `docs/plans/3-plan-and-select-runs-from-what-changed.md` maps the components `shibuya-core` to the selectors `shibuya/core-runner/**`, `shibuya/core-ordering/**` and `shibuya/core-batch/**`, `shibuya-metrics` to `shibuya/metrics/**`, `shibuya-pgmq-adapter` to `shibuya/pgmq-adapter/**` and `shibuya-kiroku-adapter` to `shibuya/kiroku-adapter/**`, so these component names are a contract. `docs/plans/11-cover-the-kafka-transport-edge-with-a-disposable-broker.md` covers the fourteenth boundary, `kafka-persistence`, with the same case vocabulary and may copy the capability-probe pattern for the `hw-kafka-client` fork. `docs/plans/13-cover-the-keiro-outbox-inbox-and-job-queue.md` should read the leased-bound and crash-budget findings, because `keiro-pgmq` is the one keiro component that calls `runApp`. `docs/plans/15-verify-the-assembled-runtime-end-to-end-and-under-soak.md`, whose package may depend on layer packages, may import `Kenshou.Suite.Shibuya.Fixture.RestartLoop`; keep that module's interface stable.

Revision note (2026-09-23): Implementation started after verifying the prerequisite harness. The invalid-configuration scenario identifier was shortened to fit the kernel's 48-character segment limit; Progress and Surprises now record the initial compiled package, two registered scenarios and their released-cohort evidence. All unfinished acceptance criteria remain open.

Revision note (2026-09-23): Added the bounded idle-intake halt scenario and recorded a reproducible released-versus-head result. The fixture now forces the audited concurrent interleaving before timing `waitApp`; both cohort outcomes and cleanup evidence are in Surprises & Discoveries.

Revision note (2026-09-23): Completed shared knob parsing and generated parser checks, and introduced the lifecycle matrix vocabulary with honest tags for the three executable scenarios. Full matrix accounting remains an open Milestone 1 requirement.

Revision note (2026-09-23): Added the synthetic broker, scripted handler and restart fixtures, then exercised conservation, invalid concurrency, source failure, lease bounds, and all valid ordering policy pairs. Eight scenarios are registered and the released and pinned-head results cited above are reproducible; database adapters, metrics, worker roles, benchmarks, soaks, and full matrix accounting remain open.

Revision note (2026-09-23): Added a concurrent shutdown fault scenario that observes all eight callers and all three adapter shutdowns, plus its matrix tags. The released core skips both siblings as the upstream review predicted; the package tests pass. Seven core-runner scenarios and the later milestones remain open.

Revision note (2026-09-23): Verified that Hackage 0.10.0.0 superseded the original 0.9.0.3 Shibuya baseline. Added an isolated current-release project file and recorded its passing package tests and current-adapter builds. The original released/head comparison remains historical; acceptance must also include the current Hackage lane.
