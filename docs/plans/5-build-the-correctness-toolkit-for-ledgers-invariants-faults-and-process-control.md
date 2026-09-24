---
id: 5
slug: build-the-correctness-toolkit-for-ledgers-invariants-faults-and-process-control
title: "Build the correctness toolkit for ledgers, invariants, faults and process control"
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
      at: 2026-09-21T16:23:22Z
      mode: "implement"
      note: "Started implementation and verified the EP-1/EP-2 foundation gate."
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T22:53:07Z
      mode: "update"
      note: "Consolidated Progress into delivered outcomes and remaining acceptance"
---

# Build the correctness toolkit for ledgers, invariants, faults and process control

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

The keiro runtime is a cohort of Haskell libraries that services link together: `kiroku` (an event store on PostgreSQL), `pgmq-hs` (a client for PGMQ, a message queue made of PostgreSQL tables), `shibuya` (a message-processing framework) and `keiro` on top. These libraries promise things such as "no event is lost", "after a crash a message is delivered again, but only a bounded number of times", "events of one stream arrive in order" and "two workers never own the same lease at the same instant". Today every test of those promises inside the runtime's own repositories runs in one operating-system process and simulates a crash by throwing a Haskell exception or calling `killThread`, which runs exactly the clean-up code that a real crash skips.

After this plan, this repository contains a library, `kenshou-check`, with which a scenario author can state such a promise as an executable invariant and test it under real failure. A scenario spawns its workers as child processes of the `kenshou` binary, has every process write the facts it produced and observed into append-only ledger files, kills workers with `SIGKILL`, terminates PostgreSQL backends, crashes and restarts the PostgreSQL server, puts a misbehaving TCP proxy between a client and its server, drops wake-up notifications, and finally runs invariant checkers over the merged ledgers. Each checker writes one small JSON document, a verdict, that says whether the invariant held, how many facts it examined, the first counter-examples if it did not hold, and whether the invariant is part of the runtime's public contract (a violation blocks a release) or merely a property of today's implementation (a violation is reported but does not block). The ledger is bounded in memory, so the same machinery serves a thirty-second smoke run and a twenty-four-hour soak.

You can see it working without any runtime library involved. Five self-test scenarios ship with the toolkit and run with `kenshou run`. The first proves that every checker is not vacuous: it builds a clean synthetic ledger on which all checkers hold, then doctors the ledger in one way per checker (drops a fact, duplicates one, reorders two, and so on) and passes only if each doctored ledger makes exactly the targeted checker report a violation. The second kills and restarts a real child process and shows that the duplicates caused by each kill are counted, excused because they fall inside the recorded crash window, and bounded by the declared budget. The third terminates PostgreSQL backends by `application_name`, blocks writers behind a lock, and crashes the server with durability on, then shows that every acknowledged write survived. The fourth partitions a client from PostgreSQL through the proxy and shows latency, stall, blackhole and reset are each observable. The fifth lets a state-machine test find a bug in a deliberately broken register and shows that `kenshou run --seed <n>` reproduces the same shrunk counter-example. Every coverage plan that follows (pgmq-hs, kiroku, shibuya, Kafka, keiro, the assembled runtime) builds its correctness and concurrency scenarios from these parts.


## Progress

- [x] (2026-09-21) Correctness toolkit complete: durable ledgers, invariant verdicts, process control, fault injection, and model-based support pass package and live crash tests. See Outcomes & Retrospective for results.

## Surprises & Discoveries

- PostgreSQL backend enumeration initially used the administrative database, so
  its `current_database()` filter could never see scenario clients. Selecting
  through the run database fixed both targeting and the live self-test.
- Killing the `psql` lock-holder client does not immediately interrupt a backend
  sleeping inside a query on macOS; the lock healer must terminate the named
  backend and then reap the client process.
- Hedgehog 1.7 exposes deterministic report execution through
  `Hedgehog.Internal.Runner.checkReport`; the local Mori corpus did not contain
  Hedgehog, so the exact solver-selected 1.7 source was unpacked and inspected.


## Decision Log

- Decision: Ledger files live in `verdicts/ledger/` inside the run directory.
  Rationale: The MasterPlan's run-directory contract (Integration Point 5) lists no home for raw fact files, and this plan owns `verdicts/`. The files are the evidence a verdict was computed from and must be in the artifact manifest so that a later attestation can recompute the verdict. A subdirectory does not disturb consumers that read `verdicts/*.json`.
  Date: 2026-09-20

- Decision: `kenshou-check` imports no module of any runtime library (kiroku, keiro, shibuya, pgmq-hs). Durable-truth oracles are SQL text against named relations, and the wake-up injector wraps a plain wait function rather than keiro's `WakeSignal` type.
  Rationale: A checker that links the code under test is not independent of it, and a toolkit that depends on keiro would drag keiro into the pgmq and kiroku layer builds. The layer packages adapt in one line.
  Date: 2026-09-20

- Decision: A producer records an `intent` fact before the call and a `produced` fact after it is acknowledged; a consumer records its `observed` or `effect` fact and flushes it to the operating system before it acknowledges to the runtime. Only acknowledged facts are required to be observed; an intent without an acknowledgement is indeterminate and may or may not appear downstream.
  Rationale: A `SIGKILL` cannot lose bytes already handed to the kernel, so flush-before-acknowledge removes false "loss" reports, and the three-way classification (acknowledged, failed, indeterminate) is the only honest reading of a call that was in flight when the process died.
  Date: 2026-09-20

- Decision: One ledger file sequence per process incarnation, JSON Lines, rotated into immutable 64 MiB segments; verification merges them with an external sort. Rolling verification that discards verified segments during a soak is not part of this plan.
  Rationale: Immutable segments can be digested and listed in the manifest, and the format already allows rolling verification to be added later without touching writers. The plan that owns the long soaks (`docs/plans/15-verify-the-assembled-runtime-end-to-end-and-under-soak.md`) can request it if twenty-four-hour ledgers prove too large for a cell's disk.
  Date: 2026-09-20

- Decision: A verdict's status is `held`, `violated` or `not-evaluated`. A checker that examined zero relevant facts is `not-evaluated` with reason `vacuous` unless the scenario explicitly allows an empty input. Contract verdicts that are `violated` make the run `failed`; contract verdicts that are `not-evaluated` make it `errored`; implementation verdicts never change the outcome.
  Rationale: The most common way for a correctness suite to lie is to pass because nothing was checked.
  Date: 2026-09-20

- Decision: A PostgreSQL server crash is injected by sending `SIGQUIT` to the postmaster (PostgreSQL's immediate shutdown, which skips the shutdown checkpoint and forces write-ahead-log recovery on the next start) and restarting through `EphemeralPg.restart`. `SIGKILL` of the postmaster is an optional mode that additionally waits for orphaned backends to exit.
  Rationale: Immediate shutdown exercises recovery without leaving shared memory attached; both modes are only meaningful with `pg.durability=durable`.
  Date: 2026-09-20

- Decision: `kenshou-check` exports its own `selftest`-layer bundle (`Kenshou.Check.Selftest.bundle`) and registers it with the usual three-line edit in `kenshou-cli`.
  Rationale: Integration Point 3 says each layer package exports one bundle, but the `selftest` layer has scenarios contributed by five plans and no package of its own. One bundle per contributing package keeps the toolkits independent of one another.
  Date: 2026-09-20

- Decision: Unit tests for process control spawn `kenshou-check-fixture-worker`, a small executable declared inside `kenshou-check`, not the `kenshou` binary.
  Rationale: `kenshou-cli` depends on `kenshou-check`, so a test in `kenshou-check` that needed the `kenshou` executable would create a package cycle.
  Date: 2026-09-20

- Decision: Cell-only injectors (packet filtering with `iptables`, traffic shaping with `tc`, disk-full, memory limit) call one hook executable named by the environment variable `KENSHOU_CELL_FAULT_HOOK`; when it is unset they report themselves unavailable.
  Rationale: Those faults need root on a machine this process does not own. A hook keeps the `Fault` interface identical on a laptop and on a cell and leaves the privileged part to `docs/plans/16-provide-leased-verification-cells-in-load-testing-infra.md`.
  Date: 2026-09-20

- Decision: Ledger streams are plain pull sources (`IO (Maybe Fact)`), and the merge fan-in is capped at 64 open files.
  Rationale: No streaming library is needed for a sequential merge, and macOS allows only 256 open files per process by default.
  Date: 2026-09-20

- Decision: The linearizability search has a step budget; exhausting it yields `not-evaluated` with reason `search-budget-exhausted` and the run outcome `inconclusive`.
  Rationale: The problem is NP-complete; an honest "could not decide" is better than a hang or a guess.
  Date: 2026-09-20

- Decision: The supervisor uses `System.Process` plus explicit POSIX process
  groups and signals rather than adding `typed-process`.
  Rationale: The kernel already exposes process specifications in terms of raw
  executables, arguments and environments, while correctness depends on the
  explicit process-group, pid, signal and reaping semantics implemented here.
  A second process abstraction would not strengthen those guarantees.
  Date: 2026-09-21

- Decision: A fifth self-test scenario, `selftest/check/correctness/model-replays-counterexample`, is added beyond the four the MasterPlan brief named.
  Rationale: Milestone 5 would otherwise have no behaviour observable through `kenshou run`.
  Date: 2026-09-20


## Outcomes & Retrospective

EP-5 delivered the `kenshou-check` package and registered five executable
self-tests. The package provides rotating crash-surviving ledgers, bounded
external sorting, versioned verdicts, nine non-vacuous invariant checkers, SQL
oracles, process-group supervision, PostgreSQL/network/wake/time/cell faults,
seeded Hedgehog reports, and a step-bounded memoized linearizability checker.

Acceptance covers 33 package examples, schema validation of live fact and
verdict output, real `SIGKILL` worker restart, named PostgreSQL backend
termination, lock release, durable postmaster crash/recovery, live TCP latency,
stall, blackhole and reset, and deterministic model replay. ADR-8 records
contract-versus-implementation classification and ADR-9 records the external
termination definition of a crash. The package imports no runtime library, so
the layer plans can use the same evidence machinery without coupling their
builds.


## Context and Orientation

This repository, `keiro-runtime-kenshou` (kenshou, 検証, means "verification"), produces evidence about the keiro runtime. The governing document is `docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md`; this plan is its fifth child. The repository is one cabal project; every package directory is named `kenshou-*` and is picked up by the glob `kenshou-*/*.cabal` in `cabal.project`, so adding a package never requires editing the package list. The toolchain is GHC 9.12.4 with `default-language: GHC2024`, cabal 3.16, formatting by fourmolu and cabal-gild through treefmt, and tests with `hspec` plus `hspec-hedgehog`. Records use `OverloadedRecordDot`. Plain `IO` is fine for harness code.

At the time this plan was written the repository held only documents. This plan hard-depends on `docs/plans/2-build-the-harness-kernel-for-scenarios-dimensions-run-specs-and-results.md` (which itself depends on `docs/plans/1-bootstrap-the-kenshou-repository-and-pin-the-runtime-cohort.md`). Before starting, the following must exist; step 0 of Concrete Steps checks it. From the bootstrap plan: a Nix development shell (`nix develop`) with GHC, cabal, PostgreSQL 18 and 17, `just`, `jq`, `okf`; `cabal.project` importing the pinned runtime cohort; `docs/adr/` as an OKF bundle with `docs/adr/profile.dhall`. From the kernel plan: the package `kenshou-core` with `Kenshou.Core.Scenario` (`Scenario`, `ScenarioId`, `Tier`, `Placement`, `RunContext`, `ScenarioReport`), `Kenshou.Core.Knob` (`KnobSpec`), `Kenshou.Core.Dimension`, `Kenshou.Core.Bundle` (`LayerBundle` with fields `layer`, `scenarios`, `roles`), `Kenshou.Core.Outcome`, `Kenshou.Core.Env.Postgres` (`PostgresEnv`), `Kenshou.Core.Role` (`WorkerRole`, `RoleContext`, and the control-channel message types as data), `Kenshou.Core.Manifest`; the package `kenshou-cli` with the executable `kenshou` (`list`, `run`, hidden `worker`, `cohort show`) and `kenshou-cli/src/Kenshou/Cli/Registry.hs`; the directory `schemas/`; and the self-test scenarios `selftest/kernel/correctness/always-pass` and `selftest/kernel/concurrency/worker-echo`. The kernel's exact function names were not final when this plan was drafted, so this plan confines every call into the kernel to one adapter module, `Kenshou.Check.Scenario`; read the kernel modules first and adapt that one module.

The contracts this plan relies on, restated from the MasterPlan's Integration Points. A scenario identifier is the path `<layer>/<component>/<kind>/<name>`; the layer here is `selftest`, the component is `check`, and the kind is `correctness` or `concurrency`. Each scenario declares a cost tier (`smoke` under one minute, `standard` under ten, `extended` under an hour, `soak` hours), a placement (`local`, `cell`, `either`), its knobs (typed parameters with a name, a default and allowed values, set with `--set name=value`) and the dimension values it supports (`telemetry.tracing`, `telemetry.metrics`, `pg.durability` with values `fsync-off` and `durable`, `pg.version` with values `17` and `18`, set with `--dim name=value`). A run is identified by a UUIDv7 and writes into `<out>/<run-id>/`, which holds `run-spec.json`, `run-result.json`, `manifest.json` (every file with its SHA-256), `samples/`, `series/`, `verdicts/<checker>.json` (schema `kenshou.verdict/v1`, owned by this plan), `diagnosis/` and `logs/`. Every versioned document is JSON with a `schema` field and a JSON Schema under `schemas/`. Run outcomes are `passed`, `failed`, `errored` (the scenario could not be evaluated), `inconclusive` and `infrastructure-failure`, mapped to exit codes 0, 1, 4, 3 and 4; a usage error is 2. The seed in the run specification drives every random choice so that a failing run can be repeated. A scenario never opens a database itself: it asks the kernel for a `PostgresEnv`, which is an ephemeral server started with the `ephemeral-pg` library (honouring `pg.durability` and `pg.version`) or an external server named in the run specification. Worker roles are named entry points registered in a bundle and run by the hidden subcommand `kenshou worker --role <name>` as a child process of the same binary; the kernel owns the `WorkerRole` type and the dispatch, this plan owns supervision.

Terms used below. An event store keeps an append-only log of events grouped into streams; kiroku assigns every event a version within its stream and a global position in the store-wide `$all` stream. Optimistic concurrency means an append states the stream version it expects and fails if another writer got there first. At-least-once delivery means a consumer may see an item again after a failure but never misses one, so handlers must be idempotent (safe to repeat); an idempotency key is the identifier by which repeats are recognised. A checkpoint is the durable position up to which a subscription has processed. A consumer group splits one subscription among several members. A visibility timeout is PGMQ's mechanism for redelivery: a message that was read becomes invisible for that many seconds and reappears if it was not deleted; the shibuya PGMQ adapter's default is 30 seconds. A lease is a row that names an owner and an expiry time; ownership lapses when the owner stops renewing. An advisory lock is a PostgreSQL lock on an application-chosen integer instead of a row. A backend is the server process PostgreSQL forks for each client connection; the postmaster is the parent server process. `LISTEN`/`NOTIFY` is PostgreSQL's best-effort publish-subscribe; kiroku uses it to wake subscribers. The write-ahead log (WAL) is what PostgreSQL replays after a crash; with `fsync` and `synchronous_commit` off (the `ephemeral-pg` default) an acknowledged commit can be lost in a crash, which is why crash scenarios require `pg.durability=durable`. `SIGKILL` ends a process immediately with no clean-up, `SIGTERM` asks it to exit, `SIGSTOP` and `SIGCONT` freeze and thaw it. A process group is a set of processes that can be signalled together; an orphan is a child that outlives its parent. Quiescence means all work has reached a terminal state. Linearizability means a concurrent history of operations can be explained by some sequential order that respects real time. Shrinking is a property-testing library reducing a failing input to a minimal one. An external sort sorts more data than fits in memory by sorting chunks to temporary files and merging them. JSON Lines (JSONL) is one JSON value per line. OKF is the house format for document bundles (Markdown with YAML frontmatter) validated by the `okf` tool against a profile; an ADR is an Architecture Decision Record.

Why this toolkit exists. keiro's own MasterPlan `mori://shinzui/keiro/masterplans/22-make-the-test-infrastructure-exercise-real-crash-and-production-semantics` (Mori cannot resolve plan URIs yet; the file is `/Users/shinzui/Keikaku/bokuno/keiro/docs/masterplans/22-make-the-test-infrastructure-exercise-real-crash-and-production-semantics.md`) records that the runtime's "crash" tests use hand-built stranded rows, a thrown `SimulatedCrash` exception, or `killThread`, "which delivers an async exception and runs the graceful bracket cleanup a real `kill -9` skips", so for example the shard fail-over tests exercise graceful lease release, never lease expiry. Its child `mori://shinzui/keiro/plans/132-add-real-crash-window-tests-on-a-durability-enabled-fixture` designed a durable fixture (`fsync`, `synchronous_commit` and `full_page_writes` on) and backend-kill helpers but was never started, and it explicitly left postmaster crashes and process kills out of scope. It also warns that a kill test on the default non-durable fixture can pass because committed transactions were lost. `keiro-pgmq/test/Main.hs` line 661 in `mori://shinzui/keiro` still carries a pending test waiting for "a deterministic keiro-pgmq-level transient polling fault injector". This plan delivers those missing tools once, for every layer.

Prior art that was read and what is kept. The old `kiroku-bench` project (not registered in Mori; `https://github.com/shinzui/kiroku-bench`, checkout `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku-bench`) has `kiroku-bench/src/Kiroku/Bench/Delivery.hs`, a 269-line produced-versus-delivered tracker. Its shape is right — record every produced global position, record every delivered position per subscriber, compute missing, duplicate, out-of-order and foreign sets, write a verdict JSON — and its flaws are instructive: it keeps everything in a `Map Int64` and `Seq Int64` in memory, it stamps events with a process-local monotonic clock, and duplicates never fail the verdict. `mori://shinzui/load-testing-infra` holds an unstarted design for the same problem in `docs/masterplans/5-kiroku-correctness-under-load-and-event-ordering-verification.md` and `docs/plans/21-…`, `22-…`, `23-…`, `25-…` and `17-…` (under `/Users/shinzui/Keikaku/bokuno/load-testing-infra/docs/`). Kept from it: JSONL ledgers written through one handle guarded by an `MVar`, identity carried in event metadata as writer index and per-writer sequence, the rule that a verdict must "detect a missing global position even when a duplicate keeps the total count looking correct", a failure matrix (restart PostgreSQL, reject versus drop packets to port 5432, memory limit, disk fill, `kill -9`), and the observation that rejecting and dropping packets exercise different recovery paths. Two errors in that material: its per-category SQL selects `stream_events.global_position`, a column that does not exist (the global position is the `stream_version` of the row with `stream_id = 0`), and it assumes producer and consumer share one process clock.

Facts verified in the sibling sources that the design depends on. `mori://shinzui/ephemeral-pg` (`/Users/shinzui/Keikaku/bokuno/ephemeral-pg-project/ephemeral-pg`, version 0.3.1.0) exports `start`, `stop`, `restart :: Database -> IO (Either StartError Database)`, `Config` with `postgresSettings :: [(Text, Text)]` and `shutdownMode :: Last ShutdownMode` (`ShutdownGraceful` sends `SIGTERM`, `ShutdownFast` `SIGINT`, `ShutdownImmediate` `SIGQUIT`), and `EphemeralPg.Database` exposes `Database` with `dataDirectory`, `socketDirectory`, `port` and `process :: PostgresProcess`, whose `pid :: CPid` is the postmaster's process id. The server listens on a Unix socket and also on TCP `127.0.0.1:<port>` with trust authentication, which is what lets the proxy sit in front of it. `restart` restarts on the same data directory and port but passes `defaultConfig` to the new postmaster, so extra `postgresArgs` are lost while settings written to `postgresql.conf` persist; it returns a new `Database` value. In `mori://shinzui/kiroku` (`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`), `kiroku-store/src/Kiroku/Store/Notification.hs` sets `application_name` to `kiroku-listener` on the one `LISTEN` connection per store, and the schema (package `kiroku-store-migrations`, cohort pin 0.4.0.0) has `kiroku.streams`, `kiroku.events`, `kiroku.stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)`, `kiroku.subscriptions`, `kiroku.dead_letters` and the frozen public view `kiroku.subscription_checkpoints_v1 (subscription_name, consumer_group_member, checkpoint_position, checkpoint_updated_at)`. kiroku serialises appends on the `$all` row, so global positions are contiguous today, but its documented contract is only "strictly increasing and totally ordered". In `mori://shinzui/keiro` (`/Users/shinzui/Keikaku/bokuno/keiro`, version 0.17.0.0) the tables are `keiro.keiro_outbox` (status `pending`, `publishing`, `sent`, `rejected`, `failed`, `dead`; stuck `publishing` rows are judged by `updated_at`), `keiro.keiro_inbox` (`processing`, `completed`, `failed`; unique on `source, dedupe_key`), `keiro.keiro_timers` (`scheduled`, `firing`, `fired`, `cancelled`, `dead`; `fire_at`, `updated_at`, `fired_event_id`), `keiro.keiro_workflows` (`leased_by`, `lease_expires_at`, `generation`), `keiro.keiro_workflow_steps`, `keiro.keiro_subscription_shards` (`owner_worker_id`, `lease_expires_at`), `keiro.keiro_dead_letters` and `keiro.keiro_projection_dedup`. `keiro/src/Keiro/Wake.hs` defines `newtype WakeSignal = WakeSignal { waitForWake :: Int -> IO WakeReason }` with `WakeReason = WokenByNotify | WokenByTimeout` and `neverWake`, and `Keiro.Workflow.Resume.runPollLoopWith :: WakeSignal -> Int -> IO () -> IO ()` accepts any signal. keiro has no clock abstraction and three clock regimes: functions that take `now :: UTCTime` from the caller (timer and outbox claims), functions that call `getCurrentTime` internally, and SQL that uses `now()` (leases, back-off), which tests can only influence by back-dating rows. PGMQ (`mori://shinzui/pgmq-hs`, package `pgmq-migration` 0.6.1.0) creates per-queue tables `pgmq.q_<queue>` and `pgmq.a_<queue>` with `msg_id`, `read_ct`, `enqueued_at`, `last_read_at`, `vt`, `message`, `headers`, plus `pgmq.meta`. hedgehog 1.7 (the version kiroku's build resolves) provides `Hedgehog.Internal.Runner.checkReport :: PropertyConfig -> Size -> Seed -> PropertyT m () -> (Report Progress -> m ()) -> m (Report Result)`, `Hedgehog.Internal.Seed.from :: Word64 -> Seed`, `Gen.sequential`, `Gen.parallel`, `executeSequential`, `executeParallel`, and `FailureReport` with `failureShrinks`, `failureShrinkPath`, `failureAnnotations`, `failureMessage`.

ADR context. There is no local ADR corpus relevant to this plan yet: `docs/adr/` is created by the bootstrap plan and at most holds its two records (layer packages never import one another; every result carries a resolved cohort identity); scan its filenames before starting and read anything that mentions processes, faults or verdicts. The relevant cross-repository decisions are these. `mori://shinzui/keiro/okf/adrs/concepts/ADR-25` requires worker loops to isolate failures per pass and per item and keep running, which is what the backend-kill and proxy injectors put under test. `mori://shinzui/keiro/okf/adrs/concepts/ADR-24` and `mori://shinzui/keiro/okf/adrs/concepts/ADR-42` freeze keiro's deterministic identifiers and the producer outbox identity, which is why a fact's `id` can be an exact expected identifier and "exactly N effects per idempotency key" is checkable. `mori://shinzui/kiroku/okf/adrs/concepts/ADR-2` makes consumer groups static hash partitions, the basis of the ownership checker's use for group members, and `mori://shinzui/kiroku/okf/adrs/concepts/ADR-4` makes ordinary checkpoint saves monotonic and rewinds an explicit separate operation, the basis of the checkpoint checker. `mori://shinzui/kiroku/okf/adrs/concepts/ADR-6` freezes `kiroku.subscription_checkpoints_v1`, which is why the oracle reads that view and not the underlying table. `mori://shinzui/kiroku/okf/adrs/concepts/ADR-3` fixes the dedicated `kiroku` schema and the channel name `<schema>.events`. This plan owns two new ADRs, named in the MasterPlan: "crash means SIGKILL of a process or termination of a backend, never a thrown exception" (milestone 3) and "invariants are labelled contract or implementation; only contract invariants block" (milestone 2; first exercised for real by the gapless-position check in `docs/plans/9-cover-kiroku-in-isolation.md`). Create each with `okf id next docs/adr --profile docs/adr/profile.dhall ADR`, add a line with `okf log add`, and validate with `okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce`.


## Plan of Work

The work adds one package, `kenshou-check/`, with modules under `Kenshou.Check.*`, a three-line registration in `kenshou-cli`, two JSON Schemas under `schemas/`, and two ADRs. It proceeds in five milestones, each ending with something runnable.

### Milestone 1 — The bounded ledger and the verdict document

Scope: the fact record, the ledger writer and reader, the external sort, the verdict document, and the adapter onto the kernel. At the end a scenario can record millions of facts from several threads into rotated files, merge them in bounded memory, and write a verdict that the kernel lists in the run result. Run `cabal test kenshou-check-test` and `cabal run kenshou -- run selftest/check/correctness/ledger-detects-loss-dup-reorder --out /tmp/kenshou-out`; expect the tests to pass and `verdicts/ledger-integrity.json` with status `held`.

Create `kenshou-check/kenshou-check.cabal` with a library (`hs-source-dirs: src`), the test suite `kenshou-check-test` (`test/Main.hs`, `ghc-options: -threaded -rtsopts -with-rtsopts=-N`), and the executable `kenshou-check-fixture-worker` (`fixture/Main.hs`), which the test suite names in `build-tool-depends`. Copy the common stanza (language, default extensions, warnings) from `kenshou-core/kenshou-core.cabal`.

`kenshou-check/src/Kenshou/Check/Fact.hs` defines the unit of evidence. A fact says that a named process did something to an identified item at a time.

```haskell
data FactKind
  = Intent | Produced | Observed | Effect | Terminal
  | Acquired | Acted | Released | Checkpoint
  | DisturbanceStart | DisturbanceEnd | Mark
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data ProcId = ProcId { role :: !Text, index :: !Int, incarnation :: !Int }

data Fact = Fact
  { kind  :: !FactKind
  , key   :: !Text          -- ordering or partition key: stream name, message group, lease name
  , seq   :: !Int64         -- producer-assigned per-key sequence starting at 1, or a position for Checkpoint
  , id    :: !Text          -- unique identity of the item: event id, message id, idempotency key
  , scope :: !Text          -- logical producer or consumer; defaults to "<role>/<index>"
  , proc  :: !ProcId
  , n     :: !Word64        -- arrival counter within this incarnation's ledger (total order per process)
  , mono  :: !Word64        -- GHC.Clock.getMonotonicTimeNSec; comparable only within one process
  , wall  :: !Int64         -- microseconds since the Unix epoch; comparable across processes within the skew bound
  , attrs :: !Aeson.Object  -- free form, e.g. {"gp": 1234, "attempt": 2, "owner": "w-7"}
  }
```

The JSON field names equal the record field names, `kind` is the lower-case hyphenated constructor name, and `proc` is rendered `"<role>/<index>.<incarnation>"`. The monotonic time never leaves the process in message metadata; when a scenario needs to stamp a message for a cross-process latency or ordering check it stamps wall-clock microseconds.

`kenshou-check/src/Kenshou/Check/Ledger.hs` writes files named `verdicts/ledger/<role>-<index>.<incarnation>.<segment>.jsonl` (segment is four digits from `0001`). The first line of every segment is a header object with `schema: "kenshou.ledger/v1"`, the run id, `proc`, the operating-system pid, the host name, the start wall and monotonic times, and `clock: {source, skewBoundMicros}`. The source is `same-host` with a bound of 1000 microseconds unless the environment variable `KENSHOU_CLOCK_SKEW_BOUND_MICROS` supplies a measured bound (the cell sets it from its time-synchronisation daemon); if facts from several hosts are merged and no bound was supplied, 50000 is assumed and the header says `assumed`. All threads of a process share one writer; an `MVar` guards the handle and the counter `n`, so lines are whole. `record` appends to a 64 KiB buffer; `recordDurable` appends and calls `hFlush`, handing the bytes to the kernel so that a later `SIGKILL` cannot lose them. The rule for scenario authors is: call `recordDurable` for `Observed`, `Effect`, `Acted` and `Intent` facts before the step they guard (the acknowledgement, the side effect, the call), and plain `record` otherwise. When a segment exceeds `segmentBytes` (default 64 MiB) the writer closes it and opens the next; closed segments are never reopened.

```haskell
data LedgerConfig = LedgerConfig { directory :: FilePath, proc :: ProcId, runId :: Text, segmentBytes :: Int, clock :: ClockInfo }
withLedger    :: LedgerConfig -> (LedgerWriter -> IO a) -> IO a
record        :: LedgerWriter -> FactKind -> Text -> Int64 -> Text -> Aeson.Object -> IO ()
recordDurable :: LedgerWriter -> FactKind -> Text -> Int64 -> Text -> Aeson.Object -> IO ()
flushLedger   :: LedgerWriter -> IO ()
```

`kenshou-check/src/Kenshou/Check/Ledger/Read.hs` exposes `newtype FactSource = FactSource { next :: IO (Maybe Fact) }`, `openSegment :: FilePath -> IO (LedgerHeader, FactSource)`, and `discoverLedgers :: FilePath -> IO LedgerSet` (all segments grouped by process and ordered by incarnation and segment, with each file's SHA-256 for the verdict's `inputs`). A final line without a newline, or a final line that does not parse, is a torn tail: it is dropped and counted. Any other unparseable line makes the ledger corrupt, which checkers report as `not-evaluated` with reason `corrupt-ledger`.

`kenshou-check/src/Kenshou/Check/Ledger/Sort.hs` provides the external sort. It reads a source, accumulates at most `runRecords` facts (default 200000), sorts them by the requested order, writes them to a temporary run file under `<run-dir>/verdicts/ledger/.sort/`, and merges runs through a `Data.Map`-based priority queue holding one fact per run. When there are more than 64 runs it merges in passes. Memory use is therefore proportional to `runRecords`, never to the ledger's size.

```haskell
data SortOrder = ByKeySeq | ByScopeKeyArrival | ByScopeArrival | ByKeyWall
sortedFacts :: SortConfig -> SortOrder -> (Fact -> Bool) -> LedgerSet -> (FactSource -> IO a) -> IO a
```

`ByKeySeq` orders by `(key, seq, kind, wall)` and serves loss, duplicate and effect counting; `ByScopeKeyArrival` orders by `(scope, key, incarnation, n)` and serves per-key order; `ByScopeArrival` by `(scope, incarnation, n)` serves global order and checkpoints; `ByKeyWall` serves ownership. Temporary runs are deleted when the callback returns.

`kenshou-check/src/Kenshou/Check/Verdict.hs` defines the document this plan owns. One file per checker instance is written to `verdicts/<checker>.json`; `checker` is a name unique within the run (for example `no-loss.subscriber-a`) and `invariant` is the kind of check.

```haskell
data InvariantClass = Contract | Implementation
data VerdictStatus  = Held | Violated | NotEvaluated

data Verdict = Verdict
  { checker :: Text, invariant :: Text, cls :: InvariantClass, status :: VerdictStatus
  , reason :: Maybe Text, summary :: Text
  , counts :: Map Text Int64            -- always "examined" and "violations"; checker-specific keys besides
  , parameters :: Aeson.Value           -- budgets, windows, deadlines, skew bound actually used
  , counterExamples :: [Aeson.Value], counterExamplesTruncated :: Bool   -- first 20 by default
  , inputs :: [InputRef]                -- relative path and sha256 of every ledger segment or oracle result read
  , replay :: Maybe Replay              -- seed, size, shrink path and command line, for model-based verdicts
  , checkedAt :: UTCTime, durationMillis :: Int64 }

writeVerdict         :: FilePath -> RunInfo -> Verdict -> IO FilePath
outcomeFromVerdicts  :: [Verdict] -> Outcome
```

The rendered document adds `schema: "kenshou.verdict/v1"`, `runId`, `scenario`, renders `cls` as `class` with values `contract` and `implementation`, renders `status` as `held`, `violated`, `not-evaluated`, and adds the derived boolean `blocking` (true exactly when the class is `contract`). `outcomeFromVerdicts` returns `failed` if any contract verdict is `violated`, otherwise `inconclusive` if a contract verdict is `not-evaluated` with reason `search-budget-exhausted`, otherwise `errored` if any contract verdict is `not-evaluated`, otherwise `passed`. Add `schemas/kenshou.verdict.v1.schema.json` and `schemas/kenshou.ledger-fact.v1.schema.json`, following whatever file naming the kernel plan established in `schemas/`, with golden fixtures under `kenshou-check/test/golden/` and a unit test that validates emitted documents the same way the kernel's tests do.

`kenshou-check/src/Kenshou/Check/Scenario.hs` is the only module that touches the kernel's `RunContext`. `withCheck :: RunContext -> (CheckEnv -> IO a) -> IO a` creates `verdicts/ledger/`, opens the harness process's own ledger (proc `harness/0.0`), and exposes the run id, the seed, the run directory, the skew bound and a logger. `finishWithVerdicts :: CheckEnv -> [Verdict] -> IO ScenarioReport` writes the verdict files, registers the kernel's `verdicts` summary section (a list of `{checker, invariant, class, status, violations}` plus `nonBlockingViolations`), and returns a report whose outcome is `outcomeFromVerdicts`. `deriveSeed :: Word64 -> Text -> Word64` gives every consumer of randomness (fault schedule, generator, doctoring) an independent stream from the run seed and a label.

`kenshou-check/src/Kenshou/Check/Selftest.hs` exports `bundle :: LayerBundle` with layer `selftest`; register it by adding one import and one list element to `kenshou-cli/src/Kenshou/Cli/Registry.hs` and `kenshou-check` to `build-depends` in `kenshou-cli/kenshou-cli.cabal`. In this milestone the scenario `selftest/check/correctness/ledger-detects-loss-dup-reorder` (module `Kenshou.Check.Selftest.LedgerNonVacuity`) has its first form: four threads record `ledger.facts` facts, the writer rotates, and the verdict `ledger-integrity` (class `contract`) holds when the merged `ByKeySeq` stream contains exactly the recorded facts in order with no torn or corrupt line. If the run-time system was started with `-T`, it also asserts that `GHC.Stats` `max_live_bytes` stayed under `ledger.max-live-mib`.

### Milestone 2 — The invariant checker library

Scope: the checkers, disturbance windows, SQL oracles, and the non-vacuity self-test in its final form. At the end `kenshou run selftest/check/correctness/ledger-detects-loss-dup-reorder` writes ten verdicts that hold on the clean ledger plus `verdicts/non-vacuity.json`, which holds only if every doctored ledger made its targeted checker report `violated`.

`kenshou-check/src/Kenshou/Check/Window.hs` defines `DisturbanceWindow { label :: Text, target :: Text, start :: Int64, end :: Maybe Int64 }` in wall-clock microseconds, read from `DisturbanceStart` and `DisturbanceEnd` facts by `loadWindows :: LedgerSet -> IO [DisturbanceWindow]` (windows are few, so they are held in memory), and `newtype SkewBound`. A window is the interval during which a fault was active or a process was dead and recovering: for a kill it runs from the signal to the restarted process's `ready` message.

`kenshou-check/src/Kenshou/Check/Invariant.hs` defines a checker as a strict fold over one sorted view, so state is constant or proportional to one key.

```haskell
data CheckFold = forall s. CheckFold { initial :: s, step :: s -> Fact -> s, finish :: s -> CheckResult }
data Checker = Checker { name :: Text, invariant :: Text, cls :: InvariantClass, order :: SortOrder
                       , select :: Fact -> Bool, allowEmpty :: Bool, fold :: CheckFold }
runCheckers :: CheckEnv -> LedgerSet -> [Checker] -> IO [Verdict]
```

`runCheckers` groups checkers by `order`, produces each sorted view once, and feeds every checker of the group in a single pass. The checkers live in `Kenshou.Check.Invariant.NoLoss`, `.Duplicates`, `.Order`, `.Gapless`, `.Effects`, `.Quiescence`, `.Checkpoint` and `.Ownership`, and are defined as follows; each is class `contract` unless stated.

`noLoss` holds when every `Produced` fact (an acknowledged item) has at least one `Observed` fact with the same `key`, `seq` and `id` in the named consumer scope. `Intent` facts without a matching `Produced` are counted as `indeterminate` and never required; an `Observed` fact with no `Intent` at all is a phantom and a violation. `duplicatesWithin` takes a `DuplicateBudget { maxPerWindow :: Maybe Int, maxRedeliveryDelayMicros :: Maybe Int64 }`. A second observation of an item in the same scope is excused when some disturbance window of that scope lies between the two observations, allowing for the skew bound: the first observation is no later than the window's end plus skew and the second no earlier than its start minus skew. Unexcused duplicates are violations; so are excused duplicates beyond `maxPerWindow` for one window (for a kiroku subscription the budget is its `batchSize`, because checkpoints are saved per batch) and excused duplicates later than `maxRedeliveryDelayMicros` after the window's end (for PGMQ, one visibility timeout). `perKeyOrder` holds when, within each scope and key, the arrival order of first observations is increasing in `seq`; replays of already-seen items are the duplicate checker's business, not an order violation. `globalOrder` holds when, within each scope, the position in the named attribute (for kiroku `gp`) strictly increases in arrival order, except that it may rewind at an incarnation boundary or inside a disturbance window. `gaplessPositions` holds when the positions of acknowledged facts form a contiguous range; its class is `implementation`, because kiroku documents positions only as strictly increasing. `exactlyNEffects` holds when every `id` has exactly N `Effect` facts (default 1). `eventualQuiescence` holds when every acknowledged item has a `Terminal` fact no later than `deadlineMicros` after the later of its production and the end of the last disturbance window. `monotonicCheckpoints` holds when `Checkpoint` facts of one `key` (subscription and member) never decrease in arrival order, except across an explicitly recorded `Mark` with `attrs.reset = true`. `disjointOwnership` builds, per lease `key`, each owner's intervals from `Acquired` to `Released` (or to the owner's kill instant), and holds when no `Acted` fact by one owner falls inside another owner's interval or strictly between two `Acted` facts of another owner by more than the skew bound; it is the check that catches a worker frozen by `SIGSTOP` that wakes after its lease expired and acts anyway.

`kenshou-check/src/Kenshou/Check/Oracle.hs` treats the runtime's own tables as the durable truth. `runOracle :: PostgresEnv -> OracleQuery a -> IO (OracleResult a)` runs a named SQL text on a dedicated `hasql` connection with `application_name` `kenshou-oracle` and saves the rows to `verdicts/oracle/<name>.json` so that they become verdict inputs. `sampleOracle` runs a query periodically and writes each row as a fact (for example `Checkpoint` facts from the checkpoint view) into the ledger of proc `oracle/0.0`. `reconcile :: Text -> OracleQuery [ItemRef] -> Checker` compares acknowledged facts with rows: an acknowledged item missing from the table is a violation (an acknowledged write was lost), an indeterminate item may be present or absent. The catalogue is in three modules so that a coverage plan imports the names, not the SQL.

```sql
-- Kenshou.Check.Oracle.Kiroku.globalPositionGaps  (class implementation)
SELECT count(*) AS event_count,
       coalesce(max(stream_version) - min(stream_version) + 1 - count(*), 0) AS gap_count
FROM kiroku.stream_events WHERE stream_id = 0;

-- Kenshou.Check.Oracle.Kiroku.streamVersionGaps  (class contract; zero rows expected)
SELECT stream_id, count(*) AS cnt, min(stream_version) AS min_v, max(stream_version) AS max_v
FROM kiroku.stream_events WHERE stream_id <> 0
GROUP BY stream_id
HAVING max(stream_version) - min(stream_version) + 1 <> count(*) OR min(stream_version) <> 1;

-- Kenshou.Check.Oracle.Kiroku.checkpoints
SELECT subscription_name, consumer_group_member, checkpoint_position
FROM kiroku.subscription_checkpoints_v1;

-- Kenshou.Check.Oracle.Keiro.outboxNonTerminal  (quiescence when the count reaches zero)
SELECT count(*) FROM keiro.keiro_outbox WHERE status NOT IN ('sent', 'rejected', 'dead');

-- Kenshou.Check.Oracle.Pgmq.queueDepth  (the queue name is quoted with format('%I'))
SELECT count(*) AS visible_or_leased, coalesce(max(read_ct), 0) AS max_read_ct FROM pgmq.q_orders;
```

`Kenshou.Check.Oracle.Keiro` also names `inboxByStatus`, `timersByStatus`, `workflowLeases` (`leased_by`, `lease_expires_at` from `keiro.keiro_workflows`), `shardOwners` (from `keiro.keiro_subscription_shards`; sampled, it yields `Acquired` facts and detects a premature steal, an owner change while the previous `lease_expires_at` was still in the future) and `deadLetters`. Both gap queries are valid only for scenarios that do not truncate or hard-delete streams; the scenario author states that by choosing them. `awaitQuiescence :: PostgresEnv -> OracleQuery Int64 -> Deadline -> IO QuiescenceResult` polls a count until it is zero.

The self-test in its final form has tier `smoke`, placement `either`, needs no PostgreSQL, and supports only `telemetry.tracing=off` and `telemetry.metrics=off`. Knobs: `ledger.facts` (integer, default 20000, 1000 to 5000000), `ledger.keys` (integer, default 64, 1 to 100000), `ledger.observers` (integer, default 2, 1 to 16), `ledger.sort-run-records` (integer, default 5000, 100 to 1000000; the small default forces a real multi-run merge), `ledger.max-live-mib` (integer, default 256). From the seed it writes a clean ledger that includes two honest disturbance windows with in-budget duplicates, runs all checkers (every verdict must hold), then produces one doctored copy per mutation and reruns: drop one observation (`no-loss`), add a duplicate outside any window and another that exceeds the budget inside one (`duplicates`), swap two first observations of one key (`per-key-order`), swap two positions (`global-order`), delete one position (`gapless-positions`), add a second effect (`exactly-n-effects`), delete a terminal fact (`eventual-quiescence`), regress a checkpoint (`monotonic-checkpoints`), and make a frozen owner act inside another's interval (`disjoint-ownership`). The verdict `non-vacuity` (class `contract`) holds when every mutation turned its targeted checker to `violated` with the doctored fact among the counter-examples and left the checkers it should not affect at `held`; the doctored results are embedded in that verdict's `parameters`, never written as separate verdict files, so that no tool mistakes them for findings.

### Milestone 3 — Process control for worker roles

Scope: supervision of child processes. At the end a scenario can start worker roles, talk to them, kill, freeze, thaw and restart them, and every kill is a recorded disturbance window. Run `cabal run kenshou -- run selftest/check/concurrency/kill-and-restart-worker --out /tmp/kenshou-out`; expect exit code 0, a `duplicates` verdict whose `counts.excused` is greater than zero and whose `counts.violations` is zero, and no surviving child process.

`kenshou-check/src/Kenshou/Check/Process.hs` is built on `typed-process` and `unix`.

```haskell
data ProcessSpec = ProcessSpec { proc :: ProcId, executable :: FilePath, args :: [String], env :: [(String, String)] }
roleProcess      :: CheckEnv -> Text -> Int -> Aeson.Value -> IO ProcessSpec   -- this binary: ["worker", "--role", name, …]
withSupervisor   :: CheckEnv -> (Supervisor -> IO a) -> IO a
spawn            :: Supervisor -> ProcessSpec -> IO Child
awaitReady       :: Child -> Int -> IO ()
sendCommand      :: Child -> ControlCommand -> IO ()
progress         :: Child -> STM ProgressSnapshot
awaitMark        :: Child -> Text -> Int -> IO ()
signalChild      :: Supervisor -> Child -> ChildSignal -> IO ()    -- Term | Kill | Stop | Cont
killChild        :: Supervisor -> Child -> IO ()                   -- SIGKILL, waits for exit, opens a disturbance window
restartChild     :: Supervisor -> Child -> IO Child                -- next incarnation; closes the window on "ready"
stopGracefully   :: Supervisor -> Child -> Int -> IO ExitCode      -- stop command, then SIGTERM, then SIGKILL, each escalation recorded
withRestartLoop  :: Supervisor -> RestartPolicy -> ProcessSpec -> (IO Child -> IO a) -> IO a
crashWindows     :: Supervisor -> IO [DisturbanceWindow]
```

`roleProcess` uses `System.Environment.getExecutablePath` so that the child is the same binary, which is also what makes deployment to a cell simple; the exact flags of `kenshou worker` come from the kernel. `spawn` starts the child in its own process group, sets `PGAPPNAME=kenshou-<first 8 characters of the run id>-<role>-<index>` in its environment so that every libpq connection the role opens is identifiable in `pg_stat_activity` without the runtime library's cooperation, passes the ledger directory, run id, incarnation and skew bound, and wires the control channel. The control protocol is line-delimited JSON whose message types are data in `Kenshou.Core.Role`: from the supervisor `start` (with role arguments) and `stop` (with a deadline); from the worker `ready`, `progress` (named counters and named marks such as `claimed`), `facts` (a batch of fact objects, for roles that cannot write to the run directory; the supervisor appends them to `verdicts/ledger/<role>-<index>.<incarnation>.relay.jsonl`) and `stopped`. If the kernel's vocabulary lacks `progress` or `facts`, add them there additively and update Integration Point 8 of the MasterPlan first. The expected transport is commands on the child's standard input, events on its standard output and human logs on standard error; the supervisor copies standard error to `logs/<proc>.stderr.log`, every protocol line to `logs/<proc>.control.jsonl`, and any non-JSON line on the event stream to `logs/<proc>.stdout.log` instead of failing. `RestartPolicy { initialBackoffMillis, maxBackoffMillis, multiplier, maxRestarts }` defaults to 100, 5000, 2 and 50.

Every signal is recorded in the harness ledger before it is sent: `DisturbanceStart` with `key` equal to the target's scope and `attrs` naming the signal and the child's pid, and `DisturbanceEnd` when the next incarnation reports `ready` (for `SIGSTOP`, when `SIGCONT` is sent). These are the windows the duplicate checker consumes. Orphans are prevented three ways: `withSupervisor` kills every process group it created with `SIGKILL` when it exits, normally or by exception; a worker must exit when its control input reaches end-of-file, which covers a supervisor that was itself killed (if the kernel's `kenshou worker` dispatch does not do this yet, add `exitImmediately (ExitFailure 70)` on end-of-file there); and `spawn` appends `{pid, pgid, startedAt, proc}` to `logs/pids.jsonl`, which `sweepOrphans :: FilePath -> IO [CPid]` uses to kill survivors of an earlier run only when the recorded start time still matches the live process.

The scenario `selftest/check/concurrency/kill-and-restart-worker` (module `Kenshou.Check.Selftest.KillRestart`, role `selftest-check-consumer`) has tier `smoke`, placement `either`, needs no PostgreSQL and supports only the `off` telemetry values. The role emulates an at-least-once consumer: it walks items 1 to `worker.items`, records a durable `Observed` fact for each, and saves its position to a checkpoint file only every `worker.checkpoint-every` items, so each kill forces a replay of at most that many. Knobs: `worker.items` (integer, default 5000), `worker.rate-per-second` (integer, default 2000), `worker.checkpoint-every` (integer, default 50, 1 to 1000), `kill.count` (integer, default 3, 0 to 20), `kill.signal` (`SIGKILL` default, or `SIGTERM`), `pause.millis` (integer, default 300), `restart.backoff-millis` (integer, default 100). The harness kills the role `kill.count` times at seeded instants, freezes it once for `pause.millis`, and finally stops it gracefully. Verdicts, all `contract`: `no-loss`, `duplicates` with budget `maxPerWindow = worker.checkpoint-every`, `per-key-order`, `eventual-quiescence`, and `process-control`, which holds when each kill produced a new pid and an exit status of "killed by signal 9", no fact has a wall time inside the freeze window, the graceful stop produced the mark `drained` that a kill never produces, and no process of the run survives. A second, shorter phase runs the role with `--bug skip-after-restart`, which loses one item after each restart; the scenario passes only if `no-loss` reports `violated` for that phase, and that expected violation is embedded in `process-control`'s parameters, not written as a failing verdict.

### Milestone 4 — PostgreSQL, network and wake-up fault injectors

Scope: a common fault interface, a schedule language, and the injectors. At the end `selftest/check/concurrency/postgres-backend-kill` and `selftest/check/concurrency/proxy-partition` pass, and a coverage plan can write `at (seconds 20) (terminateBackends pg (ByApplicationName "kiroku-listener"))`.

`kenshou-check/src/Kenshou/Check/Fault.hs`:

```haskell
data Fault = Fault { name :: Text, target :: Text, availability :: IO Availability, inject :: IO FaultHandle }
data FaultHandle = FaultHandle { heal :: IO (), details :: Aeson.Value }
data Availability = Available | Unavailable Text

at       :: Duration -> Fault -> Schedule
every    :: Duration -> Fault -> Schedule          -- seeded jitter of ±10 % unless `exactly` is applied
during   :: PhaseName -> Schedule -> Schedule      -- offsets count from the kernel's phase marker: warm-up, steady, drain
onMark   :: Child -> Text -> Fault -> Schedule     -- fire when a worker reports a named mark, e.g. "claimed"
holding  :: Duration -> Fault -> Fault             -- heal automatically after the duration
withSchedule :: CheckEnv -> Schedule -> IO a -> IO a
```

`Schedule` is a `Monoid`. `withSchedule` runs the schedule beside the action, records a `DisturbanceStart` and `DisturbanceEnd` fact around every injection (the end includes `recoveryGraceMicros`, default one second), heals every outstanding fault when the action ends, and turns an injector's own failure into the exception `FaultInjectionFailed`, which a scenario reports as `errored`.

`kenshou-check/src/Kenshou/Check/Fault/Postgres.hs` acts through a dedicated administrative `hasql` connection with `application_name` `kenshou-fault`. `data BackendSelector = ByApplicationName Text | ByQueryPattern Text | ByPid Int32 | AllOtherBackends`; the patterns are SQL `LIKE` patterns. `listBackends` selects `pid, application_name, state, wait_event_type, wait_event, left(query, 200)` from `pg_stat_activity` where `datname = current_database()`, `pid <> pg_backend_pid()` and `backend_type = 'client backend'`; `terminateBackends :: PostgresEnv -> BackendSelector -> Fault` calls `pg_terminate_backend(pid)` for each match and records the victims; `terminateOneBackend` picks one victim with the seeded generator. kiroku's `LISTEN` connection is `ByApplicationName "kiroku-listener"`; a role's pool is `ByApplicationName "kenshou-<run>-<role>-%"`. `holdLock :: PostgresEnv -> LockTarget -> Fault` with `LockTarget = TableLock Text Text | RowLock Text Text | AdvisoryLock Int64` opens a transaction, takes the lock (`LOCK TABLE … IN <mode> MODE`, `SELECT … FOR UPDATE`, or `pg_advisory_xact_lock`), and rolls back on `heal`. `hogConnections :: PostgresEnv -> Int -> Fault` holds idle connections to starve the server's connection slots. `withStatementTimeout :: Int -> ProcessSpec -> ProcessSpec` sets `PGOPTIONS=-c statement_timeout=<ms>` for one child, which needs no support from the runtime library. `crashPostmaster :: PostgresEnv -> CrashMode -> Fault` with `CrashMode = ImmediateShutdown | FastShutdown | KillPostmaster` is available only for an ephemeral environment: it signals the postmaster pid (`SIGQUIT`, `SIGINT`, or `SIGKILL` followed by waiting until no process holds the data directory), waits for exit, and on `heal` calls `EphemeralPg.restart`, stores the returned `Database` back into the environment, and records the old and new postmaster pid and `pg_postmaster_start_time()` in the closing disturbance fact. This needs two things from `Kenshou.Core.Env.Postgres`: access to the ephemeral `Database` in a mutable cell, and the server's TCP host and port. If the kernel does not expose them, add the accessors `postmasterControl :: PostgresEnv -> Maybe PostmasterControl` and `tcpEndpoint :: PostgresEnv -> (HostName, PortNumber)` there and update Integration Point 7 of the MasterPlan first. For an external server `crashPostmaster` is `Unavailable`.

`kenshou-check/src/Kenshou/Check/Fault/Network.hs` is a TCP proxy that runs inside the harness process, never inside a worker that may be killed.

```haskell
data ProxyMode = Forward | Latency Int | Throttle Int | Stall | Blackhole | RefuseNew
withTcpProxy  :: IO (HostName, PortNumber) -> (TcpProxy -> IO a) -> IO a   -- listens on 127.0.0.1, port chosen by the OS
proxyPort     :: TcpProxy -> PortNumber
setProxyMode  :: TcpProxy -> ProxyMode -> IO ()
resetConnections :: TcpProxy -> IO Int                                    -- close with SO_LINGER 0 so the peer sees RST
proxyFault    :: TcpProxy -> ProxyMode -> Fault
proxiedConnectionString :: PostgresEnv -> TcpProxy -> Text                -- host=127.0.0.1 port=<proxy> dbname=… user=…
```

Each accepted connection gets two copying threads that consult a `TVar ProxyMode` for every chunk: `Latency` delays each chunk by the given milliseconds in each direction, `Throttle` limits bytes per second, `Stall` stops copying while keeping the sockets open (bytes queue in the kernel, the client sees a hung server), `Blackhole` reads and discards, and `RefuseNew` closes new connections immediately. The upstream address is an `IO` action resolved per connection so that the proxy's port can be reserved before the server it fronts is started; the Kafka broker fixture in `docs/plans/11-cover-the-kafka-transport-edge-with-a-disposable-broker.md` needs that, because a Kafka broker must advertise the proxy's address for clients to keep using it. On a cell the same `Fault` values can instead come from `Kenshou.Check.Fault.Cell`.

`kenshou-check/src/Kenshou/Check/Fault/Wake.hs` provides `newWakeControl :: IO WakeControl`, `setWakePolicy :: WakeControl -> WakePolicy -> IO ()` with `WakePolicy = PassThrough | DropAll | DropFraction Double | DelayMicros Int`, and `faultyWait :: WakeControl -> (r -> Bool) -> r -> (Int -> IO r) -> (Int -> IO r)`, which turns a dropped notification into waiting out the rest of the timeout and returning the timeout value. The keiro layer adapts it in one line, `WakeSignal (faultyWait ctl (== WokenByNotify) WokenByTimeout (waitForWake real))`; `DropAll` behaves as keiro's `neverWake`. Dropping notifications at the source is done with `terminateBackends … (ByApplicationName "kiroku-listener")`. `kenshou-check/src/Kenshou/Check/Fault/Time.hs` serves the two clock regimes that can be influenced: `newVirtualNow :: IO (IO UTCTime, NominalDiffTime -> IO ())` yields a `now` action and a way to jump it forward, for the keiro functions that take `now` from the caller; `backdateRows :: PostgresEnv -> BackdateTarget -> NominalDiffTime -> IO Int64` with `BackdateTarget { table, column, predicate }` subtracts an interval from a timestamp column, for state judged by the database clock, for example `keiro.keiro_subscription_shards.lease_expires_at`, `keiro.keiro_workflows.lease_expires_at`, `keiro.keiro_outbox.updated_at`, `keiro.keiro_timers.updated_at` and `pgmq.q_<queue>.vt`. Code that calls `getCurrentTime` internally can only be tested with short real timeouts. `kenshou-check/README.md` documents these three regimes and the checker catalogue. `kenshou-check/src/Kenshou/Check/Fault/Cell.hs` provides `cellFault :: Text -> Aeson.Value -> Fault` for `net-reject`, `net-drop`, `net-delay`, `disk-fill` and `memory-limit`; it runs `$KENSHOU_CELL_FAULT_HOOK inject <fault> <json>` (which prints a token) and `$KENSHOU_CELL_FAULT_HOOK heal <token>`, and is `Unavailable` when the variable is unset.

The scenario `selftest/check/concurrency/postgres-backend-kill` (module `Kenshou.Check.Selftest.BackendKill`, role `selftest-check-pg-writer`) has tier `standard`, placement `either`, requires a `PostgresEnv` with no runtime migrations, supports both values of `pg.durability` and of `pg.version`, and only the `off` telemetry values. It creates `kenshou_selftest.items (key text, seq bigint, id text primary key)`. Each of `writers` roles inserts one row per transaction, recording a durable `Intent` before and a `Produced` after the commit, and reconnects with bounded back-off on error; one more connection with `application_name` `kenshou-selftest-listener` runs `LISTEN kenshou_selftest`. Knobs: `writers` (integer, default 4, 1 to 32), `run.seconds` (integer, default 30, 10 to 600), `kill.every-seconds` (integer, default 5), `lock.hold-millis` (integer, default 2000), `crash.mode` (`immediate` default, `fast`, `kill`, `none`). The schedule terminates one writer backend every `kill.every-seconds`, terminates the listener once, holds `LOCK TABLE kenshou_selftest.items IN ACCESS EXCLUSIVE MODE` once, and, only when `pg.durability=durable` and the environment is ephemeral, crashes and restarts the postmaster once. Verdicts, all `contract`: `acknowledged-writes-survive` (a `reconcile` against the table: no `Produced` fact is missing, indeterminate intents may go either way), `writers-recover` (every writer produced again within ten seconds after each window), `lock-blocks-and-releases` (no `Produced` fact inside the lock window, none failed because of it), and `backends-terminated` (each injection found at least one victim and the victim's pid is gone from `pg_stat_activity`).

The scenario `selftest/check/concurrency/proxy-partition` (module `Kenshou.Check.Selftest.ProxyPartition`) has tier `smoke`, placement `either`, requires a `PostgresEnv`, and supports the same dimensions. One client thread connects through the proxy and runs one insert per `1/client.rate-per-second` seconds with a two-second statement and connect timeout, recording `Intent`, `Produced` and the latency. Knobs: `client.rate-per-second` (integer, default 50), `proxy.latency-millis` (integer, default 50), `proxy.stall-millis` (integer, default 2000), `proxy.blackhole-millis` (integer, default 3000). The schedule applies latency, stall, blackhole, then a reset. The verdict `proxy-effects` holds when the median latency inside the latency window is at least twice `proxy.latency-millis` minus 20 percent, no operation completes inside the stall window and the stalled one completes after it, operations inside the blackhole window fail by timeout, and the reset produces a connection error followed by a successful reconnect within one second; `acknowledged-writes-survive` is checked as above.

### Milestone 5 — Model-based testing support with replayable seeds

Scope: running hedgehog state-machine tests from scenarios, and a small linearizability checker. At the end `kenshou run selftest/check/correctness/model-replays-counterexample --seed 7` fails the embedded buggy model the same way every time and the scenario passes.

`kenshou-check/src/Kenshou/Check/Model.hs` wraps hedgehog 1.7. A state-machine test describes commands with a generator, an execution against the real system, and callbacks that update a model state and check outputs; hedgehog generates sequences (`Gen.sequential`) or a prefix with two concurrent branches (`Gen.parallel`) and shrinks a failing sequence.

```haskell
data ModelRun = ModelRun { name :: Text, cls :: InvariantClass, tests :: Int, size :: Int, property :: PropertyT IO () }
runModel            :: CheckEnv -> ModelRun -> IO Verdict
sequentialProperty  :: (forall v. state v) -> Range Int -> [Command Gen (PropertyT IO) state] -> PropertyT IO ()
parallelProperty    :: (forall v. state v) -> Range Int -> Range Int -> [Command Gen (PropertyT IO) state] -> PropertyT IO ()
```

`runModel` calls `Hedgehog.Internal.Runner.checkReport` with `Seed.from (deriveSeed runSeed name)`, no terminal output, and the configured test count. On `Failed` it renders the `FailureReport` (message, annotations holding the shrunk command list, shrink count, shrink path) into the verdict's first counter-example and fills `replay` with the seed, the size and the literal command `kenshou run <scenario> --seed <run seed>` plus the knobs in force. Because the generator depends only on the seed, a rerun regenerates the same sequence; when the system under test is nondeterministic the shrink may differ, which the verdict's summary states. `GaveUp` yields `not-evaluated`.

`kenshou-check/src/Kenshou/Check/Model/Linearizability.hs` checks recorded histories.

```haskell
data Completion o = Returned o | Failed | Indeterminate
data Operation i o = Operation { process :: Text, key :: Text, input :: i, invoked :: Int64, completed :: Maybe Int64, completion :: Completion o }
data SeqModel s i o = SeqModel { initial :: s, apply :: s -> i -> (o, s), agrees :: o -> o -> Bool }
data LinResult = Linearizable | NotLinearizable [Text] | Undecided
checkLinearizable :: Ord s => LinConfig -> SeqModel s i o -> [Operation i o] -> LinResult
registerModel     :: SeqModel (Maybe Int64) RegisterOp RegisterResult      -- read, write, compare-and-set
appendLogModel    :: SeqModel [Text] LogOp LogResult                       -- append returns a position, read returns a prefix
linearizability   :: Text -> InvariantClass -> SeqModel s i o -> (Fact -> Maybe (Operation i o)) -> Checker
```

Histories are split by `key` and checked independently. The search repeatedly picks an operation that was invoked before every pending operation completed, applies it to the model, and backtracks when the recorded result disagrees, memoising visited pairs of (set of linearised operations, model state); `Failed` operations are removed, `Indeterminate` ones may take effect at any later point or never. Times are wall-clock microseconds with the invocation moved earlier and the completion later by the skew bound, which can only make the check more permissive. `LinConfig { maxSteps }` defaults to 5000000; exhaustion is `Undecided`. `registerModel` fits optimistic-concurrency appends (compare-and-set on a stream version); `appendLogModel` fits a kiroku stream or a Kafka partition.

The scenario `selftest/check/correctness/model-replays-counterexample` (module `Kenshou.Check.Selftest.ModelReplay`) has tier `smoke`, placement `either`, no PostgreSQL. It runs `parallelProperty` against an in-memory register whose compare-and-set is deliberately not atomic, knob `model.tests` (integer, default 200), and then runs the same property again with the same derived seed. The verdict `model-replay` holds when both runs fail, both shrunk counter-examples are identical, and a correct register passes; the verdict `linearizability-non-vacuity` holds when `checkLinearizable` accepts a generated valid history and rejects the same history with one read result altered.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro-runtime-kenshou`, inside the development shell (`nix develop`, or automatically through `direnv`).

Step 0, check the expected starting state.

```bash
cabal build kenshou-core kenshou-cli
cabal run kenshou -- list --json | jq -r '.. | .id? // empty' | grep '^selftest/kernel/'
cabal run kenshou -- run selftest/kernel/concurrency/worker-echo --out /tmp/kenshou-out; echo "exit=$?"
ls schemas/ docs/adr/
```

Expect the kernel self-test identifiers, `exit=0`, and both directories. If any of this is missing, the kernel plan is not finished; stop and finish it first.

Milestone 1.

```bash
mkdir -p kenshou-check/src/Kenshou/Check kenshou-check/test/golden kenshou-check/fixture
cabal build kenshou-check
cabal test kenshou-check-test
cabal run kenshou -- run selftest/check/correctness/ledger-detects-loss-dup-reorder --out /tmp/kenshou-out
RUN=$(ls -td /tmp/kenshou-out/*/ | head -1)
ls "$RUN/verdicts/ledger" | head -3
jq '{checker, class, status, counts}' "$RUN/verdicts/ledger-integrity.json"
```

An illustrative transcript (counts and names will differ):

```text
harness-0.0.0001.jsonl
writer-0.0.0001.jsonl
writer-1.0.0001.jsonl
{ "checker": "ledger-integrity", "class": "contract", "status": "held",
  "counts": { "examined": 20000, "violations": 0, "tornTail": 0, "sortRuns": 4 } }
```

Milestone 2.

```bash
cabal test kenshou-check-test
cabal run kenshou -- run selftest/check/correctness/ledger-detects-loss-dup-reorder --out /tmp/kenshou-out; echo "exit=$?"
RUN=$(ls -td /tmp/kenshou-out/*/ | head -1)
jq -r '[.checker, .class, .status] | @tsv' "$RUN"/verdicts/*.json
jq '.parameters.mutations[] | {mutation, target, targetStatus}' "$RUN/verdicts/non-vacuity.json" | head -12
```

```text
disjoint-ownership      contract        held
duplicates              contract        held
gapless-positions       implementation  held
no-loss                 contract        held
non-vacuity             contract        held
…
{ "mutation": "drop-observation", "target": "no-loss", "targetStatus": "violated" }
exit=0
```

Milestones 3 and 4.

```bash
cabal run kenshou -- run selftest/check/concurrency/kill-and-restart-worker --set kill.count=5 --out /tmp/kenshou-out; echo "exit=$?"
RUN=$(ls -td /tmp/kenshou-out/*/ | head -1)
jq '.counts' "$RUN/verdicts/duplicates.json"
grep -c disturbance-start "$RUN"/verdicts/ledger/harness-0.0.*.jsonl
pgrep -f 'kenshou worker' || echo "no orphans"
cabal run kenshou -- run selftest/check/concurrency/postgres-backend-kill --dim pg.durability=durable --out /tmp/kenshou-out; echo "exit=$?"
cabal run kenshou -- run selftest/check/concurrency/proxy-partition --out /tmp/kenshou-out; echo "exit=$?"
```

```text
{ "examined": 5212, "violations": 0, "excused": 212, "windows": 6, "maxInOneWindow": 50 }
6
no orphans
exit=0
```

Milestone 5.

```bash
cabal run kenshou -- run selftest/check/correctness/model-replays-counterexample --seed 7 --out /tmp/kenshou-out; echo "exit=$?"
RUN=$(ls -td /tmp/kenshou-out/*/ | head -1)
jq '.parameters.buggyRegister.replay' "$RUN/verdicts/model-replay.json"
```

ADRs, in the milestone that owns each.

```bash
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

Format and run the repository gate before every commit (`just verify` is the bootstrap plan's gate; use `treefmt` and `cabal test all` if it is absent). Commit after each Progress item. Commits follow Conventional Commits, for example `feat(check): add bounded ledger writer and external sort`, and carry three trailers:

```text
MasterPlan: docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md
ExecPlan: docs/plans/5-build-the-correctness-toolkit-for-ledgers-invariants-faults-and-process-control.md
Intention: intention_01m2zvy0gje40tdsdragvzr3tq
```


## Validation and Acceptance

Milestone 1 is accepted when `cabal test kenshou-check-test` passes with tests that prove: a fact survives a JSON round trip (property); a writer given a 1 MiB segment limit produces several segments whose concatenation equals what was recorded; a file truncated in the middle of its last line reads without error and reports one torn line, while a file with a broken line in the middle is reported corrupt; the external sort of 200000 random facts with `runRecords = 1000` equals `Data.List.sortOn` of the same facts; and, with `+RTS -T`, sorting 2000000 facts keeps `max_live_bytes` under 256 MiB. It is also accepted only if the self-test scenario appears in `kenshou list`, exits 0, and its verdict file validates against `schemas/kenshou.verdict.v1.schema.json`.

Milestone 2 is accepted when each checker has three unit tests (a ledger on which it holds, one on which it is violated with the expected counter-example, and an empty selection that yields `not-evaluated` with reason `vacuous`), the oracle SQL runs against a database migrated by the kernel with kiroku, keiro and PGMQ (an empty store gives `gap_count = 0` and zero rows; a store with a manually deleted `$all` row gives `gap_count = 1`), and the self-test exits 0 with `non-vacuity` held. To see non-vacuity is itself real, temporarily make `noLoss` ignore missing observations: the self-test must then exit 1 with `non-vacuity` violated, naming the mutation `drop-observation`.

Milestone 3 is accepted when `selftest/check/concurrency/kill-and-restart-worker` exits 0 with `kill.count` from 0 to 20; with `kill.count=0` the `duplicates` verdict reports zero excused duplicates and zero windows; with `--set worker.checkpoint-every=1000 --set kill.count=3` the excused count is larger but never above 1000 per window; `logs/` contains a `stderr.log` and a `control.jsonl` per incarnation; and after killing the `kenshou run` process itself with `kill -9` from another terminal, `pgrep -f 'kenshou worker'` finds nothing within two seconds.

Milestone 4 is accepted when both scenarios exit 0 on PostgreSQL 17 and 18; with `--dim pg.durability=durable` the `disturbance-end` fact of the crash step in `verdicts/ledger/harness-0.0.0001.jsonl` records a new postmaster pid and a `pg_postmaster_start_time()` later than the crash instant, and `acknowledged-writes-survive` holds (if the kernel's durable fixture captures the server log under `logs/` with `log_min_messages` at `log` or lower, it also shows "database system was not properly shut down; automatic recovery in progress"; `ephemeral-pg`'s defaults discard the log and set `log_min_messages` to `PANIC`, so do not rely on it); and with `--dim pg.durability=fsync-off` the crash step is skipped with a logged reason. The injectors must also be shown to be non-vacuous: a unit test runs the `proxy-effects` clauses against a client that bypassed the proxy and expects the latency, stall and blackhole clauses to be `violated`, and a unit test runs `terminateBackends` with a selector that matches nothing and expects `backends-terminated` to be `violated`, not `held`.

Milestone 5 is accepted when the scenario exits 0 for any seed, two runs with the same `--seed` produce byte-identical `parameters.buggyRegister.counterExample`, and the unit tests show `checkLinearizable` accepting a sequential history, accepting a concurrent history that needs reordering within overlaps, rejecting a stale read, treating an indeterminate write as either applied or not, and returning `Undecided` when `maxSteps` is 10.

The whole plan is accepted when `kenshou list --json` shows the five `selftest/check/…` scenarios, all five exit 0 locally, `cabal test kenshou-check-test` passes, `okf validate` passes with the two new ADRs, and `kenshou-check.cabal` has no dependency on any kiroku, keiro, shibuya or pgmq package.


## Idempotence and Recovery

Every run writes into a fresh `<out>/<run-id>/` directory, so rerunning a scenario never touches earlier evidence; delete `/tmp/kenshou-out` at will. Ledger segments are created with exclusive open and the incarnation number in the name, so a restarted process can never append to a predecessor's file. The external sort's temporary runs live under `verdicts/ledger/.sort/` and are removed by a `finally`; if a run was killed, delete that directory, and note that `.sort/` is excluded from the manifest.

Child processes are reaped by `withSupervisor` even on exception. If the harness itself is killed, workers exit on control-channel end-of-file; if any survive (a frozen worker cannot notice), run `pkill -CONT -f 'kenshou worker'; pkill -KILL -f 'kenshou worker'`, or call `sweepOrphans` on the run's `logs/pids.jsonl`. Ephemeral PostgreSQL servers are owned by the kernel's environment and by `ephemeral-pg`'s own stale-instance sweep; after a crashed postmaster-crash step, a leftover server is found with `pgrep -fl 'postgres -D'` and removed with `kill -QUIT <pid>` followed by deleting its temporary directory. The proxy holds only in-process sockets and disappears with the process. Locks and hogged connections belong to connections with `application_name` `kenshou-fault`; if one outlives a run on an external server, `SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = 'kenshou-fault'` clears it. The self-test schema `kenshou_selftest` is dropped at the start and end of the scenarios that use it, so they can be repeated against an external database. Cell hooks must be idempotent on `heal`; after an interrupted cell run, call the hook with `heal-all`.

The registration edit in `kenshou-cli` is additive and safe to reapply. ADR identifiers are allocated by `okf id next`; if a commit is abandoned after allocation, reuse the same identifier in the retry instead of allocating another. If the kernel's types differ from what this plan expected, change `Kenshou.Check.Scenario` and the two possible kernel additions named in milestones 3 and 4, record the difference in Surprises & Discoveries, and leave every other module as designed.


## Interfaces and Dependencies

Libraries, with the versions the runtime's own build plans resolve today (the pinned cohort's `index-state` decides the actual versions; add no upper bound tighter than the cohort's): `base` with GHC 9.12.4, `aeson` 2.2.5.1, `bytestring`, `containers`, `text`, `time`, `directory`, `filepath`, `stm` 2.5.3.1, `async` 2.2.6, `unix` 2.8.8.0 (signals, process groups), `process` 1.6.26.1 and `typed-process` 0.2.13.0 (children and pipes), `network` 3.2.9.0 (the proxy; verify `StructLinger` and `setSockOpt` with `:info` in `cabal repl`), `hasql` 1.10.x (`Hasql.Connection.acquire`, `Hasql.Connection.use`, `Hasql.Session.script`, `Hasql.Connection.Settings.connectionString` and `applicationName`), `random` 1.2.1.3 with `splitmix` 0.1.3.2 (seeded choices), `hedgehog` 1.7, `ephemeral-pg` 0.3.1.0 (`EphemeralPg.restart`, `EphemeralPg.Database`), `cryptohash-sha256` or the kernel's manifest hashing function for input digests, and `kenshou-core`. The test suite adds `hspec` 2.11.17 and `hspec-hedgehog` 0.3.0.0. No kiroku, keiro, shibuya or pgmq package is a dependency.

Modules and the names that must exist at the end of each milestone, all under `kenshou-check/src/`. After milestone 1: `Kenshou.Check.Fact` (`Fact`, `FactKind`, `ProcId`), `Kenshou.Check.Ledger` (`LedgerConfig`, `LedgerWriter`, `withLedger`, `record`, `recordDurable`, `flushLedger`), `Kenshou.Check.Ledger.Read` (`FactSource`, `LedgerSet`, `openSegment`, `discoverLedgers`), `Kenshou.Check.Ledger.Sort` (`SortOrder`, `SortConfig`, `sortedFacts`), `Kenshou.Check.Verdict` (`Verdict`, `InvariantClass`, `VerdictStatus`, `writeVerdict`, `outcomeFromVerdicts`), `Kenshou.Check.Scenario` (`CheckEnv`, `withCheck`, `finishWithVerdicts`, `deriveSeed`), `Kenshou.Check.Selftest` (`bundle`). After milestone 2: `Kenshou.Check.Window` (`DisturbanceWindow`, `SkewBound`, `loadWindows`), `Kenshou.Check.Invariant` (`Checker`, `CheckFold`, `runCheckers`, and re-exports of `noLoss`, `duplicatesWithin`, `DuplicateBudget`, `perKeyOrder`, `globalOrder`, `gaplessPositions`, `exactlyNEffects`, `eventualQuiescence`, `monotonicCheckpoints`, `disjointOwnership`), `Kenshou.Check.Oracle` (`OracleQuery`, `runOracle`, `sampleOracle`, `reconcile`, `awaitQuiescence`) and `Kenshou.Check.Oracle.Kiroku`, `.Keiro`, `.Pgmq`. After milestone 3: `Kenshou.Check.Process` with the signatures given in milestone 3 plus `sweepOrphans`. After milestone 4: `Kenshou.Check.Fault` (`Fault`, `FaultHandle`, `Schedule`, `at`, `every`, `during`, `onMark`, `holding`, `withSchedule`), `Kenshou.Check.Fault.Postgres` (`BackendSelector`, `listBackends`, `terminateBackends`, `terminateOneBackend`, `holdLock`, `hogConnections`, `withStatementTimeout`, `crashPostmaster`), `Kenshou.Check.Fault.Network` (`TcpProxy`, `ProxyMode`, `withTcpProxy`, `proxyPort`, `setProxyMode`, `resetConnections`, `proxyFault`, `proxiedConnectionString`), `Kenshou.Check.Fault.Wake` (`WakeControl`, `WakePolicy`, `newWakeControl`, `setWakePolicy`, `faultyWait`), `Kenshou.Check.Fault.Time` (`newVirtualNow`, `BackdateTarget`, `backdateRows`), `Kenshou.Check.Fault.Cell` (`cellFault`). After milestone 5: `Kenshou.Check.Model` (`ModelRun`, `runModel`, `sequentialProperty`, `parallelProperty`) and `Kenshou.Check.Model.Linearizability` (`Operation`, `Completion`, `SeqModel`, `LinResult`, `checkLinearizable`, `registerModel`, `appendLogModel`, `linearizability`).

Documents owned: `kenshou.verdict/v1` (files `verdicts/<checker>.json`) and `kenshou.ledger/v1` (header and fact lines of `verdicts/ledger/*.jsonl`), each with a schema in `schemas/`. Files outside the package that this plan edits: `kenshou-cli/src/Kenshou/Cli/Registry.hs` and `kenshou-cli/kenshou-cli.cabal` (registration), `schemas/`, `docs/adr/`, and, only if the kernel lacks them, the additive changes to `Kenshou.Core.Role` and `Kenshou.Core.Env.Postgres` described above together with the matching MasterPlan Integration Point.

Consumers. Every coverage plan (`docs/plans/8-cover-pgmq-hs-in-isolation.md` through `docs/plans/15-verify-the-assembled-runtime-end-to-end-and-under-soak.md`) uses the ledger, the checkers, the supervisor and the injectors; each chooses its duplicate budget from its component's configuration (kiroku subscription `batchSize`, PGMQ `visibilityTimeout`) and its oracles from the catalogue. `docs/plans/6-build-the-diagnostics-toolkit-for-memory-leaks-and-concurrency-stalls.md` uses `Kenshou.Check.Process` for its seeded self-tests. `docs/plans/11-cover-the-kafka-transport-edge-with-a-disposable-broker.md` uses the proxy in front of its broker and the state-machine helpers. `docs/plans/16-provide-leased-verification-cells-in-load-testing-infra.md` and `docs/plans/17-run-kenshou-on-leased-cells-with-payloads-submission-and-retrieval.md` supply `KENSHOU_CELL_FAULT_HOOK` and `KENSHOU_CLOCK_SKEW_BOUND_MICROS` on a cell. `docs/plans/18-record-runs-and-attestations-in-a-historic-okf-evidence-bundle.md` reads verdict documents and their `inputs` digests, and an attestation recomputes a verdict by running `runCheckers` over the linked ledger files.
