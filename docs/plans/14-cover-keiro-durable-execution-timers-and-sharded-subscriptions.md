---
id: 14
slug: cover-keiro-durable-execution-timers-and-sharded-subscriptions
title: "Cover keiro durable execution, timers and sharded subscriptions"
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
      at: 2026-09-24T05:09:17Z
      mode: "implement"
      note: "Started implementation; verified dependency seam and discovered role-name contract"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T13:20:57Z
      mode: "implement"
      note: "Added shared workflow journal, effect and retry oracles with doctored-input tests"
---

# Cover keiro durable execution, timers and sharded subscriptions

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

keiro's durable-execution engine promises that a long-running business process written as ordinary Haskell survives crashes, redeployments and idle waits: every named step is journaled, a crashed workflow is picked up by another worker, a `sleep` is a row in a timer table rather than a thread, an external approval is a durable promise, and a busy event category can be drained by a pool of identical worker processes that divide the work among themselves with leases. Today every one of those promises is tested inside keiro by threads in one process, with "crash" meaning a thrown exception or `killThread`, against a PostgreSQL that runs with `fsync=off`. Nothing kills a real process between a side effect and its journal commit, nothing runs three resume-worker processes against one database, and nothing measures what a parked population or a wake-up storm costs.

After this plan, a maintainer can run `kenshou list --json` and see four new components in the `keiro` layer — `workflow`, `timer`, `shard` and `wake` — with correctness, concurrency, benchmark and soak scenarios. They can run, for example, `kenshou run keiro/workflow/concurrency/sigkill-step-boundary --dim pg.durability=durable --out runs/` and watch the harness start resume-worker processes, `SIGKILL` them between a step's side effect and its journal append, and then prove from the journal, the instance table and a per-process effect ledger that every step was journaled exactly once per generation, that every side effect ran at least once and was duplicated only inside a recorded crash window, and that every workflow reached a terminal state. They can do the same for timers (claims under `FOR UPDATE SKIP LOCKED` across processes, stuck-claim requeue, dead-lettering at the attempt ceiling, guarded foreground resume tokens) and for sharded subscriptions (bucket coverage after a worker dies, graceful relinquish versus lease expiry, zombies that duplicate but never move a checkpoint backward). They can benchmark workflow steps per second, resume latency against journal length and snapshot policy, timer drain rate, shard scaling from one to N processes, and push wake-up versus polling, and they can soak a long-lived population of parked and active workflows and receive a leak verdict per worker process.

The plan also turns several facts discovered by reading keiro's source into executable evidence: a suspected crash window that can strand a parent workflow after its child completes, a suspected way for one misconfigured shard worker to poison the lease table for correctly configured ones, the documented gap that a late-joining shard worker receives no buckets, and the undocumented per-pass cost that pending awakeables impose on every resume worker.


## Progress

Milestone 1 — Durable workflow scenarios

- [x] (2026-09-24 05:09Z) Verified the package and CLI build, the required self-test and command identifiers, and the delivered fixture and kernel signatures. EP-12 still has unfinished independent benchmark and soak work; its fixture seam needed here is present.
- [x] (2026-09-24 05:17Z) Added `Kenshou.Suite.Keiro.Workflow.Fixture` as the EP-12 seam and `ensureDurableTables`; both compile. Account command and conservation adapters are still needed when the transfer workflow is added.
- [x] (2026-09-24 05:17Z) Added `Kenshou.Suite.Keiro.Workflow.Effects` with flushed effect and crash-arm facts, named boundaries, self-`SIGKILL` plans, and a pure crash schedule test. A child-process kill test remains to be added with crash scenarios.
- [ ] Added the linear definition, registry entry, and pure expected-step/result model in `Workflow.Definitions`; eight definitions and their model tests remain.
- [x] (2026-09-24 05:17Z) Registered an incremental `keiro/workflow/correctness/linear-replay-smoke` scenario. It passed against provisioned PostgreSQL and wrote seven passing verdicts for replay, effects, journal identity, and step index.
- [x] (2026-09-24 05:31Z) Added a `keiro/workflow-resume-worker` role and incremental `keiro/workflow/concurrency/linear-self-sigkill-smoke` scenario. A durable PostgreSQL run passed seven verdicts, including one bounded duplicate after a real process self-`SIGKILL` and no consumed attempt.
- [x] (2026-09-24) Added named, ordinal and rotated sleeper definitions and `keiro/workflow/correctness/sleep-via-timers`. The final form passed both PostgreSQL durability modes with nine verdicts for deterministic timer rows and payloads, stable first-arm deadline and wake hint, due discovery without firing, batched wake, terminal-owner cancellation, generation pinning, completion journals, and single execution of surrounding step effects.
- [x] (2026-09-24) Added the approval workflow definition and `keiro/workflow/correctness/awakeable-signal-semantics`. Seven verdicts passed in both PostgreSQL durability modes for journaled publication, idempotent signal payload, unknown-ID refusal, terminal-owner settlement without a wake journal, cancellation without a result journal, a cancelled await throwing, and a signal before the await.
- [ ] Extend awakeable cancellation coverage through the resume worker's attempt ceiling and terminal `WorkflowFailed` state; add compensation-on-cancel coverage.
- [ ] Add `Kenshou.Suite.Keiro.Workflow.Knobs` and complete `.Roles`. A basic `keiro/workflow-resume-worker` is registered and exercised; knob plumbing, push mode, the driver, and GC worker remain. The delivered kernel requires slash-form role names.
- [x] (2026-09-24 13:25Z) Added the first shared `Kenshou.Suite.Keiro.Workflow.Oracle` checks for journal step identity, effect coverage bounded by crash windows, and the retry backoff ladder. Doctored duplicate, missing, wrong-ID, and mistimed inputs fail their unit tests; the linear replay and real `SIGKILL` probes use the shared checks and pass.
- [ ] Complete the workflow oracle with database-backed quiescence and stranded-suspension checks, and wire its full journal/effect verdicts into the remaining scenarios.
- [ ] Add the workflow correctness scenarios (seven) and see them pass locally.
- [ ] Add the workflow concurrency and crash scenarios (eleven) and see them pass or report their known defect.
- [ ] Add the `wake` correctness scenario.
- [ ] Extend EP-12's bundle module with `Kenshou.Suite.Keiro.Workflow.scenarios` and `.roles`; confirm `kenshou list` shows them.
- [ ] For each suspected defect that reproduces, file the improvement request in keiro and attach the `KnownDefect` reference.

Milestone 2 — Timer scenarios

- [ ] Add `Kenshou.Suite.Keiro.Timer.Knobs`, `.Roles` (`keiro/timer-worker`) and `.Oracle` with unit tests.
- [x] (2026-09-24 05:35Z) Added both timer correctness scenarios; each passed under both `fsync-off` and `durable`. The attempt-ceiling probe checks two callback executions, post-claim dead-lettering on attempt three, zero-ceiling refusal, persisted reason and invalid options.
- [ ] Add the timer concurrency and crash scenarios (four).
- [ ] Extend the bundle; confirm `kenshou list`.

Milestone 3 — Sharded subscription scenarios

- [ ] Add `Kenshou.Suite.Keiro.Shard.Knobs` and complete `.Roles` and `.Oracle`. Pure coverage/disjointness, deadline arithmetic and checkpoint monotonicity checkers have doctored-input tests. A registered `keiro/shard-worker` now validates shard-count startup in its own process, but its subscription delivery loop and knob plumbing remain.
- [x] (2026-09-24 05:33Z) Registered an incremental `keiro/shard/correctness/lease-coverage-smoke` scenario. Runs under both PostgreSQL durability modes passed five verdicts for one-bucket-per-pass ownership, complete coverage, relinquish and immediate transfer.
- [x] (2026-09-24 13:43Z) Added `keiro/shard/correctness/shard-count-mismatch`, exercising the same `ensureShards` startup path as a worker. Both PostgreSQL durability modes reproduced two contract failures: extra rows remained after a larger misconfigured caller, and a fresh correct caller failed. The scenario exits zero as a reported known defect with `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-49`.
- [x] (2026-09-24 13:48Z) Changed the shard-count mismatch probe to start count-two, count-six and fresh count-four worker processes. Both PostgreSQL durability modes reproduced the same two contract failures and no other failures.
- [ ] Add delivery assertions for the shard-count mismatch scenario; add the other two shard correctness scenarios.
- [ ] Add the shard concurrency and crash scenarios (six).
- [ ] Extend the bundle; confirm `kenshou list`.

Milestone 4 — Durable-execution benchmarks, soak and telemetry arms

- [ ] Add the six benchmarks and run each once locally at shakedown size with `pg.durability=durable`.
- [ ] Add the two soaks (each as a `soak`-tier id and an `extended`-tier `-reduced` id) and pass the short forms locally with a leak verdict per worker process.
- [ ] Wire `telemetry.tracing` and `telemetry.metrics` through the roles and add `keiro/workflow/benchmark/telemetry-overhead`.
- [ ] Add the durable-execution section to `docs/layers/keiro.md`. An initial section documents the runnable workflow, timer and shard probes; extend it with the remaining scenario identifiers and knobs as they land.
- [ ] Write the ADRs named in Context and Orientation and validate the ADR bundle.
- [ ] Record outcomes, distill to ADRs, and update the MasterPlan's Progress entries for EP-14.


## Surprises & Discoveries

- The plan's example list filter assumes a top-level JSON array. The delivered CLI emits `kenshou.scenario-list/v1` with scenarios under `.scenarios[]`; `jq -r '.scenarios[].id'` found all required dependency identifiers on 2026-09-24.
- The delivered worker role parser accepts `keiro/<name>` rather than `keiro.workflow.<name>`; `mkRoleName` in `kenshou-core/src/Kenshou/Core/Role.hs` enforces exactly two slash-delimited segments. Planned role names were adapted to that format.
- `Keiro.Workflow.Journal` is a hidden package module in the released cohort; the public `Keiro.Workflow` module re-exports `deterministicJournalId` and `loadStepIndex`. A direct hidden-module import failed compilation and was replaced by the public import.
- Reading the correctness toolkit's ledger directory while `withCheck` still held the harness ledger open failed on macOS with `withBinaryFile: resource busy (file is locked)`. The crash probe seals the harness ledger before polling worker ledgers; its rerun passed with the `crash-armed` fact and both `s2` effect facts present.
- The CLI cohort document identifies components by `.id`, not `.name` as the plan's illustrative filter says. `jq '.components[] | select(.id=="keiro")'` confirmed the executed cohort still pins `keiro`, `keiro-core`, `keiro-pgmq`, migrations and test support to 0.17.0.0.
- A real self-`SIGKILL` produced a ledger file ending inside a JSON line. `foldFacts` raised `Data.ByteString.hGetLine: end of file` before it could apply its existing torn-final-line rule, so the scenario exited 4 without verdicts. The ledger reader now treats that EOF as the torn final fact; the rerun passed all seven verdicts.
- Keiro 0.17.0.0's `ensureShards` commits bucket insertion before throwing `ShardCountMismatch`. A four-bucket subscription remained at four rows after a count-two caller, but grew to six after a count-six caller; a subsequent count-four caller also threw. The external probe reported only `shard-larger-worker-left-four` and `shard-correct-worker-recovers` as failures in both durability modes. The upstream request is `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-49`; the local Mori registry had not indexed it immediately after creation.
- When an awakeable is signalled from the approval publication effect, the signal's journal append can cause the publish step action to run again before its own append settles. The first signal returns `True`, the repeated signal returns `False`, and the same workflow run completes from the indexed wake result. This was observed in both durability modes; the scenario judges the stable payload and idempotent return values rather than assuming one execution of the publication action.


## Decision Log

- Decision: Begin EP-14 against EP-12's delivered fixture modules while EP-12 finishes unrelated benchmark and soak acceptance. Use the working build and required registered scenarios as the dependency gate. Register new worker roles with the delivered `keiro/<name>` format and keep the intended workflow/timer/shard suffixes.
  Rationale: The fixture domain and CLI bundle already compile and expose the interfaces EP-14 consumes. `mkRoleName` rejects the dotted role names proposed before the kernel implementation existed.
  Date: 2026-09-23

- Decision: Register `keiro/workflow/correctness/linear-replay-smoke` as an incremental vertical probe before the full all-kind replay scenario. Keep its summary limited to the linear workflow.
  Rationale: It proves the fixture, public journal APIs, ledger, bundle registration, and verdict artifact path end to end while the remaining workflow definitions are built. It does not claim the acceptance of the planned all-kind scenario.
  Date: 2026-09-23

- Decision: Only one module of this plan, `Kenshou.Suite.Keiro.Workflow.Fixture`, imports the EP-12 fixture domain (`Kenshou.Suite.Keiro.Fixture.*`); every other module goes through it.
  Rationale: `docs/plans/12-…` was being drafted concurrently and its exact names were unknown. A single seam makes a naming mismatch a one-file fix and makes this plan's needs explicit. The completed plan `docs/plans/12-cover-the-keiro-command-processor-process-managers-and-routers.md` delivers the fixture as the modules `Kenshou.Suite.Keiro.Fixture.Domain`, `.Account`, `.Transfer`, `.Bonus`, `.Projection`, `.Model`, `.Workload`, `.Oracle`, `.Runtime`, `.Roles` and `.Bridge` (account-ledger aggregate, transfer saga process manager, bonus router, projections, pure model, seeded workload, SQL oracles including `money-is-conserved`, and `submitAccountCommand`); read its Milestone 1 and its Interfaces and Dependencies section first and reconcile the names assumed here against the real exports before writing anything else.
  Date: 2026-09-20

- Decision: Scenario components are `workflow`, `timer`, `shard` and `wake`, matching the keiro sub-components the change-aware planner (`docs/plans/3-…`) maps to module paths. The `wake` scenarios live in modules under `Kenshou.Suite.Keiro.Workflow.Wake`, because Integration Point 1 grants this plan only the `.Workflow.*`, `.Timer.*` and `.Shard.*` namespaces and keiro ships a push driver only for the resume worker.
  Rationale: Selection by changed component needs the component name; the namespace contract is kept.
  Date: 2026-09-20

- Decision: The deterministic crash mechanism is a self-delivered `SIGKILL` (`System.Posix.Signals.raiseSignal sigKILL`) at a named boundary point inside the worker process, armed by role arguments; randomly timed `SIGKILL`s from the supervisor are the second mechanism.
  Rationale: The windows under test are microseconds wide. A supervisor-timed kill almost never lands in them; a self-kill at the exact instruction is still a real `SIGKILL` to the operating system and to PostgreSQL (no exception handler, no `finally`, no connection shutdown), and is reproducible from the seed.
  Date: 2026-09-20

- Decision: Side effects of steps, timer fires and shard deliveries are recorded in the correctness toolkit's per-process ledger files, flushed before the effect returns; business effects that must be exactly-once use fixture commands with caller-supplied event identifiers.
  Rationale: The ledger must survive the death of the process and must not travel through the database being faulted. Deterministic identifiers are keiro's own recommended pattern for idempotent step bodies, so the scenarios verify the pattern users are told to adopt.
  Date: 2026-09-20

- Decision: Time is compressed with short leases and timeouts (seconds, as keiro's own tests do), with the caller-supplied `now` where keiro accepts one, and with row back-dating elsewhere. Production defaults (60 s workflow lease, 300 s stuck-timer requeue, 30 s/10 s shard lease) are exercised by knob values in `extended`-tier runs, not by default.
  Rationale: keiro has no clock abstraction; a `standard`-tier scenario cannot wait five minutes per requeue.
  Date: 2026-09-20

- Decision: A documented limitation is encoded as a scenario that PASSES when the limitation behaves exactly as documented, with invariant class `implementation`. A `KnownDefect` reference is used only when a contract scenario fails and an upstream artifact describes the gap.
  Rationale: "`continueAsNew` abandons awakeable identifiers" and "a slow `fire` double-fires" are contracts users rely on in the negative; treating them as defects would hide a change in their behaviour.
  Date: 2026-09-20

- Decision: Suspected defects found by reading source are first written as contract scenarios with no `KnownDefect`. The reference is attached only after the failure reproduces and an improvement request exists in keiro.
  Rationale: A source reading is a hypothesis. The suite's job is to produce the evidence, and the MasterPlan routes fixes to the owning repository.
  Date: 2026-09-20

- Decision: Timer and shard scenarios declare `telemetry.tracing` support as `off` only; workflow scenarios support all four values.
  Rationale: `runTimerWorkerWith` and `runShardedSubscriptionGroupAck` accept no tracer in keiro 0.17.0.0. Declaring an arm that changes nothing would produce meaningless overhead figures.
  Date: 2026-09-20

- Decision: Each soak is registered under two identifiers that share one implementation: `<name>` (tier `soak`, placement `cell`) and `<name>-reduced` (tier `extended`, placement `either`).
  Rationale: Integration Point 3 gives a scenario exactly one tier, while every soak must also run locally at a reduced duration.
  Date: 2026-09-20

- Decision: The shard failover deadline asserted is `leaseTtl + (ceil(lost / survivors) + 2) × renewInterval`, not "about `leaseTtl`".
  Rationale: `acquireOwnedBuckets` claims at most one bucket per reconcile pass by design, so re-homing `lost` buckets takes several passes after the lease expires.
  Date: 2026-09-20


## Outcomes & Retrospective

Implementation is in progress. The first durable workflow crash probe passed
against the pinned keiro 0.17.0.0 cohort and observed a single duplicated `s2`
effect with one journal entry after a self-`SIGKILL`. Both timer correctness
scenarios passed under `fsync-off` and `durable`. A shard lease probe passed
coverage and clean transfer in both modes. These results establish the fixture,
ledger, process, timer and lease integration paths; the full scenario matrix,
benchmarks, soaks and ADR distillation remain open.


## Context and Orientation

### Where this plan sits

This repository, `keiro-runtime-kenshou`, is a verification suite for the keiro runtime, a cohort of Haskell libraries. The initiative is coordinated by `docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md`; this is its child plan EP-14. At the time of writing the repository holds only documents. By the time this plan starts, the plans it depends on must be complete: `docs/plans/1-…` (the cabal project, the Nix development shell, the pinned cohort), `docs/plans/2-…` (the harness kernel), `docs/plans/4-…` (measurement), `docs/plans/5-…` (correctness), `docs/plans/6-…` (diagnostics), `docs/plans/7-…` (telemetry) and `docs/plans/12-…` (the `kenshou-keiro` package and the shared fixture domain). Read those plans for exact type and function names; this plan names what it needs from each and the implementer adapts to the delivered signatures.

A scenario is a registered value, not a test-suite test. It has a four-segment identifier `<layer>/<component>/<kind>/<name>` (layer `keiro` here; kind one of `correctness`, `concurrency`, `soak`, `benchmark`), a cost tier (`smoke` under one minute, `standard` under ten, `extended` under an hour, `soak` hours), a placement (`local`, `cell`, `either`; a cell is a leased set of Google Cloud machines), typed knobs (`KnobSpec`: name, type, default, allowed values, named after the configuration record field they set), the dimension values it supports, and optionally a `KnownDefect` reference (a `mori://` URI) that turns an expected failure into a reported, non-blocking outcome. Dimensions are cross-cutting switches: `telemetry.tracing` (`off`, `noop`, `sdk-inmemory`, `sdk-otlp`), `telemetry.metrics` (`off`, `collect`, `serve`, `serve-scraped`), `pg.durability` (`fsync-off`, `durable`; `durable` is mandatory for benchmarks and crash scenarios) and `pg.version` (`17`, `18`; keiro requires 18, so every scenario here supports `18` only). Scenarios run with `kenshou run <id> --set knob=value --dim name=value --out DIR`, which writes a run directory containing `run-spec.json`, `run-result.json`, `manifest.json`, `samples/`, `series/`, `verdicts/<checker>.json` (schema `kenshou.verdict/v1`), `diagnosis/` and `logs/`. Outcomes are `passed`, `failed`, `errored`, `inconclusive`, `infrastructure-failure`; exit codes are 0, 1, 2 (usage), 3 (inconclusive), 4 (errored or infrastructure failure).

Each layer package exports one `bundle :: LayerBundle` carrying its scenarios and its worker roles. A worker role is a named entry point run as a child operating-system process by the hidden `kenshou worker` subcommand; the correctness toolkit's `Kenshou.Check.Process` spawns roles, exchanges line-delimited JSON with them, and delivers signals. This matters here because keiro scales by running more processes and its crash guarantees are about `SIGKILL` (the signal that ends a process immediately, running no cleanup code), not about Haskell exceptions. `kenshou-keiro` is the one layer package built by three plans: `docs/plans/12-…` creates its cabal file and bundle and registers the bundle in `kenshou-cli/src/Kenshou/Cli/Registry.hs`; this plan adds modules, dependencies and list elements inside the package and touches no other package. Layer packages never import one another.

A scenario never opens a database itself. It asks the kernel for a `PostgresEnv` — an ephemeral PostgreSQL started by the `ephemeral-pg` library, or an external server on a cell — migrated by one `pg-migrate` plan composed from the components it requests. Every scenario here requests the kiroku and keiro components (`Kiroku.Store.Migrations.kirokuMigrations`, `Keiro.Migrations.keiroMigrations`).

### What is being verified

keiro is `mori://shinzui/keiro`, on disk at `/Users/shinzui/Keikaku/bokuno/keiro`; the released cohort pins version 0.17.0.0, and the source under `keiro/src` at the repository head was verified identical to the tag `keiro-0.17.0.0` on 2026-09-20. It stores events in kiroku (`mori://shinzui/kiroku`, `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`), a PostgreSQL event store: an append-only log of events grouped into streams, with a global order called `$all`. keiro's tables live in the PostgreSQL schema `keiro`; kiroku's in `kiroku`.

A durable workflow (`keiro/src/Keiro/Workflow.hs`) is an `effectful` computation run by `runWorkflowWith :: WorkflowRunOptions -> WorkflowName -> WorkflowId -> Eff (Workflow : es) a -> Eff es (WorkflowOutcome a)`, where the outcome is `Completed a | Suspended | Cancelled | Failed | ContinuedAsNew`. `step name action` runs `action` and then appends ("journals") a `StepRecorded` event to the kiroku stream `wf:<name>-<id>`; on a later run the recorded result is returned and the action is not run. Replay is keyed by step name, not position. The documented guarantee is that step side effects are at-least-once across process crashes — every effect happens one or more times, never zero — because a crash after the action and before the journal commit runs the action again; step bodies must therefore be idempotent, meaning that repeating them changes nothing further. The journal append (`keiro/src/Keiro/Workflow/Journal.hs`, `prepareJournalAppend`) takes a transaction-scoped advisory lock (a PostgreSQL lock on an arbitrary key, released at commit) on `<workflowId>/<workflowName>/<generation>/<stepName>`, re-checks the index table `keiro.keiro_workflow_steps`, appends with the deterministic event identifier `deterministicJournalId` (a UUID version 5, that is, a hash of a name, so the same name always yields the same identifier; here over `keiro:workflow:<name>:<id>:<generation>:<step>`), and upserts the instance row in `keiro.keiro_workflows`, all in one transaction. Its outcomes are `JournalAppended`, `JournalAlreadyPresent`, `JournalRefusedTerminal` and `JournalAppendConflict`. Lifecycle markers (`__workflow_completed__`, `__workflow_cancelled__`, `__workflow_failed__`, and the rotation marker) additionally share one per-generation lock, so the first writer wins. `awaitStep name arm` returns a journaled result or runs the idempotent arming action and suspends; sleeps (`Keiro.Workflow.Sleep`: `sleepNamed`, step prefix `sleep:`), awakeables (`Keiro.Workflow.Awakeable`: `awakeableNamed`, `signalAwakeable`, `cancelAwakeable`, prefixes `awkid:` and `awk:`) and children (`Keiro.Workflow.Child`: `spawnChild`, `awaitChild`, `cancelChild`, `runChildWorkflow`, prefix `child:`) are built on it. An awakeable is a durable promise: the workflow allocates a random identifier, journals it, hands it to an outside party, and suspends until that party signals it. `continueAsNew seed` rotates the workflow onto a fresh journal generation (`wf:<name>-<id>#<g>`) so journals stay bounded; `patch` journals a branch decision for code evolution.

The resume worker (`keiro/src/Keiro/Workflow/Resume.hs`) is what makes workflows survive. `resumeWorkflowsOnce :: WorkflowResumeOptions -> WorkflowRegistry es -> Eff es ResumeSummary` runs one pass: it counts pending awakeables, discovers instances with `findUnfinishedWorkflowIds now` (exact discovery: rows that are `running`, or `suspended` with a due `wake_after`; a workflow parked on an unresolved wake is never returned), claims each through an expiring row lease (`claimInstance owner leaseTtl`, giving `ClaimAcquired | ClaimLeaseHeld | ClaimPaced | ClaimUnavailable`), and re-invokes it through the application-supplied registry (`type WorkflowRegistry es = Map WorkflowName (WorkflowDef es)`). A lease is an ownership claim that expires by itself: a row records an owner and an expiry, a live owner keeps renewing, and a dead owner's claim lapses. The runtime renews before each fresh step action and each unresolved await arm and throws `WorkflowLeaseLost` if another owner has taken the row, so the run stops before further side effects. The verified defaults of `WorkflowResumeOptions` are `pollInterval = 1_000_000` microseconds, `maxAttempts = 5`, `leaseTtl = 60` seconds, `maxConcurrentAdvances = 1`; of `WorkflowRunOptions`, `snapshotPolicy = Never`, `pageSize = 100`, `metrics = Nothing`, `tracer = Nothing`, `activePatches = Set.empty`, `leaseHeartbeat = Nothing`, `onJournalAppend = Nothing`. A synchronous exception from a workflow body consumes an attempt and sets `next_attempt_at = now() + LEAST(power(2, attempts + 1), 64)` seconds in SQL (2, 4, 8, 16, 32, then 64); at `maxAttempts` the worker appends `WorkflowFailed`. Store errors are counted as `transientErrors` and consume no attempt; neither does a lost lease or a killed process. The loop drivers are `runWorkflowResumeWorkerWith` (fixed poll; survives per-pass failures), `runWorkflowResumeWorkerPush :: KirokuStore -> WorkflowResumeOptions -> WorkflowRegistry '[Store, Error StoreError, IOE] -> IO ()` and the generic `runPollLoopWith :: WakeSignal -> Int -> IO () -> IO ()`. `Keiro.Wake` builds a `WakeSignal` from kiroku's single `LISTEN` connection (PostgreSQL's `LISTEN`/`NOTIFY` is best-effort publish/subscribe; the listener's `application_name` is `kiroku-listener`), and `neverWake` simulates every notification being dropped. `Keiro.Workflow.Gc` (`gcWorkflowsOnce now policy`, `WorkflowGcPolicy {retention, batchSize}`) hard-deletes the streams and rows of terminal workflows.

Durable timers (`keiro/src/Keiro/Timer.hs`, `Timer/Schema.hs`) are rows in `keiro.keiro_timers` with status `scheduled | firing | fired | cancelled | dead`. `scheduleTimerTx` upserts and re-arms only a `scheduled` row; `scheduleTimerOnceTx` inserts only if absent. `claimDueTimer now` takes the earliest due row with `FOR UPDATE SKIP LOCKED` (a row lock that concurrent claimers skip instead of waiting on), marks it `firing` and increments `attempts`. `runTimerWorkerWith :: Maybe KeiroMetrics -> TimerWorkerOptions -> UTCTime -> (TimerRow -> Eff es (Maybe EventId)) -> Eff es (Maybe TimerRow)` first recovers expired guarded claims, requeues `firing` rows older than `requeueStuckAfter`, records gauges, then claims and fires one timer; `drainDueTimersWith` does the same for up to a limit. keiro provides no timer loop: the application ticks. Defaults: `maxAttempts = Nothing`, `requeueStuckAfter = Just 300`; `maxAttempts = Just n` dead-letters when the post-claim `attempts` exceeds `n`. Firing is at-least-once, and a `fire` that outlasts `requeueStuckAfter` may be fired twice; both are documented. A dead timer can be resumed in the foreground through an expiring token: `claimDeadTimer`, `renewTimerResume`, `completeTimerResume`, `parkTimerResume`, `cancelTimerResume`, `recoverExpiredTimerResumes`. Only workflow garbage collection deletes timer rows, and only sleep timers; keiro 0.17.0.0 ships no retention for other terminal timer rows.

Sharded subscriptions (`keiro/src/Keiro/Subscription/Shard.hs`, `Shard/Schema.hs`, `Shard/Worker.hs`) let a pool of identical processes drain one category. kiroku partitions a category into N buckets — consumer-group members, a static hash of the stream identifier — each with its own checkpoint in kiroku's `subscriptions` table keyed `(subscription_name, consumer_group_member)` with column `last_seen`; the checkpoint upsert takes `GREATEST`, so it never moves backward, and it is saved at the tail of each fetched batch. keiro adds leases in `keiro.keiro_subscription_shards`. `runShardedSubscriptionGroupAck store name options handler` runs `reconcileShardsOnce` every `renewInterval`: estimate live workers from unexpired leases, renew held buckets and claim at most one more if below `fairShareTarget = ceil(N / liveWorkers)`, shed excess when more than one worker is live, start a reader per newly owned bucket and stop readers for lost ones. Defaults: `leaseTtl = 30`, `renewInterval = 10`, `batchSize = 100`, `bufferSize = 256`, `handlerRetryDelay = RetryDelay 1`, `retryPolicy = RetryPolicy 5`, `onShardError = Nothing` (silent). The handler returns `ShardAckOk | ShardAckRetry RetryDelay | ShardAckDeadLetter DeadLetterReason`; a synchronous exception becomes a retry, and exhaustion writes `kiroku.dead_letters`. A clean stop relinquishes leases in a `finally`; a killed process recovers by lease expiry. The delivery guarantee is at-least-once with none skipped; a zombie — a worker paused past its lease — can duplicate but cannot regress a checkpoint. `ensureShards` throws `ShardCountMismatch` when workers disagree on N.

### Facts verified in source that shape the scenarios

keiro has no clock abstraction, and the three clock regimes are mixed within single mechanisms. The caller supplies `now` to `runTimerWorkerWith`, `drainDueTimersWith`, `claimDueTimer`, `requeueStuckTimers`, `findUnfinishedWorkflowIds` and `gcWorkflowsOnce`, so virtual time works there. The worker process's own clock (`getCurrentTime`) writes and compares workflow instance leases (`claimInstance`, `renewInstanceLease`) and shard leases (`acquireOwnedBuckets`, `claimShardsTx`, `renewLeaseTx`) and sets a sleep's `fire_at`. The database clock writes the crash backoff (`now()` in `recordCrashStmt`), which is then compared with the worker's clock in the claim statement, writes a claimed timer's `updated_at` (compared with the caller's `now` on requeue), and governs guarded timer resume entirely (`clock_timestamp()`). The research note that places shard and workflow leases on the database clock is wrong. Consequently a virtual `now` far in the future requeues a just-claimed timer immediately, and lease scenarios must use short real TTLs or back-date rows with the correctness toolkit's time helper.

Direct `runWorkflow` calls take no lease. A process that starts a workflow inline races any resume worker that discovers the `running` row, and both may execute the same step action; the journal still converges to one entry. `Keiro.Workflow.Instance.upsertInstanceTx` is public and is how `spawnChild` makes a zero-step child discoverable, so the driver can also start workflows without running them.

Every resume pass runs `SELECT count(*) FROM keiro.keiro_awakeables WHERE status = 'pending'` even when metrics are off, in every worker process, so the documented claim that parked workflows cost nothing per pass holds for discovery but not for that query. Discovery itself has no SQL `LIMIT`; `resumeWorkflowsOnceUpTo` truncates on the client. In push mode every append to any stream wakes the resume worker.

`runChildWorkflow` commits the child's completion marker in one transaction and delivers the result to the parent (`childCompletionHook`) in a second. A process death between them leaves the child `completed` (never discovered again), the link row `running`, and the parent `suspended` with no wake; `awaitChild`'s arm re-delivers only from a link row already marked `completed`. No keiro test or document covers this window. It is a suspected defect.

`ensureShards` inserts rows `0..N-1` with `ON CONFLICT DO NOTHING`, commits, and only then throws `ShardCountMismatch`. A worker configured with a larger N than the table therefore leaves extra rows carrying the wrong `shard_count`, after which correctly configured workers also fail their own `ensureShards`. keiro's test checks only the throw. It is a suspected defect.

A worker that joins after another already owns every bucket owns nothing, is therefore invisible in the lease table, and never triggers shedding; it receives buckets only when a lease expires. keiro records this as a deliberate gap in `mori://shinzui/keiro/plans/51-consumer-group-sharding-for-category-subscriptions` and `mori://shinzui/keiro/masterplans/6-v2-durable-execution-phase-2-rotation-versioning-push-delivery-and-sharding` (plan and masterplan URIs do not resolve through the released Mori CLI yet).

The resume worker overwrites `WorkflowRunOptions.onJournalAppend`, so that hook is usable for crash injection only on direct `runWorkflowWith` and `runChildWorkflow` calls. `runWorkflowResumeWorkerPush` hard-codes `wakeSignalFromStore`, so a dropped-notification variant must use `runPollLoopWith` with its own pass. `workflowSleepOrPmFire` is not exported; to combine custom `TimerWorkerOptions` with workflow sleeps a worker composes `workflowSleepFireAction` with its own fallback. `runShardedSubscriptionGroupAck` does not call `mkShardedWorkerOptions`. The workflow span is one `Internal` span `workflow <name>` per run, not per step.

### What this plan consumes from its dependencies

From the kernel (`docs/plans/2-…`, package `kenshou-core`, namespace `Kenshou.Core.*`): `Scenario`, `ScenarioId`, `Tier`, `Placement`, `KnownDefect`, `KnobSpec` and resolved knob values, `DimensionSupport`, `LayerBundle`, `WorkerRole`, `RoleContext`, `RunContext` (resolved knobs and dimensions, environment handles, seed, output directory, logger, summary registration, phase markers) and `PostgresEnv` with the composed migration. From measurement (`docs/plans/4-…`, `Kenshou.Measure.*`): the latency recorder, closed-loop load generators (N workers issuing requests back to back) and open-loop ones (requests issued at a fixed arrival rate regardless of completions) with coordinated-omission correction (latency measured from the intended start time, so a stalled system cannot hide its own delay), the GHC runtime, process and PostgreSQL samplers writing `series/*.csv` (including `pg_stat_statements` deltas and named relation sizes), summaries and paired comparison. From correctness (`docs/plans/5-…`, `Kenshou.Check.*`): the bounded per-process ledger and its merge; the checkers no-loss, duplicates-only-inside-declared-windows, per-key order, exactly-N effects per key, eventual quiescence, monotonic checkpoints and disjoint ownership; `Kenshou.Check.Process` (spawn, `SIGTERM`, `SIGKILL`, `SIGSTOP`/`SIGCONT`, restart loops, crash-window bookkeeping, observing a child that died from signal 9); fault injectors (terminating backends — a backend is the PostgreSQL server process serving one connection — by `application_name`, stopping and starting the postmaster, PostgreSQL's parent server process, on a durable fixture, the TCP proxy, a lossy `WakeSignal`, and row back-dating); and the parallel state-machine helper built on hedgehog, a property-testing library that generates command sequences from a seed and shrinks failures. From diagnostics (`docs/plans/6-…`, `Kenshou.Diagnose.*`): the leak verdict (a judgement of `leak-suspected`, `stable` or `insufficient-data` from the slope of sampled series such as live bytes after major garbage collections) and the stall watchdog, which captures Haskell thread dumps and a PostgreSQL lock graph when progress stops. From telemetry (`docs/plans/7-…`, `Kenshou.Telemetry.*`): `withTelemetry` handles (`Maybe Tracer`, `Maybe Meter`, endpoint registrar), `Kenshou.Telemetry.Compose` for kiroku event handlers, and `kenshou overhead`.

From the EP-12 fixture domain (`docs/plans/12-…`, namespace `Kenshou.Suite.Keiro.Fixture.*`) this plan needs exactly the following, and nothing else. First, a way to open a kiroku store for a role or scenario from the `PostgresEnv` with a chosen pool size, a connection-string `application_name`, and the telemetry handles already adapted (`Maybe KeiroMetrics` from `newKeiroMetrics`, `Maybe Tracer`, and the composed kiroku `eventHandler` including `kirokuEventBridge`). Second, the account aggregate: an account identifier type, commands to open, deposit and withdraw, a function that runs one command with caller-supplied `eventIds` and reports whether it appended or was a duplicate, and the kiroku category name of account streams. Third, a seeded workload generator that yields an unbounded deterministic sequence of account commands over a configurable number of accounts. Fourth, a SQL-backed conservation oracle (the sum of balances equals deposits minus withdrawals, and no account is negative). Fifth, the module that defines `bundle :: LayerBundle` for the package, so that this plan can append its scenario and role lists. If the delivered names differ, adapt `Kenshou.Suite.Keiro.Workflow.Fixture` only. If a capability is missing, add it to the fixture in the same commit and record the change in `docs/plans/12-…`'s Decision Log.

### Architecture decisions

There is no local ADR corpus until `docs/plans/1-…` creates `docs/adr/` as a profile-governed OKF bundle (OKF, the Open Knowledge Format, is a directory of Markdown files with YAML frontmatter validated by the house tool `okf`). Before starting, scan `docs/adr/` filenames and read the records on layer isolation, crash semantics (crash means `SIGKILL` or backend termination, never an exception), invariant classes (contract invariants block a release, implementation invariants are reported) and measurement independence.

The cross-repository decisions this plan verifies are these. `mori://shinzui/keiro/okf/adrs/concepts/ADR-5`: on an await replay miss the interpreter falls back to the generation-scoped step index before arming. `mori://shinzui/keiro/okf/adrs/concepts/ADR-6`: wake-source rows are the durable authority for exposure and terminal races. `mori://shinzui/keiro/okf/adrs/concepts/ADR-7`: the generation that first arms a sleep owns the timer and its wake hint. `mori://shinzui/keiro/okf/adrs/concepts/ADR-8`: failure history is immutable and the derived terminal state is revivable. `mori://shinzui/keiro/okf/adrs/concepts/ADR-23`: discovery is exact and every wake-source transition must write the instance row. `mori://shinzui/keiro/okf/adrs/concepts/ADR-24`: deterministic identifiers hash UTF-8 seed bytes and are frozen. `mori://shinzui/keiro/okf/adrs/concepts/ADR-25`: worker loops isolate failures per pass and per item. `mori://shinzui/keiro/okf/adrs/concepts/ADR-27`: lifecycle markers are append-only and the first writer wins. `mori://shinzui/keiro/okf/adrs/concepts/ADR-39`: foreground timer resume uses expiring token ownership. `mori://shinzui/kiroku/okf/adrs/concepts/ADR-2` and `mori://shinzui/kiroku/okf/adrs/concepts/ADR-4`: consumer groups are static hash partitions and ordinary checkpoint saves are monotonic. keiro's own plan for real crash tests, `mori://shinzui/keiro/plans/132-add-real-crash-window-tests-on-a-durability-enabled-fixture` under `mori://shinzui/keiro/masterplans/22-make-the-test-infrastructure-exercise-real-crash-and-production-semantics`, is deferred; this plan delivers the workflow, timer and shard parts of its intent from outside.

Two decisions of this plan deserve new local ADRs: "durable-execution scenarios compress time with short leases, a caller-supplied `now` and row back-dating, and cover production defaults by knob" and "a documented limitation is a passing expectation, a known defect is a failing contract with an upstream reference". Check first whether `docs/plans/5-…` or `docs/plans/13-…` already recorded the second and extend that record instead. Allocate handles with `okf id next docs/adr --profile docs/adr/profile.dhall ADR` and validate with `okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce`.


## Plan of Work

All new source lives under `kenshou-keiro/src/Kenshou/Suite/Keiro/` and all new unit tests under `kenshou-keiro/test/`, in the suite `kenshou-keiro-test` that `docs/plans/12-…` created. Each component has an aggregator module — `Kenshou.Suite.Keiro.Workflow`, `Kenshou.Suite.Keiro.Timer`, `Kenshou.Suite.Keiro.Shard` — exporting `scenarios :: [Scenario]` and `roles :: [WorkerRole]`, which EP-12's bundle module concatenates. Every scenario below supports `pg.version=18` only. Correctness scenarios support both `pg.durability` values and default to `fsync-off`; concurrency, benchmark and soak scenarios support `durable` only. Every role opens its store with `application_name=kenshou-<role>-<index>` so the backend-kill injector can target it, and wires `onShardError`, `WorkflowResumeOptions.logEvent` and the garbage collector's log hook into the run's `logs/` and the ledger. Unless stated, placement is `either`.

### Milestone 1 — Durable workflow scenarios

Scope: the shared machinery for all three components and every workflow and wake correctness, concurrency and crash scenario. At the end `kenshou list --json` shows eighteen `keiro/workflow/*` scenarios and one `keiro/wake/*` scenario, `cabal test kenshou-keiro-test` passes the new unit tests, and `kenshou run keiro/workflow/concurrency/sigkill-step-boundary --dim pg.durability=durable --out runs/` ends `passed` with a `verdicts/` file per checker. Acceptance is that every contract scenario passes on the released cohort or fails reproducibly with evidence that was filed upstream.

Create `kenshou-keiro/src/Kenshou/Suite/Keiro/Workflow/Fixture.hs`, the seam described above, and `Workflow/Effects.hs`:

```haskell
module Kenshou.Suite.Keiro.Workflow.Effects where

-- | One observed side effect, appended to the process's ledger and flushed before returning.
data EffectFact = EffectFact
  { kind :: !Text          -- "step" | "timer-fire" | "shard-delivery" | "arm"
  , key :: !Text           -- e.g. "kenshouLinear/<id>/0/s3", a timer id, an event id
  , process :: !Text       -- role name and index
  , attributes :: !Value }

-- | A place where a crash is meaningful.
data BoundaryPoint
  = AfterStepAction !Text            -- action ran, journal append not started
  | AfterTimerFire                   -- fire produced its event, markTimerFired not called
  | AfterSleepJournalAppend          -- sleep completion journaled, timer not marked fired
  | AfterChildCompletionMarker       -- child's WorkflowCompleted committed, parent not yet woken
  | AfterAwakeableAllocation         -- pending row registered, awkid step not journaled
  deriving stock (Eq, Show)

-- | Self-SIGKILL the n-th time a boundary point is reached by this process.
data CrashPlan = CrashPlan { point :: !BoundaryPoint, occurrence :: !Int }

data EffectSink = EffectSink
  { recordEffect :: EffectFact -> IO ()
  , boundary :: BoundaryPoint -> IO () }

newEffectSink :: RoleContext -> [CrashPlan] -> IO EffectSink
ensureDurableTables :: DurableStore -> IO ()
```

`boundary` writes a flushed `crash-armed` fact and calls `raiseSignal sigKILL` when a plan matches; the supervisor sees the child die from signal 9 and records the crash window. `ensureDurableTables` idempotently creates the schema `kenshou_durable` with `awakeable_publications (workflow_name, workflow_id, generation, label, awakeable_id uuid, PRIMARY KEY (workflow_name, workflow_id, generation, label))`, written by an upsert because publishing is itself an at-least-once step, and `shard_sink (event_id uuid PRIMARY KEY, stream_id bigint, global_position bigint, bucket int, first_worker text, deliveries int)`, written with `ON CONFLICT (event_id) DO UPDATE SET deliveries = shard_sink.deliveries + 1`.

Create `Workflow/Definitions.hs` with the fixture workflows and a pure model. Names are camelCase because `mkWorkflowName` rejects `-`, `:` and `#`. `kenshouLinear` runs `workflow.steps` named steps `s0…`, each recording an effect and returning a value derived from the seed, the workflow identifier and the index, and returns their fold. `kenshouSleeper` is step, `sleepNamed "nap"`, step. `kenshouApproval` allocates an awakeable under the label `approval`, publishes its identifier in a following step, awaits, and finishes. `kenshouParent` spawns `workflow.children` instances of `kenshouChild` and awaits them all. `kenshouRotator` restores its seed, runs a fixed number of steps, and calls `continueAsNew` until the seed reaches `workflow.rotations`. `kenshouPatched` branches on `patch (PatchId "p1")` between two step names. `kenshouFlaky` throws a synchronous exception from step `boom` until a configured attempt. `kenshouTransfer` withdraws from one fixture account, sleeps, and deposits to another, each with an event identifier derived by UUID version 5 from the workflow identifier and step name.

```haskell
type DurableEs = '[Store, Error StoreError, IOE]   -- the row runWorkflowResumeWorkerPush requires

data WorkflowKind = Linear | Sleeper | Approval | Parent | Child | Rotator | Patched | Flaky | Transfer
workflowNameOf :: WorkflowKind -> WorkflowName
durableRegistry :: EffectSink -> DurableStore -> DefinitionParams -> WorkflowRegistry DurableEs
expectedSteps :: WorkflowKind -> DefinitionParams -> Int -> [Text]      -- step names per generation
expectedResult :: WorkflowKind -> DefinitionParams -> WorkflowId -> Value
```

Create `Workflow/Knobs.hs`. The knobs shared by workflow scenarios, each defaulting to a scenario-friendly value with keiro's default in parentheses, are: `workflow.lease-ttl-seconds` (decimal, 3; keiro 60), `workflow.max-attempts` (int, 5), `workflow.max-concurrent-advances` (int, 1; allowed 1–64), `workflow.poll-interval-ms` (int, 100; keiro 1000), `workflow.snapshot-policy` (`never` | `every-<n>` | `on-terminal`, `never`), `workflow.page-size` (int, 100), `workflow.wake-mode` (`poll` | `push` | `push-never-wake` | `push-lossy`, `poll`), `workflow.loop` (`keiro` for the shipped loop drivers, `harness` for a loop over `resumeWorkflowsOnce` that records every `ResumeSummary`; default `harness` in correctness scenarios and `keiro` elsewhere), `workflow.start-mode` (`inline` for a direct `runWorkflowWith`, `deferred` for `upsertInstanceTx … WfRunning`; default `deferred`), `workflow.resume-processes` (int, 2), `workflow.pool-size` (int, 10, kiroku's `poolSize`), `workflow.steps` (int, 8), `workflow.instances` (int, 100), `workflow.children` (int, 3) and `workflow.rotations` (int, 4). `push-never-wake` and `push-lossy` run `runPollLoopWith` with `neverWake` or the correctness toolkit's lossy signal and a pass identical to the shipped one.

Create `Workflow/Roles.hs` with three roles. `keiro/workflow-resume-worker` builds the registry and runs the loop selected by `workflow.loop` and `workflow.wake-mode`. `keiro/workflow-driver` starts instances, signals and cancels awakeables read from `awakeable_publications`, cancels workflows, and runs children directly when a scenario needs a boundary hook. `keiro/workflow-gc-worker` runs `runWorkflowGcWorkerWith`. Create `Workflow/Oracle.hs`:

```haskell
-- contract: per generation, each expected step has exactly one StepRecorded event in the generation
-- stream, its event id equals deterministicJournalId, exactly one index row exists, and exactly one
-- lifecycle marker closes a closed generation.
journalExactlyOnce :: DurableStore -> [WorkflowRef] -> IO Verdict
-- contract: every journaled step has >= 1 effect; extra effects only inside declared windows.
effectsAtLeastOnce :: LedgerView -> [Window] -> [WorkflowRef] -> IO Verdict
-- contract: all instances terminal by the deadline, no expired lease on a non-terminal row,
-- no scheduled or firing sleep timer owned by a terminal workflow.
allReachedTerminal :: DurableStore -> Deadline -> [WorkflowRef] -> IO Verdict
-- contract: no instance is 'suspended' while the wake it awaits is resolved or abandoned.
noStrandedSuspensions :: DurableStore -> IO Verdict
backoffLadder :: NominalDiffTime -> NominalDiffTime -> [UTCTime] -> Either Text ()
```

The journal is read through keiro and kiroku's public API (`loadStepIndex`, `currentGeneration`, `readStreamForwardStream` with `workflowJournalCodec`), not by guessing kiroku table layouts.

The correctness scenarios, all tier `smoke` unless noted and all with contract oracles unless noted, are as follows.

`keiro/workflow/correctness/replay-and-journal-identity` runs every workflow kind to completion through suspensions, then re-runs each with a body whose steps are reordered and one renamed. It passes when `journalExactlyOnce` holds, reordered steps are not re-executed (one effect each), the renamed step executes fresh while the old entry remains, every returned value equals the JSON round trip of the journaled one, results equal `expectedResult`, and stream names are `wf:<name>-<id>` and `wf:<name>-<id>#<g>`.

`keiro/workflow/correctness/exact-discovery` (tier `standard`; knobs `workflow.population.parked`, int, 2000, and `workflow.parked-on`, `awakeable` | `sleep` | `child`) parks a population and runs one harness pass. It passes when `discovered == 0`, no step effect is recorded, and a second pass after resolving k wakes discovers exactly k. It reports the pass duration and the `pg_stat_statements` deltas so the pending-awakeable count is visible.

`keiro/workflow/correctness/sleep-via-timers` verifies, for `sleepNamed` and for the ordinal form `sleep` (journaled as `sleep:0`, `sleep:1`, …), that a sleep is a `keiro_timers` row with the payload kind `keiro.workflow.sleep` and the identifier `sleepTimerId`; that re-entering an unresolved sleep leaves `fire_at` and `wake_after` untouched (duration is measured from the first arm); that with no timer worker running a due sleep is reported as `sleepDue` and makes no advance; that one `drainWorkflowSleepTimers` pass wakes K sleepers; that a sleep owned by a terminal workflow is cancelled instead of fired; and that a rotated workflow's sleep carries its generation (ADR-7).

`keiro/workflow/correctness/awakeable-signal-semantics` verifies that the first `signalAwakeable` returns `True` and later ones `False` without changing the payload, an unknown identifier returns `False`, a signal delivered before the workflow reaches its await is observed, a signal to a terminal workflow settles the row and journals nothing, and `cancelAwakeable` makes the await throw `WorkflowAwakeableCancelled`, which either drives compensation when caught or consumes attempts until `WorkflowFailed`.

`keiro/workflow/correctness/children-spawn-await-cancel-fail` runs `kenshouParent` through resume passes. It passes when the spawn is journaled once as `child:<childId>` and never repeated on replay, each child is discoverable before it has any step, the parent stays undiscovered while children run, each result arrives as the envelope `{"ok": …}` under `child:<childId>:result`, `cancelChild` writes the child's `WorkflowCancelled` marker and makes `awaitChild` throw `WorkflowChildCancelled`, a child failed at the attempt ceiling makes it throw `WorkflowChildFailed` with the recorded reason, and a parent that rotated still attaches to a completed child.

`keiro/workflow/correctness/continue-as-new-abandons-awakeable-ids` (class `implementation`, a documented limitation) rotates `kenshouRotator` while an awakeable is outstanding. It passes when each generation's journal length stays bounded by the steps per generation, the new generation publishes a different identifier, a signal to the old identifier transitions only its own row and wakes nothing, and a signal to the new identifier completes the workflow.

`keiro/workflow/correctness/patch-decisions-are-frozen` starts instances with `activePatches` empty, restarts the worker with `p1` active, and starts fresh instances. It passes when in-flight instances keep `False` forever, fresh ones record `True`, the decision is identical after `SIGKILL` and after rotation, and two workers with different patch sets racing one fresh instance agree on one recorded set.

The concurrency and crash scenarios, all tier `standard`, `pg.durability=durable`, are as follows.

`keiro/workflow/concurrency/sigkill-step-boundary` (knobs `fault.kill-interval-ms`, int, 2000; `fault.duration-seconds`, int, 60; `fault.targeted`, bool, true) runs `workflow.resume-processes` workers over `workflow.instances` linear workflows. Half of the kills are self-kills at `AfterStepAction`, half are supervisor kills at random instants, and workers are restarted. It passes when `journalExactlyOnce`, `effectsAtLeastOnce` (extra effects per step bounded by the kill and lease-expiry windows that overlap it) and `allReachedTerminal` hold with deadline `fault end + leaseTtl + 10 × pollInterval + 5 s`, and every instance's `attempts` is still 0, since a killed process consumes no attempt.

`keiro/workflow/concurrency/lease-loss-stops-side-effects` (knob `workflow.lease-loss-mechanism`, `slow-step` | `sigstop`, default `sigstop`) makes worker 0 hold a step past `leaseTtl`, by a long action or by `SIGSTOP`, while worker 1 claims the instance. It passes when the step after the slow one has exactly one effect overall, produced by the lease holder, worker 0 records a lease skip, no attempt is consumed, and the journal is exactly-once.

`keiro/workflow/concurrency/resume-workers-race` varies `workflow.resume-processes` (1–8), `workflow.max-concurrent-advances` (1, 4, 16) and `workflow.pool-size` (4, 10, 20) with no faults and `deferred` starts. It passes when every step effect count is exactly 1 and all instances complete; with `max-concurrent-advances` above `pool-size` it must still pass, with transient errors reported and the stall watchdog attached.

`keiro/workflow/concurrency/direct-run-vs-resume-worker` uses `workflow.start-mode=inline` while resume workers poll. The contract oracle is `journalExactlyOnce` and correct results; the number of duplicated step effects is reported as a measurement, because duplication without any crash is implied by "direct runs take no lease" but stated nowhere.

`keiro/workflow/concurrency/crash-backoff-and-max-attempts` (default `workflow.max-attempts=4`) runs `kenshouFlaky` under two worker processes. It passes when consecutive executions of `boom` are separated by at least 2, 4 and 8 seconds minus the measured database-to-worker clock skew and at most that plus `2 × pollInterval + 2 s`; the fourth crash appends `WorkflowFailed` and sets status `failed`; nothing executes during the following 16 seconds; a direct run returns `Failed`; a backend kill during an advance leaves `attempts` unchanged; and `resurrectFailedWorkflow` returns `WorkflowResurrected`, after which the repaired workflow completes while the failure event remains in the stream (ADR-8). An `extended` run with `workflow.max-attempts=8` verifies the 64-second cap.

`keiro/workflow/concurrency/database-faults` (knob `fault.kind`, `backend-kill` | `postmaster-restart` | `proxy-reset` | `listener-kill`, default `backend-kill`) injects the fault every few seconds under load with the shipped loop. It passes when no worker process exits (ADR-25), `ResumePassFailed` or transient errors are logged, no attempt is consumed, and the journal and quiescence oracles hold.

`keiro/workflow/concurrency/sleep-fire-crash-window` kills a timer worker at `AfterSleepJournalAppend`. It passes when the timer is requeued and re-fired, the journal holds exactly one `sleep:` entry, the timer ends `fired`, and the workflow completes.

`keiro/workflow/concurrency/awakeable-signal-and-cancel-races` drives, with the hedgehog parallel state-machine helper and the run's seed, concurrent signals from several processes, cancels, resume passes timed around the suspension write, and signaller kills. The model is one status per awakeable (`pending`, `completed v`, `cancelled`). It passes when exactly one signal or cancel returns `True` per awakeable, a winning cancel leaves no `awk:` entry and a winning signal delivers its payload, `noStrandedSuspensions` holds (the hazard ADR-23 and keiro's plan 239 address), and orphaned `pending` rows — allocated by a step killed at `AfterAwakeableAllocation` — number at most the kills at that point (class `implementation`, reported).

`keiro/workflow/concurrency/child-completion-crash-window` runs the child through `runChildWorkflow` with an `onJournalAppend` hook that reaches `AfterChildCompletionMarker` on the completion append and self-kills; ordinary resume workers then run for the quiescence deadline. The contract is that the parent completes with the child's result. From source this is expected to FAIL on keiro 0.17.0.0. If it does, file the improvement request in keiro and attach it as `KnownDefect`; until then the scenario carries none.

`keiro/workflow/concurrency/terminal-marker-first-writer-wins` races `cancelWorkflow` from several processes against completion, against failure at the attempt ceiling and against rotation. It passes when each closed generation's stream holds exactly one lifecycle marker, the instance status matches it, exactly one caller sees `WorkflowCancelRecorded` when cancel won and all others `WorkflowAlreadyTerminal` with the winner, and at most one step action already in flight finishes after the marker commits (ADR-27).

`keiro/workflow/concurrency/gc-vs-concurrent-appends` runs the garbage-collection role with a virtual `now` beyond `retention` while drivers send late signals to completed workflows and restart collected identifiers. It passes when no worker exits, and after quiescence every identifier is either fully present and consistent or fully absent (no rows in `keiro_workflows`, `keiro_workflow_steps`, `keiro_awakeables`, `keiro_workflow_children`, no sleep timers, no stream). The resurrect-versus-collect race is reported, not judged.

`keiro/wake/correctness/push-fallback-when-notify-dropped` (tier `standard`) runs the resume worker in `push-never-wake`, then in `push` while the `kiroku-listener` backend is killed repeatedly. It passes when every signalled workflow advances within `pollInterval + 2 s` of its signal, and nothing is lost.

### Milestone 2 — Timer scenarios

Scope: component `timer`. At the end six `keiro/timer/*` correctness and concurrency scenarios are listed and `kenshou run keiro/timer/concurrency/sigkill-between-fire-and-mark --dim pg.durability=durable --out runs/` ends `passed`.

Create `Timer/Knobs.hs`, `Timer/Roles.hs` and `Timer/Oracle.hs`. Knobs: `timer.max-attempts` (`none` | int, `none`), `timer.requeue-stuck-after-seconds` (`none` | decimal, 2; keiro 300), `timer.drain-limit` (int, 1; 1 selects `runTimerWorkerWith`, more selects `drainDueTimersWith`), `timer.tick-interval-ms` (int, 50; the application-owned loop), `timer.worker-processes` (int, 4), `timer.count` (int, 5000), `timer.clock` (`wall` | `virtual`, `wall`). The role `keiro/timer-worker` validates options with `mkTimerWorkerOptions`, ticks, and fires through `\row -> workflowSleepFireAction row >>= maybe (businessFire row) (pure . Just)`; `businessFire` records a `timer-fire` effect and appends one event to the stream `kenshouTimer-<timerId>` with an event identifier derived from the timer identifier, returning it (a duplicate append returns the same identifier).

`keiro/timer/correctness/lifecycle-and-at-least-once` (tier `smoke`, virtual `now`) verifies upsert re-arming only while `scheduled`, first-arm-wins for `scheduleTimerOnceTx`, claim order by `(fire_at, timer_id)`, `fired_event_id` on success, a `fire` returning `Nothing` leaving the row `firing`, `cancelTimer` and `deadLetterTimer` refusing terminal rows, and immediate requeue when the virtual `now` exceeds the claim time by `requeueStuckAfter`.

`keiro/timer/correctness/max-attempts-dead-letters-post-claim` (tier `smoke`, virtual `now`) uses a `fire` that always returns `Nothing` and advances `now` past the requeue timeout each pass. It passes when claims 1 to n fire, claim n+1 moves the row to `dead` without firing with `last_error = 'timer exceeded attempt ceiling of <n>'` and `attempts = n + 1`, `Just 0` dead-letters on the first claim, and `mkTimerWorkerOptions` rejects a negative ceiling and a non-positive timeout.

`keiro/timer/concurrency/skip-locked-claims-across-processes` (tier `standard`) makes `timer.count` timers due at once for `timer.worker-processes` processes. It passes when every timer ends `fired` with the expected `fired_event_id`, each has exactly one effect and `attempts = 1`, no `(timer_id, attempts)` pair was claimed by two processes, and none remains `firing`.

`keiro/timer/concurrency/sigkill-between-fire-and-mark` kills workers at `AfterTimerFire` and at random. It passes when every timer ends `fired`, each business stream holds exactly one event, raw fires per timer are at most one plus the windows overlapping it, and no row is `firing` later than `requeueStuckAfter + 2 ticks` after the fault schedule ends.

`keiro/timer/concurrency/slow-fire-double-fires` (class `implementation`, a documented limitation) makes the first `fire` outlast `requeueStuckAfter`. It passes when a second worker fires the same timer, `attempts = 2`, the business effect exists once, the row is `fired`, and the slow worker's `markTimerFired` returns `False`.

`keiro/timer/concurrency/foreground-resume-tokens` races `claimDeadTimer` from several processes for one dead timer, with `leaseSeconds = 2`. It passes when exactly one caller receives a claim and `attempts` rises by one; refusals change no column; `renewTimerResume` extends the deadline; after the owner is killed, any ordinary worker pass — including one configured with `requeueStuckAfter = Nothing` — returns the row to `dead` with reason and attempts retained and never exposes it to `claimDueTimer`; `markTimerFired`, `cancelTimer`, `deadLetterTimer` and `requeueStuckTimer` refuse the guarded row; and a late `completeTimerResume` from the former owner returns `False` (ADR-39). Expiry runs on the database clock, so the scenario waits in real time or back-dates `resume_lease_until`.

### Milestone 3 — Sharded subscription scenarios

Scope: component `shard`. At the end nine `keiro/shard/*` correctness and concurrency scenarios are listed and `kenshou run keiro/shard/concurrency/sigkill-failover-vs-graceful-relinquish --dim pg.durability=durable --out runs/` ends `passed`.

Create `Shard/Knobs.hs`, `Shard/Roles.hs` and `Shard/Oracle.hs`. Knobs: `shard.shard-count` (int, 8), `shard.lease-ttl-seconds` (decimal, 3; keiro 30), `shard.renew-interval-seconds` (decimal, 0.5; keiro 10), `shard.batch-size` (int, 100), `shard.buffer-size` (int, 256), `shard.handler-retry-delay-ms` (int, 100; keiro 1000), `shard.retry-max-attempts` (int, 5), `shard.worker-processes` (int, 3), `shard.handler` (`plain` | `ack`, `ack`), `shard.events` (int, 20000), `shard.streams` (int, 500). The role `keiro/shard-worker` validates with `mkShardedWorkerOptions` and runs `runShardedSubscriptionGroupAck` inside an async that the control channel's stop message cancels (a bare `SIGTERM` runs no Haskell cleanup, so "graceful" means the cancel path that reaches keiro's `finally`). Its handler records a `shard-delivery` effect with event identifier, bucket, attempt and worker, then writes `shard_sink`. The role `keiro/shard-appender` appends fixture account events from the seeded workload. The oracle module provides:

```haskell
failoverDeadline :: ShardTiming -> Int -> Int -> NominalDiffTime
-- leaseTtl + (ceil(lost / survivors) + 2) * renewInterval
coverageAndDisjointness :: [OwnershipSample] -> Verdict   -- sampled every 100 ms with ownershipSnapshotFor
checkpointsMonotonic :: [CheckpointSample] -> Verdict     -- kiroku subscriptions.last_seen per member
```

`keiro/shard/correctness/single-worker-drains-all-buckets` (tier `smoke`) passes when one worker comes to own all N buckets within `(N + 2) × renewInterval`, never sheds, and the sink holds every appended event with first deliveries in stream order per stream.

`keiro/shard/correctness/shard-count-mismatch` (tier `smoke`) starts a pool with N = 4, then a worker with N = 2 and one with N = 6. The contract is that each mismatched worker dies with `ShardCountMismatch` having read nothing, and that a fresh correctly configured worker started afterwards still starts. From source the last clause is expected to FAIL after the N = 6 attempt. Handle it as the child-completion scenario is handled.

`keiro/shard/correctness/ack-coupled-handler-variants` (tier `standard`) marks events in the workload as retry-k-times, dead-letter, or throw. It passes when `ShardAckRetry` redelivers with `attempt` counting 0, 1, … and total deliveries never exceed `retryMaxAttempts` under one owner, exhaustion and `ShardAckDeadLetter` each write one `kiroku.dead_letters` row and advance, a throwing `plain` handler behaves as a retry with `handlerRetryDelay`, no event after a dead-lettered one is lost, and `keiro.subscription.deadlettered` equals the row count when metrics are collected.

The concurrency scenarios are tier `standard`, `durable`, and share one delivery oracle: no-loss against the category's events, duplicates only inside membership-change windows and at most `batchSize` per bucket per change (the checkpoint is saved at the batch tail), per-stream order of first deliveries, and `checkpointsMonotonic`.

`keiro/shard/concurrency/coverage-after-membership-change` starts workers concurrently, then stops and starts members on a seeded schedule under load. It passes when no sample shows two unexpired owners for a bucket and, after each change, the union of owned buckets returns to all N within `failoverDeadline` (kills) or `(ceil(released / survivors) + 2) × renewInterval` (graceful stops); the measured gap is reported.

`keiro/shard/concurrency/sigkill-failover-vs-graceful-relinquish` compares the two exits. It passes when a killed worker's buckets are not claimed before their `lease_expires_at` and are claimed within `failoverDeadline`, while a gracefully stopped worker's rows show `owner_worker_id IS NULL` at once and are re-owned well inside `leaseTtl`.

`keiro/shard/concurrency/fair-share-shedding` starts one worker, and a second while unowned buckets remain. It passes when every live worker ends with at most `ceil(N / k)` buckets, coverage is complete, and the event in flight on a shed bucket is redelivered.

`keiro/shard/concurrency/late-joiner-gets-no-buckets` lets one worker own all N and then starts two more. The contract is that the pool converges to at most `ceil(N / k)` each within `N × renewInterval`. It carries `KnownDefect` `mori://shinzui/keiro/plans/51-consumer-group-sharding-for-category-subscriptions`; the evidence it records is that the late workers own zero buckets until the first dies.

`keiro/shard/concurrency/zombie-past-lease-ttl` sends `SIGSTOP` to a worker for `2 × leaseTtl` and then `SIGCONT`. It passes when duplicates from the zombie occur only between `SIGCONT` and its next reconcile plus one second, checkpoints never decrease, and the zombie delivers nothing from a lost bucket after that pass.

`keiro/shard/concurrency/database-faults` kills reader backends and restarts the postmaster. It passes when `ShardReaderDied` or `ShardAcquireFailed` reaches the error hook, a dead reader is restarted within two reconcile passes, no worker exits, and the delivery oracle holds.

### Milestone 4 — Durable-execution benchmarks, soak and telemetry arms

Scope: measurement and endurance. At the end the six benchmarks, two soaks (four identifiers) and the telemetry overhead scenario are listed, `docs/layers/keiro.md` has a durable-execution section listing every scenario, knob and what it proves, and the ADRs exist. Benchmarks require `pg.durability=durable`, run paired trials through the measurement toolkit, record latency in-process, and are authoritative only on a cell; locally they are shakedowns.

`keiro/workflow/benchmark/step-throughput` measures steps per second and journal-append latency for `kenshouLinear` by `workflow.max-concurrent-advances` (1, 4, 16), `workflow.resume-processes` (1, 2, 4) and `workflow.pool-size` (10, 20). kiroku serialises all appends through the `$all` row, so the ceiling this finds is expected; the scenario records it rather than judging it.

`keiro/workflow/benchmark/resume-latency-by-journal-length` measures signal commit to next step effect for instances with `workflow.steps` of 10, 100, 1000 and 5000 journaled steps under `workflow.snapshot-policy` (`never`, `every-50`, `every-500`) and `workflow.page-size` (100, 1000).

`keiro/wake/benchmark/push-vs-poll-wake-latency` sends open-loop signals (knob `wake.signal-rate-per-second`, int, 50) and measures signal-to-effect latency for `workflow.wake-mode` `poll` at 1000 ms and 100 ms, `push`, and `push-never-wake`; the knob `wake.background-append-rate-per-second` (int, 0) adds unrelated appends to expose the cost of being woken by every append, reported as passes and statements per second.

`keiro/workflow/benchmark/parked-population-pass-cost` measures harness-loop pass latency and statement deltas for `workflow.population.parked` of 0, 1000, 10000 and 100000 by `workflow.parked-on`, quantifying the pending-awakeable count query.

`keiro/timer/benchmark/drain-rate` measures timers per second and fire lag (from `fire_at` to the effect) by `timer.worker-processes` (1–8), `timer.drain-limit` (1, 100, 1000) and a backlog of 10000 or 100000, plus an open-loop arm (`timer.schedule-rate-per-second`).

`keiro/shard/benchmark/scaling-1-to-n-processes` measures events per second and append-to-handler latency with `shard.shard-count=16` for 1, 2, 4 and 8 processes, `shard.batch-size` (10, 100, 1000) and a handler cost knob (`shard.handler-work-micros`, 0 or 1000).

`keiro/workflow/soak/parked-and-active-population` (tier `soak`, placement `cell`, `soak.duration-minutes` default 240) and `…-reduced` (tier `extended`, default 20) sustain an open-loop arrival of all workflow kinds that holds a parked population (`workflow.population.parked`, 5000) and an active one, with two push-mode resume workers, two timer workers, one garbage-collection worker with short retention, delayed signals, and optional kills (`soak.kill-interval-seconds`, 0 = off). It passes when the diagnostics toolkit reports `stable` for every worker process on live bytes after major collections, Haskell threads, file descriptors and PostgreSQL connections; the ledger invariants of Milestone 1 hold over the whole run; row counts of `keiro_workflows`, `keiro_workflow_steps`, `keiro_awakeables` and `keiro_timers` plateau after warm-up and dead tuples stay bounded; rotator journals stay bounded per generation; and resume-latency p99 in the last tenth of the run is at most 1.5 times the first tenth after warm-up. Lease churn is reported as the rates of `leaseSkipped` and `paced` per pass.

`keiro/timer/soak/schedule-fire-churn` and `…-reduced` sustain scheduling, firing and cancelling with lease churn from restarts. Leak verdicts and claim-latency drift are judged as above; the size of the partial index `keiro_timers_due_idx` and the count of non-terminal rows must plateau, while growth of terminal rows is reported as the expected consequence of keiro shipping no timer retention. The same soak keeps a shard pool running against the appender and judges its worker processes and `keiro_subscription_shards` churn.

Telemetry. Workflow roles pass the `Maybe Tracer` and `Maybe KeiroMetrics` from the fixture seam into `WorkflowRunOptions` (`#tracer`, `#metrics`, set with generic-lens labels); timer roles pass the metrics handle to `runTimerWorkerWith`; shard roles have only the store's composed kiroku `eventHandler` with `kirokuEventBridge`. Workflow scenarios declare all four `telemetry.tracing` values; timer and shard scenarios declare `off` only; all declare the `telemetry.metrics` values EP-12's seam supports. `keiro/workflow/benchmark/telemetry-overhead` is `step-throughput` at a fixed shape, intended for `kenshou overhead … --arms tracing=off,noop,sdk-otlp --arms metrics=off,collect`; with `sdk-inmemory` it also asserts one `workflow <name>` span per run carrying `keiro.workflow.name` and `keiro.workflow.id`, and that `keiro.workflow.steps.executed`, `keiro.workflow.steps.replayed`, `keiro.workflow.resumed`, `keiro.workflow.lease.skipped`, `keiro.timer.fire.lag`, `keiro.timer.attempts` and `keiro.timer.requeued` moved consistently with the ledger.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro-runtime-kenshou`, inside the development shell. Flag spellings and JSON shapes of `kenshou` beyond those fixed by the MasterPlan are owned by `docs/plans/1-…` and `docs/plans/2-…`; adjust the `jq` filters and flags if they differ.

Check the hard dependencies before writing code:

```bash
test -f kenshou-keiro/kenshou-keiro.cabal && echo "EP-12 package present"
nix develop -c cabal build kenshou-keiro kenshou-cli
nix develop -c cabal run kenshou -- list --json \
  | jq -r '.[].id' | grep -E '^(selftest/(measure|check|diagnose|telemetry)|keiro/command)/' | head
```

```text
EP-12 package present
selftest/check/concurrency/kill-and-restart-worker
selftest/check/correctness/ledger-detects-loss-dup-reorder
selftest/diagnose/soak/leaking-worker
selftest/measure/benchmark/sleep-service
selftest/telemetry/benchmark/arms-on-synthetic-service
keiro/command/...
```

If any line is missing, stop: the corresponding plan is not complete. Also confirm that `grep -n Keiro kenshou-cli/src/Kenshou/Cli/Registry.hs` shows the `kenshou-keiro` bundle; if `docs/plans/12-…` has not registered it, make the three-line edit of Integration Point 3 (one import, one list element, one `build-depends` entry in `kenshou-cli/kenshou-cli.cabal`) and note it in that plan. Confirm the keiro source the scenarios were designed against is what the cohort links:

```bash
nix develop -c cabal run kenshou -- cohort show --json | jq '.components[] | select(.name=="keiro")'
git -C /Users/shinzui/Keikaku/bokuno/keiro diff --stat keiro-0.17.0.0 HEAD -- keiro/src | tail -1
```

Add modules to `kenshou-keiro/kenshou-keiro.cabal` (`exposed-modules`, and any missing `build-depends` among `keiro`, `keiro-core`, `kiroku-store`, `effectful`, `hasql`, `hasql-transaction`, `aeson`, `containers`, `text`, `time`, `uuid`, `stm`, `async`, `unix`, `streamly-core`, `kenshou-core`, `kenshou-measure`, `kenshou-check`, `kenshou-diagnose`, `kenshou-telemetry`), format, build and test after each group of modules:

```bash
nix develop -c treefmt
nix develop -c cabal build kenshou-keiro
nix develop -c cabal test kenshou-keiro-test
```

Run scenarios as they are added, for example:

```bash
nix develop -c cabal run kenshou -- run keiro/workflow/correctness/replay-and-journal-identity --out runs/
nix develop -c cabal run kenshou -- run keiro/workflow/concurrency/sigkill-step-boundary \
  --dim pg.durability=durable --set workflow.resume-processes=3 --out runs/
echo "exit=$?"
```

```text
scenario  keiro/workflow/concurrency/sigkill-step-boundary
run       0199f3c2-…            (illustrative)
kills     29 (15 targeted after-step-action, 14 random)
verdicts  journal-exactly-once passed (800 steps, 100 instances)
          effects-at-least-once passed (duplicates 17, all inside 29 windows)
          all-reached-terminal  passed (deadline 9.0 s, last completion 4.1 s)
outcome   passed
exit=0
```

Inspect evidence with `jq . runs/<run-id>/verdicts/*.json` and `ls runs/<run-id>/logs/`. When a suspected defect reproduces, file the improvement request in `/Users/shinzui/Keikaku/bokuno/keiro` under `docs/improvement-requests/` following that repository's conventions (frontmatter `type: Improvement Request`, the next `requestId`, `origin: mori://shinzui/keiro-runtime-kenshou`), commit it there with trailers that reference this plan as `mori://shinzui/keiro-runtime-kenshou/plans/14-cover-keiro-durable-execution-timers-and-sharded-subscriptions`, then set the scenario's `KnownDefect` to `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-<n>`.

Commit after each green group with a Conventional Commit and the three trailers:

```text
feat(keiro): add durable workflow crash scenarios

MasterPlan: docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md
ExecPlan: docs/plans/14-cover-keiro-durable-execution-timers-and-sharded-subscriptions.md
Intention: intention_01m2zvy0gje40tdsdragvzr3tq
```


## Validation and Acceptance

Milestone 1 is accepted when `cabal test kenshou-keiro-test` passes, including tests that feed each oracle a doctored input and see it fail (a journal with a duplicated step, an effect outside every window, a `suspended` row with a completed awakeable, a backoff sequence that is too short); `kenshou list --json` shows the nineteen identifiers; every correctness scenario exits 0 with `fsync-off` and with `durable`; and every concurrency scenario exits 0 with `durable`, except a scenario whose suspected defect reproduced, which must exit 0 as a reported known defect once its reference is attached and must show the counter-example (for the child window: the parent's identifier, status `suspended`, and the link row `running` beside a `completed` child) in its verdict. Non-vacuity is shown once per crash scenario by running it with `fault.duration-seconds=0` and observing zero duplicates, then with faults and observing duplicates greater than zero.

Milestone 2 is accepted when the six timer scenarios exit 0 and `slow-fire-double-fires` shows `attempts = 2` with one business event. Milestone 3 is accepted when the nine shard scenarios exit 0 (`late-joiner-gets-no-buckets` as a known defect) and `coverage-after-membership-change` reports a measured coverage gap below its deadline for every membership change. Milestone 4 is accepted when each benchmark produces `samples/` histograms and a summary with throughput and p50/p90/p99/p99.9; a repeated pair of identical runs compared with `kenshou compare` yields `pass` or `inconclusive`, never `regression`; both `-reduced` soaks exit 0 locally with a `diagnosis/` leak finding of `stable` per worker process; `kenshou overhead keiro/workflow/benchmark/telemetry-overhead --arms tracing=off,sdk-inmemory` writes a `kenshou.overhead-report/v1`; `docs/layers/keiro.md` lists every identifier in this plan; and `okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce` passes.

The whole plan is accepted when a reader can run `kenshou run` for one scenario per component and kind, and find in the run directory the ledger-backed verdicts that state, with counts and first counter-examples, whether keiro's durable-execution guarantees held.


## Idempotence and Recovery

Every scenario provisions its own database through the kernel and writes to a fresh run directory, so re-running is always safe and never touches an earlier run. `ensureDurableTables` uses `IF NOT EXISTS`. Workflow, timer and subscription names carry the run identifier, so an external (cell) database reused across runs cannot mix populations; garbage collection scenarios restrict their assertions to their own identifiers.

Crash scenarios leave processes and PostgreSQL backends behind only if the harness itself is killed. The correctness toolkit places workers in a process group and reaps it; if a run is interrupted, find leftovers with `pgrep -fl 'kenshou worker'` and remove them with `pkill -KILL -f 'kenshou worker'`, and clear ephemeral clusters as `docs/plans/2-…` describes. A worker stopped by `SIGSTOP` that is never continued must be killed the same way. Postmaster-restart faults run only against the durable ephemeral fixture or a cell's dedicated server, never a shared database.

If a module fails to compile after the fixture domain changed, fix only `Kenshou.Suite.Keiro.Workflow.Fixture`. If a scenario is flaky because a deadline is too tight on a slow laptop, do not widen the oracle silently: record the observed timing in Surprises & Discoveries, express the deadline in terms of the knobs, and re-run with the seed from `run-spec.json` to reproduce. Soaks on a cell are resumable only as whole runs; a failed lease or fetch is handled by `docs/plans/17-…`.


## Interfaces and Dependencies

Libraries come from the pinned cohort of `docs/plans/1-…`: `keiro` and `keiro-core` 0.17.0.0 (`Keiro.Workflow`, `.Workflow.Resume`, `.Workflow.Sleep`, `.Workflow.Awakeable`, `.Workflow.Child`, `.Workflow.Gc`, `.Workflow.Instance`, `.Timer`, `.Subscription.Shard`, `.Subscription.Shard.Worker`, `.Wake`, `.Telemetry`, `Keiro.EventStream` for `SnapshotPolicy`), `kiroku-store` 0.8.0.1 (`Kiroku.Store.Connection`, `.Effect`, `.Read`, `.Transaction`, `.Subscription.Types`), `effectful` 2.6, `hasql` 1.10 with `hasql-transaction`, `hs-opentelemetry-api` 1.0, `unix` for `raiseSignal`, and the five `kenshou-*` foundation packages. No other layer package is imported.

At the end of Milestone 1 these modules exist under `kenshou-keiro/src/Kenshou/Suite/Keiro/`: `Workflow.hs` (`scenarios :: [Scenario]`, `roles :: [WorkerRole]`), `Workflow/Fixture.hs` (`DurableStore`, `withDurableStore`, the account command helpers, `fixtureCategory`, `conservationOracle`), `Workflow/Effects.hs`, `Workflow/Definitions.hs`, `Workflow/Knobs.hs` (`workflowKnobs :: [KnobSpec]`, `resumeOptionsFrom`, `runOptionsFrom`), `Workflow/Roles.hs`, `Workflow/Oracle.hs`, `Workflow/Correctness.hs`, `Workflow/Concurrency.hs` and `Workflow/Wake.hs`. At the end of Milestone 2: `Timer.hs`, `Timer/Knobs.hs` (`timerOptionsFrom :: … -> Either TimerWorkerConfigError TimerWorkerOptions`), `Timer/Roles.hs`, `Timer/Oracle.hs`, `Timer/Correctness.hs`, `Timer/Concurrency.hs`. At the end of Milestone 3: `Shard.hs`, `Shard/Knobs.hs` (`shardOptionsFrom :: … -> Either ShardedWorkerConfigError ShardedWorkerOptions`), `Shard/Roles.hs`, `Shard/Oracle.hs` (`failoverDeadline`, `coverageAndDisjointness`, `checkpointsMonotonic`), `Shard/Correctness.hs`, `Shard/Concurrency.hs`. At the end of Milestone 4: `Workflow/Bench.hs`, `Workflow/Soak.hs`, `Timer/Bench.hs`, `Timer/Soak.hs`, `Shard/Bench.hs`, and the section in `docs/layers/keiro.md`. Worker role names are `keiro/workflow-resume-worker`, `keiro/workflow-driver`, `keiro/workflow-gc-worker`, `keiro/timer-worker`, `keiro/shard-worker` and `keiro/shard-appender`.

`docs/plans/15-…` (the assembled runtime) may reuse `Workflow/Definitions.hs`, `Workflow/Effects.hs` and the three oracle modules, because `kenshou-runtime` is allowed to depend on `kenshou-keiro`; keep their exports free of scenario-specific state. `docs/plans/3-…` selects these scenarios through the components `workflow`, `timer`, `shard` and `wake`. `docs/plans/13-…` is independent of this plan; the two only share EP-12's bundle module, where each appends its own lists.


## Revision Note — 2026-09-24

Implementation began against the delivered EP-12 fixture and kernel APIs. The
plan records their actual CLI JSON and worker-role naming contracts and the
passing incremental workflow, timer and shard probes. Remaining acceptance
criteria and unfinished work stay in Progress so implementation can resume
without mistaking a green slice for the completed initiative.

## Revision Note — 2026-09-24 (workflow oracle)

The two incremental workflow probes now share pure journal and effect checks, and
the test suite rejects doctored evidence. The retry spacing check follows
keiro's persisted 2, 4, 8, …, 64 second gate. A process kill exposed a torn
ledger-line reader error; the reader now discards that incomplete final fact.
Database-backed workflow oracles and the remaining scenarios remain open.

## Revision Note — 2026-09-24 (shard mismatch)

The shard count mismatch probe now documents and reproduces a released Keiro
defect, with an upstream improvement request. Separate worker processes run
the same startup path and confirm rejection plus table poisoning. The shard
role still needs its subscription delivery loop, and the mismatch probe needs
delivery evidence before Milestone 3 is complete.

## Revision Note — 2026-09-24 (awakeable semantics)

The approval definition and its end-to-end scenario now exercise durable
awakeable publication, signal and cancellation paths. Signal-before-await
coverage revealed a legitimate repeated publication action; the verdict
checks idempotence across that repeat. Worker-driven cancellation exhaustion
and compensation remain open.
