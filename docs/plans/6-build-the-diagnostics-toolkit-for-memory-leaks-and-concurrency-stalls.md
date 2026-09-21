---
id: 6
slug: build-the-diagnostics-toolkit-for-memory-leaks-and-concurrency-stalls
title: "Build the diagnostics toolkit for memory leaks and concurrency stalls"
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
---

# Build the diagnostics toolkit for memory leaks and concurrency stalls

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

The platform owner asked that this verification suite "serve as a base for diagnosing concurrency problems or memory leak problems" in the keiro runtime (the cohort of Haskell libraries — pgmq-hs, kiroku, shibuya and its adapters, keiro — that services link together). Today a multi-hour run that slowly eats memory, or a worker that silently stops, leaves nothing behind except a red result. After this plan a maintainer can do three things they could not do before.

First, every soak scenario (a scenario that runs for a long time to expose slow resource growth) can end with a leak verdict. The verdict is computed from the time series the measurement toolkit already samples: for the Haskell heap, native memory, Haskell threads, operating-system threads, file descriptors, PostgreSQL connections, named tables and queue depths it fits a robust growth rate with a confidence interval, reports it in units per hour and as projected hours until a limit, and answers `leak-suspected`, `stable` or `insufficient-data`. `kenshou diagnose leak <run-dir>` re-judges any existing run directory offline, with different thresholds if wanted.

Second, a scenario wrapped in the stall watchdog that stops making progress no longer hangs until its time budget expires. Within a deadline the watchdog writes a diagnosis containing a dump of every Haskell thread (identifier, label, blocking reason and, in the right build, a decoded stack), PostgreSQL's view of the same instant (every session with its wait event, every lock, and the who-blocks-whom graph with cycles marked), connection-pool occupancy, and a classification: `deadlock`, `lock-wait`, `pool-starvation`, `blocked-indefinitely`, `idle-spin` or `unknown`. `kenshou diagnose stall <run-dir>` renders it for a human.

Third, `kenshou diagnose profile <scenario> --mode closure-type|info-table|eventlog|profiled` reruns any scenario under a heap profile or a size-bounded GHC event log, using build variants that need no profiled libraries first, and `docs/guides/diagnosing-leaks-and-stalls.md` walks from "the soak went red" to "the retaining allocation site is identified".

To see it working, run the seven self-test scenarios this plan adds. `selftest/diagnose/soak/leaking-worker` leaks a known number of bytes per second and passes only if the detector says `leak-suspected` with a slope within fifteen percent of the injected rate; `selftest/diagnose/soak/stable-worker` churns memory without retaining it and passes only if the detector stays quiet; `selftest/diagnose/concurrency/deadlocked-workers` makes two PostgreSQL sessions lock two rows in opposite order and passes only if the diagnosis says `deadlock` and the cycle contains exactly those two backend process ids.


## Progress

Milestone 1 — The leak verdict over sampled series

- [ ] Confirm the state delivered by `docs/plans/2-build-the-harness-kernel-for-scenarios-dimensions-run-specs-and-results.md` and `docs/plans/4-build-the-measurement-toolkit-for-load-latency-sampling-and-comparison.md` (build green, `series/rts.csv` headers recorded in Surprises & Discoveries).
- [ ] Create the package `kenshou-diagnose` (cabal file, `Kenshou.Diagnose`, test suite `kenshou-diagnose-test`).
- [ ] `Kenshou.Diagnose.Context`: the single adapter over the kernel's `RunContext`.
- [ ] `Kenshou.Diagnose.Document`: the `kenshou.diagnosis/v1` envelope, its JSON codecs and `schemas/diagnosis.v1.schema.json`.
- [ ] `Kenshou.Diagnose.Stats`: Theil–Sen slope, moving-block bootstrap interval, window minima and medians, with property tests.
- [ ] `Kenshou.Diagnose.Series` and `Kenshou.Diagnose.Series.Catalog`: header-driven CSV reading and the probe-to-column bindings, reconciled with the real headers.
- [ ] `Kenshou.Diagnose.Leak`: probe specifications, the verdict rules, `judgeLeaks`, `analyseRunDirectory`, `leakOutcome`, and `policies/leak-default.json` with `schemas/leak-policy.v1.schema.json`.
- [ ] `Kenshou.Diagnose.Leak.MajorGcProbe`: the opt-in forced major collection sampler writing `series/rts-major.csv`, refusing benchmark scenarios.
- [ ] Synthetic-series fixtures and unit tests: leak, sawtooth-stable, plateau-after-growth, too-short, interval-straddles-floor.
- [ ] Create the ADR "leak verdicts are judged on live bytes after major garbage collections, not on resident memory".

Milestone 2 — The stall watchdog with thread dumps and lock graphs

- [ ] `Kenshou.Diagnose.Progress` (counters) and `Kenshou.Diagnose.Threads` (labels, dump, stack decoding with a timeout, `SIGUSR2` dump handler for worker processes).
- [ ] `Kenshou.Diagnose.Postgres`: activity, lock, statement-rate and settings captures returning JSONB; advisory-lock key labelling.
- [ ] `Kenshou.Diagnose.LockGraph`: wait-for graph, cycles, root blockers, DOT and text rendering.
- [ ] `Kenshou.Diagnose.Pool`: occupancy statistics folded from hasql-pool observations.
- [ ] `Kenshou.Diagnose.Stall` and `Kenshou.Diagnose.Stall.Classify`: `withWatchdog`, capture, the pure classifier, `suspendDeadline`, `StallDetected`.
- [ ] Classifier unit tests over checked-in snapshot fixtures; an integration test of the PostgreSQL captures on PostgreSQL 17 and 18.

Milestone 3 — Profiling build variants and bounded event logs

- [ ] Spike: prove `endEventLogging` can be called from Haskell through the foreign function interface and stops event-log growth; record the result.
- [ ] `cabal.diagnose-info-table.project` and `cabal.diagnose-profiled.project`, build directories under `dist-diagnose/`, ignore rules.
- [ ] `Kenshou.Diagnose.Profile`: modes, run-time system flag assembly, profile sessions, the worker re-exec hook, phase markers in the event log, harness-driven heap censuses.
- [ ] `Kenshou.Diagnose.Profile.EventlogGuard`: in-process size guard, parent-side backstop, free-disk preflight.
- [ ] `Kenshou.Diagnose.Profile.GhcDebug` behind the cabal flag `ghc-debug`.
- [ ] `just diagnose-tools`, `just diagnose-build-info-table`, `just diagnose-build-profiled`.

Milestone 4 — `kenshou diagnose` recipes and the diagnosis guide

- [ ] `kenshou-cli/src/Kenshou/Cli/Diagnose.hs` with `leak`, `stall` and `profile`, wired into the executable; exit codes per the command-line contract.
- [ ] `Kenshou.Diagnose.Render`: human-readable and `--json` output.
- [ ] A checked-in fixture run directory and golden tests for the three subcommands.
- [ ] `docs/guides/diagnosing-leaks-and-stalls.md`.

Milestone 5 — Seeded leak and deadlock self-tests that prove the detectors fire

- [ ] `Kenshou.Diagnose.SelfTest.Leak`: `leaking-worker` (heap, threads and file-descriptor kinds) and `stable-worker`.
- [ ] `Kenshou.Diagnose.SelfTest.Stall`: `deadlocked-workers`, `pool-starved`, `lock-waiter`, `idle-spinner`, `healthy-progress`.
- [ ] `Kenshou.Diagnose.SelfTest.bundle` registered in `kenshou-cli/src/Kenshou/Cli/Registry.hs`.
- [ ] Run all seven scenarios locally on PostgreSQL 18 and the four PostgreSQL ones also on 17; walk the guide end to end with `leaking-worker`; record transcripts here.
- [ ] ADR distillation pass; update the MasterPlan's Progress and registry status.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Judge the Haskell heap on two bases, in this order of preference: exact samples taken immediately after a forced major collection (opt-in, `series/rts-major.csv`), otherwise the lower envelope (per-window minimum) of the sampled `live_bytes` restricted to windows in which the major-collection counter advanced. Never use resident memory or `max_live_bytes` for the heap.
  Rationale: `GHC.Stats` reports the live bytes of the most recent collection. After a minor collection that figure counts everything sitting in the old generation, dead or not, so the raw series is a sawtooth whose minima are the true after-major-collection values. Under load almost every sample follows a minor collection, so filtering to "last collection was major" yields almost no points; the envelope does not have that problem. `max_live_bytes` is a high-water mark that can never fall, so a slope fitted to it is biased upward (the existing PGMQ endurance test in `mori://shinzui/shibuya-pgmq-adapter`, file `shibuya-pgmq-adapter-bench/app/Endurance.hs`, records exactly that figure).
  Date: 2026-09-20

- Decision: Add a separate, lower-confidence probe `process.native-bytes` (resident memory minus the run-time system's `mem_in_use_bytes`) instead of ignoring resident memory altogether.
  Rationale: The known leak in Hackage `hw-kafka-client` 5.3.0 (every polled librdkafka message wrapped without a finalizer) is memory allocated by C code. It never appears in GHC's live bytes. The MasterPlan's rule that heap leaks are not judged on resident memory stands; native memory is a different resource and resident memory is the only portable signal for it.
  Date: 2026-09-20

- Decision: Implement Theil–Sen and a seeded moving-block bootstrap inside `Kenshou.Diagnose.Stats` rather than reusing the measurement toolkit's bootstrap.
  Rationale: The measurement toolkit resamples independent paired trials. A sampled series is autocorrelated, so resampling individual points understates the interval; blocks are required. The code is about 150 pure lines and is property-tested here.
  Date: 2026-09-20

- Decision: The watchdog opens its own PostgreSQL connection when it starts, not when it fires, and never borrows from a scenario's pool.
  Rationale: The situations being diagnosed include an exhausted pool and an exhausted `max_connections`. A connection acquired in advance is the only one guaranteed to exist at that moment.
  Date: 2026-09-20

- Decision: PostgreSQL captures are SQL statements that return one JSONB value, decoded with aeson into tolerant records.
  Rationale: `pg_stat_activity` and `pg_locks` differ slightly between PostgreSQL 17 and 18 and contain arrays and nullable columns; one JSONB column avoids a wide positional decoder that breaks on a version change, and unknown fields are preserved verbatim in the diagnosis.
  Date: 2026-09-20

- Decision: Offline commands never write into an existing run directory, and a profile session is a directory that wraps a run directory rather than adding files to it.
  Rationale: Integration Point 5 says a later run never writes into an earlier run's directory, and the kernel seals each run with a manifest of SHA-256 digests. Event logs are produced by the run-time system while the process exits, after the manifest is computed, so they cannot live inside the sealed directory.
  Date: 2026-09-20

- Decision: The lock graph's Graphviz DOT text is embedded as a string inside the stall JSON, and worker thread dumps are separate `kenshou.diagnosis/v1` documents of kind `thread-dump`.
  Rationale: Integration Point 5 defines `diagnosis/*.json`; keeping everything JSON honours it.
  Date: 2026-09-20

- Decision: Worker processes dump their threads when they receive `SIGUSR2`; heartbeats from workers reach the watchdog through whoever reads the worker's control channel.
  Rationale: `docs/plans/5-build-the-correctness-toolkit-for-ledgers-invariants-faults-and-process-control.md` is only a soft dependency. A signal handler and a counter need nothing from it, and work identically whether the worker was spawned by that toolkit's supervisor or directly.
  Date: 2026-09-20

- Decision: Profiling variants are root-level cabal project files that import `cabal.project`, built into `dist-diagnose/<variant>`; post-processing tools are installed with `cabal install --ignore-project` into `.dev/bin`. A Nix-built variant for GCP cells is left to `docs/plans/17-run-kenshou-on-leased-cells-with-payloads-submission-and-retrieval.md`.
  Rationale: The house dev shell supplies GHC and cabal and builds happen with cabal, so a project-file variant is the smallest working mechanism; Nix package outputs do not exist in this repository until the cell payload plan creates them. nixpkgs frequently marks `eventlog2html` broken for a new GHC, and `--ignore-project` keeps the tools out of the cohort's constraints (the cohort forces `aeson <2.3`).
  Date: 2026-09-20

- Decision: The self-test scenarios ship in a `selftest`-layer bundle exported by `kenshou-diagnose` itself (`Kenshou.Diagnose.SelfTest.bundle`), registered in the CLI registry with the usual three-line edit.
  Rationale: The kernel cannot depend on a toolkit, so the kernel's own `selftest` bundle cannot contain these scenarios; several bundles may carry the same layer name.
  Date: 2026-09-20

- Decision: The leak self-tests leak inside the scenario's main process; the deadlock self-test raises `deadlock_timeout` on its two sessions.
  Rationale: How per-process series files are named for worker processes is not fixed by any contract yet, and the main process is always sampled. PostgreSQL resolves a deadlock by itself after `deadlock_timeout` (one second by default) by aborting one transaction, which would race the watchdog; raising it makes the cycle persist until it has been captured.
  Date: 2026-09-20

- Decision: Add a fourth profile mode, `profiled`, and three scenarios beyond the four named in the drafting brief (`lock-waiter`, `idle-spinner`, `healthy-progress`). The five milestone titles are the MasterPlan's, unchanged.
  Rationale: The brief asks for a profiled-libraries variant as an explicit heavier option, which needs a mode to select it. Every classification the watchdog can emit should be proven to fire by a run, and a negative control proves it stays quiet.
  Date: 2026-09-20


- Decision: Register `diagnose` in the Analysis command group, organize its nested options by user intent, use the shared explicit standard-input source for policy documents, and contribute an embedded `diagnostics` help topic.
  Rationale: Diagnosis interprets already captured evidence or explicitly captures a live system; it is not a normal scenario execution. The command's breadth makes grouped help and durable in-binary guidance necessary, and EP-2's seam keeps its JSON and completion behavior consistent.
  Date: 2026-09-20


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This repository, `keiro-runtime-kenshou`, is a verification suite for the keiro runtime. At the time this plan was drafted it contained only documentation: `README.md`, `mori.dhall`, the MasterPlan at `docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md` and nineteen child plans under `docs/plans/`. This plan is child plan 6. It hard-depends on three earlier plans and must not start before they are complete. `docs/plans/1-bootstrap-the-kenshou-repository-and-pin-the-runtime-cohort.md` delivers the Nix dev shell (GHC 9.12.4, cabal 3.16, PostgreSQL 17 and 18, `just`), one cabal project whose `cabal.project` lists packages with the glob `kenshou-*/*.cabal` (so a new package is added by creating its directory, never by editing a list), the pinned runtime cohort under `cohort/`, a `Justfile`, a `.gitignore`, and the ADR bundle at `docs/adr/`. `docs/plans/2-build-the-harness-kernel-for-scenarios-dimensions-run-specs-and-results.md` delivers the package `kenshou-core` and the executable `kenshou` in `kenshou-cli`. `docs/plans/4-build-the-measurement-toolkit-for-load-latency-sampling-and-comparison.md` delivers the package `kenshou-measure`, whose samplers write the time series this plan analyses. `docs/plans/5-build-the-correctness-toolkit-for-ledgers-invariants-faults-and-process-control.md` is a soft dependency: nothing here requires it.

The kernel vocabulary this plan relies on is restated here so that this document stands alone. A scenario is one runnable verification, identified by the four-segment path `<layer>/<component>/<kind>/<name>`; the layer is one of `selftest`, `pgmq`, `kiroku`, `shibuya`, `kafka`, `keiro`, `runtime`, and the kind is one of `correctness`, `concurrency`, `soak`, `benchmark`. A scenario declares a cost tier (`smoke` under one minute, `standard` under ten, `extended` under an hour, `soak` hours), a placement (`local`, `cell` — a leased set of Google Cloud machines — or `either`), its knobs (typed per-scenario parameters with a default and allowed values, set with `--set name=value`), and the values it supports of four cross-cutting dimensions (`telemetry.tracing`, `telemetry.metrics`, `pg.durability` with values `fsync-off` and `durable`, `pg.version` with values `17` and `18`). A package contributes scenarios by exporting one value `bundle :: LayerBundle`; `kenshou-cli/src/Kenshou/Cli/Registry.hs` is the single list of bundles, and registering costs one import, one list element and one `build-depends` entry in `kenshou-cli/kenshou-cli.cabal`. A scenario's body is `run :: RunContext -> IO ScenarioReport`; the `RunContext` gives it its resolved knobs and dimensions, environment handles (a scenario never opens a database by itself; it asks the kernel for a `PostgresEnv`, an ephemeral or external PostgreSQL server), the seed that drives every random choice, the output directory, a logger, phase markers (warm-up, steady, drain) with timestamps, and a way to register opaque JSON summary sections named `measurements`, `verdicts`, `diagnosis` and `telemetry` in the run result. Outcomes use one vocabulary: `passed`, `failed`, `errored`, `inconclusive`, `infrastructure-failure`. Exit codes are contractual: 0 for passed, 1 for failed, 2 for a usage error, 3 for inconclusive, 4 for errored or infrastructure-failure. Multi-process scenarios run their workers as child processes of the same binary through the hidden subcommand `kenshou worker`.

Every run writes a run directory, and a later run never writes into an earlier one. This plan owns the `diagnosis/` line and the document `kenshou.diagnosis/v1`; every versioned document is JSON with a `schema` field and has a JSON Schema under `schemas/`.

```text
<out>/<run-id>/
  run-spec.json      kenshou.run-spec/v1           kernel
  run-result.json    kenshou.run-result/v1         kernel; carries the "diagnosis" summary section this plan fills
  manifest.json      kenshou.artifact-manifest/v1  kernel; sha256 of every file, computed when the run ends
  samples/           latency histograms            measurement toolkit
  series/*.csv       time series: rts.csv, proc.csv, pg-*.csv, scrape-*.csv   measurement and telemetry toolkits
  verdicts/          kenshou.verdict/v1            correctness toolkit
  diagnosis/*.json   kenshou.diagnosis/v1          THIS PLAN: leak and stall findings, thread dumps, lock graphs
  logs/              stdout and stderr of the harness and every worker
```

The measurement toolkit's drafting brief promises these samplers, written at a configurable interval: the GHC run-time system (live bytes after the last major collection, maximum live bytes, memory in use, major collection count, collector CPU and elapsed time, allocated bytes; it requires the run-time flag `-T`), the process (resident memory, operating-system threads, file descriptors, CPU, from `/proc/self` on Linux with a documented macOS fallback), the Haskell thread count, and PostgreSQL (`pg_stat_statements` deltas, `pg_stat_activity` wait events and connection counts by `application_name`, checkpoint activity, write-ahead-log bytes, relation and index sizes and dead tuples for named tables). No contract fixes the column names, and that plan had not been written when this one was drafted. This plan therefore reads series only through `Kenshou.Diagnose.Series.Catalog`, which binds logical probe names to a file, a time column and a value column, and its first implementation step is to run a measurement self-test and reconcile the catalog with the real headers. The catalog is written against these expected names: `series/rts.csv` with `t_mono_ns`, `live_bytes`, `last_gc_gen`, `major_gcs`, `max_live_bytes`, `mem_in_use_bytes`, `haskell_threads`; `series/proc.csv` with `t_mono_ns`, `rss_bytes`, `os_threads`, `open_fds`, `cpu_ns`; `series/pg-activity.csv` in long form with `t_mono_ns`, `application_name`, `state`, `connections`; `series/pg-relations.csv` in long form with `t_mono_ns`, `relation`, `total_bytes`, `dead_tuples`. For multi-process runs the catalog treats `series/rts.csv` as the main process and `series/rts-<suffix>.csv` as another process named by the suffix, and judges each separately.

Terms used in this plan, in plain language. GHC's default garbage collector is a generational copying collector: new data lives in a nursery that is collected often (a minor collection), survivors are promoted to an old generation that is collected rarely (a major collection), and collection works by copying live data to fresh memory. Live bytes is the amount of data still reachable after a collection. Resident set size (RSS) is the physical memory the operating system has given the process; under a copying collector it is roughly twice the live data plus whatever the run-time system has not returned, so it rises and falls for reasons unrelated to leaks, which is why heap leaks are not judged on it. A leak, for this plan, is any resource whose level grows without bound while the workload is steady. The Theil–Sen estimator is the median of the slopes between all pairs of points; it tolerates roughly a quarter of the points being outliers, which ordinary least squares does not. A bootstrap confidence interval is obtained by recomputing a statistic on many random resamples of the data and taking percentiles; a moving-block bootstrap resamples contiguous blocks instead of single points so that the correlation between neighbouring samples is preserved. A heartbeat is a counter a scenario increments whenever it makes progress; a watchdog is a thread that acts when no heartbeat has advanced for a deadline. A thread dump is a list of every Haskell thread with its status; a thread is usually blocked on an `MVar` (a one-slot synchronised variable) or on STM (software transactional memory, GHC's composable blocking primitive). A wait event is PostgreSQL's name for what a session is currently waiting on, visible in the `pg_stat_activity` view; `pg_locks` lists every lock held or awaited; `pg_blocking_pids(pid)` returns the sessions blocking a given session; the lock graph (or wait-for graph) has sessions as nodes and "waits for" as edges, and a cycle in it is a deadlock. An advisory lock is an application-defined PostgreSQL lock identified only by a 64-bit number. Pool starvation is every connection of a connection pool being held while more threads wait for one. A busy spin is a loop that consumes CPU or issues queries at full speed while accomplishing nothing. The GHC event log is a binary trace the run-time system writes when started with `-l`; info-table profiling is a heap profile broken down by the code location that allocated each object, available in an ordinary (non-profiled) build compiled with `-finfo-table-map`; a heap census is one sample of such a profile, and taking one forces a major collection. `ghc-debug` is a tool that attaches to a running Haskell process through a socket and lets one walk its heap. An IAP tunnel is Google Cloud's Identity-Aware Proxy TCP forwarding, the only way into a cell's machines.

Facts about the run-time system that were verified while drafting (against GHC 9.10.3 with base 4.20, the compiler on the drafting machine, and against the GHC 9.12 user guide; re-verify in the dev shell with `ghci -e ':t GHC.Conc.Sync.threadLabel'` and similar). `GHC.Conc.listThreads :: IO [ThreadId]`, `GHC.Conc.threadStatus :: ThreadId -> IO ThreadStatus` (constructors `ThreadRunning`, `ThreadFinished`, `ThreadBlocked BlockReason`, `ThreadDied`; block reasons `BlockedOnMVar`, `BlockedOnBlackHole`, `BlockedOnException`, `BlockedOnSTM`, `BlockedOnForeignCall`, `BlockedOnOther`), `GHC.Conc.labelThread`, `GHC.Conc.threadCapability` and `GHC.Conc.Sync.fromThreadId :: ThreadId -> Word64` exist; `threadLabel :: ThreadId -> IO (Maybe String)` is exported by `GHC.Conc.Sync` and, in base 4.20, not by `GHC.Conc`. `GHC.Stack.CloneStack.cloneThreadStack :: ThreadId -> IO StackSnapshot` and `decode :: StackSnapshot -> IO [StackEntry]` (fields `functionName`, `moduleName`, `srcLoc`, `closureType`) exist, and `decode` returns entries only for code compiled with `-finfo-table-map`. `GHC.Stats.getRTSStats` gives `gc :: GCDetails` for the most recent collection with `gcdetails_live_bytes`, `gcdetails_gen` and `gcdetails_mem_in_use_bytes`, plus `major_gcs` and `max_live_bytes`. `GHC.Profiling.requestHeapCensus`, `startHeapProfTimer` and `stopHeapProfTimer` let a program take heap censuses on demand when started with `--no-automatic-heap-samples`. `Debug.Trace.traceMarkerIO` writes a named marker into the event log. The event-log flag takes class letters (`s` scheduler, `g` collector, `n` non-moving collector, `p` and `f` sparks, `T` ticky, `u` user events, `a` all) and `-` disables, so `-l-agu` means "nothing except collector and user events"; `-ol<file>` names the output; `--eventlog-flush-interval=<seconds>` flushes periodically; `-hT` (by closure type) and `-hi` (by info table) are the two heap-profile modes that work without the profiling run-time system; `-i<seconds>` sets the census interval, 0.1 seconds by default.

Facts about the runtime libraries that were verified in their sources. No runtime library labels its threads: a search for `labelThread` across `mori://shinzui/keiro` (`/Users/shinzui/Keikaku/bokuno/keiro`), `mori://shinzui/kiroku` (`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`), `mori://shinzui/shibuya` (`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`), the PGMQ and Kafka adapters, `mori://shinzui/pgmq-hs`, `mori://shinzui/kafka-effectful`, `mori://shinzui/ephemeral-pg`, `mori://shinzui/pg-migrate` and hasql-pool finds nothing, so in a thread dump only the harness's own threads carry names and runtime threads are identified by decoded stacks in the info-table build. kiroku's pool connections do not set `application_name`; only its listener connection does (`SET application_name = 'kiroku-listener'` in `kiroku-store/src/Kiroku/Store/Notification.hs`), so a scenario that wants its sessions recognisable puts `application_name=...` into the connection string. kiroku exposes hasql-pool's observations through `ConnectionSettings.observationHandler :: Maybe (Observation -> IO ())` (`kiroku-store/src/Kiroku/Store/Connection.hs`; defaults: `poolSize = 10`, `idleInTransactionTimeout = 30` seconds, `statementTimeout = Nothing`). hasql-pool (`mori://hasql/hasql`, `/Users/shinzui/Keikaku/hub/haskell/hasql-project/hasql-pool`, version 1.4.2 in the local corpus) reports only per-connection status changes (`ConnectingConnectionStatus`, `ReadyForUseConnectionStatus`, `InUseConnectionStatus`, `TerminatedConnectionStatus`), has no waiter count, makes waiters block in STM, and by default gives up after an acquisition timeout of ten seconds with `AcquisitionTimeoutUsageError`; in production, therefore, pool starvation looks like bursts of that error rather than an infinite hang. The advisory-lock keys in the runtime are: keiro workflow steps, `pg_advisory_xact_lock(hashtextextended(key, 0))` with key text `<workflowId>/<workflowName>/<generation>/<stepName>` and the step name `__keiro_lifecycle__` for lifecycle markers (`keiro/src/Keiro/Workflow/Schema.hs`, `workflowStepLockKey`; `keiro/src/Keiro/Workflow/Journal.hs`); kiroku's consumer-group start-up guard, `pg_try_advisory_xact_lock(hashtextextended(name || ':' || member, 0))` (`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`, `guardMember`); PGMQ queue creation, `pg_advisory_xact_lock(hashtext('pgmq.queue_' || queue_name))`, and PGMQ FIFO reads, `pg_try_advisory_xact_lock(hashtextextended(fifo_key, 0))` (`pgmq-migration/migrations/0001-install-v1.11.0.sql` in pgmq-hs); and pg-migrate's session-level lock with the literal key `0x70675F6D69677261` (decimal 8099547378373587553, `pg-migrate/src/Database/PostgreSQL/Migrate/Ledger/Types.hs`). keiro's command processor starts snapshot-seed verification on a fire-and-forget thread (`scheduleSeedVerification` in `keiro/src/Keiro/Command.hs`, sampled one in `seedVerifySampleRate = 1000`), a natural suspect for thread and connection growth when the rate is set to 1. shibuya's review `docs/reviews/REV-15-batcher-lifecycle-audit.md` (project `mori://shinzui/shibuya`; artifact-level URI pending) records that in-progress batch keys are not bounded by the inbox size, a natural suspect for heap growth under high key cardinality.

Prior art and its lessons, from `mori://shinzui/load-testing-infra` (`/Users/shinzui/Keikaku/bokuno/load-testing-infra`). That harness had no heap-over-time series at all, only resident memory scraped every fifteen seconds, which cannot reveal a slow leak. A full `-l` event log was 8.2 GiB for a 120-second run and 37 to 38 GiB per ten minutes, once filling a disk so that nothing was collected; its collector skipped transfers above `EVENTLOG_MAX_BYTES` (500 MiB). Every profiled mode was rejected at start-up because no profiling libraries were built, and the two modes that need none (`-hT`, `-hi`) were never tried. Its unstarted plan `mori://shinzui/load-testing-infra/plans/24-category-subscription-idle-efficiency-and-busy-spin-regression-guard` (not yet resolvable through Mori) defines the idle busy-spin gate this plan adopts: a kiroku category subscriber once looped at full speed while its category was idle, delivering correctly and in order while burning CPU, and the discriminating signal was the `pg_stat_statements` call count of its read statement per second. Separately, `mori://shinzui/haskell-nix-dev` records that GHC 9.12.4 panics compiling the profiling objects of one package on aarch64-darwin, a risk for the profiled variant.

ADR context. There is no local ADR corpus relevant to this work yet: `docs/plans/1-bootstrap-the-kenshou-repository-and-pin-the-runtime-cohort.md` creates `docs/adr/` as a profile-governed OKF bundle (OKF, the Open Knowledge Format, is a directory of Markdown files with YAML frontmatter validated by the house tool `okf`) with two records about package layering and cohort identity; scan its filenames before starting and read those two. A registry search for leak, soak, profiling, deadlock, eventlog and watchdog found no cross-repository ADR on these subjects. Three cross-repository decisions do bear on this plan. `mori://shinzui/kiroku/okf/adrs/concepts/ADR-5` separates performance evidence into structural checks, controlled workloads and historical telemetry and treats only the first two as authoritative; accordingly a leak verdict is computed from the run's own sampled series inside the run, never from a dashboard's history. `mori://shinzui/keiro/okf/adrs/concepts/ADR-25` requires keiro's worker loops to survive per-pass and per-item failures and to count finished work; a worker that obeys it can still be alive and yet accomplish nothing, which is why the watchdog watches progress counters rather than process liveness. The shibuya repository keeps its ADRs outside an OKF bundle, so the artifact-level URI is pending; the record is `mori://shinzui/shibuya` at `docs/adr/0001-remove-obsolete-linked-actors-and-test-gc-liveness.md`. It explains that GHC raises `BlockedIndefinitelyOnSTM` in a thread whose wake-up source has become unreachable, and that it does so at a major collection; this plan's opt-in forced major collections therefore change when such defects surface, which must be documented as part of the perturbation. This plan owns one new ADR named by the MasterPlan: leak verdicts are judged on live bytes after major garbage collections, not on resident memory. Create it in Milestone 1 with `okf id next docs/adr --profile docs/adr/profile.dhall ADR` to allocate the handle, and validate with `okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce`. A second candidate, to be decided at the distillation pass, is "diagnosis never mutates a sealed run directory".


## Plan of Work

All new library code lives in the new package `kenshou-diagnose` under the namespace `Kenshou.Diagnose.*`. It depends on `kenshou-core` and `kenshou-measure`, on `hasql` and `hasql-pool` for the PostgreSQL captures, and on no runtime library: everything it knows about keiro, kiroku or PGMQ is data (key formulas, table names) that scenario authors pass in. Follow the house cabal style: `cabal-version: 3.0`, a `common warnings` stanza, `default-language: GHC2024`, default extensions `BlockArguments DuplicateRecordFields ImportQualifiedPost NoFieldSelectors OverloadedLabels OverloadedRecordDot OverloadedStrings`, a library and a test suite named `kenshou-diagnose-test` using `hspec` with `hspec-hedgehog`.

### Milestone 1 — The leak verdict over sampled series

Scope: from a run's `series/` files to `diagnosis/leak.json` and a `diagnosis` summary in the run result. At the end a scenario can call one function after its steady phase and obtain a verdict, and a pure function can judge any run directory on disk. Run `cabal test kenshou-diagnose:tests`; acceptance is that synthetic series with a known slope are judged `leak-suspected` with the slope inside the reported interval, a sawtooth with a flat envelope is `stable`, and a short series is `insufficient-data`.

Create `kenshou-diagnose/kenshou-diagnose.cabal` and `kenshou-diagnose/src/Kenshou/Diagnose.hs` (re-exports of the scenario-author API). Create `kenshou-diagnose/src/Kenshou/Diagnose/Context.hs`, the only module allowed to touch the kernel's `RunContext`, so that a difference between this plan's assumptions and the kernel's real field names is fixed in one place. Bind each function to whatever `kenshou-core/src/Kenshou/Core/Run.hs` and `Scenario.hs` actually export.

```haskell
module Kenshou.Diagnose.Context where

runDirectory     :: RunContext -> FilePath
runIdentity      :: RunContext -> (Text, Text)               -- run id, scenario id
runSeed          :: RunContext -> Word64
scenarioKind     :: RunContext -> Kind
steadyWindow     :: RunContext -> IO (Maybe (Double, Double)) -- steady phase, in seconds on the series time axis
publishDiagnosis :: RunContext -> Text -> Aeson.Value -> IO () -- adds one entry to the run result's "diagnosis" section
logWarn          :: RunContext -> Text -> IO ()
```

Create `kenshou-diagnose/src/Kenshou/Diagnose/Document.hs` with the envelope shared by every diagnosis: `schema` (always `kenshou.diagnosis/v1`), `kind` (`leak`, `stall`, `thread-dump` or `profile`), `runId`, `scenario`, `generatedAt`, `generator` (package, version, algorithm name and version) and a kind-specific body. Write `schemas/diagnosis.v1.schema.json` (mirror the file-naming convention the kernel used for `kenshou.run-result/v1`) and validate emitted documents against it with the schema test helper the kernel's test suite provides. A leak document looks like this; every number that leads to the verdict is present so that a reader can recompute it from the named source file.

```json
{
  "schema": "kenshou.diagnosis/v1",
  "kind": "leak",
  "runId": "0199f0c2-7d1e-7c3a-9b1f-2f0d6a1c4e55",
  "scenario": "selftest/diagnose/soak/leaking-worker",
  "generator": { "package": "kenshou-diagnose", "version": "0.1.0.0", "algorithm": "theil-sen+moving-block-bootstrap/1" },
  "verdict": "leak-suspected",
  "window": { "startSeconds": 5.0, "endSeconds": 45.0, "cut": "steady-phase+warmup-cut" },
  "parameters": { "seed": 42, "resamples": 1000, "confidence": 0.95, "policy": "policies/leak-default.json" },
  "perturbation": { "forcedMajorGcs": 40, "forcedPauseSeconds": 0.31, "fractionOfRun": 0.0078 },
  "probes": [
    { "probe": "heap.live-bytes", "process": "main", "unit": "bytes", "expectation": "bounded",
      "basis": "forced-major-gc", "points": 40, "durationSeconds": 40.0,
      "level": { "first": 9437184, "last": 51380224, "median": 30408704 },
      "slopePerHour": 3774873600, "intervalPerHour": [3698000000, 3851000000],
      "secondHalfSlopePerHour": 3770000000, "growthOverWindow": 41943040,
      "floorPerHour": 1048576, "minGrowth": 2097152,
      "limit": 17179869184, "projectedHoursToLimit": 4.5,
      "verdict": "leak-suspected", "reason": "interval-above-floor",
      "source": { "file": "series/rts-major.csv", "column": "live_bytes" } }
  ]
}
```

Create `kenshou-diagnose/src/Kenshou/Diagnose/Stats.hs`, pure and seeded. `theilSen` is the median of pairwise slopes; above 2,000 points first reduce the series with window medians so that the quadratic pair count stays near two million. `slopeWithInterval` resamples contiguous blocks of length `ceiling (sqrt n)` with a `StdGen` made from the run seed, recomputes the slope for each of `resamples` replicas and takes the percentile interval. `windowMinima` and `windowMedians` reduce a series to one point per window, placed at the time of the chosen sample.

```haskell
module Kenshou.Diagnose.Stats where

data SlopeEstimate = SlopeEstimate
  { slope :: !Double, intercept :: !Double      -- units per second, units
  , low :: !Double, high :: !Double             -- percentile interval of the slope
  , points :: !Int, resamples :: !Int, blockLength :: !Int }

theilSen          :: Vector (Double, Double) -> Maybe (Double, Double)
slopeWithInterval :: Word64 -> Int -> Double -> Vector (Double, Double) -> Maybe SlopeEstimate
windowMinima      :: Double -> Vector (Double, Double) -> Vector (Double, Double)
windowMedians     :: Double -> Vector (Double, Double) -> Vector (Double, Double)
```

Create `kenshou-diagnose/src/Kenshou/Diagnose/Series.hs` (a header-driven reader built on `cassava`'s streaming decoder so that a 24-hour file is never fully resident; it reads wide files by column name and long files by filtering on label columns, and returns a clear error naming the file and the missing column) and `kenshou-diagnose/src/Kenshou/Diagnose/Series/Catalog.hs` (the bindings described in Context and Orientation, including discovery of `series/rts-<suffix>.csv` for other processes). Create `kenshou-diagnose/src/Kenshou/Diagnose/Leak.hs`:

```haskell
module Kenshou.Diagnose.Leak where

data LeakVerdict = LeakSuspected | Stable | InsufficientData
data Expectation = Bounded | Informational       -- Informational probes are reported and never fail a run
data Aggregation = WindowMin | WindowMedian      -- WindowMin for sawtooth series (heap, dead tuples)

data ProbeSpec = ProbeSpec
  { name :: !Text, unit :: !Text, binding :: !SeriesBinding
  , aggregation :: !Aggregation, expectation :: !Expectation
  , floorPerHour :: !Double        -- absolute floor on the slope
  , minGrowth :: !Double           -- absolute floor on total growth over the judged window
  , minRelativeGrowth :: !Double   -- and relative to the median level
  , limit :: !(Maybe Double) }

data LeakSpec = LeakSpec
  { probes :: ![ProbeSpec], warmupCutSeconds :: !Double, minPoints :: !Int
  , minDurationSeconds :: !Double, envelopeWindowSeconds :: !Double
  , resamples :: !Int, confidence :: !Double }

defaultLeakSpec     :: LeakSpec
loadLeakPolicy      :: FilePath -> IO (Either Text LeakSpec)
judgeLeaks          :: RunContext -> LeakSpec -> IO LeakReport   -- writes diagnosis/leak.json, publishes the summary
analyseRunDirectory :: FilePath -> LeakSpec -> Word64 -> IO (Either DiagnoseError LeakReport)  -- pure of the directory; writes nothing
leakOutcome         :: LeakReport -> Outcome   -- LeakSuspected -> failed, InsufficientData -> inconclusive, Stable -> passed
```

The rules, per probe and per process. Cut the series to the steady phase and drop a further `warmupCutSeconds` (default 300; caches and pools are still filling). Reduce it with the probe's aggregation over windows of `envelopeWindowSeconds` (default 60); for the heap on the envelope basis, drop windows in which `major_gcs` did not advance, because their minimum is not an after-major-collection value. If fewer than `minPoints` (default 30) points remain or they span less than `minDurationSeconds` (default 1,200), the verdict is `insufficient-data`. Otherwise fit the slope and interval. The verdict is `leak-suspected` when the interval's lower bound exceeds `floorPerHour`, the fitted growth over the window exceeds both `minGrowth` and `minRelativeGrowth` times the median level, and the slope of the second half of the window alone exceeds half the floor; that last condition separates a leak from a cache that grew and then levelled off, which is reported as `stable` with reason `plateau-after-growth`. It is `stable` when the interval's upper bound is below the floor or the growth floors are not met. When the interval straddles the floor it is `insufficient-data` with reason `interval-straddles-floor`, which tells the operator to run longer. The overall verdict is the worst over the `Bounded` probes. The default probes and floors, stored in `policies/leak-default.json` (schema `kenshou.leak-policy/v1`, `schemas/leak-policy.v1.schema.json`), are: `heap.live-bytes` (1 MiB per hour, growth floors 2 MiB and 1 percent), `process.native-bytes` (resident memory minus `mem_in_use_bytes`; 8 MiB per hour and 5 percent, because allocator retention makes it noisy; its reason text always says "native memory, lower confidence"), `haskell.threads`, `os.threads`, `os.fds` and `pg.connections` per `application_name` (each 1 per hour, growth floor 5), and `pg.relation-bytes` and `pg.dead-tuples` per named relation (`Informational` unless the scenario marks a relation `Bounded`, since an event table grows by design while a PGMQ queue table under steady consumption should not). Queue depths are probes a scenario adds with its own binding. Limits for the projection come from the environment: physical memory or the Linux control-group limit for the two memory probes, the soft `RLIMIT_NOFILE` for descriptors, and `max_connections` for connections.

Create `kenshou-diagnose/src/Kenshou/Diagnose/Leak/MajorGcProbe.hs` with `withMajorGcProbe :: RunContext -> Double -> IO a -> IO a`. At the given interval a labelled thread calls `System.Mem.performMajorGC`, immediately reads `getRTSStats`, and appends `t_mono_ns,live_bytes,major_gcs,gc_gen,pause_ns` to `series/rts-major.csv`, discarding a sample whose `gc_gen` shows that a minor collection slipped in between. It is opt-in through a knob each soak scenario exposes as `diagnose.major-gc-interval-ms` (default 0, off), and it throws if `scenarioKind` is `benchmark`. The perturbation must be documented in the module header, in the leak document's `perturbation` block and in the guide: each forced collection is a stop-the-world pause proportional to the live heap, so latency figures from such a run are not comparable; it changes promotion and ageing; and because GHC detects unreachable blocked threads at major collections, it makes `BlockedIndefinitelyOnMVar` and `BlockedIndefinitelyOnSTM` surface earlier than they otherwise would — a real defect revealed sooner, not an artefact, but a timing difference a reader must know about.

### Milestone 2 — The stall watchdog with thread dumps and lock graphs

Scope: progress counters, the watchdog, the three captures, the classifier and the stall document. At the end a scenario wrapped in `withWatchdog` that stops ticking gets `diagnosis/stall-1.json` within its deadline and, by default, ends as `failed` instead of hanging. Run `cabal test kenshou-diagnose:tests`; acceptance is that the classifier returns the expected class for every checked-in snapshot fixture, and that the PostgreSQL capture test, which creates a real two-session lock wait on PostgreSQL 17 and on 18, finds the waiting edge.

Create `kenshou-diagnose/src/Kenshou/Diagnose/Progress.hs` (a `ProgressCounter` is a name, a `required` flag and an unboxed atomic counter; `tick` is one atomic increment, cheap enough for a per-message call site) and `kenshou-diagnose/src/Kenshou/Diagnose/Threads.hs`. The latter offers `labelMe :: String -> IO ()` and `forkLabelled :: String -> IO () -> IO ThreadId` with the naming convention `kenshou:<package>:<purpose>` (the watchdog, the probe and the samplers label themselves so that the classifier can exclude harness threads), `dumpThreads :: Bool -> IO ThreadDump`, which lists every thread with `fromThreadId`, `threadLabel`, `threadStatus` and `threadCapability` and, when asked, decodes each stack with `cloneThreadStack` under a 250-millisecond timeout per thread and a cap of 200 threads (cloning needs the target's capability to respond, so a capability stuck in a long foreign call must not hang the dump), and `installThreadDumpSignal :: FilePath -> Text -> IO ()`, which installs a `SIGUSR2` handler that writes `diagnosis/threads-<role>-<pid>-<n>.json` (kind `thread-dump`). `kenshou worker` calls `installThreadDumpSignal` before dispatching to the role; that one line in `kenshou-cli` is part of this milestone.

Create `kenshou-diagnose/src/Kenshou/Diagnose/Postgres.hs`. Every capture is a statement of the form `SELECT coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) FROM (...) t`, run on the dedicated connection with `statement_timeout` set to five seconds and `application_name` set to `kenshou-diagnose`. The activity capture selects from `pg_stat_activity` for `datname = current_database()` excluding `pg_backend_pid()`: `pid`, `usename`, `application_name`, `backend_type`, `state`, `wait_event_type`, `wait_event`, the ages in seconds of `xact_start`, `query_start` and `state_change` against `clock_timestamp()`, `left(query, 2000)` and `pg_blocking_pids(pid) AS blocked_by`. The lock capture selects from `pg_locks`: `pid`, `locktype`, `mode`, `granted`, `relation::regclass::text`, `transactionid::text`, `classid`, `objid`, `objsubid` and the age of `waitstart` (a column present since PostgreSQL 14). The statement-rate capture reads `calls` and `total_exec_time` for the top fifty statements from `pg_stat_statements` twice, `spinProbeSeconds` apart; if the extension is absent (the query fails with "relation does not exist") it falls back to the `xact_commit + xact_rollback` delta from `pg_stat_database` and records `statementSource: "pg_stat_database"`. An advisory lock appears in `pg_locks` with `locktype = 'advisory'`; for a 64-bit key `objsubid` is 1, `classid` holds the high 32 bits and `objid` the low 32 bits, so the key is `(classid::bigint << 32) | objid::bigint` reinterpreted as signed. Hashes cannot be inverted, so labelling works forwards: the scenario supplies candidate labels, the capture asks PostgreSQL itself for their hashes, and matches are annotated.

```haskell
data AdvisoryKeySpec = HashTextExtended !Text | HashText !Text | LiteralKey !Int64
data AdvisoryLabel = AdvisoryLabel { label :: !Text, key :: !AdvisoryKeySpec }

keiroWorkflowStepLock     :: Text -> Text -> Int -> Text -> AdvisoryLabel  -- "<wid>/<name>/<gen>/<step>"
keiroWorkflowLifecycleLock :: Text -> Text -> Int -> AdvisoryLabel         -- step "__keiro_lifecycle__"
kirokuConsumerGroupGuard  :: Text -> Int32 -> AdvisoryLabel                -- "<subscription>:<member>"
pgmqQueueLock             :: Text -> AdvisoryLabel                         -- hashtext("pgmq.queue_<queue>")
pgmqFifoKeyLock           :: Text -> AdvisoryLabel
pgMigrateLedgerLock       :: AdvisoryLabel                                 -- 0x70675F6D69677261
```

Each helper's Haddock names the upstream source file given in Context and Orientation so that drift can be checked. Create `kenshou-diagnose/src/Kenshou/Diagnose/LockGraph.hs`: nodes are backend pids annotated from the activity capture, an edge runs from a waiter to each pid in its `blocked_by`, labelled with the waiter's ungranted lock; `cycles` are the strongly connected components of size two or more, `roots` are blockers that are not themselves waiting (a root in state `idle in transaction` is the classic culprit and is flagged), and `renderDot` and `renderText` produce the two human forms. Create `kenshou-diagnose/src/Kenshou/Diagnose/Pool.hs` with `newPoolObserver :: Text -> Int -> IO (Observation -> IO (), IO PoolStats)`: the first component goes into `Hasql.Pool.Config.observationHandler` or kiroku's `ConnectionSettings.observationHandler`, and the second returns counts of connecting, ready, in-use and terminated connections plus the number of seconds the pool has been continuously saturated (`inUse == size`).

Create `kenshou-diagnose/src/Kenshou/Diagnose/Stall.hs` and `Stall/Classify.hs`.

```haskell
data StallClass = Deadlock | LockWait | PoolStarvation | BlockedIndefinitely | IdleSpin | Unknown
data OnStall = CaptureAndContinue | CaptureAndAbort

data WatchdogConfig = WatchdogConfig
  { deadlineSeconds :: !Double       -- default 60; scenarios expose it as the knob stall.deadline-s
  , pollIntervalSeconds :: !Double   -- default 1
  , maxCaptures :: !Int              -- default 3
  , onStall :: !OnStall              -- default CaptureAndAbort
  , postgres :: !(Maybe Text)        -- connection string for the dedicated connection
  , advisoryLabels :: ![AdvisoryLabel]
  , captureStacks :: !Bool           -- default True; stacks are empty outside the info-table build
  , spinProbeSeconds :: !Double }    -- default 2

withWatchdog         :: RunContext -> WatchdogConfig -> (Watchdog -> IO a) -> IO a
newProgress          :: Watchdog -> Text -> Bool -> IO ProgressCounter   -- name, required
tick                 :: ProgressCounter -> IO ()
tickBy               :: ProgressCounter -> Word64 -> IO ()
registerPool         :: Watchdog -> Text -> IO PoolStats -> IO ()
registerStateProbe   :: Watchdog -> Text -> IO Aeson.Value -> IO ()      -- e.g. kiroku's subscriptionStates, a queue depth
registerChildProcess :: Watchdog -> Text -> ProcessID -> IO ()           -- receives SIGUSR2 at capture time
suspendDeadline      :: Watchdog -> Text -> IO a -> IO a                 -- for deliberately silent windows such as a PostgreSQL server restart
captureNow           :: Watchdog -> Text -> IO StallReport
classify             :: StallSnapshot -> (StallClass, [StallClass], [Text]) -- primary, every class that matched, reasons

newtype StallDetected = StallDetected StallReport   -- thrown to the scenario thread under CaptureAndAbort
```

The watchdog is a labelled thread. Every `pollIntervalSeconds` it reads the counters; when no `required` counter has advanced for `deadlineSeconds` and no `suspendDeadline` is active, it captures: the local thread dump, a `SIGUSR2` to each registered child followed by a wait of at most two seconds for their dump files, the PostgreSQL captures (recorded as `postgres.available = false` with the error text when the server is unreachable, which is itself evidence), every registered pool and state probe, and the process's CPU utilisation over the spin-probe window from `System.CPUTime.getCPUTime` (portable, main process only). Heartbeats from worker processes arrive as `progress` messages on the kernel's control channel; whoever reads that channel (the correctness toolkit's supervisor, or a scenario that spawned the worker directly) calls `tickBy`. The classifier is a pure function of the snapshot, first match wins, and every matching class is listed as secondary. `deadlock`: the wait-for graph has a cycle. `lock-wait`: at least one session has `wait_event_type = 'Lock'` for at least half the deadline and the graph is acyclic; the reasons name the root blockers, their state and transaction age. `pool-starvation`: a registered pool has been saturated for at least half the deadline, no session waits on a lock, and at least one non-harness Haskell thread is `BlockedOnSTM` (which is where hasql-pool's waiters block). `idle-spin`: CPU utilisation is at least half a core, or the statement rate is at least 100 per second, while progress is zero. `blocked-indefinitely`: every non-harness Haskell thread is finished or blocked on an `MVar` or on STM, every session of the database is `idle`, and CPU is near zero. Otherwise `unknown`. The stall document carries `detectedAt`, `deadlineSeconds`, the counters with their last-advanced times, `classification`, `secondary`, `reasons`, `haskellThreads` per process, `postgres` (`activity`, `locks`, `graph` with `nodes`, `edges`, `cycles`, `roots` and `dot`, and `advisory`), `pools`, `stateProbes` and `idleSpin`.

### Milestone 3 — Profiling build variants and bounded event logs

Scope: two build variants, four profile modes, a bounded event log and an optional `ghc-debug` stub. At the end `Kenshou.Diagnose.Profile` can run any scenario under a heap profile into a profile session directory. Acceptance: the info-table variant builds with `just diagnose-build-info-table`; a closure-type session of `selftest/kernel/correctness/always-pass` produces a non-empty event log that `ghc-events show` parses; and with the limit set to 1 MiB and scheduler events enabled the log stops growing and the session report says `truncated: true`.

Begin with a spike, because one mechanism is unproven: a twenty-line program that starts with `+RTS -l -olspike.eventlog`, forks a thread that watches the file's size, and calls `foreign import ccall safe "endEventLogging" c_endEventLogging :: IO ()` (declared in the run-time system's `rts/EventLogWriter.h`) when it passes 1 MiB while the main thread keeps emitting `traceEventIO`. Promote the mechanism if the file stops growing and the program exits cleanly; if not, the in-process guard is dropped, the parent-side backstop below becomes the only guard, and the Decision Log records it.

Create `cabal.diagnose-info-table.project` and `cabal.diagnose-profiled.project` at the repository root (root-level so that the `kenshou-*/*.cabal` glob still resolves; if the bootstrap plan ended up selecting cohorts with per-cohort project files instead of an import, mirror that mechanism). Add `dist-diagnose/` and `.dev/` to `.gitignore`.

```text
-- cabal.diagnose-info-table.project
import: cabal.project
package *
  ghc-options: -finfo-table-map -fdistinct-constructor-tables

-- cabal.diagnose-profiled.project
import: cabal.project
profiling: True
library-profiling: True
profiling-detail: late
```

The first rebuilds every dependency once with allocation-site tables (the libraries that ship with GHC, such as `base` and `containers`, are not rebuilt, so their closures carry no source location) and still links the ordinary run-time system. The second builds profiled libraries for the whole cohort; it is the explicit heavier option, it is where the GHC 9.12.4 profiling-object panic noted above may strike (if it does, record the package and fall back to info-table mode), and it is never a prerequisite for anything else. Check that `kenshou-cli/kenshou-cli.cabal` links the executable with `-threaded -rtsopts "-with-rtsopts=-N -T"`; without `-rtsopts` no profiling flag is accepted, and without `-T` the samplers are blind. Add it if missing.

Create `kenshou-diagnose/src/Kenshou/Diagnose/Profile.hs`.

```haskell
data ProfileMode = ClosureType | InfoTable | Eventlog ![Char] | Profiled !Char   -- event classes; breakdown c, r, d or y
data ProfileRequest = ProfileRequest
  { mode :: !ProfileMode, scenario :: !Text, runArgs :: ![String]
  , sessionRoot :: !FilePath, censusIntervalSeconds :: !Double   -- default 10
  , eventlogMaxBytes :: !Word64                                  -- default 536870912
  , workerRole :: !(Maybe Text) }

rtsFlags            :: ProfileMode -> FilePath -> Double -> [String]
runProfileSession   :: ProfileRequest -> IO ProfileReport
reexecWithWorkerRts :: Text -> IO ()      -- called first thing by `kenshou worker`
markPhase           :: Text -> IO ()      -- traceMarkerIO, so eventlog2html draws phase lines
```

`rtsFlags` yields `-hT -i<n> -l-agu -ol<session>/kenshou.eventlog --eventlog-flush-interval=5` for `ClosureType`, the same with `-hi` for `InfoTable`, `-l-a<classes> -ol…` for `Eventlog` (default classes `gu`; the scheduler class `s` is what made the old logs enormous and must be asked for explicitly), and `-h<c|r|d|y> -l-agu -ol…` for `Profiled`. Every heap census forces a major collection, so the default interval is ten seconds rather than GHC's tenth of a second, and a session's measurements are never benchmark evidence. `runProfileSession` creates `<sessionRoot>/profile-<utc>-<mode>/`, checks that free disk space is at least four times `eventlogMaxBytes`, locates the right binary (`cabal list-bin` against the variant's project file and build directory, failing with the exact build command if it is missing), and executes `<binary> run <scenario> --out <session>/run <runArgs> +RTS <flags> -RTS`. Flags go on the command line, not in the `GHCRTS` environment variable, so that worker child processes do not inherit them and overwrite one event-log file. To profile a worker instead, `workerRole` sets `KENSHOU_WORKER_GHCRTS_<ROLE>`; `reexecWithWorkerRts`, called at the top of the `kenshou worker` handler, sees that variable while `GHCRTS` is unset and re-executes the same binary with `GHCRTS` set and `-ol<session>/worker-<role>-<pid>.eventlog` (exec keeps the process id, so supervision by pid is unaffected). The session ends with `profile.json` (kind `profile`: mode, variant, flags, binary path, the wrapped run's id and the SHA-256 of its `manifest.json`, event-log bytes, `truncated`) beside the run directory, never inside it.

Create `kenshou-diagnose/src/Kenshou/Diagnose/Profile/EventlogGuard.hs`: when `KENSHOU_EVENTLOG_PATH` and `KENSHOU_EVENTLOG_MAX_BYTES` are set, a labelled thread polls the file size once a second, and on crossing the limit calls `endEventLogging`, logs a warning and writes `<path>.truncated`. `runProfileSession` also watches from outside and terminates the child if the file reaches twice the limit. Create `kenshou-diagnose/src/Kenshou/Diagnose/Profile/GhcDebug.hs` behind the manual cabal flag `ghc-debug` (default off, on both `kenshou-diagnose` and `kenshou-cli`): `withGhcDebugIfRequested :: IO a -> IO a` wraps the executable's `main` and, when `KENSHOU_GHC_DEBUG_SOCKET` is set, calls `GHC.Debug.Stub.withGhcDebugUnix`, or `withGhcDebugTCP host port` for `KENSHOU_GHC_DEBUG_TCP=host:port`. Without the flag it is the identity and warns if either variable is set. The stub links the C++ standard library (`extra-libraries: stdc++`), which is a known source of link trouble on macOS and the reason for the flag. Add the `Justfile` recipes `diagnose-build-info-table`, `diagnose-build-profiled` and `diagnose-tools` (the last runs `cabal install --ignore-project --installdir=.dev/bin --install-method=copy --overwrite-policy=always` once for `eventlog2html-0.12.0` and once for `ghc-events-0.21.0.0`).

### Milestone 4 — `kenshou diagnose` recipes and the diagnosis guide

Scope: the command-line surface and the written guide. At the end the three subcommands work against any run directory. Acceptance: against the fixture run directory `kenshou-diagnose/test/fixtures/run-leaking/`, `kenshou diagnose leak` prints a `leak-suspected` line for `heap.live-bytes` and exits 1; against `run-stalled/`, `kenshou diagnose stall` prints the deadlock cycle and exits 1; a nonexistent directory exits 4; a bad flag exits 2.

Create `kenshou-cli/src/Kenshou/Cli/Diagnose.hs` exporting an `optparse-applicative` Analysis `CliCommand`, add it where the kernel registered `list` and `run`, and add `kenshou-diagnose` to the executable's `build-depends`. Use EP-2's option groups: Input for run directories, policy files and live connection sources; Analysis for seed, reclassification and profile mode; Capture for interval, event-log and worker controls; Output for JSON, dot and destination paths. `--policy -` uses `InputSource`. Create `kenshou-diagnose/src/Kenshou/Diagnose/Render.hs` for the text forms; every subcommand also accepts `--json`, whose standard output contains only the document while diagnostics go to standard error. `kenshou diagnose leak <run-dir> [--policy FILE] [--seed N] [--out FILE]` calls `analyseRunDirectory`, prints one line per probe and process, writes the document only to `--out` or standard output, and exits 0 for `stable`, 1 for `leak-suspected`, 3 for `insufficient-data`, 4 when the directory or its series cannot be read. `kenshou diagnose stall <run-dir> [--reclassify] [--dot FILE]` renders every `diagnosis/stall-*.json` (classification, reasons, the lock graph as text, the blocked threads grouped by label and block reason, pools); `--reclassify` re-runs the pure classifier on the stored snapshot, which is how old captures benefit from better rules; it exits 0 when the run recorded no stall and 1 when it did. `kenshou diagnose stall --live --connection <connstr> [--out FILE]` takes the PostgreSQL captures right now against any database, for a hung system that had no watchdog. `kenshou diagnose profile <scenario> --mode closure-type|info-table|eventlog|profiled [--classes gu] [--breakdown c] [--interval-s 10] [--eventlog-max-bytes N] [--worker ROLE] [--out DIR] [--set k=v]… [--dim k=v]…` calls `runProfileSession`, runs `eventlog2html` on the result when `.dev/bin/eventlog2html` exists, prints the session path, and exits with the wrapped run's code, or 4 if the tooling failed.

Add `kenshou-cli/help/diagnostics.md` as a `HelpTopic` through EP-2's registry. It explains the leak and stall verdicts, the confidence hierarchy, sealed-run immutability, live capture, profiling perturbation, and the recovery path from a summary to raw series and event logs. Keep `docs/guides/diagnosing-leaks-and-stalls.md` as the full guide; the embedded topic is its concise command-oriented companion.

Write `docs/guides/diagnosing-leaks-and-stalls.md` as a procedure, each step with its command and what to look for. For leaks: read the `diagnosis` section of `run-result.json`; run `kenshou diagnose leak` and identify which probe and which process grew, and whether it is heap or native; shorten the reproduction and turn on `diagnose.major-gc-interval-ms` for exact points; take a closure-type profile to learn what kind of object grows (`ARR_WORDS` means byte arrays and text, `THUNK` means unevaluated laziness, a constructor name points at a data structure); build the info-table variant and take an info-table profile to learn which source line allocates it, using eventlog2html's detailed tab; if the allocator is innocent and the question is who retains, use the profiled variant with the retainer breakdown, or attach `ghc-debug-brick` 0.8.0.0 to a binary built with the `ghc-debug` flag (locally through the Unix socket; on a cell by forwarding that socket over the IAP-tunnelled SSH connection, for which `scripts/iap-ssh.sh tunnel <instance> <remote-port> <local-port>` in `mori://shinzui/load-testing-infra` is the existing wrapper — this part is documented and explicitly marked as not exercised until `docs/plans/16-provide-leased-verification-cells-in-load-testing-infra.md` and `docs/plans/17-run-kenshou-on-leased-cells-with-payloads-submission-and-retrieval.md` deliver a cell); for native growth, the suspects are foreign libraries (librdkafka, libpq). For stalls: a walk through each classification, what evidence in the stall document supports it, and the next action it implies (for `lock-wait`, find the root blocker's transaction and why it is idle; for `pool-starvation`, look for a session that acquires a second connection or a pool smaller than the worker count; for `idle-spin`, read the top statements by call rate; for `blocked-indefinitely`, read the decoded stacks of the blocked threads in an info-table build). Close with the known suspects listed in Context and Orientation and the `max_live_bytes` trap.

### Milestone 5 — Seeded leak and deadlock self-tests that prove the detectors fire

Scope: seven scenarios in a `selftest`-layer bundle, registered in the CLI. All are tier `smoke`, placement `either`, and support only the default telemetry dimension values (`off`, `off`). At the end `kenshou run` on each reports `passed`, and deliberately breaking a detector (for example forcing the classifier to return `unknown`) turns the corresponding scenario `failed`, which is what makes them non-vacuous. Create `kenshou-diagnose/src/Kenshou/Diagnose/SelfTest.hs` (`bundle :: LayerBundle`), `SelfTest/Leak.hs` and `SelfTest/Stall.hs`, and make the three-line registration edit.

`selftest/diagnose/soak/leaking-worker` needs no PostgreSQL. A labelled thread in the main process retains resources at a known rate while the measurement toolkit's samplers run at 500 milliseconds and the scenario judges with thresholds scaled to seconds (`minDurationSeconds = 20`, `warmupCutSeconds = 0`, `envelopeWindowSeconds = 1`). Knobs: `leak.kind` (enum `heap`, `threads`, `fds`; default `heap`), `leak.bytes-per-second` (integer, default 1048576, 65536 to 67108864), `leak.units-per-second` (integer, default 5, for the two count kinds), `leak.chunk-bytes` (integer, default 4096), `run.duration-s` (integer, default 45, 20 to 3600), `run.warmup-s` (integer, default 5), `diagnose.major-gc-interval-ms` (integer, default 1000; 0 exercises the envelope basis). The heap kind conses freshly built 4,096-byte `ShortByteString`s (each filled with a varying byte inside `IO` so that the optimiser cannot share them) onto an `IORef` list; the threads kind forks threads that block on an `MVar` kept reachable from a global list (so that the run-time system does not reap them); the descriptor kind opens `/dev/null`. It passes only if the overall verdict is `leak-suspected`, the targeted probe's slope is within 15 percent of the injected rate (20 percent for the count kinds) and lies inside its own interval, and no other bounded probe is `leak-suspected`. If the targeted series is absent on the platform it is `inconclusive`, never `passed`.

`selftest/diagnose/soak/stable-worker` allocates at `alloc.bytes-per-second` (default 8388608) into a ring that retains at most `retain.ring-bytes` (default 33554432), with `run.duration-s` 45, `run.warmup-s` 10 and the same probe knob. It passes only if every bounded probe is `stable`, at least `minPoints` points were judged (so that quiet is not mere lack of data), and total allocation exceeded five times the ring.

The five concurrency scenarios require a `PostgresEnv` with no runtime component migrated, support `pg.version` 17 and 18 and both durabilities, create their own table `diagnose_selftest (id int primary key, v int)`, and share the knob `stall.deadline-s` (integer, default 5, 2 to 60) with `onStall = CaptureAndContinue`, so that the scenario can inspect the report and then clean up. `selftest/diagnose/concurrency/deadlocked-workers` (extra knob `lock.deadlock-timeout-s`, default 120): two labelled threads with their own connections, named `kenshou-selftest-deadlock-a` and `-b` through `application_name`, each run `BEGIN; SET LOCAL deadlock_timeout = …; UPDATE … WHERE id = <own>`, meet at a barrier, then update the other's row. It passes only if the classification is `deadlock`, one cycle contains exactly the two pids the scenario read with `pg_backend_pid()`, and both labelled threads appear unfinished in the dump; it then calls `pg_terminate_backend` on one pid. Setting `deadlock_timeout` needs a superuser or, on PostgreSQL 15 and later, `GRANT SET ON PARAMETER deadlock_timeout`; if the `SET` is refused the outcome is `errored` with that explanation. `selftest/diagnose/concurrency/pool-starved` (knobs `pool.size`, default 2, 1 to 8; `pool.acquisition-timeout-s`, default 600): as many threads as the pool has connections each open a session and, from inside it, ask the same pool for a second connection — the nested-acquisition bug. It passes only if the classification is `pool-starvation`, the observed pool shows `inUse == size`, and the graph has no cycle. `selftest/diagnose/concurrency/lock-waiter`: one session updates a row and then sits `idle in transaction` while a second waits for the row; passes only on `lock-wait` with the first pid as the single root, flagged idle-in-transaction. `selftest/diagnose/concurrency/idle-spinner`: a thread runs `SELECT 1` in a tight loop and never ticks; passes only on `idle-spin` with a statement rate above the threshold. `selftest/diagnose/concurrency/healthy-progress`: a thread ticks ten times a second for three deadlines; passes only if no stall document was written.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro-runtime-kenshou`, inside the Nix dev shell (`nix develop`, or automatically through direnv). Transcripts are illustrative: identifiers, process ids and figures will differ.

Before starting, confirm the state the hard dependencies deliver, and record the real series headers in Surprises & Discoveries. The `jq` path below assumes `kenshou list --json` prints an array of objects with an `id` field; adjust it to the kernel's actual shape.

```bash
cabal build all
cabal run kenshou -- list --json | jq -r '.[].id' | grep '^selftest/'
cabal run kenshou -- run selftest/measure/benchmark/sleep-service --out .dev/runs
head -1 .dev/runs/*/series/rts.csv .dev/runs/*/series/proc.csv
ghci -e ':t GHC.Conc.Sync.threadLabel' -e ':t GHC.Stack.CloneStack.cloneThreadStack' -e ':t GHC.Profiling.requestHeapCensus'
```

If `series/rts.csv` lacks a column the catalog expects (in particular the generation of the last collection and the major-collection counter), that is a gap in the measurement toolkit: add the column there in the same change, and note it in both plans' Decision Logs.

Per milestone, build and test the package, then exercise the behaviour.

```bash
cabal build kenshou-diagnose
cabal test kenshou-diagnose:tests
just diagnose-tools
just diagnose-build-info-table
cabal run kenshou -- run selftest/diagnose/soak/leaking-worker --out .dev/runs
cabal run kenshou -- run selftest/diagnose/concurrency/deadlocked-workers --out .dev/runs --dim pg.version=17
cabal run kenshou -- diagnose leak .dev/runs/<run-id>
cabal run kenshou -- diagnose stall .dev/runs/<run-id>
cabal run kenshou -- diagnose profile selftest/diagnose/soak/leaking-worker --mode info-table --out .dev/profiles
```

```text
$ cabal run kenshou -- diagnose leak .dev/runs/0199f0c2-7d1e-7c3a-9b1f-2f0d6a1c4e55
leak verdict: leak-suspected   (window 5.0 s .. 45.0 s, seed 42, policy scenario-supplied)
  heap.live-bytes       main  +3600.2 MiB/h  [3526.8, 3672.9]  forced-major-gc  40 pts  to limit 4.5 h  leak-suspected
  process.native-bytes  main     +0.4 MiB/h  [-9.1, 10.3]      window-median    40 pts                  stable
  haskell.threads       main     +0.0 /h     [0.0, 0.0]        window-median    40 pts                  stable
  os.fds                main     +0.0 /h     [0.0, 0.0]        window-median    40 pts                  stable
$ echo $?
1

$ cabal run kenshou -- diagnose stall .dev/runs/0199f0c3-11aa-7e02-8c55-90b2f6d1a7c3
stall #1 at 2026-09-20T18:04:11Z after 5.0 s without progress: deadlock
  wait-for cycle: 41872 -> 41873 -> 41872
    41872 kenshou-selftest-deadlock-a  active  Lock/transactionid  5.1 s  UPDATE diagnose_selftest SET v = v + 1 WHERE id = 2
    41873 kenshou-selftest-deadlock-b  active  Lock/transactionid  5.0 s  UPDATE diagnose_selftest SET v = v + 1 WHERE id = 1
  haskell threads (main, pid 90211): 9 total; blocked: kenshou:selftest:deadlock-a, kenshou:selftest:deadlock-b
  pools: none registered
```

Create the ADR in Milestone 1 and validate the bundle.

```bash
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

Commit after each milestone, directly on the current branch, with a Conventional Commits subject such as `feat(diagnose): add the leak verdict over sampled series` and these three trailers.

```text
MasterPlan: docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md
ExecPlan: docs/plans/6-build-the-diagnostics-toolkit-for-memory-leaks-and-concurrency-stalls.md
Intention: intention_01m2zvy0gje40tdsdragvzr3tq
```


## Validation and Acceptance

Milestone 1 is accepted when `cabal test kenshou-diagnose:tests` passes with these cases present and green: Theil–Sen recovers the slope of an exact line and of a line with twenty percent of its points replaced by outliers; for synthetic autocorrelated noise around a known slope the 95 percent interval contains the truth for at least ninety of a hundred seeds; the same seed gives the same interval twice; a sawtooth whose minima are flat is `stable` while the same sawtooth with rising minima is `leak-suspected`; a series that rises and then levels off is `stable` with reason `plateau-after-growth`; a five-point series is `insufficient-data`; an emitted leak document validates against `schemas/diagnosis.v1.schema.json`; and `withMajorGcProbe` throws for a benchmark scenario. The ADR exists and `okf validate` passes.

Milestone 2 is accepted when the classifier returns the expected primary class for each fixture under `kenshou-diagnose/test/fixtures/snapshots/` (one per class, plus a snapshot with PostgreSQL unavailable), a three-session cycle is found as one cycle, the signed reconstruction of an advisory key round-trips for negative keys, and the integration test that creates a two-session row-lock wait finds an edge from the waiter's pid to the holder's pid on both PostgreSQL 17 and 18. A manual check: run any scenario under `withWatchdog` with a two-second deadline and a `threadDelay` of ten seconds in place of work, and observe `diagnosis/stall-1.json` appear after about two seconds and the run end `failed` rather than hanging.

Milestone 3 is accepted when the spike's result is recorded; `just diagnose-build-info-table` produces a binary under `dist-diagnose/info-table`; a closure-type session writes an event log that `.dev/bin/ghc-events show` parses and that contains heap-profile samples and the phase markers; and an `eventlog` session with classes `sgu` and a 1 MiB limit ends with `truncated: true` and a log no larger than twice the limit. The profiled variant either builds or its failure is recorded with the offending package; it blocks nothing.

Milestone 4 is accepted when the golden tests for the three subcommands pass against the fixture run directories, the exit codes are as specified (0, 1, 3, 4 and 2 each demonstrated by a test), running `kenshou diagnose leak` leaves the run directory's `manifest.json` still valid (no file added or changed), and a reader who has never seen the repository can follow the guide's leak walk-through using `selftest/diagnose/soak/leaking-worker` and arrive, in eventlog2html's detailed view of an info-table profile, at a band whose source location is in `kenshou-diagnose/src/Kenshou/Diagnose/SelfTest/Leak.hs`.

Milestone 5, and the plan as a whole, is accepted when all seven scenarios report `passed` locally with `pg.version=18`, the five PostgreSQL ones also with `pg.version=17`, `leaking-worker` passes for each of `leak.kind=heap`, `threads` and `fds` (or is `inconclusive` with a stated reason where the platform lacks the series), `leaking-worker` with `diagnose.major-gc-interval-ms=0` still passes on the envelope basis, and the non-vacuity check holds: temporarily forcing `classify` to return `Unknown`, or the leak rule to return `Stable`, turns the corresponding scenarios `failed` with exit code 1. Record the transcripts in this plan.


## Idempotence and Recovery

Every step is additive and repeatable. Runs always create a new run directory, and offline commands write nothing into an existing one, so re-running any command is safe. `analyseRunDirectory` is deterministic for a given directory, policy and seed. Build variants live in their own directories under `dist-diagnose/` and never disturb `dist-newstyle/`; delete `dist-diagnose/` to reclaim space (the first info-table build recompiles the whole cohort and takes a long time; later builds are incremental). `just diagnose-tools` overwrites `.dev/bin` and can be repeated. `installThreadDumpSignal` replaces any previous handler and numbers its files, so repeated signals never overwrite a dump.

The stall self-tests leave nothing behind on success: they use `CaptureAndContinue`, then terminate one backend (`deadlocked-workers`, `lock-waiter`), cancel their threads and release their pool. If one is interrupted, an ephemeral PostgreSQL server disappears with its temporary directory; against an external server, clear leftovers with `SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name LIKE 'kenshou-selftest-%'` and `DROP TABLE IF EXISTS diagnose_selftest`. A profile session that was killed may leave a partial event log; the session directory is self-contained and can simply be deleted. If an event log fills the disk despite the guards, the wrapped run ends `errored`; delete the session and rerun with fewer classes or a lower limit. The `ghc-debug` socket file is removed by the stub on exit; after a `SIGKILL`, remove it by hand from the path given in `KENSHOU_GHC_DEBUG_SOCKET`.

If the measurement toolkit's headers differ from the catalog, only `Kenshou.Diagnose.Series.Catalog` and its tests change. If the kernel's `RunContext` differs from the assumptions, only `Kenshou.Diagnose.Context` changes. If the `endEventLogging` spike fails, drop the in-process guard, keep the parent-side one, and record the decision; nothing else depends on it.


## Interfaces and Dependencies

Libraries, all resolved by the pinned cohort from `docs/plans/1-bootstrap-the-kenshou-repository-and-pin-the-runtime-cohort.md`, so state bounds compatible with it rather than the newest on Hackage: `base` 4.21 (GHC 9.12.4); `hasql >=1.10 && <1.11` and `hasql-pool >=1.4 && <1.5` (keiro and kiroku-store both require `hasql <1.11` and `hasql-pool <1.5`; Hackage's newest, hasql 2.0.1.0 and hasql-pool 1.5.0.1, cannot be used; in hasql 1.10 a session runs with `Hasql.Connection.use connection session` and statements are built with `preparable` and `unpreparable`); `aeson >=2.2.2 && <2.3`; `random >=1.2.1 && <1.4`; `stm >=2.5 && <2.6`; `process >=1.6 && <1.7`; `cassava` 0.5.4.1; `async`, `unix`, `directory`, `filepath`, `time`, `containers`, `vector`, `text`, `bytestring`; `kenshou-core` and `kenshou-measure`. Optional, behind the flag `ghc-debug`: `ghc-debug-stub ==0.8.0.0` (released 2026-03-26; compatible with GHC 9.12 since 0.7.0.0; exports `withGhcDebug`, `withGhcDebugUnix :: String -> IO a -> IO a`, `withGhcDebugTCP :: String -> Word16 -> IO a -> IO a`). Tests: `hspec`, `hspec-hedgehog`, `hedgehog`. Tools installed outside the project: `eventlog2html` 0.12.0 (tested upstream with GHC 9.12.2; it requires `ghc-events >=0.20 && <0.21` for its own build), `ghc-events` 0.21.0.0 (`base <4.23`), and `ghc-debug-brick` 0.8.0.0, whose version must equal the stub's. PostgreSQL 17 and 18 from the dev shell; `pg_stat_statements` is used when the environment has it and is never required.

At the end of Milestone 1 these exist: `Kenshou.Diagnose.Context` (the seven adapter functions shown above), `Kenshou.Diagnose.Document` (`Diagnosis`, `DiagnosisKind`, `encodeDiagnosis`, `decodeDiagnosis`), `Kenshou.Diagnose.Stats` (`theilSen`, `slopeWithInterval`, `windowMinima`, `windowMedians`), `Kenshou.Diagnose.Series` (`readWide`, `readLong`, `SeriesBinding`), `Kenshou.Diagnose.Series.Catalog` (`defaultCatalog`, `discoverProcesses`), `Kenshou.Diagnose.Leak` (`LeakSpec`, `ProbeSpec`, `LeakVerdict`, `LeakReport`, `defaultLeakSpec`, `loadLeakPolicy`, `judgeLeaks`, `analyseRunDirectory`, `leakOutcome`) and `Kenshou.Diagnose.Leak.MajorGcProbe` (`withMajorGcProbe`). At the end of Milestone 2: `Kenshou.Diagnose.Progress`, `Kenshou.Diagnose.Threads` (`labelMe`, `forkLabelled`, `dumpThreads`, `installThreadDumpSignal`), `Kenshou.Diagnose.Postgres` (`captureActivity`, `captureLocks`, `captureStatementRate`, `AdvisoryLabel` and the six label helpers), `Kenshou.Diagnose.LockGraph` (`buildGraph`, `cycles`, `roots`, `renderDot`, `renderText`), `Kenshou.Diagnose.Pool` (`PoolStats`, `newPoolObserver`), `Kenshou.Diagnose.Stall` and `Kenshou.Diagnose.Stall.Classify` with the signatures shown above. At the end of Milestone 3: `Kenshou.Diagnose.Profile` (`ProfileMode`, `ProfileRequest`, `rtsFlags`, `runProfileSession`, `reexecWithWorkerRts`, `markPhase`), `Kenshou.Diagnose.Profile.EventlogGuard` (`startEventlogGuard`), `Kenshou.Diagnose.Profile.GhcDebug` (`withGhcDebugIfRequested`), and the two variant project files. At the end of Milestone 4: Analysis `Kenshou.Cli.Diagnose` using EP-2's `InputSource` and option groups, `Kenshou.Diagnose.Render`, and `kenshou-cli/help/diagnostics.md`. At the end of Milestone 5: `Kenshou.Diagnose.SelfTest.bundle :: LayerBundle`.


Revision note (2026-09-20): Aligned `kenshou diagnose` with EP-2's `haskell-jitsurei`-based CLI contract: Analysis grouping, intent-based option sections, explicit stdin for policy documents, clean JSON output, and an embedded `diagnostics` help topic.

Files this plan touches outside its own package, all small: `kenshou-cli/kenshou-cli.cabal`, `kenshou-cli/src/Kenshou/Cli/Registry.hs`, the executable's command list and its `worker` handler (two calls: `installThreadDumpSignal` and `reexecWithWorkerRts`), `Justfile`, `.gitignore`, `schemas/`, `policies/leak-default.json`, `docs/guides/`, `docs/adr/`. It also contributes one file to the run directory's `series/` tree, `series/rts-major.csv`, which Integration Point 5 attributes to the measurement and telemetry toolkits; this addition is deliberate and is reported to the MasterPlan.

What other plans consume. Every coverage plan (`docs/plans/8-cover-pgmq-hs-in-isolation.md` through `docs/plans/15-verify-the-assembled-runtime-end-to-end-and-under-soak.md`) wraps its concurrency and soak scenarios in `withWatchdog`, ticks a `ProgressCounter` per unit of work, registers its pools with `newPoolObserver` and `registerPool`, passes the advisory labels of its component, exposes `stall.deadline-s` and `diagnose.major-gc-interval-ms` as knobs, ends each soak with `judgeLeaks` and maps the result with `leakOutcome`, marks relations it expects to stay bounded, and labels its own threads with `forkLabelled`. `docs/plans/7-add-telemetry-arms-and-measure-observability-overhead.md` uses `judgeLeaks` per telemetry arm to answer whether enabling tracing leaks. `docs/plans/15-verify-the-assembled-runtime-end-to-end-and-under-soak.md` gates its one-, four- and twenty-four-hour soaks on the leak verdict. `docs/plans/5-build-the-correctness-toolkit-for-ledgers-invariants-faults-and-process-control.md` may call `registerChildProcess` for the workers it supervises and wrap fault windows in `suspendDeadline`. `docs/plans/17-run-kenshou-on-leased-cells-with-payloads-submission-and-retrieval.md` can build a Nix payload (the content-addressed build of `kenshou` that is shipped to a cell) from `cabal.diagnose-info-table.project` when an info-table profile is wanted on a cell; until then, cells use the `closure-type` and `eventlog` modes, which need no special build.
