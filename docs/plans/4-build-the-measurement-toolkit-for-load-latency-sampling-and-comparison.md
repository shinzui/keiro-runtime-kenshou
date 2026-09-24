---
id: 4
slug: build-the-measurement-toolkit-for-load-latency-sampling-and-comparison
title: "Build the measurement toolkit for load, latency, sampling and comparison"
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
      at: 2026-09-21T14:46:22Z
      mode: "implement"
      note: "Started EP-4 implementation after validating the completed kernel contracts."
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T22:53:07Z
      mode: "update"
      note: "Consolidated Progress into delivered outcomes and remaining acceptance"
---

# Build the measurement toolkit for load, latency, sampling and comparison

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

This repository, `keiro-runtime-kenshou`, produces verification evidence about the keiro runtime, a cohort of Haskell libraries that services link together: `pgmq-hs` (a client for PGMQ, a message queue built on PostgreSQL tables), `kiroku` (a PostgreSQL event store), `shibuya` (a message-processing framework) with its adapters, and `keiro` on top. One of the three kinds of evidence the owner asked for is benchmarking "measured with enough rigor to be compared across releases", because "a number without a baseline is not evidence". Nothing in the house can do that today. The older `kiroku-bench` driver (GitHub `shinzui/kiroku-bench`, not registered in Mori) generates load only in a closed loop, estimates percentiles by interpolating between sixteen fixed histogram buckets, never excludes warm-up, and keeps no raw samples. `mori://shinzui/keiro-benchmarks` times whole batches with a wall clock. The analysis script in `mori://shinzui/load-testing-infra` aggregates trials but never compares two arms. The one real comparator in the house is a TypeScript script private to the release audit of `mori://shinzui/shibuya`.

After this plan, a scenario author in any layer of this suite can wrap an operation in a load generator and get, without writing measurement code: latency percentiles accurate to three significant digits from a high-dynamic-range histogram; latency measured from the moment a request was supposed to start, so that a stalled system cannot hide its own stall; every raw sample retained on disk so any figure can be recomputed later; warm-up excluded by phase; and time series of the Haskell runtime, the operating-system process and PostgreSQL written as CSV files in the run directory. A maintainer can run `kenshou summarize <run-dir>` to recompute and verify a run's figures from its raw files, and `kenshou compare` over paired baseline and candidate runs to get exactly one of four verdicts — `pass`, `regression`, `inconclusive` or `infrastructure-failure` — with an exit code a script can branch on. Health gates make sure that a saturated load driver, a checkpoint that fell into one arm only, a paused virtual machine or a host-maintenance notice can never be reported as a regression of the runtime.

The work is visible through three self-test scenarios that need no runtime library at all. `selftest/measure/benchmark/sleep-service` drives a synthetic service that stalls for one second every ten seconds and shows the same run reporting a 99th-percentile latency near 910 ms when measured from the intended start and near 1 ms when measured the naive way. `selftest/measure/benchmark/regression-injected` is run as paired trials and `kenshou compare` answers `regression` for an injected slowdown, `pass` for identical arms and `inconclusive` for noisy arms. `selftest/measure/benchmark/pg-insert` writes to a scratch PostgreSQL table and leaves `series/pg-*.csv` files behind, and shows that a run made with `fsync` off is refused as benchmark evidence.


## Progress

- [x] (2026-09-21) Measurement toolkit complete: load generation, latency recording, samplers, summaries, health gates, and paired comparison have executable self-tests and PostgreSQL 17/18 evidence. See Outcomes & Retrospective for results.

## Surprises & Discoveries

- The completed kernel registers seven self-test scenarios rather than the five anticipated by this draft; the additional `outcome` and `postgres-roundtrip` scenarios are intentional EP-2 acceptance coverage. The preflight still passed: `cabal build all` succeeded in `nix develop`, `always-pass` produced `run-spec.json`, `run-result.json`, `manifest.json`, and `logs/harness.jsonl`, and `kenshou-cli` already enables `-T`.
- The real kernel adapter surface is `RunContext.knobs`, `.dimensions`, `.seed`, `.phases`, `.env`, `.outDir`, `.logger`, and `.state`. Measurement sections are registered with `putSummary context Measurements`, artifacts are allocated with `artifactPath`, media types with `declareMediaType`, and phase timings with `withPhase`; there is no separate structured phase-marker callback.
- The default HDR layout is 33,792 counters as planned, and ten million in-memory records completed within a 0.133-second test-suite run on the development machine. The same acceptance test also rebuilds the steady histogram from the retained KSMP records and checks structural equality with the stored KHST histogram.
- The three full-duration sleep-service arms passed. Open constant recorded 3,000 steady samples with intended-start p99 924.84 ms, service-time p99 4.52 ms, and max 1.012 s. Open Poisson recorded 3,042 samples with intended-start p99 927.99 ms, service-time p99 4.96 ms, and max 1.005 s. Closed loop recorded 17,767 samples with p99 4.92 ms and max 1.006 s, exposing exactly the coordinated-omission contrast the scenario is meant to demonstrate.
- The kernel enforces its completed protocol rule that PostgreSQL benchmark scenarios may advertise only durable operation, so the draft's request for an `fsync-off` arm on `selftest/measure/benchmark/pg-insert` cannot be represented in the registered scenario. The selftest therefore supports `pg.durability=durable`; Milestone 4 tests exploratory grading and refusal directly from run documents instead of weakening the kernel invariant.
- Full-duration `pg-insert` runs passed on PostgreSQL 17 at `/tmp/kenshou-ep4-m3-pg17/01a0c493-fc93-707b-8620-cc71c2d0c0e1` and PostgreSQL 18 at `/tmp/kenshou-ep4-m3-pg18-load-series/01a0c496-f07d-73c7-9e64-8cb210f7868c`. Each PostgreSQL series had 23 or more lines, `pg-activity.csv` contained `kenshou-selftest-writer` and excluded `kenshou-sampler`, steady RTS rows contained derived `live_bytes_major_mean` values, and the manifest included every emitted CSV. The final PostgreSQL 18 run inserted and recorded 780,959 rows and also retained four phase-boundary rows in `series/load.csv`.
- The Milestone 4 live acceptance corpus used distinct seeds for all paired trials. The injected slowdown produced `regression` with exit 1 and a median-latency ratio of about 1.48; equal arms produced `pass` with exit 0 and a ratio of about 1.00; mixed fast and slow arms produced `inconclusive` with exit 3. Repeating the regression comparison produced byte-identical `metrics` objects, and the emitted measurement, policy and comparison documents all passed their JSON Schemas. Declaring the wrong varying axis was rejected with exit 2 before statistical comparison.
- Health evaluation had to be reproducible by `kenshou summarize`, so it derives gates from the persisted CSV, sample metadata and run specification rather than from in-memory reports. Host notices are copied into `health-notices.jsonl` inside the run and declared in the manifest. The maintenance run still passed `summarize --verify` after `KENSHOU_HEALTH_NOTICES` was removed.
- The live health injections produced the intended evidence: backlog reached 22.80 seconds of lag and ended inconclusive with soft `open-loop-backlog`; the eight-second whole-process stop produced 8.03 seconds of sampler lateness and ended infrastructure-failure with hard `clock-anomaly`; the captured hard maintenance notice ended infrastructure-failure with `host-notice`.


## Decision Log

- Decision: Implement the high-dynamic-range histogram in this repository instead of depending on a Hackage binding.
  Rationale: The only candidate, `hdr-histogram` 0.1.0.0, was uploaded on 2016-01-03 and has no later revision; it is GPL-3 licensed, bounds `vector <0.12`, `primitive <0.7` and `deepseq <1.5` (all below what GHC 9.12.4 and the cohort use), and has no serialisation. `HdrHistogram` and `hdrhistogram` do not exist on Hackage. The algorithm is about two hundred lines and is specified exactly in Milestone 1.
  Date: 2026-09-20

- Decision: All contact with the kernel's `RunContext` is confined to `Kenshou.Measure.Session.measureEnvFromRunContext`; every other module takes a small `MeasureEnv` record.
  Rationale: The kernel plan was drafted in parallel with this one, so its exact field names are not known here. One adapter function keeps the toolkit testable with a temporary directory and limits rework to one place if names differ.
  Date: 2026-09-20

- Decision: The open-loop generator uses one shared arrival schedule whose tickets executors claim atomically, measures latency from the ticket's intended start, and never starts an operation early.
  Rationale: Per-executor sub-schedules would let one slow operation delay later arrivals even while other executors are idle, which is not how independent arrivals behave. Starting late adds honestly to measured latency; starting early would fabricate a better result.
  Date: 2026-09-20

- Decision: The series of live bytes after major garbage collections is derived from the deltas of `cumulative_live_bytes` and `major_gcs` rather than from `gcdetails_live_bytes`.
  Rationale: `GHC.Stats` documents `gcdetails_live_bytes` as updated after every collection with uncollected generations counted as live, so at a sampling instant it usually describes a minor collection. `cumulative_live_bytes` is documented as the sum of live bytes across all major collections, so its delta divided by the delta of `major_gcs` is exact for the interval and independent of when the sample fell. The diagnostics plan judges leaks on this column.
  Date: 2026-09-20

- Decision: Comparison works on per-trial summary metrics paired by index; the confidence interval is the envelope of a seeded percentile bootstrap and a Student-t interval on log ratios; a regression needs both the relative limit and the absolute floor to be exceeded at the lower bound.
  Rationale: This follows the shibuya release comparator (paired ratios, geometric mean, seeded bootstrap) and the requirement in `mori://shinzui/keiro-benchmarks/okf/improvement-requests/concepts/IR-1` for a relative change plus a practical absolute floor. With five pairs a percentile bootstrap alone is anti-conservative; taking the wider of the two intervals errs toward `inconclusive`, never toward a false `regression`.
  Date: 2026-09-20

- Decision: Compatibility means "every key component equal except the one axis the caller declares as varying", and the components are derived by the comparator from `run-spec.json` and `run-result.json` rather than read from a stored hash.
  Rationale: The kernel's compatibility key includes the cohort, so a candidate-versus-baseline comparison across two cohorts would always look incompatible if keys had to match exactly. Declaring the varying axes (`cohort`, a dimension or a knob; a non-empty list, because the telemetry-overhead plan and the assembled-runtime plan compare arms that differ in `telemetry.tracing` and `telemetry.metrics` at once) keeps the check strict for everything else. The check itself is the kernel's `compatibleExcept :: [CompatField] -> CompatInputs -> CompatInputs -> Either (NonEmpty CompatField) ()`; this plan maps each axis to a `CompatField` and records the list in the comparison document as `variedFactors`.
  Date: 2026-09-20

- Decision: A run whose scenario used PostgreSQL with `pg.durability=fsync-off` is graded `exploratory`, and `kenshou compare` answers `inconclusive`, never `pass` or `regression`, for exploratory runs unless the policy explicitly lowers `requireGrade`.
  Rationale: Every existing suite in the runtime benchmarks with `fsync=off`, which the kiroku methodology records as a distortion. The grade makes the refusal mechanical rather than a convention.
  Date: 2026-09-20

- Decision: Raw samples are retained in full for `benchmark` scenarios and replaced by ten-second interval histograms for `soak` scenarios by default.
  Rationale: `mori://shinzui/keiro-benchmarks/okf/improvement-requests/concepts/IR-1` requires that every derived benchmark figure be recomputable from raw samples. A twenty-four-hour soak at five thousand operations a second would write several gigabytes of samples that no comparison consumes; interval histograms still allow any percentile to be recomputed per interval.
  Date: 2026-09-20

- Decision: The PostgreSQL sampler uses one dedicated connection with `application_name=kenshou-sampler`, never a connection from a pool under test, and runs on its own thread.
  Rationale: Borrowing from the pool would perturb pool-starvation behaviour, and a slow statistics query must not delay runtime and process sampling. The name lets every activity query exclude the sampler itself.
  Date: 2026-09-20

- Decision: The host-maintenance hook is a JSON-lines file named by the environment variable `KENSHOU_HEALTH_NOTICES`.
  Rationale: The MasterPlan says the cell supplies health observations but defines no channel into a running process. A file is the smallest contract that works locally (a test writes it) and on a cell (the cell agent appends to it) without this toolkit knowing anything about Google Cloud.
  Date: 2026-09-20

- Decision: The measurement self-tests live in `kenshou-measure` and are exported as a second bundle whose layer is `selftest`; a third scenario, `selftest/measure/benchmark/pg-insert`, is added beyond the two the MasterPlan brief names.
  Rationale: `kenshou-core` cannot depend on a toolkit, so the kernel's own `selftest` bundle cannot hold these scenarios. The PostgreSQL samplers and the durability grade cannot be demonstrated without a scenario that uses PostgreSQL.
  Date: 2026-09-20

- Decision: The default policy requires five pairs; no policy may ask for fewer than three.
  Rationale: The `load-testing-infra` record shows plus or minus twenty percent between single trials; its rule is "N at least 3, prefer 5". The shibuya audit uses ten, which the `release` policy can adopt later.
  Date: 2026-09-20

- Decision: Register `compare` and `summarize` in the Analysis command group, use EP-2's intent-based option groups and explicit `-` input for policy documents, and contribute an embedded `comparisons` help topic.
  Rationale: These commands interpret completed evidence rather than execute workloads. Their inputs and verdict vocabulary are subtle enough to need in-binary guidance, while the shared CLI seam keeps completions and machine-readable output consistent.
  Date: 2026-09-20


## Outcomes & Retrospective

The measurement toolkit now supplies monotonic intended-start latency recording,
bounded histograms and retained raw samples, closed and open load generation,
runtime/process/host/PostgreSQL series, reproducible summaries, paired comparison,
and health-aware verdicts through one scenario-facing session API. The three
self-test scenarios prove coordinated-omission correction, deterministic
regression classification, PostgreSQL 17/18 sampling, and every health exit path.

The implementation completed all five milestones in six Conventional Commits.
`kenshou-measure-test` has 29 focused examples including property tests and the
ten-million-record cost check. Full live acceptance covered all command exit
codes, untouched/tampered/truncated summary verification, deterministic
comparison metrics, schema validation, both supported PostgreSQL versions, and
the three health injections. The repository-wide `just verify` passed, and the
recipe now runs the measurement test suite explicitly.

Two draft details were adjusted without weakening the contracts. The kernel
already forbids fsync-off benchmark scenarios, so exploratory grading was tested
from run documents rather than by registering an invalid PostgreSQL benchmark
arm. Health gates read sealed files so later summary verification can reproduce
the exact measurement section; this also gives remote-cell and evidence plans a
stable artifact boundary.


## Context and Orientation

The repository today. At the time this plan was written the repository held only `README.md`, `mori.dhall`, the MasterPlan at `docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md` and nineteen child plans under `docs/plans/`. There was no Haskell code. Two earlier plans must be complete before this one starts. `docs/plans/1-bootstrap-the-kenshou-repository-and-pin-the-runtime-cohort.md` delivers the Nix development shell (GHC 9.12.4, cabal 3.16, PostgreSQL 18 and 17, `just`, `jq`, `okf`), a `cabal.project` whose package list is the glob `kenshou-*/*.cabal` (so creating the directory `kenshou-measure/` is all it takes to add this package), the pinned runtime cohort under `cohort/`, the ADR bundle at `docs/adr/` and the recipe `just verify`. `docs/plans/2-build-the-harness-kernel-for-scenarios-dimensions-run-specs-and-results.md` delivers the package `kenshou-core` and the executable `kenshou` in `kenshou-cli`. A cohort is the exact set of runtime package versions one build links; every run result carries the resolved cohort identity.

What this plan expects from the kernel. A scenario is a value, not a test-suite test: it is identified by a four-segment path `<layer>/<component>/<kind>/<name>`, where the layer is one of `selftest`, `pgmq`, `kiroku`, `shibuya`, `kafka`, `keiro`, `runtime` and the kind is one of `correctness`, `concurrency`, `soak`, `benchmark`; it declares a cost tier (`smoke` under one minute, `standard` under ten, `extended` under an hour, `soak` hours), a placement (`local`, `cell`, `either`), its knobs and the dimension values it supports, and a function `run :: RunContext -> IO ScenarioReport`. A knob is a typed per-scenario parameter (`KnobSpec`: name, type, default, allowed values) set on the command line with `--set name=value`. A dimension is a cross-cutting switch with a closed value set, set with `--dim name=value`: `telemetry.tracing` (`off`, `noop`, `sdk-inmemory`, `sdk-otlp`), `telemetry.metrics` (`off`, `collect`, `serve`, `serve-scraped`), `pg.durability` (`fsync-off`, `durable`) and `pg.version` (`17`, `18`). Each package exports one `bundle :: LayerBundle` and `kenshou-cli/src/Kenshou/Cli/Registry.hs` lists the bundles. The kernel modules this plan imports are `Kenshou.Core.Scenario`, `Kenshou.Core.Knob`, `Kenshou.Core.Dimension`, `Kenshou.Core.Bundle`, `Kenshou.Core.RunSpec`, `Kenshou.Core.RunResult`, `Kenshou.Core.Outcome`, `Kenshou.Core.Env.Postgres` and `Kenshou.Core.Role`. From `RunContext` it needs seven things: the resolved knobs and dimensions; the environment handles, in particular a `PostgresEnv` with a connection string; the seed; the run's output directory; a structured logger; a way to register a named JSON section of the run result (this plan fills the section `measurements`); and phase markers that record when warm-up, steady state and drain began. Because the kernel plan was drafted in parallel, a name may differ; the adapter `measureEnvFromRunContext` described in Milestone 1 is the only function that has to change.

The contracts this plan must honour, restated from the MasterPlan's Integration Points. A run is identified by a UUIDv7 in lowercase text and owns the directory `<out>/<run-id>/`, which a later run never writes into. The kernel writes `run-spec.json` (`kenshou.run-spec/v1`), `run-result.json` (`kenshou.run-result/v1`) and `manifest.json` (`kenshou.artifact-manifest/v1`, the SHA-256 of every file). This plan owns two subdirectories: `samples/` for latency histograms and raw sample files, and `series/` for time-series CSV files (`rts.csv`, `proc.csv`, `pg-*.csv`; the telemetry plan later adds `scrape-*.csv`). It also owns the document `kenshou.comparison/v1` and the commands `kenshou compare` and `kenshou summarize`. Every JSON document carries a `schema` field of the form `kenshou.<name>/v<N>` and has a JSON Schema in `schemas/`. Run outcomes are `passed`, `failed`, `errored`, `inconclusive` and `infrastructure-failure`; comparison verdicts are `pass`, `regression`, `inconclusive` and `infrastructure-failure`. Exit codes are 0 for passed or pass, 1 for failed or regression, 2 for a usage error, 3 for inconclusive and 4 for errored or infrastructure-failure. The seed in the run specification drives every random choice. Most important for this plan: measurement never flows through the feature being toggled. Latency and throughput are recorded in-process and written to files, so a run with every telemetry dimension `off` is still fully measured. The old harness scraped its results from a Prometheus endpoint, which made a "metrics off" arm impossible.

Terms used in this plan. A monotonic clock only moves forward and is unaffected by time-of-day corrections; `GHC.Clock.getMonotonicTimeNSec :: IO Word64` in `base` is one. Latency is the time one operation took; throughput is completed operations per second; the p99 is the value below which ninety-nine percent of samples fall. An HDR (high dynamic range) histogram counts samples in buckets whose width grows with the value, so that any latency from a few nanoseconds to an hour is stored with a bounded relative error (0.1 percent at three significant digits) in a fixed amount of memory. A closed-loop load generator runs N workers that each start the next operation when the previous one finishes; an open-loop generator starts operations at scheduled arrival times regardless of how earlier ones are doing. Coordinated omission is the measurement error a closed loop makes: when the system stalls, the generator politely stops sending, so the stall contributes one slow sample instead of the hundreds of requests that would have queued; measuring each operation from its intended start time corrects this. Warm-up is the initial period (cold caches, pool filling, just-in-time effects in PostgreSQL) whose samples are excluded; steady is the measured window; drain lets in-flight work finish. A sampler reads a gauge at a fixed interval and appends a CSV row. The GHC runtime system (RTS) exposes garbage-collection statistics through `GHC.Stats` only when the program runs with `+RTS -T`; a major collection examines the whole heap, and the bytes still live after it are the honest measure of memory held, unlike resident set size (RSS, the memory the operating system has mapped), which a copying collector inflates. In PostgreSQL the write-ahead log (WAL) records every change, `fsync` forces it to disk, a checkpoint periodically flushes dirty pages and can dominate latency for minutes, `pg_stat_statements` is a bundled extension that counts executions per statement and must be listed in `shared_preload_libraries` at server start, `pg_stat_activity` lists connections with their `application_name` and the wait event they are blocked on. A paired comparison runs baseline (arm A) and candidate (arm B) alternately — ABBA or BAAB — so that slow drifts affect both arms equally. A bootstrap confidence interval is obtained by resampling the observed pairs many times with a seeded random generator. A compatibility key lists everything that must be equal for two results to be comparable. A cell is a leased set of Google Cloud machines on which benchmarks run; host maintenance is Google moving a virtual machine, which disturbs timing. OKF (Open Knowledge Format) is a directory of Markdown files with YAML frontmatter validated by the house tool `okf` against a profile (a schema for that directory); an ADR is an Architecture Decision Record.

Prior art, verified on disk. The closed-loop writer loop to lift is `runWriterLoop` in `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku-bench/kiroku-bench/src/Kiroku/Bench/Runtime.hs` (GitHub `shinzui/kiroku-bench`; the project is not registered in Mori, so no `mori://` URI exists for it): it polls a stop flag, times one call with `getMonotonicTimeNSec`, observes the latency and counts errors by cause (`store`, `io`). Its sibling `Metrics.hs` defines the sixteen buckets from 50 µs to 5 s that this plan replaces. The methodology rules come from `mori://shinzui/kiroku` at `docs/PERF-METHODOLOGY.md` (`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/docs/PERF-METHODOLOGY.md`; artifact-level URI pending): the kiroku append path serialises on one row lock, so its throughput-optimal pool is about 10 to 13 connections regardless of writer count, and arms must be compared best-pool against best-pool. The statistical prior art is `mori://shinzui/shibuya` at `scripts/audit/compare-performance.ts` with budgets in `docs/audits/lifecycle-release/performance-budgets.json` (`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/`; artifact-level URIs pending): paired samples, adverse ratios, geometric mean, a seeded bootstrap of 10,000 iterations at 95 percent, per-metric direction, relative limits and absolute limits for near-zero baselines. Its exit code for inconclusive is 2, which this repository's contract reserves for usage errors, so the code is a model and not a dependency. The same repository's `shibuya-core-bench/bench/Bench/Lifecycle.hs` already measures latency from a scheduled arrival time (`now - message.scheduledAtNs`), but collects samples in a list under `atomicModifyIORef'`. `mori://shinzui/load-testing-infra` at `scripts/analyze-experiment-set.py` (`/Users/shinzui/Keikaku/bokuno/load-testing-infra/`) supplies the Student-t critical values used below and the lesson that one roughly 270-second checkpoint per 600-second window produced plus or minus twenty percent between trials, while GHC productivity stayed within 0.2 points. The protocol specification is `mori://shinzui/keiro-benchmarks/okf/improvement-requests/concepts/IR-1`, which this plan calls the benchmark protocol request: monotonic timing, explicit warm-ups, retained raw samples, a declared paired ordering, thresholds with a relative change and an absolute floor, an inconclusive verdict for excessive variance, named algorithm versions, and compatibility-aware history. The health-gate requirement ("host maintenance, unexpected background load ... as infrastructure failures or inconclusive evidence, never as performance regressions") is from `mori://shinzui/load-testing-infra/okf/improvement-requests/concepts/IR-1`.

Facts about libraries, verified against sources. The cohort uses `hasql >=1.10 && <1.11` (see `kiroku-store.cabal` in `mori://shinzui/kiroku`); in that version `Hasql.Connection.acquire :: Settings -> IO (Either ConnectionError Connection)`, `Hasql.Connection.Settings` is a `Monoid` with `connectionString :: Text -> Settings` and `applicationName :: Text -> Settings`, and `Hasql.Connection.use :: Connection -> Session a -> IO (Either SessionError a)` (source at `/Users/shinzui/Keikaku/hub/haskell/hasql-project/hasql`, `mori://hasql/hasql`). `ephemeral-pg` 0.3.1.0 (`mori://shinzui/ephemeral-pg`, `/Users/shinzui/Keikaku/bokuno/ephemeral-pg-project/ephemeral-pg/src/EphemeralPg/Config.hs`) starts servers with `fsync`, `synchronous_commit` and `full_page_writes` off and `shared_buffers` of 12 MB by default, and accepts extra server settings through the `postgresSettings :: [(Text, Text)]` field of its monoidal `Config`, which is how the kernel can preload `pg_stat_statements`. In `base` 4.21 (GHC 9.12) `GHC.Stats.getRTSStatsEnabled` reports whether `-T` is on, and `GHC.Conc.listThreads :: IO [ThreadId]` exists since `base` 4.18. In PostgreSQL 17 the view `pg_stat_checkpointer` has `num_timed`, `num_requested`, `write_time`, `sync_time` and `buffers_written`; version 18 adds `num_done` and `slru_written`. In version 18 `pg_stat_wal` lost `wal_write`, `wal_sync` and their timing columns, so only `wal_records`, `wal_fpi`, `wal_bytes` and `wal_buffers_full` are common to both. Neither version has a checkpoint progress view. The only place the runtime sets an `application_name` itself is kiroku's listener connection, `kiroku-listener`; pools inherit whatever the connection string says, so coverage plans should put an `application_name` in the connection strings they hand to each component.

Architecture decisions. There is no local ADR corpus beyond what the bootstrap plan creates: `docs/adr/` is a profile-governed OKF bundle that starts with two records (layer packages never import one another; every result carries a resolved cohort identity). Scan it with `ls docs/adr` and `okf id list docs/adr --profile docs/adr/profile.dhall` before starting and read any record about measurement, comparison or the command-line protocol. Two cross-repository decisions shape this plan. `mori://shinzui/kiroku/okf/adrs/concepts/ADR-5` separates performance evidence into deterministic structural checks, controlled workloads that run a control and a candidate in the same environment against a pre-registered ratio, and historical telemetry, and treats only the first two as authoritative; this plan's comparison is the second tier, and nothing here ever issues a verdict from a historical series. The shibuya record `docs/adr/0002-require-candidate-bound-machine-checkable-release-evidence.md` in `mori://shinzui/shibuya` (that repository keeps ADRs outside an OKF bundle, so the artifact-level URI is pending) requires evidence bound to exact commits, the solver plan hash, compiler and seeds; the compatibility components in Milestone 4 are the same idea. This plan creates one ADR of its own — comparison verdicts come only from paired, interleaved, compatibility-checked, benchmark-grade runs, and history is telemetry — and contributes to two owned by other plans: "results are recorded through a channel independent of the feature under test" (owner `docs/plans/7-add-telemetry-arms-and-measure-observability-overhead.md`) and "this repository owns the runtime-facing benchmark protocol" (owner `docs/plans/2-build-the-harness-kernel-for-scenarios-dimensions-run-specs-and-results.md`).


## Plan of Work

All code lives in the new package `kenshou-measure/` under the namespace `Kenshou.Measure`. The cabal file follows the house shape used by `kenshou-core`: `cabal-version: 3.0`, a `common` stanza with `default-language: GHC2024`, the extensions `DuplicateRecordFields`, `ImportQualifiedPost`, `OverloadedRecordDot`, `OverloadedStrings`, the usual `-Wall -Wcompat` warning set, a library with `hs-source-dirs: src` and a test suite named `kenshou-measure-test` with `hs-source-dirs: test` using `hspec` and `hspec-hedgehog`. The package depends on `kenshou-core` and on no other package of this repository.


### Milestone 1 — Clocks, the latency recorder and warm-up exclusion

Scope: everything needed to record one latency correctly and cheaply and to prove it later. At the end the package builds, a test can create a recorder in a temporary directory, record samples from several threads across a warm-up and a steady phase, finish, and find `samples/<op>.hist`, `samples/<op>.service.hist`, `samples/<op>.raw` and `samples/<op>.meta.json` on disk; a histogram rebuilt from the raw file is identical to the recorded one. Run `cabal test kenshou-measure:kenshou-measure-test`; accept when the histogram, codec, samples, phase and recorder groups pass.

Create `kenshou-measure/src/Kenshou/Measure/Clock.hs`. It wraps `getMonotonicTimeNSec`, captures a wall-clock and monotonic reading together (the run origin, written into every file header so that files from several processes on one host can be aligned), and provides a sleep that loops on `threadDelay` until the monotonic clock has reached the deadline, so it may return late but never early.

```haskell
newtype Nanos = Nanos Word64
data Origin = Origin { monoNs :: !Word64, wallUnixNs :: !Int64 }
nowNs        :: IO Word64
captureOrigin :: IO Origin
sleepUntilNs :: Word64 -> IO ()
```

Create `kenshou-measure/src/Kenshou/Measure/Histogram.hs`. The layout is the log-linear scheme of HdrHistogram, specified here completely so no outside reference is needed. The configuration is `lowestDiscernible` (nanoseconds, default 1), `highestTrackable` (default 3,600,000,000,000, one hour) and `significantDigits` (1 to 5, default 3). The default for `lowestDiscernible` is 1 and not 1,000 on purpose: the promised relative precision only holds above `2 * 10^significantDigits` units, so a unit of a microsecond would store a 300 µs append with half-percent error, while a unit of a nanosecond costs only a third more memory. Derive `unitMagnitude = floor (log2 lowestDiscernible)` (0 for the default), `subBucketCountMagnitude = ceiling (log2 (2 * 10^significantDigits))` (11), `subBucketCount = 2^subBucketCountMagnitude` (2,048), `subBucketHalfCount = subBucketCount / 2`, `subBucketHalfCountMagnitude = subBucketCountMagnitude - 1` and `subBucketMask = (subBucketCount - 1) << unitMagnitude`. The bucket count is the smallest `n >= 1` such that `(subBucketCount << unitMagnitude) << (n - 1)` exceeds `highestTrackable` (32 for the defaults) and the counts array has `(n + 1) * subBucketHalfCount` entries of `Word64` (33,792 entries, 264 KiB). For a value `v`: `bucketIndex = (64 - unitMagnitude - subBucketCountMagnitude) - countLeadingZeros (v .|. subBucketMask)`, `subBucketIndex = v >> (bucketIndex + unitMagnitude)` and `countsIndex = ((bucketIndex + 1) << subBucketHalfCountMagnitude) + (subBucketIndex - subBucketHalfCount)`. As a check with the defaults, 1,000 ns maps to index 1,000, 2,048 ns to index 2,048, 2,000,000 ns to index 12,193 and one hour to index 33,420; values below 2,048 ns are stored exactly and every larger value with a relative error below 0.1 percent. The inverse, for index `i`: `b = (i >> subBucketHalfCountMagnitude) - 1` and `s = (i .&. (subBucketHalfCount - 1)) + subBucketHalfCount`; when `b < 0` subtract `subBucketHalfCount` from `s` and set `b = 0`; the lowest equivalent value is `s << (b + unitMagnitude)`, the range size is `1 << (b + unitMagnitude)` and the highest equivalent value is their sum minus one. Beside the counts the histogram keeps the exact minimum, maximum, sum and total count, and an `overflowCount` for values above `highestTrackable` (their exact maximum is still tracked). A quantile query walks the cumulative counts to `max 1 (ceiling (q * total))`, returns the highest equivalent value of that index clamped to the exact minimum and maximum, and returns the exact maximum for `q = 1` or when the target lies in the overflow. Merging adds counts element-wise and requires identical configurations. The mutable form is a `MutablePrimArray RealWorld Word64` from `primitive`, owned by one thread.

```haskell
data HistogramConfig = HistogramConfig
  { lowestDiscernible :: !Word64, highestTrackable :: !Word64, significantDigits :: !Int }
defaultHistogramConfig :: HistogramConfig
data MutableHistogram
data Histogram
newHistogram    :: HistogramConfig -> IO MutableHistogram
recordValue     :: MutableHistogram -> Word64 -> IO ()
freeze          :: MutableHistogram -> IO Histogram
merge           :: Histogram -> Histogram -> Either Text Histogram
valueAtQuantile :: Histogram -> Double -> Word64
totalCount, minValue, maxValue, overflowCount :: Histogram -> Word64
meanValue       :: Histogram -> Double
```

Create `kenshou-measure/src/Kenshou/Measure/Histogram/Codec.hs` for the file format `KHST` version 1, little-endian: the four bytes `KHST`, a `u16` version (1), a `u16` of flags (0), `u64 lowestDiscernible`, `u64 highestTrackable`, `u8 significantDigits`, `u64 totalCount`, `u64 minValue`, `u64 maxValue`, `u64 sum`, `u64 overflowCount`, `u32` number of encoded entries, then the counts as ZigZag LEB128 integers in which a non-negative number is the count of the next index and a negative number `-k` stands for `k` consecutive zero counts; trailing zeros are omitted. The format is deliberately not the HdrHistogram interchange format; integrity comes from the kernel's manifest, which records the SHA-256 of every file.

Create `kenshou-measure/src/Kenshou/Measure/Samples.hs` for the raw sample file `KSMP` version 1. The header is the bytes `KSMP`, `u16` version, `u16` flags, `u64` origin monotonic nanoseconds, `i64` origin wall-clock nanoseconds since the Unix epoch, a `u8` clock kind (0 monotonic on one host, 1 wall clock), and length-prefixed UTF-8 strings for the operation name and the process label. The body is a sequence of blocks, one per flush of one worker's buffer: `u16` worker id, `u32` record count, `u32` payload bytes, `u64` intended-start offset of the first record from the origin, then records of LEB128 integers — ZigZag delta of the intended start from the previous record, start lag (actual start minus intended start, zero in a closed loop), service time (end minus actual start), one outcome byte (0 for success, otherwise one plus the index into the error-cause table in the metadata file) and the units of work completed. Latency from intended start is start lag plus service time, so both the corrected and the naive distribution, and the phase of every sample, can be recomputed from this file alone. A record costs about seven bytes. Each worker fills a private 64 KiB buffer and hands full buffers to one writer thread through a bounded queue of 256 blocks; if the queue is full the worker drops nothing and blocks, and a counter records the event so Milestone 5 can flag that the instrument disturbed the run.

Create `kenshou-measure/src/Kenshou/Measure/Phase.hs`. The phases are `Setup`, `WarmUp`, `Steady`, `Drain` and `Done` (rendered `setup`, `warm-up`, `steady`, `drain`, `done`). A `PhasePlan` gives the warm-up duration, the steady bound (a duration or a count of completed operations) and the drain limit; it comes from the run specification's phases when present and otherwise from the scenario's default. A `PhaseClock` holds the current phase and the steady window's start and end in unboxed mutable cells that workers read without locks; `enterPhase` updates them, forwards the marker to the kernel and asks the samplers for a boundary row. A sample belongs to the phase in which its intended start falls: an operation that was due during steady state but completed during drain is a steady sample, and one due during warm-up never is.

```haskell
data Phase = Setup | WarmUp | Steady | Drain | Done
data SteadyBound = SteadyFor !Nanos | SteadyCount !Word64
data PhasePlan = PhasePlan { warmUp :: !Nanos, steady :: !SteadyBound, drain :: !Nanos }
newPhaseClock :: MeasureEnv -> PhasePlan -> IO PhaseClock
enterPhase    :: PhaseClock -> Phase -> IO ()
currentPhase  :: PhaseClock -> IO Phase
phaseOf       :: PhaseClock -> Word64 -> IO Phase
```

Create `kenshou-measure/src/Kenshou/Measure/Recorder.hs`. A `Recorder` owns the operations of one process; `registerOp` names one; `newWorkerRecorder` gives a Haskell thread its private state: two steady-phase histograms (latency from intended start, and service time), unboxed counters for successes, failures and units per phase, a small map of failures by cause touched only on the failure path, and the raw-sample buffer. Nothing on the success path takes a lock or allocates beyond the amortised buffer hand-off, which is what "lock-free per-thread recorders" means in Haskell, where a recorder is owned by one green thread. All memory is allocated when the worker recorder is created, so the instrument appears in memory series as a constant level and never as a slope (64 workers with two default histograms each cost 33 MiB; a scenario with many workers and sub-hour latencies can lower `highestTrackable`). `finishRecorder` requires that workers have stopped; it merges the worker histograms, writes `samples/<op>.hist`, `samples/<op>.service.hist` and `samples/<op>.meta.json` (schema `kenshou.sample-meta/v1`: operation, latency basis `intended-start` or `actual-start`, clock kind, histogram configuration, raw-sample policy, error-cause table, counts per phase, file names), and closes `samples/<op>.raw`. The raw-sample policy is `RawFull`, `RawSampled n` (one block in `n`) or `RawOff`; under the last two the recorder also writes `samples/<op>.ihist`, a sequence of frames (`u64` start offset, `u64` end offset, `u8` phase, one `KHST` body) produced every `measure.interval-histogram-seconds`: the sampler thread bumps an epoch counter and each worker, on its next record, hands over its interval histogram and starts a new one. In a worker process started by `kenshou worker` every file name gains the process label before the extension (`samples/append.writer-2.raw`); the parent merges `samples/<op>.*.hist` into `samples/<op>.hist` when it finishes.

```haskell
newtype OpName = OpName Text
newtype ErrorCause = ErrorCause Text        -- short stable label such as "version-conflict", "store", "io", "timeout"
data OpResult = OpOk !Int | OpFailed !ErrorCause   -- Int: units of work completed, e.g. events in a batch
newRecorder       :: MeasureEnv -> PhaseClock -> RecorderConfig -> IO Recorder
registerOp        :: Recorder -> OpName -> IO OpHandle
newWorkerRecorder :: OpHandle -> Int -> IO WorkerRecorder
recordOp          :: WorkerRecorder -> Word64 -> Word64 -> Word64 -> OpResult -> IO ()  -- intended start, actual start, end
recordDuration    :: WorkerRecorder -> Word64 -> Word64 -> OpResult -> IO ()            -- end, duration measured elsewhere
timeOp            :: WorkerRecorder -> IO OpResult -> IO OpResult
finishRecorder    :: Recorder -> IO RecorderReport
```

`recordDuration` exists for latencies that cross processes, such as append-to-delivery, where the caller computes a duration from wall-clock stamps carried in message metadata; the metadata file then says `clock: wall`. Create `kenshou-measure/src/Kenshou/Measure/Session.hs` with the adapter record and nothing else yet.

```haskell
data MeasureEnv = MeasureEnv
  { runDir          :: FilePath
  , seed            :: Word64
  , origin          :: Origin
  , processLabel    :: Maybe Text
  , scenarioKind    :: Kind                       -- from Kenshou.Core.Scenario
  , pgDurability    :: Maybe Text                 -- Nothing when the scenario asked for no PostgreSQL
  , specPhases      :: Maybe PhasePlan
  , onPhase         :: Phase -> Origin -> IO ()   -- forwards to the kernel's phase markers
  , registerSection :: Text -> Aeson.Value -> IO ()
  , logLine         :: Text -> IO ()
  }
measureEnvFromRunContext :: RunContext -> IO MeasureEnv
```

Tests for this milestone live in `kenshou-measure/test/Kenshou/Measure/` beside a hand-written `kenshou-measure/test/Main.hs`. Property tests (hedgehog): for every value in range the highest equivalent value of its index is within `10^(-significantDigits)` of it; `merge` is commutative and associative; quantiles of a histogram agree with exact quantiles of the same values in a sorted vector to the configured precision; both codecs round-trip. A golden file `kenshou-measure/test/golden/histogram-v1.khst` pins the byte format. The timing tests answer the third acceptance criterion of the benchmark protocol request (`mori://shinzui/keiro-benchmarks/okf/improvement-requests/concepts/IR-1`): with a phase plan of 200 ms warm-up and 300 ms steady, samples whose intended start lies in warm-up are absent from `samples/<op>.hist` and present in `samples/<op>.raw`; the recorder is given only monotonic readings; and a single thread records ten million samples in under 2.5 seconds (250 ns each; expect well under 100 ns).


### Milestone 2 — Closed-loop and open-loop load generators

Scope: drive an `Operation` through warm-up, steady state and drain under either load model and record every call. At the end `kenshou list` shows `selftest/measure/benchmark/sleep-service` and running it demonstrates coordinated-omission correction with numbers that match an analytic prediction. Run `cabal test kenshou-measure:kenshou-measure-test` and the three `kenshou run` commands in Concrete Steps.

Create `kenshou-measure/src/Kenshou/Measure/Load/Types.hs`.

```haskell
data Operation = Operation { name :: OpName, run :: Int -> Word64 -> IO OpResult }  -- worker or executor id, sequence number
data Arrival = ConstantRate !Double | PoissonRate !Double                            -- operations per second
data ClosedConfig = ClosedConfig { workers :: !Int, thinkTimeNs :: !Word64, staggerNs :: !Word64 }
data OverloadConfig = OverloadConfig { maxLagNs :: !Word64, sustainedIntervals :: !Int, abortLagNs :: !Word64 }
data OpenConfig = OpenConfig { arrival :: !Arrival, executors :: !Int, rampFrom :: !Double, overload :: !OverloadConfig }
data LoadModel = ClosedLoop ClosedConfig | OpenLoop OpenConfig
data LoadReport = LoadReport
  { offered, started, completed, failed :: !Word64, maxLagNs :: !Word64
  , overloaded :: Maybe OverloadEvidence, abortedEarly :: !Bool }
runLoad :: Measurement -> LoadModel -> Operation -> IO LoadReport
```

`Kenshou.Measure.Load.Closed` is `runWriterLoop` generalised: `workers` threads (labelled `kenshou-load-<n>` with `GHC.Conc.labelThread`) start staggered across `staggerNs` so that pools do not fill in one burst, then each loops — check the phase, read the clock, run the operation under `try`, read the clock, record, optionally sleep the think time — until the steady bound is reached and the phase clock enters drain, where each worker finishes its current call and exits. An exception thrown by the operation is recorded as `OpFailed (ErrorCause "exception")` and the loop continues, because a load generator must survive the failures it provokes. In a closed loop the intended start is the actual start, the metadata file says `latency basis: actual-start`, and the summary marks the latency figures as subject to coordinated omission.

`Kenshou.Measure.Load.Arrival` and `Kenshou.Measure.Load.Open` implement the open loop. The schedule is one shared state `(nextIndex, nextIntendedNs, generator)` in an `IORef` advanced with `atomicModifyIORef'`: a constant rate adds `1e9 / rate` nanoseconds, a Poisson process adds an exponentially distributed gap `-ln(u) / rate` with `u` drawn from a `splitmix` generator seeded from the run seed, so the arrival sequence is reproducible. During warm-up the rate ramps linearly from `rampFrom * rate` (default 1.0, no ramp) to the full rate. `executors` threads, the bound on operations in flight (default 256), each claim the next ticket, call `sleepUntilNs` on its intended start, read the clock as the actual start, run the operation and record intended start, actual start and end. Tickets are claimed lazily by free executors, so no queue of pending arrivals exists and memory stays bounded whatever happens. When every executor is busy, tickets are claimed late and the lag (actual minus intended start) grows; that lag is part of every recorded latency, which is the correction. The generator publishes to `series/load.csv` once per sampling interval: `t_mono_ns`, `t_wall_ms`, `phase`, `offered` (arrivals due so far), `started`, `completed`, `failed`, `in_flight`, `backlog` (due but not started), `lag_p50_ns`, `lag_max_ns`. It records `OverloadEvidence` when the maximum lag exceeds `maxLagNs` for `sustainedIntervals` consecutive intervals, and abandons the steady phase early (`abortedEarly`) when the lag exceeds `abortLagNs`, because beyond that point the generator has silently become a closed loop with `executors` workers and the offered rate no longer describes the run. Milestone 5 turns this evidence into an outcome.

Extend `kenshou-measure/src/Kenshou/Measure/Session.hs` with the `Measurement` record (the `MeasureEnv`, the `PhaseClock`, the `Recorder` and the configuration) and a first `withMeasurement` that assembles them around a scenario body and returns a `MeasurementReport`; this milestone's report holds the `RecorderReport` and the `LoadReport`s, Milestone 3 adds the samplers, Milestone 4 the summary and Milestone 5 the health observations. `runLoad` drives the phase clock itself: it enters warm-up when it starts, steady state when the warm-up has elapsed, drain when the steady bound is reached, and returns when the workers have stopped or the drain limit has passed.

Create `kenshou-measure/src/Kenshou/Measure/Knobs.hs` exporting `loadKnobs` and `measureKnobs` (lists of the kernel's `KnobSpec`, with per-scenario defaults passed in) and `loadModelFromKnobs`. The shared knobs are: `load.model` (enum `closed`, `open-constant`, `open-poisson`); `load.workers` (integer at least 1, closed loop); `load.think-time-us` (integer, default 0); `load.rate-per-second` (decimal above 0, open loop); `load.executors` (integer at least 1, default 256); `load.max-lag-ms` (integer, default 1000); `load.abort-lag-ms` (integer, default 30000); `measure.sample-interval-ms` (integer 100 to 60000, default 1000); `measure.raw-samples` (enum `full`, `sampled`, `off`; default `full` for kind `benchmark`, `off` for kind `soak`); `measure.raw-sample-one-in` (integer, default 100); `measure.histogram-digits` (integer 1 to 5, default 3); `measure.interval-histogram-seconds` (integer, default 10); `measure.pg-statements` (enum `off`, `snapshots`, `periodic`; default `snapshots`). Because they are knobs they appear in the run specification and in the compatibility components, so two runs with different load models can never be compared by accident.

Create `kenshou-measure/src/Kenshou/Measure/Selftest/SleepService.hs` and `kenshou-measure/src/Kenshou/Measure/Selftest.hs` (exporting `bundle :: LayerBundle` with layer `selftest`), and register the bundle with the three-line edit: one import and one list element in `kenshou-cli/src/Kenshou/Cli/Registry.hs` and `kenshou-measure` in the `build-depends` of `kenshou-cli/kenshou-cli.cabal`. If the kernel's registry rejects a second bundle for the layer `selftest`, the intended rule is "no duplicate scenario identifiers", not "one bundle per layer"; raise it against the kernel plan and record the outcome in the Decision Log rather than moving these scenarios into `kenshou-core`.

Scenario `selftest/measure/benchmark/sleep-service`. Tier `smoke`, placement `either`, no PostgreSQL required, dimensions `telemetry.tracing=off` and `telemetry.metrics=off` only. Default phases: 5 s warm-up, 30 s steady, 5 s drain. The service is a gate that a controller thread closes for `service.stall-ms` every `service.stall-every-ms`; one operation (named `request`) waits for the gate to be open and then sleeps `service.base-latency-us`. Knobs beyond the shared ones: `service.base-latency-us` (integer, default 1000), `service.stall-ms` (integer, default 1000), `service.stall-every-ms` (integer, default 10000), and scenario defaults `load.model=open-constant`, `load.rate-per-second=100`, `load.executors=1`, `load.workers=1`, `load.max-lag-ms=5000`. With one executor the system is a single-server queue, and the prediction is simple: with stall length S = 1 s, cycle T = 10 s, rate R = 100 per second and service time s of about 1 ms (utilisation ρ = R·s ≈ 0.1), a request arriving at offset u inside a stall waits S − u(1 − ρ); the slowest one percent of all arrivals are those with u below 0.01·T = 0.1 s, so the p99 from intended start is about S − 0.1(1 − ρ) ≈ 910 ms. A simulation of this queue gives 913 to 925 ms for constant and Poisson arrivals; the p90 sits on the edge between stalled and unstalled requests, wanders between 85 and 200 ms, and is therefore not asserted. Measured the naive way, only the one call per stall that finds the gate closed is slow, so the service-time p99 stays near 1 ms. The scenario's outcome is `passed` when all of the following hold, otherwise `failed`: in the open models `op.request.latency.p99` lies between 800 ms and 1,000 ms and `op.request.service.p99` is under five times the base latency; in the closed model `op.request.latency.p99` is under five times the base latency while the maximum exceeds 900 ms, and the summary carries the coordinated-omission warning; the steady sample count is within two percent of rate times steady duration for the constant model and within ten percent for the Poisson model (whose count varies by about the square root of its mean); and every percentile recomputed from `samples/request.raw` equals the one read from `samples/request.hist`. Until Milestone 4 provides the summary the scenario reads these figures from the `RecorderReport`; the metric names used here are the ones the summary will carry. The measurement it establishes: the recorder's percentiles are right, warm-up is excluded, and measuring from intended start recovers what a closed loop hides.


### Milestone 3 — Runtime, process and PostgreSQL samplers

Scope: periodic time series under `series/`, which the diagnostics plan (`docs/plans/6-build-the-diagnostics-toolkit-for-memory-leaks-and-concurrency-stalls.md`) later reads to judge leaks and stalls; the column names below are therefore a contract. At the end `withMeasurement` gives a scenario a fully assembled `Measurement`, and `selftest/measure/benchmark/pg-insert` leaves every series file behind under PostgreSQL 17 and 18.

Create `kenshou-measure/src/Kenshou/Measure/Sampler.hs` and `kenshou-measure/src/Kenshou/Measure/Sampler/Csv.hs`. Every CSV file has a header row, RFC 4180 quoting, decimal integers, empty fields for unavailable values, and the three leading columns `t_mono_ns` (nanoseconds since the run origin), `t_wall_ms` (Unix milliseconds) and `phase`. One thread labelled `kenshou-sampler` ticks at absolute deadlines (`origin + k * interval`, so it does not drift), runs the in-process samplers, and writes its own row to `series/sampler.csv`: `scheduled_mono_ns`, `late_ns`, `cost_ns` and `wall_minus_mono_ns` (the change in the difference between the two clocks since the previous tick). `enterPhase` requests an extra boundary row so that deltas over the steady window are exact. The PostgreSQL sampler runs on a second thread so a slow statistics query cannot delay the others.

`kenshou-measure/src/Kenshou/Measure/Sampler/Rts.hs` writes `series/rts.csv` with `gcs`, `major_gcs`, `allocated_bytes`, `max_live_bytes`, `cumulative_live_bytes`, `live_bytes_major_mean`, `live_bytes_last_gc`, `last_gc_gen`, `mem_in_use_bytes`, `max_mem_in_use_bytes`, `large_objects_bytes`, `compact_bytes`, `slop_bytes`, `block_fragmentation_bytes`, `copied_bytes`, `gc_cpu_ns`, `gc_elapsed_ns`, `mutator_cpu_ns`, `mutator_elapsed_ns`, `cpu_ns`, `elapsed_ns`, `haskell_threads` (the length of `GHC.Conc.listThreads`) and `capabilities`. `live_bytes_major_mean` is the change in `cumulative_live_bytes` divided by the change in `major_gcs` since the previous row, empty when no major collection happened; this is the column to fit a leak slope to. RTS counters are refreshed at collections, so a row describes the state at the most recent one; a busy program collects many times a second, an idle one shows flat lines. When `getRTSStatsEnabled` is false the sampler writes no file and the summary says `rts: unavailable`; check that `kenshou-cli/kenshou-cli.cabal` links the executable with `-threaded -rtsopts "-with-rtsopts=-N -T"` and add `-T` if the kernel plan did not.

`kenshou-measure/src/Kenshou/Measure/Sampler/Process.hs` writes `series/proc.csv`: `rss_bytes`, `rss_max_bytes`, `os_threads`, `open_fds`, `cpu_user_ns`, `cpu_system_ns`, `cpu_total_ns`, `voluntary_ctxt_switches`, `nonvoluntary_ctxt_switches`. On Linux the values come from `/proc/self/stat` (parse the fields after the last closing parenthesis, because the command name may contain spaces), `/proc/self/status` and the entry count of `/proc/self/fd`. On macOS, which exists for local development only, `cpu_total_ns` comes from `System.CPUTime.getCPUTime`, `open_fds` from the entry count of `/dev/fd`, `rss_bytes` and `os_threads` from `proc_pidinfo` with the flavour `PROC_PIDTASKINFO` (fields `pti_resident_size` and `pti_threadnum`) through the small C file `kenshou-measure/cbits/kenshou_proc_darwin.c`, compiled only under `if os(darwin)`; the remaining columns are empty. `kenshou-measure/src/Kenshou/Measure/Sampler/Host.hs` writes `series/host.csv` on Linux only: the aggregate `cpu` line of `/proc/stat` (`cpu_user`, `cpu_nice`, `cpu_system`, `cpu_idle`, `cpu_iowait`, `cpu_irq`, `cpu_softirq`, `cpu_steal`, in clock ticks), `loadavg1` and `mem_available_bytes`. The parsers are pure functions tested against captured text fixtures under `kenshou-measure/test/fixtures/proc/`, so the tests pass on macOS too.

`kenshou-measure/src/Kenshou/Measure/Sampler/Postgres.hs` opens one connection with `Hasql.Connection.acquire (connectionString cs <> applicationName "kenshou-sampler")` and writes the files below. `series/pg-statements.csv` is written only when `pg_stat_statements` is usable: the sampler runs `CREATE EXTENSION IF NOT EXISTS pg_stat_statements` and a probe query, and on failure logs one line and reports `pgStatements: unavailable` in the summary. With `measure.pg-statements=snapshots` it writes one snapshot at the start of steady state and one at its end, with query texts joined only in the final snapshot; with `periodic` it also samples every tenth tick. The kernel's ephemeral fixture must start the server with `shared_preload_libraries = 'pg_stat_statements'` for this to work; `ephemeral-pg` accepts that through `postgresSettings`. If the kernel offers no way to request it, record that in Surprises & Discoveries and raise it against the kernel plan; the sampler's graceful absence keeps this plan unblocked. The scenario names the relations to watch in `PgSamplerConfig.relations`, for example `kiroku.events`.

```sql
-- series/pg-activity.csv: one row per group per tick
SELECT coalesce(application_name, ''), coalesce(state, ''), coalesce(wait_event_type, ''),
       coalesce(wait_event, ''), count(*)
FROM pg_stat_activity
WHERE backend_type = 'client backend' AND application_name <> 'kenshou-sampler'
GROUP BY 1, 2, 3, 4;

-- series/pg-checkpointer.csv: columns common to PostgreSQL 17 and 18; on 18 also select c.num_done, on 17 write an empty field
SELECT c.num_timed, c.num_requested, c.write_time, c.sync_time, c.buffers_written,
       (pg_control_checkpoint()).checkpoint_lsn::text,
       extract(epoch FROM (pg_control_checkpoint()).checkpoint_time)::bigint
FROM pg_stat_checkpointer c;

-- series/pg-wal.csv
SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0')::bigint, w.wal_records, w.wal_fpi,
       w.wal_bytes::bigint, w.wal_buffers_full
FROM pg_stat_wal w;

-- series/pg-database.csv
SELECT xact_commit, xact_rollback, blks_read, blks_hit, tup_inserted, tup_updated, tup_deleted,
       deadlocks, temp_bytes
FROM pg_stat_database WHERE datname = current_database();

-- series/pg-relations.csv: once per watched relation, $1 = 'schema.table'
SELECT pg_relation_size($1::regclass), pg_indexes_size($1::regclass), pg_total_relation_size($1::regclass),
       s.n_live_tup, s.n_dead_tup, s.n_tup_ins, s.n_tup_upd, s.n_tup_del, s.autovacuum_count
FROM pg_stat_all_tables s WHERE s.relid = $1::regclass;

-- series/pg-statements.csv
SELECT queryid, calls, total_exec_time, rows, shared_blks_hit, shared_blks_read, wal_bytes::bigint
FROM pg_stat_statements(false)
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database());
```

A checkpoint completed between two rows when `checkpoint_lsn` changed; one was in progress when `buffers_written` rose while `checkpoint_lsn` did not. Finish `Kenshou.Measure.Session` (the `summary` and `health` fields of the report arrive with Milestones 4 and 5):

```haskell
data MeasureConfig = MeasureConfig
  { defaultPhases :: PhasePlan, histogram :: HistogramConfig, rawSamples :: RawSamplePolicy
  , sampleIntervalMs :: Int, postgres :: Maybe PgSamplerConfig, extraSamplers :: [Sampler] }
data PgSamplerConfig = PgSamplerConfig { connectionString :: Text, relations :: [Text], statements :: PgStatementsMode }
measureConfigFromKnobs :: RunContext -> PhasePlan -> Either Text MeasureConfig
withMeasurement :: RunContext -> MeasureConfig -> (Measurement -> IO a) -> IO (a, MeasurementReport)
data MeasurementReport = MeasurementReport
  { recorder :: RecorderReport, loads :: [LoadReport], summary :: MeasurementSummary, health :: [HealthObservation] }
```

`withMeasurement` creates `samples/` and `series/`, captures the origin, starts the phase clock, recorder and samplers, runs the body, enters `Done`, stops the samplers, finishes the recorder, and (from Milestone 4) computes the summary and registers it as the `measurements` section. `extraSamplers` is how the telemetry plan adds its scrape series. It uses `bracket` throughout so that an exception in the scenario still closes files and the connection.

Scenario `selftest/measure/benchmark/pg-insert`. Tier `smoke`, placement `either`, requires PostgreSQL with no runtime migrations, supports `pg.durability` both values and `pg.version` `17` and `18`, telemetry dimensions `off` only. Default phases 3 s, 15 s, 2 s. Each of `load.workers` (default 8) closed-loop workers opens its own connection with `application_name=kenshou-selftest-writer` and inserts rows of `pg-insert.payload-bytes` (integer 1 to 65536, default 256) into `kenshou_selftest.inserts (id bigserial primary key, worker int, seq bigint, payload bytea)`, created in setup with `CREATE SCHEMA IF NOT EXISTS` and truncated. The sampler watches that relation. Outcome `passed` when the row count equals the recorder's success count and every expected series file has at least three rows. It establishes that the samplers work on both server versions and gives Milestone 4 a PostgreSQL-backed run to grade.


### Milestone 4 — Summaries and paired comparison with verdicts

Scope: turn files into figures, and paired figures into a verdict. At the end `kenshou summarize` recomputes a run's measurements from its raw files and `kenshou compare` writes a `kenshou.comparison/v1` document and exits with the contract code. Acceptance is the walk-through in Concrete Steps: `regression` (exit 1) for an injected slowdown, `pass` (exit 0) for identical arms, `inconclusive` (exit 3) for noisy arms, exit 2 for incompatible runs.

`Kenshou.Measure.Stats` holds the pure statistics: exact quantiles by linear interpolation on a sorted vector, geometric and arithmetic means, the coefficient of variation, a percentile bootstrap driven by `System.Random.SplitMix` (deterministic for a given seed on every platform), and the two-sided 95 percent Student-t critical values for 1 to 29 degrees of freedom (12.706, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365, 2.306, 2.262, 2.228, ... 2.045, then 1.96), as in `analyze-experiment-set.py`.

`Kenshou.Measure.Summary` defines the section `kenshou.measurements/v1` and `summarizeRunDir :: FilePath -> IO (Either SummaryError MeasurementSummary)`, which reads only files in the run directory. Per operation it reports the steady count, failures by cause, throughput in operations and in units per second, and p50, p90, p99, p99.9, maximum and mean for latency and for service time, with the latency basis. From `series/rts.csv` over the steady rows it reports allocation rate, allocated bytes per operation, GC productivity (one minus GC elapsed over total elapsed), maximum live bytes and the mean of `live_bytes_major_mean`. From `series/proc.csv` it reports CPU utilisation (CPU time over wall time times capabilities) and maximum RSS. From the PostgreSQL series it reports WAL bytes per operation, checkpoints started and completed in the window, and the statement deltas. `Kenshou.Measure.Metrics` flattens all of it into a map of stable metric names that policies match with `*` wildcards: `op.<name>.throughput`, `op.<name>.latency.p50`, `.p90`, `.p99`, `.p999`, `.max`, `.mean`, `op.<name>.service.p99`, `op.<name>.error-rate`, `rts.alloc-bytes-per-op`, `rts.alloc-rate`, `rts.gc-productivity`, `rts.max-live-bytes`, `rts.live-bytes-major-mean`, `proc.cpu-utilisation`, `proc.rss-max`, `pg.wal-bytes-per-op`, `pg.checkpoints-in-window`; each value carries its unit (`ns`, `ops/s`, `bytes`, `ratio`). The summary also carries `algorithm: {"name": "kenshou-summary", "version": 1}` and a `grade`. The grade is `benchmark` when the raw-sample policy was `full`, no hard health observation exists (Milestone 5) and, if the scenario used PostgreSQL, `pg.durability` was `durable`; otherwise it is `exploratory` with the reasons listed. An abridged section:

```json
{
  "schema": "kenshou.measurements/v1",
  "algorithm": { "name": "kenshou-summary", "version": 1 },
  "grade": "exploratory",
  "gradeReasons": ["pg.durability=fsync-off"],
  "window": { "steadyStartMonoNs": 5000213411, "steadyEndMonoNs": 20000187000, "steadySeconds": 14.99997 },
  "ops": { "insert": { "latencyBasis": "actual-start", "coordinatedOmissionRisk": true, "count": 181220,
                       "throughput": 12081.5, "latencyNs": { "p50": 612351, "p99": 2418687, "max": 40239103 } } },
  "metrics": { "op.insert.throughput": { "value": 12081.5, "unit": "ops/s" } },
  "health": []
}
```

`Kenshou.Measure.Compare.Ordering` is what the planner (`docs/plans/3-plan-and-select-runs-from-what-changed.md`), the overhead protocol and the cell plan call to order trials. Pair `k` runs baseline then candidate when `k` is even and candidate then baseline when odd (ABBA); BAAB is the mirror image. Each arm therefore occupies early and late positions equally often, which cancels linear drift such as table growth or the phase of the checkpoint cycle. Both members of a pair receive the same `pairSeed`, derived from the base seed and the pair index.

```haskell
data Arm = Baseline | Candidate
data PairedOrdering = ABBA | BAAB
data TrialSlot = TrialSlot { position :: !Int, pairIndex :: !Int, arm :: !Arm, pairSeed :: !Word64 }
pairedSchedule       :: PairedOrdering -> Int -> Word64 -> [TrialSlot]
validateInterleaving :: [(Arm, Int, UTCTime)] -> Either Text ()
```

`Kenshou.Measure.Compare.Compatibility` derives the key components of a run from its documents: suite version, scenario identifier, resolved knobs, resolved dimensions, cohort identity (component versions or commits and the solver plan hash), machine profile from the environment fingerprint (operating system, architecture, CPU model, cores, memory, GHC, RTS flags, PostgreSQL version and settings, placement) and the schema versions of the run result and the measurements section. The caller declares one varying axis: `cohort` (the default), `dim:<name>` or `knob:<name>`. Every other component must be equal across all runs, and the varying one must take exactly two values, one per arm. A difference in scenario, knobs, dimensions or schema is a usage error (exit 2, no document written, the differing components printed). A difference in the machine profile means the environment changed between arms and yields the verdict `infrastructure-failure`. This is the fifth acceptance criterion of the benchmark protocol request (`mori://shinzui/keiro-benchmarks/okf/improvement-requests/concepts/IR-1`).

`Kenshou.Measure.Compare.Policy` parses `kenshou.comparison-policy/v1`. Create `policies/default.json` as below and `policies/selftest.json`, identical except `"name": "selftest"`, `"minimumPairs": 3` and only the throughput and p50 rules. The parser rejects `minimumPairs` below 3, `bootstrapIterations` below 1,000, and any rule without both `relativeLimit` and `absoluteFloor`. The absolute floor is in the metric's own unit: an adverse change smaller than the floor is never a regression, however large it is in relative terms.

```json
{
  "schema": "kenshou.comparison-policy/v1",
  "name": "default",
  "minimumPairs": 5,
  "confidenceLevel": 0.95,
  "bootstrapIterations": 10000,
  "resamplingSeed": 20260920,
  "requireInterleaving": true,
  "requireGrade": "benchmark",
  "maxCiRelativeWidth": 0.5,
  "maxCheckpointAsymmetry": 0.34,
  "metrics": [
    { "match": "op.*.throughput",      "direction": "higher-is-better", "relativeLimit": 0.05, "absoluteFloor": 1.0 },
    { "match": "op.*.latency.p50",     "direction": "lower-is-better",  "relativeLimit": 0.10, "absoluteFloor": 50000 },
    { "match": "op.*.latency.p99",     "direction": "lower-is-better",  "relativeLimit": 0.15, "absoluteFloor": 200000 },
    { "match": "rts.alloc-bytes-per-op", "direction": "lower-is-better", "relativeLimit": 0.05, "absoluteFloor": 64 },
    { "match": "rts.max-live-bytes",   "direction": "lower-is-better",  "relativeLimit": 0.10, "absoluteFloor": 1048576 }
  ]
}
```

`Kenshou.Measure.Compare.compareRuns :: Policy -> NonEmpty VaryingAxis -> [RunDir] -> [RunDir] -> IO (Either CompareError Comparison)` (on the command line `--vary` may be repeated; the comparison document lists the axes under `variedFactors`). Runs are paired by the pair index in the run specification when the kernel provides one, otherwise by the position of the `--baseline` and `--candidate` arguments. For each policy rule and matching metric the comparator forms, per pair, the adverse ratio (candidate over baseline when lower is better, baseline over candidate when higher is better) and the adverse delta. It estimates the geometric mean of the ratios and the arithmetic mean of the deltas, and for each takes as its interval the envelope of the seeded percentile-bootstrap interval and the Student-t interval (on log ratios for the ratio). The metric is a `regression` when the lower bound of the ratio exceeds `1 + relativeLimit` and the lower bound of the delta exceeds `absoluteFloor`; a `pass` when the upper bound of the ratio is at most `1 + relativeLimit` or the upper bound of the delta is at most `absoluteFloor`; otherwise `inconclusive`. Before either rule is applied, the metric is `inconclusive` when the ratio interval's upper bound over its lower bound exceeds `1 + maxCiRelativeWidth`, which is that request's rule that "excessive variance produces an inconclusive verdict". The overall verdict is `infrastructure-failure` if any input run's outcome is `errored` or `infrastructure-failure`, any run carries a hard health observation, or the machine profiles differ; otherwise `regression` if any metric regressed; otherwise `inconclusive` if any metric is inconclusive, fewer than `minimumPairs` pairs exist, the observed start times are not interleaved while the policy requires it, or a run's grade is below `requireGrade`; otherwise `pass`. The document records the comparison identifier (a UUIDv7 from the same generator the kernel uses for run identifiers), the algorithm (`"name": "paired-bootstrap-t-envelope", "version": 1`, generator `splitmix`, iterations, seed, confidence level), the policy with its SHA-256, the varying axis and its two values, the compatibility components, every run with its identifier, arm, pair index, position and the SHA-256 of its `run-result.json`, per-metric pairs, estimates, bounds, limits, baseline coefficient of variation, status and a one-line message, the health observations considered, the verdict and the exit code. Nothing in a verdict ever comes from a historical series, which is the rule of `mori://shinzui/kiroku/okf/adrs/concepts/ADR-5`.

`Kenshou.Measure.Cli` exports two `optparse-applicative` command parsers, and the only edit in `kenshou-cli` is to add them to the registry the kernel plan created. Register both `compare` and `summarize` as Analysis `CliCommand` values. `kenshou compare --baseline DIR --candidate DIR [more pairs] --policy FILE [--vary cohort|dim:NAME|knob:NAME] [--out FILE] [--json]` groups run inputs under Input, varying axes and policy under Comparison, and format/path under Output; `--policy -` uses EP-2's `InputSource`. It prints a table or the JSON document, writes it to `--out` when given, never writes into a run directory, and exits 0, 1, 3 or 4 by verdict and 2 for usage and compatibility errors. `kenshou summarize RUN_DIR [--json] [--verify]` groups verification under Analysis and format under Output, prints the recomputed section, and with `--verify` compares every figure with the `measurements` section stored in `run-result.json`; it exits 0 when they agree and 1 when they do not, which is the request's sixth acceptance criterion and the hook the evidence plan's verifier will call. An unreadable run directory exits 4. In every JSON path standard output contains only the JSON document and diagnostics go to standard error.

Add `kenshou-cli/help/comparisons.md` as a `HelpTopic` through EP-2's topic registry. It explains pairs, baseline and candidate arms, varying axes, compatibility refusal, health gates, policy thresholds, `pass` versus `regression` versus `inconclusive`, and why historical series never determine a verdict. This is an embedded operator quick reference; the source remains a standalone file included in the Cabal source distribution.

Scenario `selftest/measure/benchmark/regression-injected`. Tier `smoke`, placement `either`, no PostgreSQL, telemetry dimensions `off` only, default phases 2 s, 10 s, 1 s. A closed loop of `load.workers` (default 4) calls an operation `work` that sleeps `service.base-latency-us` (integer, default 2000) plus `service.extra-latency-us` (integer, default 0), the sum multiplied, when `service.noise` (enum `none`, `high`; default `none`) is `high`, by one factor per run drawn log-uniformly between 0.6 and 1.6 from the run seed. A last knob, `service.label` (enum `a`, `b`; default `a`), changes nothing about the work; it exists because the compatibility check requires the varying axis to take two values, so two behaviourally identical arms need something harmless to differ in. The outcome is `passed` when the run completes with at least 1,000 steady samples; a benchmark run never judges itself. What the scenario establishes is a property of the comparator, shown by three comparisons of five ABBA pairs each. Varying `service.extra-latency-us` from 0 to 500 (a twenty-five percent slowdown of the sleep) gives `regression`. Varying only `service.label` from `a` to `b` gives `pass`. Varying only `service.label` with `service.noise=high` on every run gives `inconclusive`, because each run then draws its own slowdown factor. In that last comparison every run must have a different seed; this deliberately departs from `pairedSchedule`, which gives both members of a pair the same seed so that real workloads are identical across arms.

Add JSON Schemas under `schemas/` for `kenshou.measurements/v1`, `kenshou.sample-meta/v1`, `kenshou.comparison/v1`, `kenshou.comparison-policy/v1` (and in Milestone 5 `kenshou.health-notice/v1`), following the file-naming convention the kernel plan established there, and validate emitted documents against them in the unit tests the same way `kenshou-core` does. Golden fixtures under `kenshou-measure/test/golden/compare/` hold four small sets of fabricated run directories and the expected comparison documents: clear improvement (`pass`), clear regression, excessive noise (`inconclusive`) and an input run with outcome `infrastructure-failure`; a fifth test flips one knob, one dimension, the cohort, a schema version and the CPU model in turn and expects the compatibility result described above. Finally create `kenshou-measure/src/Kenshou/Measure/Methodology.hs` (constants such as `recommendedKirokuPoolSize = 12`, `kirokuPoolRange = (10, 13)`, `minimumTrials = 3`, `defaultTrials = 5`) and the guide `docs/guides/measuring-and-comparing.md`, which states the rules in plain words: size a kiroku arm's pool at 10 to 13 and compare best pool against best pool; never quote a single trial; make the steady window span a checkpoint cycle or interleave arms inside one environment; benchmarks use `pg.durability=durable`; prefer an open loop for latency and a closed loop for capacity; size the driver so the harness is not the bottleneck.


### Milestone 5 — Health gates that separate infrastructure trouble from regressions

Scope: decide, from evidence the run itself collected, whether the environment can be trusted. At the end a run whose environment misbehaved ends `inconclusive` (exit 3) or `infrastructure-failure` (exit 4), its measurements are graded `exploratory`, and `kenshou compare` can never turn it into `regression`. Acceptance is the three injected conditions in Concrete Steps plus the comparator tests.

Create `kenshou-measure/src/Kenshou/Measure/Health.hs`.

```haskell
data Severity = Info | Soft | Hard
data HealthObservation = HealthObservation
  { gate :: Text, severity :: Severity, fromMonoNs :: Word64, toMonoNs :: Word64, detail :: Text, evidence :: Aeson.Value }
data HealthConfig = HealthConfig { cpuSoft, cpuHard, stealSoft :: Double, clockStepNs, pauseNs :: Word64, minSteadySamples :: Word64 }
evaluateHealth :: HealthConfig -> RunDir -> LoadReport -> IO [HealthObservation]
healthOutcome  :: [HealthObservation] -> Maybe Outcome    -- Hard -> infrastructure-failure, Soft -> inconclusive, Info -> Nothing
```

The gates, each evaluated over the steady window. `driver-cpu-saturation`: host CPU busy fraction from `series/host.csv` where available, otherwise process CPU over capabilities from `series/proc.csv`; soft above 0.70, hard above 0.90, because a saturated driver measures itself. `cpu-steal`: steal time above two percent of the window, soft; this is the noisy-neighbour signal on cloud machines. `open-loop-backlog`: overload evidence from the load report is soft (the offered rate was not sustained, so latency figures describe a queue, not the system), and hard when the driver was also saturated or the generator aborted early. `checkpoint-in-window`: always `Info`, recording how many checkpoints started and completed and what fraction of the window they overlapped; the comparator turns it into `inconclusive` when the two members of a pair differ in overlap by more than the policy's `maxCheckpointAsymmetry`, since a checkpoint that fell into one arm only is the dominant noise source the earlier harness recorded. `clock-anomaly`: a change of more than 50 ms in `wall_minus_mono_ns` between ticks is soft (the wall clock was stepped, which matters for cross-process latencies); a sampler tick later than the larger of five intervals and two seconds is hard (the process or the virtual machine was paused). `recorder-backpressure` and `sampler-overrun` (tick cost above the interval) are soft: the instrument disturbed the run. `insufficient-samples`: fewer than `minSteadySamples` (default 1,000) steady samples for an operation, soft. `rts-stats-unavailable` is `Info`.

The host-maintenance hook. When the environment variable `KENSHOU_HEALTH_NOTICES` names a file, the toolkit reads it at the end of the run; each line is a JSON object with schema `kenshou.health-notice/v1` and the fields `source` (for example `gce-maintenance-event`), `severity` (`soft` or `hard`), `at` (RFC 3339) and `detail`. A notice whose time lies between the run's start and end becomes an observation with the gate name `host-notice`. The toolkit knows nothing about Google Cloud: on a cell, the agent or wrapper delivered by `docs/plans/16-provide-leased-verification-cells-in-load-testing-infra.md` and `docs/plans/17-run-kenshou-on-leased-cells-with-payloads-submission-and-retrieval.md` polls the metadata server and appends lines; locally a test writes the file.

`withMeasurement` evaluates the gates after the samplers stop, stores the observations in the summary's `health` list and lets them lower the grade. Scenario authors fold the observations into their report with the helper `measuredOutcome :: MeasurementReport -> Outcome -> Outcome` in `Kenshou.Measure.Session`: any hard observation makes the outcome `infrastructure-failure` whatever the scenario concluded, because a verdict reached in a broken environment cannot be trusted; otherwise any soft observation turns `passed` or `failed` into `inconclusive`; otherwise the scenario's outcome stands. Use it in the three self-test scenarios. Add the knob `selftest.inject` (enum `none`, `backlog`, `process-pause`, `maintenance-notice`; default `none`) to the sleep-service scenario: `backlog` offers 2,000 requests a second to the one-millisecond single server; `process-pause` starts `sh -c 'sleep 8; kill -CONT <pid>'` with the `process` package and then raises `SIGSTOP` on itself in the middle of steady state (eight seconds, because the hard threshold at the default interval is five); `maintenance-notice` appends a hard notice to the file named by `KENSHOU_HEALTH_NOTICES`. With any injection the scenario skips its analytic checks and reports `measuredOutcome` applied to `passed`. Extend the comparator tests: a candidate that is forty percent slower but carries a hard observation yields `infrastructure-failure`; a pair with a checkpoint in one arm only yields `inconclusive`.

ADR work for this milestone. Create the ADR "Comparison verdicts come only from paired, interleaved, compatibility-checked, benchmark-grade runs; history is telemetry", citing `mori://shinzui/kiroku/okf/adrs/concepts/ADR-5` and recording the fsync-off refusal, the varying-axis rule, the two-threshold rule and the interval envelope. Look for the ADR on recording results through a channel independent of the feature under test: if the telemetry plan has not created it yet, create it with the recorder's role described and leave the telemetry arms to that plan; if it exists, add the recorder paragraph. Add a paragraph on `compare` and `summarize` to the kernel plan's protocol ADR. Allocate handles with `okf id next`, never by counting files, and add an `okf log add` entry for each record whose timestamp advances.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro-runtime-kenshou`, inside the development shell (`nix develop`, or automatically through `direnv`). First confirm the expected state:

```bash
cabal build all
cabal run -v0 kenshou -- list | grep '^selftest/kernel/'
cabal run -v0 kenshou -- run selftest/kernel/correctness/always-pass --out "$TMPDIR/kenshou-check"; echo "exit=$?"
ls schemas/ docs/adr/
grep -n 'with-rtsopts' kenshou-cli/kenshou-cli.cabal
```

Expect the five kernel self-test scenarios to be listed, `exit=0`, a run directory containing `run-spec.json`, `run-result.json` and `manifest.json`, and `-T` among the RTS options. If any of this is missing, stop: the kernel plan is not complete. Then open `kenshou-core/src/Kenshou/Core/Scenario.hs` and note the real names of the `RunContext` fields for the seven needs listed in Context and Orientation.

Build and test the package after every step, and format before committing:

```bash
cabal build kenshou-measure
cabal test kenshou-measure:kenshou-measure-test --test-show-details=direct
nix fmt
```

```text
Kenshou.Measure.Histogram
  maps 1000 ns to index 1000 and 2000000 ns to index 12193 [✔]
  stays within 0.1% of every recorded value [✔]
    ✓ 100 tests
  quantiles agree with a sorted vector [✔]
Kenshou.Measure.Recorder
  excludes warm-up samples from the steady histogram [✔]
  rebuilds the histogram from the raw file [✔]
  records ten million samples within budget (0.61 s) [✔]
```

Milestone 2, the coordinated-omission demonstration (numbers are illustrative; the bands in Milestone 2 are what matters):

```bash
OUT="$TMPDIR/kenshou-measure"
cabal run -v0 kenshou -- list | grep '^selftest/measure/'
cabal run -v0 kenshou -- run selftest/measure/benchmark/sleep-service --out "$OUT"; echo "exit=$?"
cabal run -v0 kenshou -- run selftest/measure/benchmark/sleep-service --set load.model=open-poisson --out "$OUT"
cabal run -v0 kenshou -- run selftest/measure/benchmark/sleep-service --set load.model=closed --out "$OUT"
```

```text
op request  model=open-constant rate=100.0/s executors=1  steady n=3000
  latency from intended start   p50 1.29ms  p90 101.4ms  p99 911.8ms  p99.9 992.3ms  max 1001.7ms
  service time from actual start p50 1.27ms  p90 1.38ms   p99 1.71ms               max 1001.2ms
checks: p99-in-band ok  naive-p99-small ok  warm-up-excluded ok  raw-recompute ok
outcome: passed
exit=0
```

Milestone 3:

```bash
cabal run -v0 kenshou -- run selftest/measure/benchmark/pg-insert --dim pg.version=18 --dim pg.durability=durable --out "$OUT"
RUN=$(ls -td "$OUT"/*/ | head -1)
ls "$RUN/series" "$RUN/samples"
head -3 "$RUN/series/rts.csv"
cabal run -v0 kenshou -- run selftest/measure/benchmark/pg-insert --dim pg.version=17 --out "$OUT"
```

```text
host.csv  load.csv  pg-activity.csv  pg-checkpointer.csv  pg-database.csv  pg-relations.csv
pg-statements.csv  pg-wal.csv  proc.csv  rts.csv  sampler.csv
insert.hist  insert.meta.json  insert.raw  insert.service.hist
```

On macOS `host.csv` is absent. If `pg-statements.csv` is absent, the log says why; see Milestone 3.

Milestone 4, the comparison walk-through. The loop runs five pairs in ABBA order (pair 0 baseline first, pair 1 candidate first, and so on) and hands the run directories to `kenshou compare` so that the i-th `--baseline` pairs with the i-th `--candidate`. The `--seed` flag belongs to the kernel; confirm its spelling with `kenshou run --help`.

```bash
S=selftest/measure/benchmark/regression-injected
KNOB=service.extra-latency-us; BASE=0; CAND=500; EXTRA=""; CMP="$OUT/cmp-regression"
ARGS=""; n=0
for k in 0 1 2 3 4; do
  if [ $((k % 2)) -eq 0 ]; then ORDER="baseline candidate"; else ORDER="candidate baseline"; fi
  for arm in $ORDER; do
    n=$((n + 1))
    if [ "$arm" = baseline ]; then V=$BASE; else V=$CAND; fi
    cabal run -v0 kenshou -- run "$S" --set "$KNOB=$V" $EXTRA --seed $((100 + n)) --out "$CMP/$arm-$k" >/dev/null
    ARGS="$ARGS --$arm $(ls -d "$CMP/$arm-$k"/*/)"
  done
done
cabal run -v0 kenshou -- compare $ARGS --policy policies/selftest.json --vary "knob:$KNOB" --out "$CMP/comparison.json"; echo "exit=$?"
cabal run -v0 kenshou -- summarize "$(ls -d "$CMP"/baseline-0/*/)" --verify; echo "exit=$?"
```

Repeat the loop with `KNOB=service.label BASE=a CAND=b CMP="$OUT/cmp-identical"` for identical arms, and with the same settings plus `EXTRA="--set service.noise=high" CMP="$OUT/cmp-noisy"` for noisy arms. If the fixed seeds 101 to 110 happen to produce a noisy comparison that is not `inconclusive`, choose another seed base, note it here, and keep it fixed.

```text
comparison 0199e0c2-…  scenario selftest/measure/benchmark/regression-injected  varying knob:service.extra-latency-us (0 -> 500)  pairs 5  ordering ABBA ok
  op.work.throughput   ratio 1.243 [1.236, 1.251]  limit 1.050  delta 391.2 ops/s  floor 1.0    regression
  op.work.latency.p50  ratio 1.244 [1.238, 1.250]  limit 1.100  delta 0.50 ms      floor 0.05   regression
verdict: regression
exit=1
measurements verified: 23 figures recomputed from raw files, 0 differences
exit=0
```

Expect `verdict: pass` and `exit=0` for identical arms, `verdict: inconclusive` and `exit=3` for noisy arms, and, when one run is made with a different `load.workers`, a usage error naming the differing knob and `exit=2`. A `pg-insert` run made with `pg.durability=fsync-off` must be reported as grade `exploratory` and make `compare` under `policies/default.json` answer `inconclusive` with the message that the run is not benchmark-grade.

Milestone 5:

```bash
cabal run -v0 kenshou -- run selftest/measure/benchmark/sleep-service --set selftest.inject=backlog --out "$OUT"; echo "exit=$?"
cabal run -v0 kenshou -- run selftest/measure/benchmark/sleep-service --set selftest.inject=process-pause --out "$OUT"; echo "exit=$?"
KENSHOU_HEALTH_NOTICES="$OUT/notices.jsonl" cabal run -v0 kenshou -- run selftest/measure/benchmark/sleep-service --set selftest.inject=maintenance-notice --out "$OUT"; echo "exit=$?"
```

Expect `exit=3` with an `open-loop-backlog` observation, then `exit=4` with `clock-anomaly`, then `exit=4` with `host-notice`. For the ADRs:

```bash
okf id list docs/adr --profile docs/adr/profile.dhall
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
just verify
```

Commit after each green step, directly on the current branch, with Conventional Commits messages (for example `feat(measure): add the log-linear latency histogram`) that end with these three trailers:

```text
MasterPlan: docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md
ExecPlan: docs/plans/4-build-the-measurement-toolkit-for-load-latency-sampling-and-comparison.md
Intention: intention_01m2zvy0gje40tdsdragvzr3tq
```


## Validation and Acceptance

Milestone 1 is accepted when `cabal test kenshou-measure:kenshou-measure-test` passes and a reader can see, in the recorder test's temporary directory, the four files for an operation, with the warm-up samples present in the `.raw` file and absent from the `.hist` file. Milestone 2 is accepted when `kenshou list` shows `selftest/measure/benchmark/sleep-service` and all three load models end `passed`: the open models report a p99 from intended start between 800 ms and 1,000 ms while the service-time p99 of the same run is under 5 ms, and the closed model reports a p99 under 5 ms with a maximum above 900 ms and the coordinated-omission warning. That contrast, on one synthetic service whose true behaviour is known, is the proof that the toolkit measures what it claims. Milestone 3 is accepted when the `pg-insert` run directory contains every series file listed in Concrete Steps for both `pg.version=17` and `pg.version=18`, `series/rts.csv` has a non-empty `live_bytes_major_mean` in at least one steady row, `series/pg-activity.csv` shows `kenshou-selftest-writer` and never `kenshou-sampler`, and the kernel's `manifest.json` lists the new files with their digests. Milestone 4 is accepted when the walk-through gives `regression` with exit 1, `pass` with exit 0, `inconclusive` with exit 3 and a usage error with exit 2; when `kenshou summarize --verify` reports no differences on an untouched run, exits 1 on a copy of that run whose stored p99 was edited in `run-result.json`, and exits 4 on a copy whose `.raw` file was truncated in the middle of a block; when running `compare` twice on the same inputs produces byte-identical metric sections (the bootstrap is seeded); and when the emitted comparison validates against its schema. Milestone 5 is accepted when the three injected conditions end with exits 3, 4 and 4 and name the right gate, and when the comparator tests show that a slower candidate with a hard observation is `infrastructure-failure` and that checkpoint asymmetry is `inconclusive`.

The plan as a whole is accepted when `just verify` passes, `okf validate` passes on `docs/adr`, and the measurement criteria of the benchmark protocol request (`mori://shinzui/keiro-benchmarks/okf/improvement-requests/concepts/IR-1`) can be ticked off against this repository: monotonic timing with setup and warm-up excluded (criterion 3, recorder tests); deterministic verdicts for improvement, regression, noise and infrastructure failure under a declared paired order (criterion 4, golden fixtures and the walk-through); compatibility that changes with workload, dependency closure, schema or machine profile (criterion 5, compatibility tests); and every derived figure recomputable from retained raw samples under a named algorithm version (criterion 6, `summarize --verify`).


## Idempotence and Recovery

Every step is additive and can be repeated. Each `kenshou run` creates a fresh run directory named by a new UUIDv7, so reruns never overwrite evidence; `kenshou compare` and `kenshou summarize` only read run directories and write, at most, the file named by `--out`. Temporary output under `$TMPDIR/kenshou-measure` can be deleted at any time with `rm -rf`. The `pg-insert` scenario creates its schema with `IF NOT EXISTS` and truncates its table in setup, so it is safe against an external database that was used before; ephemeral servers are removed by the kernel's fixture, and if a run is killed the leftover server is visible as a `postgres` process whose data directory lies under the fixture's temporary root, which can be stopped with `pg_ctl -D <dir> stop -m immediate` and removed. The `process-pause` injection stops the `kenshou` process; if the helper that resumes it was killed, resume it by hand with `kill -CONT <pid>` or end it with `kill -KILL <pid>`. If a run is interrupted while the recorder is writing, the `.raw` file ends in a partial block: the reader must stop at the last complete block and report how many bytes it ignored, and `summarize` must then exit 4 rather than print figures from a truncated file. If the build breaks half-way through a milestone, the package boundary contains the damage: `cabal build kenshou-core kenshou-cli` still works once the `kenshou-measure` entry is temporarily removed from `kenshou-cli.cabal` and the registry, and both edits are three lines. Golden fixtures are regenerated only deliberately, with an environment variable `KENSHOU_ACCEPT_GOLDEN=1` honoured by the test helper, and a change to a golden file must be explained in the commit message because it means a file format or an algorithm changed; in that case bump the format or algorithm version instead of silently altering version 1.


## Interfaces and Dependencies

Libraries, all from the pinned cohort's build plan (check resolved versions with `cabal run kenshou -- cohort show` and `cabal freeze --dry-run`): `base` 4.21 (`GHC.Clock`, `GHC.Stats`, `GHC.Conc`), `primitive` 0.9 for unboxed mutable arrays, `vector` 0.13, `bytestring` 0.11 or 0.12, `text`, `containers`, `aeson` 2.1 or 2.2, `stm`, `async`, `directory`, `filepath`, `time`, `unix` and `process` (signals and the pause helper), `splitmix` 0.1 (seeded, platform-independent random numbers for Poisson arrivals and the bootstrap), `hasql >=1.10 && <1.11` (the sampler's dedicated connection; the same version kiroku links), `optparse-applicative` (the version `kenshou-cli` already uses), and `kenshou-core`. The test suite adds `hspec >=2.11`, `hedgehog >=1.4 && <1.8`, `hspec-hedgehog >=0.0 && <0.4` and `temporary`. No Prometheus client, no OpenTelemetry package and no runtime library (kiroku, keiro, shibuya, pgmq) may appear in this package's dependencies: that absence is what keeps measurement independent of the features under test.

At the end of Milestone 1 these exist: `Kenshou.Measure.Clock` (`nowNs`, `captureOrigin`, `sleepUntilNs`), `Kenshou.Measure.Histogram` and `.Histogram.Codec` (`encodeHistogram :: Histogram -> ByteString`, `decodeHistogram :: ByteString -> Either Text Histogram`), `Kenshou.Measure.Samples` (`openSampleWriter`, `readSamples :: FilePath -> (SampleRecord -> IO ()) -> IO SampleFileReport`), `Kenshou.Measure.Phase`, `Kenshou.Measure.Recorder` and `Kenshou.Measure.Session.measureEnvFromRunContext`, with the signatures given in Milestone 1. At the end of Milestone 2: `Kenshou.Measure.Session` with `Measurement`, `MeasurementReport` and the first `withMeasurement`; `Kenshou.Measure.Load` re-exporting `runLoad`, `Operation`, `OpResult`, `LoadModel`, `LoadReport`; `Kenshou.Measure.Knobs` (`loadKnobs`, `measureKnobs`, `loadModelFromKnobs`); `Kenshou.Measure.Selftest.bundle`. At the end of Milestone 3: `Kenshou.Measure.Sampler` (`Sampler`, `withSamplers`), the four sampler modules, and in `Kenshou.Measure.Session` the final `withMeasurement :: RunContext -> MeasureConfig -> (Measurement -> IO a) -> IO (a, MeasurementReport)` with `MeasureConfig`, `PgSamplerConfig` and `measureConfigFromKnobs`. At the end of Milestone 4: `Kenshou.Measure.Stats`, `Kenshou.Measure.Metrics`, `Kenshou.Measure.Summary.summarizeRunDir`, `Kenshou.Measure.Compare.compareRuns`, `Kenshou.Measure.Compare.Ordering.pairedSchedule`, `Kenshou.Measure.Compare.Compatibility`, `Kenshou.Measure.Compare.Policy`, `Kenshou.Measure.Cli` (`compareCommand`, `summarizeCommand`) using EP-2's `CliGroup`, `InputSource` and option-group contract, `kenshou-cli/help/comparisons.md`, `Kenshou.Measure.Methodology`, the facade `Kenshou.Measure`, the directory `policies/` and the four schemas. At the end of Milestone 5: `Kenshou.Measure.Health` and `Kenshou.Measure.Session.measuredOutcome`.

What other plans consume. Every coverage plan (`docs/plans/8-cover-pgmq-hs-in-isolation.md` through `docs/plans/15-verify-the-assembled-runtime-end-to-end-and-under-soak.md`) writes its benchmark and soak scenarios as `withMeasurement` plus `runLoad` over an `Operation`, includes `loadKnobs` and `measureKnobs` among its knobs, names the relations its component writes in `PgSamplerConfig.relations`, and takes `recommendedKirokuPoolSize` as the default of any kiroku pool-size knob. `docs/plans/6-build-the-diagnostics-toolkit-for-memory-leaks-and-concurrency-stalls.md` reads `series/rts.csv` (column `live_bytes_major_mean`, `haskell_threads`), `series/proc.csv` (`os_threads`, `open_fds`, `rss_bytes`), `series/pg-activity.csv`, `series/pg-relations.csv` and `series/pg-statements.csv` by the column names fixed in Milestone 3, and uses the sampler framework for its own series. `docs/plans/7-add-telemetry-arms-and-measure-observability-overhead.md` adds `series/scrape-*.csv` through `MeasureConfig.extraSamplers`, orders its arms with `pairedSchedule`, calls `compareRuns` with the varying axis `dim:telemetry.tracing` or `dim:telemetry.metrics`, and adds `policies/telemetry-overhead.json` in the policy format defined here. `docs/plans/3-plan-and-select-runs-from-what-changed.md` uses `pairedSchedule` to order benchmark trials and `minimumTrials`. `docs/plans/17-run-kenshou-on-leased-cells-with-payloads-submission-and-retrieval.md` runs both arms of a `pairedSchedule` inside one lease and is, with `docs/plans/16-provide-leased-verification-cells-in-load-testing-infra.md`, the writer of the `KENSHOU_HEALTH_NOTICES` file. `docs/plans/18-record-runs-and-attestations-in-a-historic-okf-evidence-bundle.md` links `kenshou.comparison/v1` documents by digest and uses `kenshou summarize --verify` as the deterministic verifier for measurement figures.


Revision note (2026-09-20): Aligned `compare` and `summarize` with EP-2's `haskell-jitsurei`-based CLI contract: Analysis grouping, intent-based option sections, explicit stdin for policy documents, clean JSON output, and an embedded `comparisons` help topic.
