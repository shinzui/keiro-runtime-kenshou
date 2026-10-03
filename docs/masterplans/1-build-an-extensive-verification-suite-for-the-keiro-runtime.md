---
id: 1
slug: build-an-extensive-verification-suite-for-the-keiro-runtime
title: "Build an extensive verification suite for the keiro runtime"
kind: master-plan
created_at: 2026-09-20T17:12:57Z
intention: "intention_01m2zvy0gje40tdsdragvzr3tq"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-20T17:12:57Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-20T21:08:38Z
      mode: "update"
      note: "Adopted relevant Haskell Jitsurei CLI patterns and the bounded Settei configuration contract."
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-21T02:35:53Z
      mode: "implement"
      note: "Started EP-1 implementation and moved its registry entry to In Progress."
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-21T03:59:09Z
      mode: "implement"
      note: "Started EP-2 implementation and moved its registry entry to In Progress."
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-21T13:20:28Z
      mode: "implement"
      note: "Started EP-3 implementation and moved its registry entry to In Progress."
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-21T14:43:41Z
      mode: "implement"
      note: "Started EP-4 implementation and moved its registry entry to In Progress."
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-21T16:21:05Z
      mode: "implement"
      note: "Started EP-5 implementation and moved its registry entry to In Progress."
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-21T18:06:42Z
      mode: "implement"
      note: "Started EP-6 implementation and moved its registry entry to In Progress."
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-21T20:51:28Z
      mode: "implement"
      note: "Started EP-7 implementation and moved its registry entry to In Progress."
    - model: "gpt-6"
      harness: "codex"
      at: 2026-09-21T23:50:00Z
      mode: "implement"
      note: "Completed EP-7 telemetry arms, paired overhead analysis, and telemetry-induced problem detection."
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-22T00:33:49Z
      mode: "implement"
      note: "Started EP-8 and moved its registry entry to In Progress."
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-22T21:24:36Z
      mode: "implement"
      note: "Recorded EP-8 disconnect-classification finding for PGMQ adapter and job-queue coverage."
    - model: "gpt-6"
      harness: "codex"
      at: 2026-09-24T02:32:57Z
      mode: "update"
      note: "Defined upstream OKF bug reports and local Mori URI issue tracking for discovered runtime failures."
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T16:33:52Z
      mode: "update"
      note: "Recorded EP-14 implementation progress and completed timer milestone."
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T22:52:53Z
      mode: "update"
      note: "Consolidated child status and removed duplicated task checklists"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-25T04:37:39Z
      mode: "implement"
      note: "Recorded verified PGMQ bug reports and EP-8 audit progress."
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-25T18:42:10Z
      mode: "implement"
      note: "Recorded EP-8 continuous backend fault traffic evidence and remaining cell gate."
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-26T00:33:23Z
      mode: "implement"
      note: "Recorded EP-10 process-isolated GC verification across three Shibuya cohorts."
    - model: "gpt-6"
      harness: "codex"
      at: 2026-09-26T04:50:27Z
      mode: "implement"
      note: "Recorded EP-10 PGMQ lease renewal and multi-process competition evidence."
    - model: "gpt-6"
      harness: "codex"
      at: 2026-09-26T05:17:41Z
      mode: "implement"
      note: "Recorded EP-10 PGMQ effect-gated SIGKILL and retry-budget evidence."
    - model: "gpt-6"
      harness: "codex"
      at: 2026-09-26T14:02:39Z
      mode: "implement"
      note: "Recorded EP-10 PGMQ postmaster and backend termination recovery across historical and current PostgreSQL 17/18 lanes."
    - model: "gpt-6"
      harness: "codex"
      at: 2026-09-26T14:23:47Z
      mode: "implement"
      note: "Sealed isolated current-release PGMQ long-poll pool starvation results on PostgreSQL 17/18."
    - model: "gpt-6"
      harness: "codex"
      at: 2026-09-26T14:39:38Z
      mode: "implement"
      note: "Completed the 13-scenario Shibuya PGMQ current-release CLI sweep, including worker-process scenarios."
    - model: "gpt-6"
      harness: "codex"
      at: 2026-09-26T15:05:00Z
      mode: "implement"
      note: "Started EP-10 Kiroku adapter verification with sealed PostgreSQL 17/18 smoke results on released and current adapters."
    - model: "gpt-6"
      harness: "codex"
      at: 2026-09-26T15:15:00Z
      mode: "implement"
      note: "Verified EP-10 Kiroku halt and forced-shutdown batch replay across released/current PostgreSQL 17/18 lanes."
    - model: "gpt-6"
      harness: "codex"
      at: 2026-09-26T15:25:00Z
      mode: "implement"
      note: "Verified EP-10 Kiroku two-process same-member ownership and durable duplicate effects on both PostgreSQL majors."
    - model: "gpt-6"
      harness: "codex"
      at: 2026-09-26T15:40:00Z
      mode: "implement"
      note: "Verified EP-10 Kiroku retry budget reset after SIGKILL on released/current PostgreSQL 17/18 lanes."
    - model: "gpt-6"
      harness: "codex"
      at: 2026-09-26T18:00:35Z
      mode: "implement"
      note: "Recorded EP-10 Kiroku crash-window matrix evidence across both adapter releases and PostgreSQL majors."
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-26T18:01:31Z
      mode: "discuss"
      note: "Scoped the first repair-and-rerun checkpoint to PostgreSQL 18."
    - model: "gpt-6"
      harness: "codex"
      at: 2026-09-26T18:48:15Z
      mode: "implement"
      note: "Recorded EP-10 parameterized core lease-bound evidence."
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-27T14:07:23Z
      mode: "update"
      note: "Marked EP-18 complete and unblocked EP-19 in the registry."
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-27T16:01:36Z
      mode: "implement"
      note: "Marked EP-19 complete after published profile adoption and validation."
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-27T16:28:26Z
      mode: "implement"
      note: "Recorded grouped owner-defect integration for the Kafka rebalance scenario."
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-28T17:54:48Z
      mode: "implement"
      note: "Recorded EP-17 payload and capability-cache progress."
    - model: "gpt-6"
      harness: "codex"
      at: 2026-09-28T21:31:15Z
      mode: "implement"
      note: "Recorded the published released payload and passing PostgreSQL 18 cell evidence."
    - model: "gpt-6"
      harness: "codex"
      at: 2026-09-28T21:42:38Z
      mode: "implement"
      note: "Recorded the first local/cell parity report."
    - model: "gpt-6"
      harness: "codex"
      at: 2026-09-29T02:26:00Z
      mode: "implement"
      note: "Recorded the passing live cell telemetry overhead trial and remaining collector artifact gates."
    - model: "gpt-6"
      harness: "codex"
      at: 2026-09-29T03:01:00Z
      mode: "implement"
      note: "Recorded sealed exact-window cell metrics exports with per-run OTLP counter evidence."
    - model: "gpt-6"
      harness: "codex"
      at: 2026-09-29T04:25:00Z
      mode: "implement"
      note: "Recorded live per-run sealed trace acceptance and the PostgreSQL role's rolling submission compatibility repair."
    - model: "gpt-6"
      harness: "codex"
      at: 2026-09-29T05:13:00Z
      mode: "implement"
      note: "Recorded exact 100-span OTLP fixture acceptance and repaired idempotent GCS resumable publication."
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-29T17:33:26Z
      mode: "implement"
      note: "Reconciled owner findings and added the dated baseline priority report."
    - model: "gpt-6"
      harness: "codex"
      at: 2026-09-29T20:33:50Z
      mode: "implement"
      note: "Recorded clean cell controls, outbox reproduction, and Kafka broker-routing finding."
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-30T01:18:06Z
      mode: "implement"
      note: "Verified the write-side window repair and advanced Keiro messaging soak coverage."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-09-30T21:07:06Z
      mode: "update"
      note: "Reconciled remaining baseline work and separated coverage, infrastructure, attribution and attestation gates from owner bug repairs."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-01T16:33:42Z
      mode: "implement"
      note: "Advanced EP-13 process diagnostics and full inbox soak evidence without changing owner-fix gates."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-01T17:36:58Z
      mode: "implement"
      note: "Advanced EP-13 messaging metrics serving and preserved open coverage and evidence gates."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-01T19:52:04Z
      mode: "implement"
      note: "Advanced EP-13 queue lease SQL evidence and independent outcome replay."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-01T20:31:38Z
      mode: "implement"
      note: "Advanced EP-13 inbox persistence and effect acceptance."
---

# Build an extensive verification suite for the keiro runtime

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

The keiro runtime is not one package. It is a cohort of Haskell libraries that real services link together: `pgmq-hs` (a client for PGMQ, a message queue built on PostgreSQL tables), `kiroku` (a PostgreSQL event store), `shibuya` (a message-processing framework) with its adapters for PGMQ queues, the kiroku store and Kafka, and at the top `keiro` itself, which turns those pieces into a command processor, process managers, routers, durable execution (workflows and timers), an inbox, an outbox, and a job queue. The platform already runs in less critical microservices and is about to be rolled out to important ones. Each library has its own unit tests, but nothing anywhere exercises the runtime across packages, across operating-system processes, under real crashes, for hours at a time, or comparably across releases. This repository, `keiro-runtime-kenshou` (検証, "verification"), exists to produce that evidence.

When this initiative is complete, a maintainer can do the following from this repository. They can list every verification scenario, each identified by the layer it isolates (`pgmq`, `kiroku`, `shibuya`, `kafka`, `keiro`, or the assembled `runtime`), the component inside that layer, the kind of evidence it produces (`correctness`, `concurrency`, `soak`, or `benchmark`), and its cost tier. They can ask the tool which scenarios are worth running given what changed — a new kiroku release, a single keiro component, or an edit inside this repository — and receive a run plan that covers the changed component and everything built on top of it, and nothing else. They can turn knobs: every scenario declares the configuration variants of the component it exercises (ordering policies, batch sizes, pool sizes, retry policies, polling versus push wake-up, and so on), and two dimensions cut across every layer — whether OpenTelemetry tracing is enabled and whether the metrics endpoints are enabled — so that the overhead and the side effects of the observability stack are themselves measured. They can run correctness scenarios on a laptop or on Google Cloud Platform (GCP) with the same command, and run benchmarks and soaks on leased, controlled GCP machines so that results are not polluted by other workloads. When something goes wrong, the same harness is the base for diagnosis: a soak that leaks memory yields a leak verdict with the evidence series behind it, and a run that stalls yields Haskell thread dumps and a PostgreSQL lock graph captured at the moment of the stall. Finally, every recorded run leaves a small, immutable record in an OKF bundle (OKF, the Open Knowledge Format, is a directory of Markdown files with YAML frontmatter that the house tools `okf` and `mori` validate and index). The record names exactly what ran, against which revision of every runtime component, where, with which knobs, what the verdict was, and links by content digest to the raw data held in durable object storage; a separate attestation record states that a deterministic verifier re-checked that data. The bundle accumulates history so that a later initiative can generate stakeholder reports from it.

The current pass fills the planned coverage and captures an initial baseline
against the pinned released cohort, preserving both passing and failing sealed
runs. It continues the existing finding audit: classify each observation against
published contracts, link an existing owner record when one covers it, or file
a bug report or improvement request under the owning repository's appropriate
OKF profile. Once coverage and owner records are complete, those projects plan
and implement fixes separately. This MasterPlan does not own those fixes. When
the platform owner returns to this plan and requests verification of the fixes,
Kenshou can pin the fixed cohort and rerun the relevant scenarios under
comparable conditions and the change-aware affected selection. The original
run set remains intact for that later comparison. Here “initial baseline” means
the as-is run set, not a mutable `baseline` flag on an evidence record.
A dated technical baseline report summarizes the run set, owner dispositions,
coverage gaps, and priority for owner projects; its working checkpoint is
[the 2026-09-29 report](../reports/2026-09-29-runtime-baseline.md). It is
updated as this pass reaches the remaining acceptance gates.

The executable is also a durable operator and automation interface, not merely a collection of parsers. Its human-facing discovery surface follows the current patterns in `mori://shinzui/haskell-jitsurei`: commands and options are grouped by user intent, long-form topics are embedded in the binary and wrap to a terminal-aware width without changing piped bytes, Bash/Zsh/Fish completions are derived from the actual `optparse-applicative` parser tree, and `--version` includes the build's Git revision. Document-valued inputs accept `-` explicitly for standard input, while machine-readable modes reserve standard output for the requested document and send diagnostics to standard error. Repeated operator defaults are resolved with `mori://shinzui/settei` from an explicit, inspectable source order; scenario knobs, dimensions, run specifications and run plans remain versioned evidence inputs rather than ambient configuration. These rules let a person discover a large command tree and let `kotei` call the same binary without scraping presentation text.

The scope boundary is deliberate. Included: the harness and its toolkits; isolated coverage for pgmq-hs, kiroku, shibuya and its three adapters, the Kafka transport, and every keiro component the platform owner named (command processor, process manager, router, durable execution, inbox, outbox, queue) together with the pieces they cannot be separated from (snapshots and projections with the command processor, timers and sharded subscriptions with durable execution); an assembled two-context reference system for end-to-end and soak runs; leased GCP verification cells built by extending the existing `load-testing-infra` repository; and the OKF evidence bundle plus the shared profile that governs it in `okf-profiles`.

Excluded: generating stakeholder reports (a future plan will consume the evidence bundle); orchestrating runs from a CI/CD system (the house CI platform `kotei` owns that under `mori://shinzui/kotei/okf/improvement-requests/concepts/IR-3`; this initiative only guarantees a machine-consumable command-line protocol for it to call); fixing defects that the suite finds in the runtime libraries (confirmed broken behavior is filed in the owning repository's OKF bug-report bundle, and the scenario that found it stays in the suite with a precise known-defect reference; behavior the producer never promised is an improvement request instead); unit tests that belong inside a runtime package; verification of `keiki` (the pure state-machine library) and of the `keiro-dsl` toolchain; keiro's online versioned read-model rebuild machinery; and comparisons of kiroku against other event stores, which remain the business of `mori://shinzui/keiro-benchmarks`.


## Decomposition Strategy

The work is decomposed along four principles. First, contracts before content: the types and file formats that every scenario shares (what a scenario is, what a knob is, what a run specification and a run result look like) are delivered by one early plan so that the many content plans can be written and implemented in parallel without inventing incompatible shapes. Second, toolkits by concern: measuring, checking correctness, diagnosing, and switching telemetry on and off are four different skills with different prior art, so each is its own plan and its own library, and scenario authors compose them. Third, coverage by layer, mirroring the runtime's own dependency order, because that is what makes a failure attributable: if the `kiroku` layer is green and the `keiro` layer is red, the problem is in keiro or in how keiro uses kiroku, and the change-aware planner can use the same layering to decide what to run. Fourth, other repositories are touched only through their own front doors: GCP infrastructure is extended in `load-testing-infra` under the improvement request that repository already carries, and the evidence profile is upstreamed to `okf-profiles` through that repository's improvement-request process after a real corpus exists here.

Nineteen child plans result, which is more than the two to seven that a MasterPlan normally wants, so they are grouped into five phases that are also implementation waves. Phase 1 (Foundations, EP-1 to EP-3) creates the repository, pins the runtime cohort, and delivers the harness kernel and the change-aware planner. Phase 2 (Toolkits, EP-4 to EP-7) delivers measurement, correctness, diagnostics, and telemetry arms. Phase 3 (Substrate coverage, EP-8 to EP-11) covers pgmq-hs, kiroku, shibuya with its PostgreSQL-backed adapters, and the Kafka transport. Phase 4 (Keiro and whole-runtime coverage, EP-12 to EP-15) covers keiro's components in three groups and then the assembled runtime. Phase 5 (Cloud execution and evidence, EP-16 to EP-19) delivers leased GCP cells, remote execution, the OKF evidence bundle, and the upstream profile.

Several alternatives were considered and rejected. The repository README sketches a top-level layout by axis (`correctness/`, `concurrency/`, `bench/`). That layout was rejected in favour of one package per layer with the axes as module subtrees and scenario tags, because the owner's two strongest requirements — isolating a problem to a component, and running only what a change affects — both need the layer, not the axis, to be the unit of build and selection. One plan per keiro component (seven plans) was rejected because components share a fixture domain and fall naturally into three groups that share failure modes: the write side and coordination (command processor, process manager, router), the messaging edge (outbox, inbox, queue), and durable execution (workflows, timers, sharded subscriptions). Depending on the older `kiroku-bench` project was rejected: it is pinned 168 commits behind current kiroku, is closed-loop only, interpolates percentiles from sixteen histogram buckets, and keeps its correctness ledger in unbounded memory; its delivery ledger, writer loop, scenario taxonomy and methodology rules are lifted into this repository instead. Reusing `keiro-benchmarks` code was rejected because it does not exercise keiro at all (it compares Message DB with kiroku); it is left untouched, and its improvement request `mori://shinzui/keiro-benchmarks/okf/improvement-requests/concepts/IR-1` is adopted as the specification for this suite's `list`/`run`/`compare` protocol. Copying `load-testing-infra` into this repository was rejected in favour of extending it in place, because its own improvement request `mori://shinzui/load-testing-infra/okf/improvement-requests/concepts/IR-1` already asks for exactly the leased-cell model this suite needs, and two copies of GCP infrastructure would drift. Writing the OKF profile first was rejected because `okf-profiles` accepts only shapes that some repository already writes by hand; the corpus comes first (EP-18) and the shared profile second (EP-19). Storing measurements inside OKF records was rejected by the owner: records carry identity, provenance, verdict, and digest-pinned links to the data, never the data.

The CLI is decomposed the same way as the rest of the initiative: one early owner defines its extension seam and interaction rules, and later plans contribute commands without recreating parser infrastructure. EP-1 establishes the executable's release identity, including the Git-aware `--version` path in both Cabal and Nix builds. EP-2 owns command grouping, option grouping, embedded help topics, terminal-width handling, completions, document input, output-channel discipline, typed configuration resolution, and the parser-level tests. EP-3, EP-4, EP-6, EP-7, EP-17 and EP-18 extend only that seam. The applicable patterns are `mori://shinzui/haskell-jitsurei/docs/cli-option-groups`, `mori://shinzui/haskell-jitsurei/docs/cli-help-topics`, `mori://shinzui/haskell-jitsurei/docs/cli-help-width`, `mori://shinzui/haskell-jitsurei/docs/cli-shell-completions`, `mori://shinzui/haskell-jitsurei/docs/cli-stdin-integration`, and `mori://shinzui/haskell-jitsurei/docs/cli-version-git-sha`. Typed layered configuration follows `mori://shinzui/settei` at release 0.2.0.0; because Mori has not registered its guide artifacts, the specific source references are the canonical project URI plus project-relative `docs/guides/cli-application.md` and `docs/guides/environment-and-cli.md`, with artifact-level URIs pending. Hierarchical Dhall configuration is explicitly legacy in `mori://shinzui/haskell-jitsurei/docs/cli-overview`; command aliases, FZF, clipboard integration and agent-assist commands do not serve this deterministic verification protocol and are excluded.

There is no local ADR corpus yet: `docs/adr/` does not exist in this repository, and EP-1 creates it as a profile-governed OKF bundle. The following cross-repository decisions shape this initiative and are cited by their canonical Mori handles. `mori://shinzui/kiroku/okf/adrs/concepts/ADR-5` separates performance evidence into structural checks, controlled A/B workloads, and historical telemetry, and treats only the first two as authoritative; this suite's comparison verdicts follow the same rule (paired candidate-versus-baseline runs decide, history informs). `mori://shinzui/kiroku/okf/adrs/concepts/ADR-2` and `mori://shinzui/kiroku/okf/adrs/concepts/ADR-4` define consumer groups as static hash partitions and checkpoints as monotonic, which are the invariants the kiroku and keiro sharding scenarios assert. `mori://shinzui/keiro/okf/adrs/concepts/ADR-24` and `mori://shinzui/keiro/okf/adrs/concepts/ADR-42` freeze keiro's deterministic identifiers, which gives the correctness checkers exact expected identifiers to look for. `mori://shinzui/keiro/okf/adrs/concepts/ADR-25` requires worker loops to survive per-pass and per-item failures, which the fault-injection scenarios test directly. `mori://shinzui/okf/okf/adrs/concepts/ADR-13` and `mori://shinzui/okf/okf/adrs/concepts/ADR-14` establish that non-Markdown files in a bundle are plain files and that okf records computations but never runs or attests them, which is why run records and attestations are new house concept types. `mori://shinzui/okf-profiles/okf/adrs/concepts/ADR-6` (the local Mori registry lags the okf-profiles repository, so this handle does not resolve yet; the record is `docs/adr/0006-attested-computation-is-excluded.md` there) deliberately excludes the `Attested Computation` type from the catalog until a consumer writes one; this initiative is that consumer, and EP-19 amends the ADR. `mori://shinzui/mori/okf/adrs/concepts/ADR-53` records assessments as immutable facts with digest-addressed evidence and warns that repeated runs need an explicit run identity, which the run record adopts. The shibuya repository keeps its ADRs outside an OKF bundle, so the artifact-level URI is pending; the relevant record is `mori://shinzui/shibuya` at `docs/adr/0002-require-candidate-bound-machine-checkable-release-evidence.md`, whose candidate manifest (exact commits, solver plan hash, compiler, service versions, seeds) is the precedent for the cohort identity every run result carries.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Bootstrap the kenshou repository and pin the runtime cohort | docs/plans/1-bootstrap-the-kenshou-repository-and-pin-the-runtime-cohort.md | None | None | Complete |
| 2 | Build the harness kernel for scenarios, dimensions, run specs and results | docs/plans/2-build-the-harness-kernel-for-scenarios-dimensions-run-specs-and-results.md | EP-1 | None | Complete |
| 3 | Plan and select runs from what changed | docs/plans/3-plan-and-select-runs-from-what-changed.md | EP-2 | None | Complete |
| 4 | Build the measurement toolkit for load, latency, sampling and comparison | docs/plans/4-build-the-measurement-toolkit-for-load-latency-sampling-and-comparison.md | EP-2 | None | Complete |
| 5 | Build the correctness toolkit for ledgers, invariants, faults and process control | docs/plans/5-build-the-correctness-toolkit-for-ledgers-invariants-faults-and-process-control.md | EP-2 | None | Complete |
| 6 | Build the diagnostics toolkit for memory leaks and concurrency stalls | docs/plans/6-build-the-diagnostics-toolkit-for-memory-leaks-and-concurrency-stalls.md | EP-2, EP-4 | EP-5 | Complete |
| 7 | Add telemetry arms and measure observability overhead | docs/plans/7-add-telemetry-arms-and-measure-observability-overhead.md | EP-2, EP-4 | EP-6 | Complete |
| 8 | Cover pgmq-hs in isolation | docs/plans/8-cover-pgmq-hs-in-isolation.md | EP-2, EP-4, EP-5, EP-6, EP-7 | EP-3 | In Progress |
| 9 | Cover kiroku in isolation | docs/plans/9-cover-kiroku-in-isolation.md | EP-2, EP-4, EP-5, EP-6, EP-7 | EP-3 | Complete |
| 10 | Cover shibuya core and its PGMQ and kiroku adapters | docs/plans/10-cover-shibuya-core-and-its-pgmq-and-kiroku-adapters.md | EP-2, EP-4, EP-5, EP-6, EP-7 | EP-3, EP-8, EP-9 | In Progress |
| 11 | Cover the Kafka transport edge with a disposable broker | docs/plans/11-cover-the-kafka-transport-edge-with-a-disposable-broker.md | EP-2, EP-4, EP-5, EP-6, EP-7 | EP-3, EP-10 | In Progress |
| 12 | Cover the keiro command processor, process managers and routers | docs/plans/12-cover-the-keiro-command-processor-process-managers-and-routers.md | EP-2, EP-4, EP-5, EP-6, EP-7 | EP-3, EP-9 | In Progress |
| 13 | Cover the keiro outbox, inbox and job queue | docs/plans/13-cover-the-keiro-outbox-inbox-and-job-queue.md | EP-12 | EP-3, EP-8, EP-10 | In Progress |
| 14 | Cover keiro durable execution, timers and sharded subscriptions | docs/plans/14-cover-keiro-durable-execution-timers-and-sharded-subscriptions.md | EP-12 | EP-3, EP-9 | In Progress |
| 15 | Verify the assembled runtime end to end and under soak | docs/plans/15-verify-the-assembled-runtime-end-to-end-and-under-soak.md | EP-11, EP-12 | EP-3, EP-13, EP-14, EP-17 | In Progress |
| 16 | Provide leased verification cells in load-testing-infra | docs/plans/16-provide-leased-verification-cells-in-load-testing-infra.md | None | EP-2 | In Progress |
| 17 | Run kenshou on leased cells with payloads, submission and retrieval | docs/plans/17-run-kenshou-on-leased-cells-with-payloads-submission-and-retrieval.md | EP-2, EP-3, EP-4, EP-7, EP-16 | EP-5 | In Progress |
| 18 | Record runs and attestations in a historic OKF evidence bundle | docs/plans/18-record-runs-and-attestations-in-a-historic-okf-evidence-bundle.md | EP-2, EP-4 | EP-5, EP-16, EP-17 | Complete |
| 19 | Publish the verification evidence profile in okf-profiles | docs/plans/19-publish-the-verification-evidence-profile-in-okf-profiles.md | EP-18 | None | Complete |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3). Hard dependencies are transitive: a plan that lists EP-12 also requires everything EP-12 requires.


## Dependency Graph

EP-1 has no dependency: it creates the build, the development shell, and the pinned cohort that every other Haskell plan compiles against. EP-2 cannot begin before EP-1 because it adds packages to that build. EP-3, EP-4 and EP-5 each need only the kernel's types from EP-2 (scenario, dimension, run specification, run result, environment, worker role) and can be implemented in parallel with one another. EP-6 needs EP-4 because its leak and stall verdicts are computed over the time series that EP-4's samplers write; it only benefits from EP-5 (its self-test scenarios are nicer with EP-5's process control but can spawn a process directly). EP-7 needs EP-4 because an overhead figure is a paired comparison between telemetry arms, and the comparison engine is EP-4's; it benefits from EP-6 for the question "does enabling tracing leak".

Every coverage plan in Phases 3 and 4 hard-depends on the kernel and on all four toolkits. This is a deliberate simplification: each coverage plan contains correctness scenarios (EP-5), benchmarks (EP-4), a soak scenario judged by a leak verdict (EP-6), and must expose the two telemetry dimensions (EP-7), so none of them can be finished without all four. The consequence is clean waves: once Phase 2 is complete, EP-8, EP-9, EP-10, EP-11 and EP-12 can all proceed in parallel, because layer packages never import one another (see Integration Point 1). The soft dependencies among them are about learning, not code: EP-10 exercises the PGMQ and kiroku adapters and is easier after EP-8 and EP-9 have established what the substrate does by itself; EP-11 is easier after EP-10 has established shibuya's own behaviour; EP-12 is easier after EP-9. EP-13 and EP-14 hard-depend on EP-12 because EP-12 owns the shared keiro fixture domain (a small aggregate with its codecs, process manager and router) inside the `kenshou-keiro` package that all three keiro plans extend; EP-13 and EP-14 are independent of each other. EP-15 hard-depends on EP-11 for the disposable Kafka broker that connects its two bounded contexts and on EP-12 for the fixture domain; it benefits from EP-13 and EP-14 being complete (their scenarios localise any end-to-end failure) and from EP-17 (the long soaks are meant to run on a cell, but every EP-15 scenario must also run locally at a reduced duration).

EP-16 is implemented in another repository and has no hard dependency here; it can start on day one. It has an integration dependency with EP-2 and EP-17: the cell protocol it defines carries a run plan and returns a run directory, both of which are kernel formats (Integration Points 5 and 9). EP-17 needs a cell to submit to (EP-16), the run-plan format (EP-3) and the kernel (EP-2); its third milestone runs paired comparisons and telemetry-overhead plans inside one lease, which needs EP-4's comparison engine and EP-7's overhead planner, so both are hard dependencies even though its first two milestones could start without them. It benefits from EP-5, whose cell-only fault injectors it wires to the cell's fault hook. EP-18 needs the run result format (EP-2) and the comparison verdict (EP-4); it benefits from EP-16 and EP-17 because recorded runs must link to data in durable storage, and the cell's results bucket is the natural home, but EP-18 documents how to use a plain Google Cloud Storage bucket if the cells are not ready. EP-19 cannot begin before EP-18 because the upstream catalog accepts only a profile observed in a real corpus.

The shortest path to first useful evidence is EP-1, EP-2, EP-4 and EP-5 in order, then EP-6 and EP-7, then EP-9 (kiroku is the substrate everything writes to). The critical path to the whole-runtime soak is EP-1, EP-2, EP-4, EP-6, EP-7, EP-12, EP-15.


## Integration Points

The following shared artifacts are touched by more than one child plan. Each names its owner — the plan that defines it — and how the others consume it. Child plans repeat the parts they rely on so that each remains self-contained; if an owner changes a contract during implementation, it must update this section first and then the consuming plans.

Integration Point 1 — repository layout and package ownership. Owner: EP-1. The repository is one cabal project whose `cabal.project` lists packages with the glob `kenshou-*/*.cabal`, so a plan adds a package by creating its directory and never edits the package list. Every library module lives under the `Kenshou` namespace. Layer packages (`kenshou-pgmq`, `kenshou-kiroku`, `kenshou-shibuya`, `kenshou-kafka`, `kenshou-keiro`) depend on the kernel and the toolkits and never on one another; the only package allowed to depend on layer packages is `kenshou-runtime` (the assembled system, which reuses the keiro fixture domain and the Kafka broker fixture) and `kenshou-cli` (which aggregates them into one executable). This boundary is what keeps the layers independently buildable and attributable, and EP-1 records it as an ADR.

```text
cabal.project                 EP-1   imports cohort/active.project; packages: kenshou-*/*.cabal
cohort/                       EP-1   released.project, head.project, *.json descriptors (Integration Point 2)
kenshou-core/                 EP-2   Kenshou.Core.*      scenario, dimension, knob, run spec/result, env, roles
                              EP-3   Kenshou.Plan.*      component graph, change detection, run plans, suites
kenshou-measure/              EP-4   Kenshou.Measure.*   recorder, load generators, samplers, summary, compare
kenshou-check/                EP-5   Kenshou.Check.*     ledger, invariants, process control, faults, models
kenshou-diagnose/             EP-6   Kenshou.Diagnose.*  leak verdict, stall watchdog, profiling variants
kenshou-telemetry/            EP-7   Kenshou.Telemetry.* tracing arms, metrics arms, scraper, overhead
kenshou-pgmq/                 EP-8   Kenshou.Suite.Pgmq.*
kenshou-kiroku/               EP-9   Kenshou.Suite.Kiroku.*
kenshou-shibuya/              EP-10  Kenshou.Suite.Shibuya.*
kenshou-kafka/                EP-11  Kenshou.Suite.Kafka.*  and Kenshou.Env.Kafka (broker fixture)
kenshou-keiro/                EP-12  Kenshou.Suite.Keiro.Fixture.*, .Command.*, .ProcessManager.*, .Router.*
                              EP-13  Kenshou.Suite.Keiro.Outbox.*, .Inbox.*, .Queue.*
                              EP-14  Kenshou.Suite.Keiro.Workflow.*, .Timer.*, .Shard.*
kenshou-runtime/              EP-15  Kenshou.Suite.Runtime.*  two-context reference system and its scenarios
kenshou-cli/                  EP-2   executable `kenshou`; Kenshou.Cli.Registry aggregates layer bundles
kenshou-remote/               EP-17  Kenshou.Remote.*    payload, cell client
kenshou-evidence/             EP-18  Kenshou.Evidence.*  record, attest, history
schemas/                      EP-1   kenshou.<name>.v<N>.schema.json, one per versioned document (each plan adds its own)
suites/                       EP-3   named suite definitions
policies/                     EP-4   comparison policies (EP-7 adds telemetry-overhead.json; layers add their own)
docs/adr/                     EP-1   ADR bundle (OKF, profile documentation.architectureDecisions)
docs/layers/<layer>.md        each coverage plan: the layer guide (scenarios, knobs, what each proves)
docs/guides/                  EP-6 diagnosing-leaks-and-stalls.md, EP-17 running-on-gcp.md
docs/verification/            EP-18  evidence bundle (OKF)
```

Inside a layer package the four evidence kinds are module subtrees, for example `Kenshou.Suite.Kiroku.Correctness.*`, `.Concurrency.*`, `.Soak.*` and `.Bench.*`. `kenshou-keiro` is the one package with three contributing plans, so there the kinds nest under the component (`Kenshou.Suite.Keiro.Command.Correctness`, `Kenshou.Suite.Keiro.Outbox.Bench`, and so on; EP-14's push-wake scenarios live under `Kenshou.Suite.Keiro.Workflow.Wake` with the component segment `wake`). Its cabal file and its single `bundle` value (`Kenshou.Suite.Keiro.Bundle`) are created by EP-12; EP-13 and EP-14 add their modules and dependencies to the cabal file, append their `scenarios` and `roles` to that bundle module, and extend `docs/layers/keiro.md`, which is why both hard-depend on EP-12. Each toolkit package (`kenshou-measure`, `kenshou-check`, `kenshou-diagnose`, `kenshou-telemetry`) also exports a small bundle of `selftest` scenarios that prove the toolkit works and that later plans use as fixtures.

Integration Point 2 — the runtime cohort and its identity. Owner: EP-1. A cohort is the exact set of runtime package versions a build links. `cohort/released.project` pins the versions that services get from Hackage today using an `index-state` and exact `constraints` (keiro 0.17.0.0 and its lock-step family including `keiro-test-support`, keiki 0.9.1.0, kiroku-store 0.8.0.1, kiroku-store-migrations 0.4.0.0, kiroku-cli 0.2.0.6 (kiroku-metrics links it), shibuya-core 0.9.0.3, shibuya-pgmq-adapter 0.16.0.0, shibuya-kiroku-adapter, shibuya-kafka-adapter 0.9.0.1, kafka-effectful 0.3.1.0, the pgmq 0.6.1.0 family, pg-migrate 1.1.0.0, ephemeral-pg 0.3.1.0, hs-opentelemetry 1.0); EP-1 verifies each against Hackage before pinning; its draft already resolved both cohorts with a `cabal --dry-run` and found one tension that the plan documents: the published `keiro-test-support` 0.17.0.0 bounds `ephemeral-pg` below 0.3, so the cohort keeps `ephemeral-pg` 0.3.1.0 behind a single package-qualified `allow-newer` with written evidence. `cohort/head.project` replaces chosen components with `source-repository-package` stanzas that name `https://github.com/shinzui/...` locations and immutable commit hashes, never `file://` paths. `cohort/active.project` is the one-line file that selects which of them `cabal.project` imports. `just use-cohort <name>` switches cohorts (it must also delete cabal's cached configuration and plan, because cabal ignores edits to imported project files). Each cohort also has a machine-readable descriptor, `cohort/<name>.json` (document `kenshou.cohort/v1`: what the cohort intends to pin), that maps every runtime component to its canonical `mori://` project URI, its packages, and its version or commit. `kenshou cohort show --json` prints the `CohortIdentity` actually resolved by the solver (document `kenshou.cohort-identity/v1`, read from `dist-newstyle/cache/plan.json`) together with the solver plan hash, and `kenshou cohort check` fails when the two disagree. Where no `plan.json` exists — on a GCP cell — the identity captured at payload build time is supplied through `--cohort-identity FILE` or `KENSHOU_COHORT_IDENTITY`. Every run result embeds that identity (Integration Point 5), EP-3 diffs two descriptors to decide what changed, EP-17 ships it to the cell, and EP-18 writes it into the run record. The choice between the Hackage `hw-kafka-client` and the house fork is part of the cohort, not a scenario knob.

EP-17 extends `kenshou.cohort-identity/v1` with an optional `resolver` value of `cabal` or `nix`; its absence means `cabal` so existing sealed records remain valid. A Nix payload computes `planHash` from its locked inputs and declares `resolver: nix`, preventing that hash from being mistaken for a Cabal solver hash.

Integration Point 3 — scenario identity, tags and registration. Owner: EP-2. A scenario identifier is the four-segment path `<layer>/<component>/<kind>/<name>`, for example `kiroku/append/concurrency/expected-version-race`. The layer is one of `selftest`, `pgmq`, `kiroku`, `shibuya`, `kafka`, `keiro`, `runtime`. The kind is one of `correctness`, `concurrency`, `soak`, `benchmark`. Each scenario also declares a cost tier — `smoke` (under one minute), `standard` (under ten minutes), `extended` (under one hour), `soak` (hours) — a placement (`local`, `cell`, or `either`), the knobs it accepts with their defaults and allowed values, the dimension values it supports, and optionally a known defect. A known defect names a reference (a `mori://` URI or upstream issue), the failure labels it explains, and a cohort scope (`appliesTo`, for example "only when `shibuya-core` was resolved from Hackage"), because many defects exist in the released cohort and are fixed at head. When the scope holds and every reported failure label is explained, the run keeps the true outcome `failed` but is marked `blocking: false` and `kenshou run` exits 0 (`--strict-known-defects` restores exit 1); when the scope does not hold, or a failure is not explained, the failure blocks as usual. "Known defect on released, must pass on head" therefore needs no second scenario. A scenario has exactly one tier, so every soak is registered twice from one implementation: `<name>` with tier `soak` and placement `cell`, and `<name>-reduced` with tier `extended` and placement `either`. Each layer package exports exactly one value, `bundle :: LayerBundle`, carrying its scenarios and its worker roles; several bundles may share the layer `selftest` (one per toolkit), and only scenario identifiers and role names must be unique across the registry. `kenshou-cli/src/Kenshou/Cli/Registry.hs` is the single list of bundles; a coverage plan registers itself by adding one import, one list element, and one `build-depends` entry in `kenshou-cli/kenshou-cli.cabal`. Beyond that three-line edit, a coverage plan may touch only these shared places, each additively: its own files under `schemas/` and `policies/`, its layer guide `docs/layers/<layer>.md`, new records in `docs/adr/`, system packages in `flake.module.nix` that its environment needs (EP-11's broker, for example), and the selectors of its own components in EP-3's component graph (`kenshou-core/data/`), after which `kenshou plan --graph-check` must report no orphan scenarios and no dead selectors. The vocabulary of component segments inside a layer is owned by that layer's plan.

One scenario can declare a `KnownDefectGroup` when independent owner reports
explain different failure labels in the same run. EP-2 filters each entry by
cohort, requires every failure label to be covered, and retains each
applicable owner reference in run and evidence records. EP-11 uses this for
the separate Kafka rebalance exit and ordering reports; an unrelated
rebalance failure still blocks.

Integration Point 4 — dimensions and knobs. Owner: EP-2 for the vocabulary, EP-7 for the telemetry behaviour. Dimensions are cross-cutting switches with closed value sets that every layer must honour. `telemetry.tracing` takes `off` (the library is handed no tracer, which for this runtime means `Nothing` or the no-op interpreter), `noop` (a tracer from a provider with no span processors), `sdk-inmemory` (the OpenTelemetry SDK with an in-memory exporter) and `sdk-otlp` (the SDK exporting over OTLP to a collector). `telemetry.metrics` takes `off`, `collect` (instruments and collectors are live in the process but nothing is served), `serve` (the HTTP endpoints are up: kiroku-metrics on its port, shibuya-metrics on its port, and whatever the layer exposes) and `serve-scraped` (the endpoints are also scraped by the harness at the run specification's scrape interval). `pg.durability` takes `fsync-off` (the ephemeral-pg default, fast, unrealistic) and `durable` (`fsync` and `synchronous_commit` on; mandatory for benchmarks and crash scenarios). `pg.version` takes `17` and `18`; keiro requires 18, kiroku supports both. Knobs, by contrast, are per-scenario typed parameters (`KnobSpec` with a name, a type, a default and allowed values) such as `kiroku.pool-size`, `outbox.ordering-policy` or `pgmq.visibility-timeout-seconds`; each coverage plan names its component's knobs after the configuration record fields they set. Scenarios declare which values they support, and not every value means something in every layer: pgmq-hs has no metrics endpoint, so its layer supports only `off` and `collect`; shibuya's in-process counters cannot be disabled, so `off` and `collect` behave identically there; keiro has no HTTP endpoint of its own, so its store workers serve kiroku-metrics and its continuous queue workers serve native Shibuya JSON and Prometheus metrics; keiro's timer and shard workers accept no tracer, so their scenarios support `telemetry.tracing=off` only. On GCP the PostgreSQL major version is a property of the cell, so `pg.version` is satisfied by choosing which cell to lease. The registry refuses a `benchmark` scenario that needs PostgreSQL and claims to support `fsync-off`. A layer asks EP-7's `Kenshou.Telemetry.withTelemetry` for handles (`Maybe Tracer`, `Maybe Meter`, and a scrape registrar) and adapts them to its component — keiro's `Maybe KeiroMetrics`, kiroku's composed `eventHandler`, shibuya's `runTracing` versus `runTracingNoop`, pgmq-hs's `runPgmq` versus `runPgmqTraced`. Measurement never flows through the feature being toggled: latency and throughput are recorded in-process by EP-4 and written to files, so a run with every telemetry dimension `off` is still fully measured. EP-7 records this rule as an ADR.

EP-7's handles also expose the existing OpenTelemetry metric-reader endpoint
as `metricEndpoint`; coverage contracts can verify its HTTP representation
without starting another reader. EP-13 uses it alongside the native Kiroku
endpoints in its messaging contract. Native servers stay alive until the
telemetry scope has finished scraping. The original independent measurement
channel and endpoint registration ownership are unchanged.

Integration Point 5 — versioned documents and the run directory. Owner: EP-2 for the run specification, run result and artifact manifest; other plans own the documents they add. Every document is JSON with a `schema` field of the form `kenshou.<name>/v<N>` and a JSON Schema in `schemas/`. A run is identified by a UUIDv7 rendered as lowercase text. A run directory has this shape, and a later run never writes into an earlier run's directory.

```text
<out>/<run-id>/
  run-spec.json          kenshou.run-spec/v1          EP-2   scenario id, knobs, dimensions, environment, seed, phases, cohort expectation
  run-result.json        kenshou.run-result/v1        EP-2   outcome, timings, cohort identity, environment fingerprint, summaries, references to the files below
  manifest.json          kenshou.artifact-manifest/v1 EP-2   every file: relative path, sha256, bytes, media type
  samples/<op>.hist      latency histograms and raw sample spill files                               EP-4
  series/*.csv           time series: rts.csv, proc.csv, pg-*.csv (EP-4); scrape-*.csv, otel-pipeline.csv (EP-7);
                         rts-major.csv (EP-6). A worker process writes <name>-<process-label>.csv. EP-4 owns the
                         column schemas (rts.csv carries major_gcs, last_gc_gen and cumulative_live_bytes, which
                         the leak verdict needs) and documents them.
  verdicts/<checker>.json  kenshou.verdict/v1         EP-5   one per invariant checker
  verdicts/ledger/*.jsonl  kenshou.ledger/v1          EP-5   raw produced/observed fact ledgers, one per process
  diagnosis/*.json       kenshou.diagnosis/v1         EP-6   leak and stall findings, thread dumps, lock graphs
  logs/                  stdout and stderr of the harness and of every worker process
```

When several runs are summarised the worst outcome wins in the order `failed`, `errored`, `infrastructure-failure`, `inconclusive`, `passed`, and a `failed` run that an applicable known defect fully explains is left out. Outcomes use one vocabulary everywhere: `passed`, `failed`, `errored` (the scenario could not be evaluated), `inconclusive` (evidence too noisy to decide) and `infrastructure-failure` (the environment, not the runtime, misbehaved). Comparisons (`kenshou.comparison/v1`, owner EP-4) use `pass`, `regression`, `inconclusive` and `infrastructure-failure`, exactly as `mori://shinzui/keiro-benchmarks/okf/improvement-requests/concepts/IR-1` specifies. Run plans (`kenshou.run-plan/v1`, owner EP-3) are ordered lists of run specifications with a reason for each inclusion. Overhead reports (`kenshou.overhead-report/v1`, owner EP-7) are sets of comparisons across telemetry arms. The seed in the run specification drives every random choice the harness makes so that a failing run can be repeated. A run directory is sealed once its manifest is written: profiling sessions, whose event logs finish later, wrap a run directory instead of adding to it, and offline commands such as `kenshou diagnose` and `kenshou compare` write their output elsewhere. The run result also carries what the evidence record needs and cannot derive later: the tier, the placement, the known-defect disposition, the harness's own commit and dirty flag (from `git` in a checkout, or from `KENSHOU_HARNESS_REVISION` and `KENSHOU_HARNESS_DIRTY` in a Nix-built payload), and two compatibility digests — `comparisonKey`, which excludes the cohort so that a candidate can be compared with a baseline, and `seriesKey`, which includes it so that history is never silently mixed. A comparison names the axes that were allowed to differ (`variedFactors`: the cohort, a dimension, or a knob; a list, because telemetry overhead varies tracing and metrics together) and refuses runs that differ anywhere else. Smaller kernel documents exist for tooling: `kenshou.scenario-list/v1`, `kenshou.worker-init/v1`, `kenshou.worker-message/v1`, `kenshou.plan-summary/v1` and `kenshou.health-notice/v1`. Schema files are named `schemas/kenshou.<name>.v<N>.schema.json`.

Integration Point 6 — the command-line protocol and interaction standard. Owner: EP-2, with the build identity established by EP-1 and commands extended by the plans named. The executable is `kenshou`. `kenshou list` prints scenarios with filters and a `--json` form (EP-2). `kenshou run` executes one run specification, or a scenario identifier with `--set knob=value` and `--dim name=value`, into an output directory (EP-2). `kenshou worker` is the hidden subcommand that runs one worker role as a child process (EP-2 defines it, EP-5 supervises it). `kenshou cohort show` and `kenshou cohort check` print and verify the cohort identity (EP-1). `kenshou plan` and `kenshou execute` produce and run a run plan (EP-3). `kenshou compare` and `kenshou summarize` work on run directories (EP-4). `kenshou diagnose` runs the leak and stall analyses and the profiling recipes (EP-6). `kenshou overhead` runs the paired telemetry comparison (EP-7). `kenshou cell` leases, submits to, watches and fetches from a GCP cell (EP-17). `kenshou record`, `kenshou attest`, `kenshou history` and `kenshou evidence check` write, read and verify the evidence bundle (EP-18). `kenshou help [TOPIC] [--width COLUMNS]`, `kenshou completions bash|zsh|fish`, and top-level `--version` are built-ins owned by EP-2 except that EP-1 supplies the Git-aware version value.

Visible commands carry one of five user-intent groups in their `CliCommand`: Discovery (`list`, `plan`, `help`), Execution (`run`, `execute`, `overhead`, `cell`), Analysis (`summarize`, `compare`, `diagnose`, `history`), Evidence (`record`, `attest`, `evidence`), and Maintenance (`cohort`, `completions`). The hidden `worker` command is internal and appears in neither help nor completions. Commands with more than a few flags use `parserOptionGroup` labels such as Input, Selection, Environment, Execution and Output; shared option records are composed instead of redeclaring the same flag in alternative parser branches. Every command and option has `progDesc` or `help` text because the enriched completion protocol uses it. Shell scripts delegate completion to `optparse-applicative`'s plain protocol for Bash and enriched protocol for Zsh and Fish, so adding a parser entry automatically updates completions.

Long-form topics live as standalone files under `kenshou-cli/help/`, are included in the source distribution, and are embedded with `file-embed`. EP-2 seeds scenarios, selectors, run specifications, outcomes and exit codes; EP-3 adds planning, EP-4 comparisons, EP-6 diagnostics, EP-17 cells and EP-18 evidence. Topic lookup is case-insensitive. `--width` wins when supplied; otherwise topic prose uses the terminal's ioctl-reported width capped at 140 columns, while redirected output is the embedded source byte-for-byte. The implementation uses `terminal-size`, never `ansi-terminal`'s cursor-query size function. Bare `kenshou help` prints a stable topic index; it does not invoke FZF.

Plans add verbs without editing a central sum type: a verb is a `CliCommand` value defined in `kenshou-core` and listed in `Kenshou.Cli.Registry` next to the bundles; the value includes its group. A plan that adds a topic adds one `HelpTopic` value to the adjacent topic registry. Every option whose metavar is `FILE` accepts `-` for standard input when the command consumes a versioned document; exactly one input in an invocation may use `-`, and omission never reads standard input implicitly. `--json` and other document-producing modes emit only the requested document to standard output; progress, warnings and errors go to standard error. `kenshou run --run-id` lets a run plan pre-assign identifiers. Exit codes are part of the contract so that `kotei` or any script can branch on them: 0 for passed or pass (and for a failure fully explained by an applicable known defect, unless `--strict-known-defects`), 1 for failed or regression, 2 for a usage error, 3 for inconclusive, 4 for errored or infrastructure-failure.

Persistent operator defaults use Settei rather than ad hoc environment/file precedence. EP-2 supplies the dependency-neutral `Kenshou.Core.Cli.Config` seam in `kenshou-core`; `kenshou-cli` and later command packages contribute typed declarations without importing the executable package back into their libraries. Command declarations resolve built-ins, then repeated strict YAML `--config FILE` sources in occurrence order, then an explicit allowlist of `KENSHOU_*` environment bindings, then named command flags. Generic Settei `--set` is not exposed because that spelling belongs to scenario knobs; commands use named flags and the shared configuration diagnostics (`--describe-config`, `--describe-config-json`, `--check-config`, `--explain-config`, `--explain-config-json`). Settings marked secret are redacted from errors and reports. Protocol variables injected into hidden workers or cell payloads are transport, not ambient operator configuration, and remain outside Settei. Most importantly, values that affect what is tested are materialised into the effective run specification, run plan, cell session or evidence record before execution. A config file may choose a default output directory, binary location, cell store/project, evidence bundle or data URI; it may not silently supply scenario knobs, dimensions, seeds, policies, or versioned input documents.

Integration Point 7 — environments and the migrated database. Owner: EP-2. A scenario never opens a database by itself; it asks the kernel for a `PostgresEnv`, which is either an ephemeral server started with `ephemeral-pg` (honouring `pg.durability` and `pg.version`) or an external server named by a connection string in the run specification (the GCP case). The kernel migrates it with one `pg-migrate` plan composed from the components the scenario requests — kiroku (`Kiroku.Store.Migrations.kirokuMigrations`), keiro (`Keiro.Migrations.keiroMigrations`) and PGMQ (`Pgmq.Migration.pgmqMigrations`) — because all components must share one ledger and keiro's own `keiro-migrate` executable omits PGMQ. PGMQ is installed without the PostgreSQL extension by that migration, so no extension is needed — with one exception: PGMQ's partitioned queues need `pg_partman`, so EP-8's partitioned-queue scenarios probe for it and end `errored` with a remediation message where it is absent, and the environment fingerprint records whether it is present. Four properties of `PostgresEnv` are load-bearing for other plans: the connection string is in libpq key=value form so a layer can append `application_name` or keepalive options; an ephemeral server also listens on TCP and exposes that endpoint, so EP-5's fault proxy can sit in front of it; "PostgreSQL crashed" means an immediate-mode stop followed by a start on the same data directory and port, through `ServerControl`; and a scenario may require additional, independently restartable servers by name (`extraPostgres`), which only EP-15 uses. The Kafka broker fixture is the same idea for Kafka and is owned by EP-11 (`Kenshou.Env.Kafka`: a private, killable Kafka-protocol broker started for the run, or external brokers named by the run specification, with per-run topic and consumer-group prefixes and optional proxied listeners so one client can be partitioned from the broker). The local default is a run-owned Redpanda 26.2.1 container through Apple Container on macOS or Docker on Linux. A cell supplies its own broker address; the run records which backend served it.

Integration Point 8 — worker roles and multi-process runs. Owner: EP-2 for the `WorkerRole` type and the `kenshou worker` dispatch, EP-5 for supervision. The runtime scales out by running more operating-system processes, and its crash guarantees are about `SIGKILL`, not about Haskell exceptions, so concurrency and crash scenarios run their workers as child processes of the same `kenshou` binary (one binary is also what makes cell deployment simple). A role is a named entry point registered in the layer's bundle. EP-5's `Kenshou.Check.Process` spawns roles, talks to them over a line-delimited JSON control channel, and delivers signals; EP-5's fault injectors act on PostgreSQL (terminating backends by `application_name`, restarting the postmaster of a durable fixture), on the network (an in-process TCP proxy that can add latency, stall, or reset connections), and on wake-ups (keiro's `neverWake` seam for keiro workers; for kiroku, whose notifier has no such seam, by disabling the notify triggers).

Integration Point 9 — the cell protocol. Owner: EP-16, in `mori://shinzui/load-testing-infra`; consumer: EP-17. A cell is a long-lived, named set of GCP machines (PostgreSQL, one or more drivers, optional Redpanda, monitoring with an OpenTelemetry collector) that is leased exclusively, reset deterministically, and given work at run time rather than baked into a machine image. The protocol is generic and knows nothing about kenshou: a submission is a content-addressed payload (a compressed `nix-store --export` bundle named by its SHA-256 and loaded with `nix-store --import`, because Nix has no released Google Cloud Storage store; plus an entry point), an opaque work file, and an output contract (the entry point is invoked with the work file and an output directory; whatever it writes there is published, immutably and with digests, under the submission's prefix in the cell's results bucket together with the cell's own fingerprint, reset evidence and health observations). There are two buckets: a mutable control bucket for leases, heartbeats and submissions, and a retention-protected results bucket that the agent cannot overwrite; the retention lock remains unset while the layout is being proven. The draft `cell.submission/v1` embeds a complete `cell.payload/v1` descriptor with NAR hash, closure paths, system and command; `cell.status/v1` reports phase and final manifest digest, and `cell.environment/v1` gives the payload its service endpoints. These schemas and examples are in `mori://shinzui/load-testing-infra` at project-relative path `schemas/cell/`, with the draft protocol at `docs/cells/protocol.md` (artifact-level URIs pending). A cell run identifier names one submission; for kenshou the work file is a run plan and the entry point is `kenshou cell exec`, a wrapper that reads the cell's environment file and then executes the plan, so one submission's output holds many kenshou run directories, and EP-17 defines how they nest and how `kenshou cell fetch` and `kenshou record` address one of them. A kenshou run directory is already sealed by its manifest when the cell publishes it, so cell facts that arrive later are never merged into `run-result.json`: the run carries `fingerprint.cell` captured at run time, and a derived `cell-run.json` beside the fetched tree carries each run's effective outcome after the cell's health gates. EP-16 in turn grants the run role the right to create databases (the kernel's external mode makes one fresh database per run), and publishes an optional generic fault hook, a measured clock-offset bound and the PostgreSQL extension inventory in its environment file and fingerprint. Additional named PostgreSQL servers degrade on a cell to separate databases on the cell's one server, so scenarios that need to restart one server independently stay `local`. EP-17 also owns the mapping from the cell's generic environment file, health observations and fault hooks to kenshou's inputs: the cohort identity and harness revision captured at payload build time, `KENSHOU_HEALTH_NOTICES` (EP-4's health gates), `KENSHOU_CELL_FAULT_HOOK` and `KENSHOU_CLOCK_SKEW_BOUND_MICROS` (EP-5's cell-only fault injectors and cross-machine ledgers), and the PostgreSQL and broker endpoints. Commits made in `load-testing-infra` under EP-16 reference this initiative as `mori://shinzui/keiro-runtime-kenshou/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime` and the child plan as `mori://shinzui/keiro-runtime-kenshou/plans/16-provide-leased-verification-cells-in-load-testing-infra`.

Integration Point 10 — the evidence bundle and its profile. Owner: EP-18 for the bundle and the local profile, EP-19 for the shared profile. The bundle lives at `docs/verification/` and is registered in `mori.dhall` as the OKF bundle `verification`, so a run record is addressable as `mori://shinzui/keiro-runtime-kenshou/okf/verification/concepts/<path>`. It holds three concept types. An `Attested Computation` (the OKF v0.2 type) defines how one verdict or headline figure is computed from raw data, which command runs it, and which deterministic verifier checks it. A `Verification Run` is an immutable event record: run identifier, scenario, kind, cohort components with their `mori://` URIs and exact revisions, environment fingerprint, knobs and dimensions, outcome, and a list of data links, each with a URI, a SHA-256 digest, a media type and a size. It contains no measurements; the data stays in durable object storage. An `Attestation` states that a named verifier at a named revision fetched the linked data, confirmed the digests, recomputed the verdict under a named computation, and what it concluded; the run's OKF `verified` list gains a machine entry at the same time, and a human sign-off is a `human:` entry. Baselines and trends are derived by readers and never stored. EP-18 develops the profile as a local Dhall descriptor beside the bundle; EP-19 moves it into `okf-profiles` as the export `assurance.verificationEvidence` and repoints the bundle at the published, hash-pinned version. Because the profile language cannot check digests, commit hashes or decimal numbers, EP-18 owns a repository-local check that does (`kenshou evidence check`). Three facts, verified against okf 0.9.0.0 while drafting, constrain the design. A committed corpus is immutable, so field and type names are frozen from the first recorded run (`computationId` with handle prefix `VC`; the discriminator `recordKind` with values `run` and `comparison`) and the shared profile may later relax rules but never rename. A closed-type profile rejects any Markdown file it has no type for, so the executor and attester resources of an `Attested Computation` are non-Markdown files under `references/`. And the vocabularies that are specific to this runtime (`layer`, `tier`) stay open in the shared profile and are re-closed here, so the final `docs/verification/profile.dhall` is the published import plus a local overlay, bound in `mori.dhall` as a derived profile.

Integration Point 11 — upstream defect reports and local tracking. Owner: the child plan that discovers and reproduces the issue; the MasterPlan tracks the cross-layer catch-up. For every unexpected failure, first preserve the failing scenario, run identifier, sealed result and relevant diagnostics, and decide whether the failure belongs to the harness, a runtime dependency, or the environment. Confirm the wrong behavior against a published contract or capability and an exact resolved project version; an unreproduced suspicion remains a blocking finding here. Before filing, inspect the owning repository's OKF bundles and existing reports, plans and improvement requests so the same reproduction is not reported twice. File one report per independently reproducible wrong behavior in that repository's `coordination.bugReports` bundle, adopting its local profile and handle allocation rules. The report must give `origin: mori://shinzui/keiro-runtime-kenshou/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime`, `affects` as the owning project's canonical Mori URI, `affectedVersion` as the actual released version (or `unreleased` for an unshipped head), observed and expected behavior with the authority for the expectation, and ordered reproduction steps. Its body must name the scenario, full `kenshou` invocation or equivalent minimal reproducer, cohort identity including exact component revisions and build source, run ID and evidence location, PostgreSQL/broker version and relevant knobs, dimensions and seed. Link any existing upstream plan or improvement request without treating it as a substitute for the bug report. Validate the owner's OKF bundle, then record the resulting canonical bug concept URI in the matching local `docs/findings/` record and in this MasterPlan's issue register. Use that same URI as the scenario's precise `KnownDefect` reference when the cohort scope and failed labels match; unrelated failures remain blocking. Keep pending findings in the local register with their current owner hypothesis and status until a report or a documented non-bug disposition resolves them. If the producer never promised the behavior, file an improvement request instead and do not mislabel a mere hypothesis as a bug. This rule applies to findings already recorded under EP-8 through EP-15 as well as new findings; check the two concurrent Keiro filings for completion instead of recreating them.

For an improvement request, follow the owning repository's improvement-request
OKF profile and validation gate. For either issue kind, reuse an existing
matching concept before filing another, then add its canonical URI to the
local finding and the countable register below.

The following cross-plan decisions should become ADRs in `docs/adr/` when the owning plan implements them: layer packages never import one another (EP-1); every result carries a resolved cohort identity, and released and head cohorts are both first-class (EP-1); results are recorded through a channel independent of the feature under test (EP-7, with EP-4); crash means `SIGKILL` of a process or termination of a backend, never a thrown exception (EP-5); invariants are labelled as contract invariants or implementation invariants, and only the former block a release (EP-5, first exercised by EP-9's gapless-position check); leak verdicts are judged on live bytes after major garbage collections, not on resident memory, with a separate lower-confidence native-memory probe for leaks the Haskell heap cannot see (EP-6); what "selected because it changed" means — changed components plus transitive dependents over build and declared run-time edges, with the reason recorded (EP-3); GCP infrastructure is extended in `load-testing-infra` rather than copied (EP-16); the Nix-built payload pins the cohort with a local overlay and refuses to run unless the identity it resolved equals the cabal-resolved identity, because the shared `haskell-nix` lock lags the cohort and strips version bounds (EP-17); evidence records are immutable events that link to data and never contain it, and baselines are derived, not stored (EP-18); and this repository, not `keiro-benchmarks`, owns the runtime-facing benchmark protocol (EP-2, with EP-4).


## Progress

Coordination checkpoint (2026-09-30): ten of nineteen child plans are Complete;
EP-8 and EP-10–17 remain In Progress. The initiative is not blocked on owners
fixing the bugs found in the released-cohort baseline. This pass still owns
unfinished scenario implementation, coverage, controlled runs, finding
classification, and evidence acceptance. Repairs belong to the owning
projects; comparable post-fix verification waits for a later platform-owner
request, as decided on 2026-09-27.

The finish line is the existing nineteen child plans and their recorded
acceptance criteria, followed by the planned integration checks and final
technical baseline handoff. Scenario counts, evidence-record counts and
individual diagnostic runs are not additional completion milestones. A new
blocking item must name the existing criterion it prevents and the concrete
evidence needed to close it. A repaired checker requires affected validation;
it does not automatically require republishing every historical matrix arm.
Further useful controls and investigations that do not prevent an existing
criterion belong in follow-up work, not in this initiative's completion gates.

Acceptance follows each criterion's stated result. In particular, EP-13
Milestone 4 accepts an A/A comparison that is `pass` or `inconclusive`; its
recorded p99 uncertainty is a baseline limitation, not a new requirement to
repeat until `pass`. This does not relax explicit passing A/A criteria in
EP-8, EP-15 or EP-17. Precisely scoped runtime defects can close verification
work through the already-defined owner-report path; repairing the runtime or
retesting a future release remains outside this pass. Harness defects that
invalidate the claimed evidence still require repair. The registry remains
ten Complete and nine In Progress; no child plan is closed by this clarification.

A baseline records what the pinned cohort actually does, including failures.
A reproduced owner defect can remain a failed, precisely scoped nonblocking
result without waiting for a fix. A new failure outside that scope, an
unattributed signal, an invalid workload, or an incomplete attestation must
remain visible and cannot be made acceptable merely by calling it a known
bug. [ADR-14](../adr/0014-distinguish-documented-limitations-from-known-defects.md)
and [ADR-18](../adr/0018-keep-verification-records-immutable-and-derive-baselines.md)
govern these distinctions.

The next work is EP-13's remaining messaging acceptance and the EP-11/EP-12
interfaces and acceptance needed by EP-15's assembled-runtime path. EP-15 has
already started consuming the delivered broker and ledger seams, but its
predecessors remain In Progress and their full acceptance is still open.
Continue independent fixture, oracle, and business-flow implementation where
those seams are available; do not describe the full dependency gates as
satisfied. PGMQ benchmark cleanup stays behind the Keiro coverage priority.
Take an EP-16 follow-up when it resolves a concrete cell capability or
acceptance blocker, rather than displacing the assembled-runtime work with
unrelated infrastructure cleanup.

| Child plan | Remaining deliverable | Current constraint |
|---|---|---|
| [EP-13 — messaging](../plans/13-cover-the-keiro-outbox-inbox-and-job-queue.md) | Broaden outbox producer/ordering/fault controls, inbox effect and persistence checks, queue worker/fault/outcome controls, controlled provision and broader throughput comparisons, remaining process-role metrics serving, queue telemetry fault coverage, and process-isolated soak diagnosis; finish queue/outbox full-soak resource acceptance, schema-valid full-soak artifacts, and remaining inbox verification. | Queue outcome revision 4 independently replays all 43 checks, including six worker controls for rounded retries, archive routing, decoder refusal and a zero retry budget; raw observations and mutation tests pass, and the clean revision-4 run has a confirmed six-check attestation. Twenty-two drain/worker configuration checks pass and independently replay; the clean configuration run has a confirmed VC-1 attestation, while the clean physical-outcome run retains an incomplete replay attestation. Worker/polling, provision and metrics controls pass; controlled comparisons retain documented p99 uncertainty, which EP-13 Milestone 4 permits. Twenty-five clean inbox/lease controls have confirmed independent VC-1 attestations, including deliberate failing controls: ten table, four delegated, four poison, three batch and four lease arms. Terminal-state revision 3 independently replays twelve checks and repairs local failure-grouping/retry-budget oracles (findings 52–53); 36 exploratory controls pass, and twenty clean durable terminal controls have confirmed independent VC-1 attestations. The repaired four-hour inbox run passes eight business checks, six resource probes, all eleven schemas and 27 artifact checks; independent soak replay remains open. Default full queue and outbox runs hold nine and eight business checks respectively, but have insufficient heap evidence and legacy verdict defects (finding 50). The repaired four-hour queue GC diagnostic passes nine business checks, six bounded resource probes, twelve schemas and 29 artifact checks. Its diagnostic heap-data and artifact gaps are closed; independent soak replay remains open. The matching four-hour outbox GC diagnostic passes eight business checks, six bounded resource probes, eleven schemas and 28 artifact checks over 288,201 unique messages and 240 restarts. All repaired full-soak artifact gaps are closed; default-GC attribution and independent soak replay remain open. Outbox restart thread finding 3 remains unattributed; killed process incarnations cannot meet the current full-duration leak-policy gate. Detailed evidence and remaining acceptance live in EP-13. |
| [EP-15 — assembled runtime](../plans/15-verify-the-assembled-runtime-end-to-end-and-under-soak.md) | Build the two-context worker topology and persistent business flow, independent SQL money/stock/terminal-state oracles, failure matrix, gated one/four/twenty-four-hour soaks, benchmarks, and whole-system telemetry comparison. | Domain, wire, ledger and broker seams exist, and the local two-topic wire smoke passed. That smoke does not exercise the two databases or establish an end-to-end order outcome. Controlled cell execution needs the required broker capability. |
| [EP-12 — write side](../plans/12-cover-the-keiro-command-processor-process-managers-and-routers.md) | Finish generalized fixture roles/oracles, the remaining matrix, benchmarks, telemetry, full soak, and guide/acceptance. | Finding 44 needs capacity-versus-drain-budget isolation; finding 46 needs writer-only or profile isolation. Low-rate business checks passed; the default-rate run still missed its drain deadline. Existing Kiroku leak reports do not excuse unrelated failures. |
| [EP-14 — durable execution](../plans/14-cover-keiro-durable-execution-timers-and-sharded-subscriptions.md) | Complete workflow definitions, crash/fault schedules, shard checkpoint and metrics assertions, benchmarks, soak pairs, telemetry, and final guide/acceptance. | Missing coverage and assertions remain implementation work; no blanket wait for a runtime fix is recorded. |
| [EP-11 — Kafka](../plans/11-cover-the-kafka-transport-edge-with-a-disposable-broker.md) | Finish broader repetitions and acceptance, full-rate churn/longer soaks, controlled benchmark and telemetry comparisons, and assembled-runtime integration proof. | Alpha and beta's recorded descriptors have no broker. Clean private-broker local correctness can proceed; controlled Kafka cell runs require EP-16's broker role. Existing scoped owner defects remain observable baseline outcomes. |
| [EP-10 — Shibuya](../plans/10-cover-shibuya-core-and-its-pgmq-and-kiroku-adapters.md) | Finish the core batch-key duration verdict, three other soak pairs, controlled cell benchmark calibration, full telemetry overhead matrix, finding audit, and outcome/ADR distillation. | Local comparison intervals are inconclusive; finding 25 still needs a clean historical reproduction or deterministic control. These are measurement and attribution gaps, not prerequisites for owner repairs. |
| [EP-8 — PGMQ](../plans/8-cover-pgmq-hs-in-isolation.md) | Finish remaining quiet-cell A/A controls, including the corrected grouped-read workload, and repeat slow-handler sensitivity on an isolated cell. | Read/ack and invisible-backlog A/A controls passed. Layer-ladder p99 remains inconclusive under the unchanged policy. Busy-workstation sensitivity ratios and invalid grouped-read slices are excluded. |
| [EP-16 — cell infrastructure](../plans/16-provide-leased-verification-cells-in-load-testing-infra.md) | Close the wider live acceptance matrix: broker role, forced health-failure branches, lifecycle/fencing and multi-driver checks, timing measurements, long-run collector rotation, and disposable-lane compatibility. | Passing reset, lease-race, recovery, health and collector slices exist. Broker provisioning is a concrete blocker for controlled Kafka/runtime runs; the wider matrix still needs its own evidence. Ownership is `mori://shinzui/load-testing-infra`. |
| [EP-17 — remote execution](../plans/17-run-kenshou-on-leased-cells-with-payloads-submission-and-retrieval.md) | Finish the wider remote/diagnostic acceptance and operator-guide clean-checkout proof against the supported cell lifecycle. | Released/head and diagnostic payload smokes, four local/cell parity cases, one-lease pairing, telemetry, sealed traces and profiles have passed. Remaining coverage depends on specific EP-16 capabilities and acceptance, with finding 47's guest termination/lease-loss cause still unattributed. |

Cross-plan baseline handoff gates remain open:

- [ ] Select clean released-cohort evidence for the planned coverage and record
  it with its exact cohort, environment, knobs, seed and durable digests.
  Historical dirty, invalid or unsealed attempts remain excluded from that
  selection; full child completion and deferred PostgreSQL 17 compatibility
  remain distinct from the PostgreSQL 18 reporting checkpoint.
- [ ] Close finding attribution and reporting gaps with an existing or new
  owner record or a documented non-bug disposition. Unresolved investigations
  keep this gate open and must be explicit in the working report. The register
  contains 55 numbered findings,
  32 distinct owner bug records and ten improvement requests; a count of
  reports is not a count of repairs or verified fixes.
- [ ] Supply independent replayable verdict checks for the selected evidence
  and publish the final baseline report. EP-18 and EP-19 are Complete, but
  that does not make every later scenario independently attestable. The
  recorded Keiro stale-claim run and Kafka rebalance/stability runs still
  expose VC-1 recomputation gaps; Kafka fencing has a working replay oracle
  and confirmed records. Preserve incomplete attestations and add new
  attestations when verification becomes possible.

Nine clean queue ordering investigations now have confirmed independent replay,
including the full 1,600-job FIFO-heads case. They cover ordering modes and worker
kills. Eleven clean revision-4 investigations add confirmed scripted-retry
replay. Revision 5 adds validated SQL lease and handler-overlap evidence with
independent replay; its clean publication and remaining fault/soak work stay open.

The historical bundle currently contains 188 run/comparison records: 182 sealed
individual runs and six comparisons. The
[working baseline report](../reports/2026-09-29-runtime-baseline.md) and child
plans hold the detailed runs and findings. Owner projects can use this as-is
evidence while they plan repairs. A fixed-cohort release assessment follows
the separately requested post-fix verification pass.


## Surprises & Discoveries

- (2026-10-01) The full inbox retry sealed with the bounded finalization cap:
  all eight business checks and six bounded resource probes passed. EP-13 owns
  its digest-linked record; independent Keiro VC-1 replay remains a separate
  incomplete evidence gate. Process-isolated outbox diagnosis also exposed a
  reproducible EP-5 supervisor retention defect, repaired with a regression.
  This does not identify the owner of historical in-process thread signals.


- EP-17's database-free worker scenario still needed the PostgreSQL reset block required by EP-16's current driver. A live run then exposed a race between `postgresql.service` restart and `postgresql-setup.service` database creation: the setup unit recreated `benchmark` while reset verification was reading the database list. EP-16 now waits for setup completion in the role executor; the next live worker run passed and its local/cell parity report has zero unexpected fields. The owner code is in `mori://shinzui/load-testing-infra` at project-relative path `nixos/pkgs/cell-agent/src/src/reset/postgres.rs` (artifact-level URI pending).
- EP-17's paired control exposed the owner image's PostgreSQL systemd start limit: five starts in ten minutes and five seconds. The first five cold resets passed; subsequent resets sealed `reset-failed` with `start-limit-hit`. The owner raised the bounded allowance to 64 in `mori://shinzui/load-testing-infra` at `b2ae523`, deployed it to alpha, and a five-pair A/A control then passed ten consecutive cold resets under one lease. The unit is at project-relative path `nixos/modules/cell-postgres.nix` (artifact-level URI pending).

- EP-10's adapter finding audit filed `mori://shinzui/shibuya-pgmq-adapter/okf/bug-reports/concepts/BUG-2` for the historical exhausted-acknowledgement hook, `mori://shinzui/shibuya-pgmq-adapter/okf/bug-reports/concepts/BUG-3` for duplicate direct-DLQ copies, and `mori://shinzui/kiroku/okf/bug-reports/concepts/BUG-4` for partial group-acquisition cleanup. Published-current adapter controls passed on PostgreSQL 17 and 18. Clean released PostgreSQL 18 runs at `9297d59` reproduced the exact hook and group-cleanup findings (`01a0e55b-52c2-75d3-aa5b-680edeff9115`, `01a0e55d-02ea-77e4-909c-f9163be0cdb5`). Two 10,000-message atomic-move reruns (`01a0e55c-0eb5-737c-9336-220939cbcd0f`, `01a0e55c-9391-73b5-a2da-b49cfa472ca3`) passed without triggering the timing-dependent duplicate; earlier pinned historical runs reproduced two and nine copies. All four new result schemas and both owner OKF bundles validated; the 34-example Shibuya package suite passed. Remaining EP-10 acceptance work stays open.

- EP-10's isolated current-release PGMQ sweep now has sealed PostgreSQL 17/18 results for all 13 registered scenarios. Its process-role path required the Shibuya-only executable to handle the kernel's hidden `worker --role` protocol; two-process lease renewal, four-consumer competition and full effect-gated SIGKILL runs then passed on both majors. The current lease-sizing runs reproduce 110 duplicate effects among 240 IDs under five-second VT and no duplicates under thirty-second VT. The only nonpassing current PGMQ verdicts remain precise, nonblocking reproductions of `mori://shinzui/shibuya-pgmq-adapter/okf/bug-reports/concepts/BUG-1` and `mori://shinzui/pgmq-hs/okf/bug-reports/concepts/BUG-1`. The EP-10 current-release matrix gives each run ID and checked-in spec.
- EP-10's gated PGMQ outage scenarios now have sealed historical and current-release PostgreSQL 17/18 results for both postmaster restart and backend termination. All default-workload producer IDs reached durable handler effects and both arms drained in every run. Isolated current Shibuya 0.10.0.0 and adapter 0.16.1.0 passed postmaster restart (`runs/01a0de0e-274c-76f0-b197-fb148c673ef4/run-result.json`, `runs/01a0de0e-c680-76ca-a57b-8acd846289bf/run-result.json`). Historical adapter 0.16.0.0 reproduced only its missing exhausted-acknowledgement callback. Backend termination reproduced the existing `mori://shinzui/pgmq-hs/okf/bug-reports/concepts/BUG-1` disconnect classification on both pgmq-effectful 0.6.1.0 and 0.6.1.1; the external restart loop recovered every message. A pre-crash Hasql oracle pool initially hung after postmaster recovery, so the fixture now acquires fresh pools for the effect ledger, recovery checks and queue cleanup. EP-10 records all run paths and keeps the other current-release PGMQ scenarios open.
- EP-10's direct-DLQ conservation probe moved 10,000 messages per fault arm on historical PostgreSQL 17/18 with no missing or duplicate IDs. Pinned remediation still links adapter 0.16.0.0 and reproduced REV-11-F1: nine extra DLQ copies at 10,000 messages under backend termination, with no source loss (`runs/01a0ddbe-0d8f-74c9-b010-9478ea1edc9f/run-result.json`). The owner changelog and `mori://shinzui/shibuya/plans/41-verify-pgmq-acknowledgement-and-dead-letter-recovery-under-faults` place the delete-first fix in 0.16.1.0, so only duplicate-copy verdicts are nonblocking below that version. A new Shibuya-only executable links isolated Hackage 0.16.1.0 and emits sealed run results with an explicit, index-pinned layer cohort identity; its full atomic-move scenario passed on PostgreSQL 17/18 (`runs/01a0ddd6-4b62-779d-b81c-cf3f50bfcef5/run-result.json`, `runs/01a0ddd5-f6cd-74fa-8a0c-e9412f4b6ba3/run-result.json`). [ADR-2](../adr/0002-every-result-carries-a-resolved-cohort-identity.md) limits that evidence to the named layer. Owner `mori://shinzui/shibuya-pgmq-adapter/okf/bug-reports/concepts/BUG-3` now records the historical duplicate; the isolated current-release PGMQ scenario sweep has completed.
- EP-10's first prefetch probe used ordinary graceful shutdown, which drained all 20 messages before it could observe buffered leases. The bounded-inbox forced-stop probe leaves 10 prefetched rows leased and four without prefetch on every tested line; no message is lost. Its normal arm could not distinguish adapter reads from already leased core-inbox rows. A new PostgreSQL-to-client response barrier stops a normal adapter after a committed read but before delivery. Historical 0.16.0.0 on PostgreSQL 17/18, pinned remediation on PostgreSQL 18, and isolated current 0.16.1.0 on PostgreSQL 17/18 all confirm immediate lease release, no adapter delivery and direct redelivery at count two. The EP-10 Surprises section records the sealed historical and remediation runs; the current-release CLI lane remains unsealed.

- EP-10's lease-sizing probe reports 110 duplicate durable effects with a five-second PGMQ VT and none with a thirty-second VT under the same 240-message backlog, across historical PostgreSQL 17/18, pinned remediation PostgreSQL 18 and isolated current-release PostgreSQL 17/18. All IDs have effects and both queues drain. The measured safe-arm read-to-handler maximum is about 8.1 seconds, above the nominal 7.6-second pipeline expression; that expression is a sizing estimate with overhead margin, not a strict bound. EP-10 records run IDs and the lease-age measurement coverage.

- EP-10 found that a shared pool sized exactly to two long-polling processors can defer both `AckOk` and a transactional dead-letter move until application shutdown. Its SQL oracle uses a separate pool and observes both source rows still present, no DLQ row and two active long polls at 25 seconds. The owner report is `mori://shinzui/shibuya-pgmq-adapter/okf/bug-reports/concepts/BUG-1`; local details and run paths are in `docs/findings/15-shibuya-pgmq-long-poll-pool-starvation.md`. The isolated Hackage 0.16.1.0 sealed PostgreSQL 18/17 CLI runs reproduce the precise `acknowledgement-deadline` known defect below adapter 0.16.2.0 with no conservation failures.

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

Research before decomposition surfaced facts that every child plan author should know.

- `keiro-benchmarks` does not benchmark keiro. Its single executable compares Message DB with kiroku appends, pins nothing, and would fail at run time against kiroku-store 0.8 because it expects `withStore` to create the schema. Evidence: `/Users/shinzui/Keikaku/bokuno/keiro-benchmarks/app/Main.hs` and its own improvement request's non-goals.
- The workload binaries that `load-testing-infra` deploys live in a third repository, `kiroku-bench`, which is not registered in Mori, is pinned to kiroku-store 0.2.0.0, and has a disabled shibuya executable and a conflict mode that produces zero appends.
- Most of keiro bypasses shibuya's runner: process-manager and router workers drain an adapter's stream serially and finalize acknowledgements themselves, and keiro reads kiroku through `subscriptionAckStream` directly. Only `keiro-pgmq` calls `Shibuya.App.runApp`. Shibuya's guarantees therefore have to be verified at the shibuya layer and cannot be assumed of keiro's workers.
- Two different shibuya-cores exist: Hackage 0.9.0.3, which keiro resolves, and an unreleased repository head with a breaking lifecycle fix. Several known defects reproduce only on the released version. The cohort mechanism exists for exactly this.
- Every existing suite in the runtime runs PostgreSQL with `fsync=off`, as superuser, under the C locale, inside one process; "crash" means a thrown exception or `killThread`. keiro's own MasterPlan 22 (`mori://shinzui/keiro/masterplans/22-make-the-test-infrastructure-exercise-real-crash-and-production-semantics`, not yet resolvable through Mori) planned real crash tests and never started them.
- The dominant benchmark noise source recorded by `load-testing-infra` was PostgreSQL checkpoints (one roughly 270-second checkpoint per 600-second window, giving plus or minus twenty percent run to run), not GHC and not GCP. Paired, interleaved runs inside one lease are the remedy, not longer single runs.
- EP-9's full local trials demonstrated the harness health gates under real overload: a 32-writer store-API ladder run recorded one pool timeout during a checkpoint, and a 250 reads/s read-target run saturated the driver and hit pool timeouts. Full-duration paced reruns passed with benchmark-grade health at 250 appends/s and 25 reads/s respectively. EP-17 must carry the scenario rate and health verdict into cell comparisons; these macOS runs are exploratory, not performance baselines.
- The metrics endpoint was load-bearing for measurement in the old harness, which would make a "metrics off" arm impossible. This is the origin of the rule in Integration Point 4.
- `hasql-opentelemetry` and `servant-health` are not part of the runtime cohort, and `hasql-opentelemetry` cannot link with it (it bounds `hs-opentelemetry-api` below 0.4 while the cohort requires 1.0). The metrics endpoints to evaluate are kiroku-metrics (default port 9091) and shibuya-metrics (default port 9090); keiro itself exposes OpenTelemetry instruments and no HTTP endpoint.
- okf stores definitions, never run artifacts, and the profile language cannot validate decimal numbers, digests or commit hashes. This is why the evidence design uses links plus a repository-local check.

Drafting the child plans against real source corrected the research in ways that cross plan boundaries. Each child plan records its own findings; these are the ones more than one plan depends on.

- The duplicate window after a crash is not always bounded by the subscription `batchSize` (100). A live, non-group `$all` kiroku subscription is fed by the shared publisher in batches of up to `publisherBatchSize = 1000` and checkpoints only at the batch tail, so its budget is 1000. EP-9 and EP-10 encode a per-path budget; any plan that asserts a duplicate bound must name the delivery path.
- The cohort as first listed did not resolve: published `keiro-test-support` 0.17.0.0 bounds `ephemeral-pg` below 0.3 (the research read keiro's unreleased working tree). EP-1 resolved both cohorts in a dry run with one package-qualified `allow-newer`. `kiroku-cli` must also be pinned because `kiroku-metrics` links it.
- Released and head `shibuya-core` both report version 0.9.0.3, so neither version bounds nor the C preprocessor can tell them apart. This is why a known defect's cohort scope is expressed by where a package was resolved from, and why layer code must compile unchanged against every cohort.
- The pinned nixpkgs has no Redpanda server package. EP-11 instead starts a run-owned Redpanda 26.2.1 image through Apple Container on macOS or Docker on Linux; both were probed on private ports. The cell broker remains supplied by the cell environment because cell machines have no internet egress.
- Nix has no released Google Cloud Storage store, so payloads travel as `nix-store --export` bundles; and a retention-locked results bucket cannot hold lease heartbeats, so the cell has a second, mutable control bucket.
- `ephemeral-pg` 0.3.1.0 restarts a server from its default configuration rather than the original one, and listens on a Unix socket unless told otherwise; the kernel therefore owns re-applying settings across a restart and enabling a TCP listener for the fault proxy.
- PostgreSQL fault targeting must query `pg_stat_activity` through the run database, not the administrative/template connection: its `current_database()` filter otherwise hides every scenario client. Lock healing must terminate the named backend as well as its client because a backend inside `pg_sleep` may not notice a killed client until the query returns.
- The `haskell-nix` revision the Seihou flake module pins locks keiro 0.16 and kiroku-store 0.8.0.0 with version bounds stripped, so a Nix build does not reproduce the cabal cohort by itself; EP-17's payload therefore uses a local cohort overlay plus an identity gate, and the solver plan hash is undefined under Nix (the cohort identity gains an optional resolver member).
- The cell's PostgreSQL role as first drafted could not create databases and was trusted on one database only, while the kernel's external mode creates one fresh database per run; EP-16 now grants `CREATEDB` and subnet-wide access and its reset drops every database the role owns.
- A scenario has one tier but every soak must run both locally and on a cell; all coverage plans converged on registering each soak twice, and the suffix was normalised to `-reduced`.
- okf 0.9.0.0 rejects any Markdown file a closed-type profile has no type for (so `references/` targets are non-Markdown), always permits core keys such as `status`, and its YAML reader turns an unquoted `off` into `false` and a digest made of digits and the letter e into a number, so the evidence writer must quote scalars.
- keiro's workflow and shard leases are judged by the worker's clock, while the crash backoff is written with the database clock and compared with the worker's; and the keiro timer and shard worker APIs accept no tracer. Both shape what the durable-execution scenarios can assert.
- Reading source for the coverage plans surfaced suspected defects that no upstream document records yet, each encoded as a probe scenario rather than asserted: a child workflow's completion and its parent's wake are separate transactions; `ensureShards` commits mismatched rows before throwing; outbox finalization is not fenced against a re-claim by another publisher; router dead-letter rows are unique on a positional index while dispatch identity is keyed by target; with the Kafka adapter's required background poll mode a halted consumer is never evicted after `max.poll.interval.ms`; and storing an offset on a revoked partition can kill a healthy consumer. Confirmed ones are to be filed against the owning repository, per the scope boundary.
- Mori exposes `shinzui/haskell-jitsurei` as the active CLI pattern catalog and shows it adopted by existing house tools. Its current catalog requires `optparse-applicative` 0.19 for option groups, uses `file-embed` for topics, uses `terminal-size` rather than `ansi-terminal` for non-blocking ioctl width detection, derives completions from the parser tree, and treats hierarchical Dhall configuration as legacy. Hackage on 2026-09-20 lists `githash` 0.1.7.0, `file-embed` 0.0.16.0 and `terminal-size` 0.3.4; upstream tags confirm `githash-0.1.7.0` and `terminal-size` 0.3.4, while `file-embed`'s upstream tag list stops at 0.0.15.0, so EP-1 must record the Hackage-versus-tag discrepancy when it refreshes and pins harness dependencies.
- Mori exposes `shinzui/settei` as the house typed, layered, provenance-aware configuration family. Hackage on 2026-09-20 lists 0.2.0.0 as the latest release of `settei`, `settei-env`, `settei-optparse-applicative`, and `settei-yaml`, and upstream has the matching annotated `v0.2.0.0` tag. Its reference CLI uses built-ins below ordered files below explicit environment bindings below named CLI sources, preserves shadowed origins, redacts secret settings, and reserves stdout for requested JSON. That model fits operator defaults but not run-defining evidence, which must be frozen into kenshou documents.
- EP-3's checked graph contains 26 whole components, 15 sub-components and 65 edges after reconciliation with Cabal's real solver plan. The important cross-plan consequence is that later coverage plans can add scenarios without changing planner code: they register a bundle and keep their owned component selectors current. The executor also proved that an interrupted attempt can remain immutable while a resumed attempt receives a fresh UUIDv7, which is the identity behavior EP-17 and EP-18 consume.
- EP-4 completed the shared measurement boundary consumed by the diagnostics, telemetry, layer-coverage, cell and evidence plans. Health gates are reproduced from sealed run artifacts; external cell notices enter through `KENSHOU_HEALTH_NOTICES` and are captured as manifested `health-notices.jsonl`. Hard evidence conditions override regressions as infrastructure failures, while soft conditions and checkpoint asymmetry make comparisons inconclusive.
- EP-7 completed both telemetry dimensions and the paired overhead protocol. Its headline synthetic report passed off-to-noop, off-to-OTLP, and off-to-serve-scraped transitions with exact sink accounting; a high-rate OTLP arm dropped 5,925,547 spans and was correctly made inconclusive. Later layer plans can use the generic handles, continuity checks, bounded handler composition, isolated scraper and sink, per-arm leak hook, and the resumable `kenshou overhead` command.
- EP-8 found that pgmq-hs 0.6.1.0 can misclassify disconnects during immediate PostgreSQL crashes, backend termination, and TCP resets as permanent statement errors. PostgreSQL 17 and 18 both preserved committed rows and recovered the same pool after a crash, while their transient-classification checks failed. The owner request is `mori://shinzui/pgmq-hs/okf/improvement-requests/concepts/IR-4`. EP-10's PGMQ adapter and EP-13's job queue should retain explicit retry and recovery evidence at this boundary; EP-8 declares only the precise classifier failure labels as non-blocking known defects, so durability and recovery failures still block.
- EP-8 also found a concurrent startup boundary in pgmq-hs: eight reconcilers converge on ten queues, but each can claim it created the same resource, and concurrent FIFO index creation can raise SQLSTATE `23505` despite `CREATE INDEX IF NOT EXISTS`. The owner request is `mori://shinzui/pgmq-hs/okf/improvement-requests/concepts/IR-5`. EP-10 and EP-13 should keep catalog convergence, worker errors, and report truthfulness as separate checks when they verify their startup paths.
- EP-8 found that a response blackhole can leave a PGMQ call blocked beyond ten seconds even with libpq `tcp_user_timeout=5000`. The separate owner request is `mori://shinzui/pgmq-hs/okf/improvement-requests/concepts/IR-6`. EP-10 and EP-13 should use a process boundary or another enforceable deadline for this fault, and should distinguish a confirmed send from one whose reply was lost. EP-8 added a separate blackhole scenario so this expected timeout failure cannot mask the independent reset-classification failure tracked by IR-4.
- EP-9's network-partition run demonstrated a 60-second local recovery miss after a blackhole and category reconnect replay, but CAP-11–13 and the owner guide promise eventual at-least-once recovery and explicitly allow replay. Neither target is a broken published provision. Diagnostic event logs showed publisher pool errors before native `$all` and group delivery resumed; `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-16` requests a prompt retry after those errors. The existing EP-8 requests `mori://shinzui/pgmq-hs/okf/improvement-requests/concepts/IR-4`, `mori://shinzui/pgmq-hs/okf/improvement-requests/concepts/IR-5` and `mori://shinzui/pgmq-hs/okf/improvement-requests/concepts/IR-6` have the non-bug or bug dispositions in the issue register; EP-10's released-cohort findings still need a report audit under Integration Point 11.

### Upstream issue register

Tracking snapshot (2026-09-29). Count each distinct canonical owner issue URI
once, even when multiple scenarios or local findings cite it. These are owner
records linked or reused for runtime findings, not a count of fixes. Contextual
requests for this initiative's tooling and infrastructure are excluded.

| Owning project | Bug reports linked | Improvement requests linked |
|---|---:|---:|
| `mori://shinzui/keiro` | 7 | 0 |
| `mori://shinzui/pgmq-hs` | 3 | 3 |
| `mori://shinzui/shibuya-kafka-adapter` | 6 | 0 |
| `mori://shinzui/shibuya-pgmq-adapter` | 3 | 0 |
| `mori://shinzui/kiroku` | 2 | 4 |
| `mori://shinzui/shibuya` | 11 | 3 |
| **Distinct owner records** | **32** | **10** |

Numbered finding coverage is tracked separately from distinct owner records:

| Finding disposition | Count |
|---|---:|
| Owner bug report linked (including two Keiro reports now marked duplicate) | 31 |
| Owner improvement request linked as the primary disposition | 6 |
| Local suite findings (including findings 39–43, 45, 48, and 50–55) | 14 |
| Owner improvement request URI not recorded | 0 |
| Unattributed runtime observations under investigation | 2 |
| Infrastructure observations with final attribution open | 2 |
| **Numbered findings** | **55** |

Of the 32 linked bug records, 16 are reported, 14 are marked fixed by their
owners, and two Keiro reports are marked duplicates of
`mori://shinzui/kiroku/okf/bug-reports/concepts/BUG-3`. The
owner's fixed status is not a Kenshou post-fix verification. Finding 16 links
a dependent adapter request after the existing store-guard request. Update
this snapshot, the matching local finding, and the register when a link or
disposition changes.

- EP-11 Kafka rebalance ordering finding: [local finding](../findings/9-kafka-rebalance-replays-committed-offsets-out-of-order.md); upstream `mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-6`. In two private-broker runs, one serial consumer handled a lower, already committed partition offset after a higher offset within the same assignment; the integrated adapter/runner source path remains to be isolated.
- EP-11 Kafka seek-barrier overwrite finding: [local finding](../findings/8-kafka-later-retry-overwrites-earlier-barrier.md); upstream `mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-5`. A real broker redelivered offsets 4–9 after dual retries at 3 and 4, then committed 10 without a successful decision for offset 3.
- EP-11 Kafka group-rebalance finding: [local finding](../findings/7-kafka-group-rebalance-ends-adapter-consumers.md); upstream `mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-4`. Surviving released adapter workers end normally during membership changes; one reduced run retained acknowledged backlog.
- EP-11 Kafka broker-restart finding: [local finding](../findings/6-kafka-broker-restart-ends-adapter-consumers.md); upstream `mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-3`. Two released adapter workers exit after a broker restart with acknowledged records still unhandled; the proxy-blackhole control passes.
- EP-11 Kafka buffered-successor ordering finding: [local finding](../findings/5-kafka-buffered-successors-run-before-retry.md); upstream `mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-2`. A serial released adapter executes offsets 4–9 before the retried offset 3 succeeds.
- EP-11 Kafka buffered-retry finding: [local finding](../findings/4-kafka-buffered-retry-leaves-successors-uncommitted.md); upstream `mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-1`. The released adapter can leave successful buffered successors uncommitted after a retry; a batch-size-one control passes.
- EP-12 write-side worker heap-growth finding: [local finding](../findings/1-keiro-write-side-worker-heap-growth.md); owner `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-1` is a duplicate of `mori://shinzui/kiroku/okf/bug-reports/concepts/BUG-3`, fixed in `kiroku-store` 0.9.0.1. Whole-worker verification on that published version remains open.
- EP-12 seed-backlog heap-growth finding: [local finding](../findings/2-keiro-seed-backlog-heap-growth.md); owner `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-2` is a duplicate of the same Kiroku BUG-3. A source-only control reduced growth; comparable published-cohort verification remains open.
- EP-12 steady-restart harness thread-growth finding: [local finding](../findings/3-keiro-steady-restart-harness-threads.md); owner remains this repository pending a focused harness investigation. No upstream runtime bug concept should be inferred from the current evidence.
- EP-17 GCS token-cache finding: [local finding](../findings/39-kenshou-gcs-token-cache-survives-expiry.md); owner is this repository. HTTP 401 interrupted a five-pair cell A/A after seven verified slices; journal resume verified all ten but one slice sealed cancelled under a second lease, so the comparison is excluded. The client repair refreshes a cached CLI token once on 401; the fresh single-lease control completed without an authorization error, though its p99 A/A verdict is inconclusive.
- EP-17 alpha lease-loss observation: [local finding](../findings/47-alpha-cell-loses-lease-during-outbox-soak.md); infrastructure attribution is pending. The driver guest terminated during a clean outbox soak, the cell sealed `cancelled` with `lease-lost` and `health-unavailable`, and the nested result did not seal. Partial verdict files are excluded; a longer-lease retry sealed and verified with all eight outbox business checks holding, while the lease-loss cause remains unattributed.
- Shared verdict counter omission: [local finding](../findings/50-verdict-writers-omit-required-assertion-counters.md). The schema requires assertion counts that several shared/model writers omitted. Source repairs and an emission guard are owned here; sealed legacy artifacts remain unchanged and schema-qualified. No runtime-owner report is added.
- EP-13 full inbox finalization timeout: [local finding](../findings/49-four-hour-inbox-soak-times-out-before-sealing.md). The cell journal confirms termination at its four-hour-plus-five-minute wall-clock limit. All eight partial business verdicts held, but no nested result or manifest sealed. Finalization cost remains unattributed; the outer infrastructure-failure is excluded from full-soak acceptance and no runtime owner report is assigned.
- EP-13 planner pin-validation finding: [local finding](../findings/48-plan-silently-drops-knob-pinned-for-another-scenario.md); owner is this repository. An outbox control requested forced major GC, but its selected scenario did not declare the knob. The planner accepted it because another catalog scenario did, silently omitted it from the run spec, and produced an invalid diagnostic repeat. Planning now rejects a pin that no selected scenario declares; the outbox result remains useful only as a repeat of the restart-linked thread signal.
- EP-11 Kafka broker-requirement finding: [local finding](../findings/40-kenshou-kafka-scenarios-omit-broker-requirement.md); owner is this repository. Broker-backed scenarios were cataloged without their Kafka environment requirement, allowing route preparation to accept a brokerless cell. The resulting Kafka barrier run errored before the defect probe and is excluded; the catalog and package test now require a broker for every live Kafka scenario.
- EP-18 cell evidence destination finding: [local finding](../findings/41-kenshou-cell-evidence-base-uri-check-runs-after-uploads.md); owner is this repository. The recorder rejected a generic GCS prefix for cell evidence only after uploading nested files there. Cell-specific destination validation now precedes all object writes; the guide shows the existing sealed cell prefix and verify-only command.
- EP-8 grouped-read benchmark finding: [local finding](../findings/42-kenshou-grouped-read-benchmark-ignored-its-workload-knobs.md); owner is this repository. Three verified alpha A/A slices failed on a send/read race. The revision-2 workload also ignored group count, grouped strategy, batch size, preload count, and FIFO-index controls. Scenario revision 3 preloads and drains grouped messages; the invalid control is excluded pending a clean-payload rerun.
- EP-12 Keiro soak-window finding: [local finding](../findings/43-keiro-write-side-soak-uses-default-diagnosis-window.md); owner is this repository. A five-minute override on the reduced write-side soak left the diagnosis window at its static twenty-minute default, making the old shortened run ineligible for baseline interpretation. The diagnosis API and two Keiro soak scenarios now use the effective window; a clean shortened alpha replay verified seconds 5–305 and passed all ten business checks.
- EP-12 write-side quiescence observation: [local finding](../findings/44-keiro-write-side-default-soak-does-not-quiesce.md); owner attribution is pending. The clean twenty-minute reduced soak at its default offered rate failed three post-drain business checks. It also reproduced heap growth already owned by Kiroku BUG-3. The current summary lacks enough stage counts to distinguish backlog from loss, so no new runtime-owner report is filed yet.
- EP-12 command-writer heap-growth observation: [local finding](../findings/46-keiro-command-writers-grow-heap-in-low-rate-soak.md); owner attribution is pending. A clean twenty-minute low-rate run passed every business check but both writer child heaps grew after major collections. A writer-only control or heap profile must separate possible lazy-workload retention in Kenshou from the command path before an owner report.
- EP-18 empty-knob evidence finding: [local finding](../findings/45-verification-record-rejects-empty-string-knob.md); owner is this repository's verification-profile integration. A passed, verified Keiro queue telemetry run initially could not be recorded because its valid empty `otel.endpoint` knob was considered absent by the profile's required-scalar rule. A type-specific local overlay and regression fixture repaired the gap; the same sealed run is now digest-linked.
- EP-13 polling-backend worker exit: [local finding](../findings/34-keiro-job-worker-exits-after-polling-backend-termination.md); owner `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-3`. A continuous worker exits after a backend termination and leaves later durable jobs queued.
- EP-13 long-poll retry accounting: [local finding](../findings/35-keiro-long-poll-consumes-read-attempt-without-handler.md); owner `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-4`. A long poll can consume a read attempt without a matching handler delivery; ordinary polling controls pass.
- EP-13 stale outbox claim finalization: [local finding](../findings/36-keiro-stale-outbox-publisher-finalizes-new-claim.md); owner `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-5`. A resumed old publisher can mark a newer successful claim failed or dead.
- EP-13 long-poll pool starvation: [local finding](../findings/37-keiro-long-poll-processors-starve-runtime-pool.md); owner `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-6`. Six processors on a three-connection pool left a job queued until a smaller replacement worker ran.
- EP-13 pre-handler telemetry gap: [local finding](../findings/38-keiro-pre-handler-dead-letter-lacks-process-span.md); owner `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-7`. The DLQ row is durable, but a pre-handler dead letter emits no promised process span.
- EP-8 disconnect-classification finding: [local finding](../findings/10-pgmq-disconnects-are-classified-as-permanent.md); upstream `mori://shinzui/pgmq-hs/okf/bug-reports/concepts/BUG-1`, with complementary diagnostic request `mori://shinzui/pgmq-hs/okf/improvement-requests/concepts/IR-4`. Fresh PostgreSQL 17/18 restarts preserved 200 confirmed keys and recovered the same pool while the released classifier marked the interruption permanent. Backend termination and TCP reset reproduced the same classification boundary on PostgreSQL 18.
- EP-8 concurrent-reconciliation finding: [local finding](../findings/11-pgmq-concurrent-reconciliation-misreports-creators.md); upstream `mori://shinzui/pgmq-hs/okf/bug-reports/concepts/BUG-2`. Eight workers could each report creating a resource that only one physical queue holds; the FIFO index race is an existing documented concurrent-startup limitation under `mori://shinzui/pgmq-hs/okf/improvement-requests/concepts/IR-5`.
- EP-8 partitioned-notification finding: [local finding](../findings/12-pgmq-partitioned-notifications-bypass-throttle.md); upstream `mori://shinzui/pgmq-hs/okf/bug-reports/concepts/BUG-3`. PostgreSQL 17/18 each emitted 1,000 leaf-channel notifications over five seconds where the configured throttle allowed at most 21. The fix is planned at `mori://shinzui/pgmq-hs/plans/23-gate-the-notification-fail-open-on-a-real-queue-row-and-state-the-partitioned-queue-contract`.
- EP-8's remaining reproduced hazards have non-bug dispositions under Integration Point 11: the response blackhole has no promised operation deadline and remains `mori://shinzui/pgmq-hs/okf/improvement-requests/concepts/IR-6`; mixed-case names are rejected by the public client and the foreign-metadata collision remains `mori://shinzui/pgmq-hs/plans/24-report-name-collisions-and-unsupported-notifications-instead-of-acting-on-them`; partition retention has no completion-aware guarantee and remains `mori://shinzui/pgmq-hs/plans/21-state-the-fifo-ordering-and-partitioned-retention-contracts-truthfully`.
- EP-9 network-partition recovery finding: [local finding](../findings/13-kiroku-network-partition-recovery-exceeds-local-bound.md). Revision-4 PostgreSQL 18 run `01a0d752-4ed9-72d0-bb88-c9b71e1e29ee` and PostgreSQL 17 run `01a0d752-4ed9-7794-acf9-f1079387d17c` each passed all contract cells, eventually covered and checkpointed 320 positions, and recorded the 60-second timing miss and 100-position category replay as implementation findings. Owner `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-16` requests faster publisher pool-error retry; `mori://shinzui/kiroku/plans/82-repair-live-reconnect-and-validate-subscription-identity-and-batch-size` addresses replay. No owner bug report is warranted by the published at-least-once contract.
- EP-9's five other reproduced improvement probes have non-bug dispositions: `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-7` explicitly classifies multi-versus-single fresh-stream deadlock avoidance as desired work; `mori://shinzui/kiroku/plans/81-make-consumer-group-topology-durable-and-resize-without-gaps` seeks online resize although CAP-13 says membership is static; `mori://shinzui/kiroku/plans/82-repair-live-reconnect-and-validate-subscription-identity-and-batch-size` seeks a smaller replay window and batch-size validation although CAP-11 permits reconnect replay without that bound and the raw constructor promises no validation; `mori://shinzui/kiroku/plans/83-contain-persistent-publisher-decode-hook-failures` seeks progress or terminal error under a permanently throwing user hook, which the published API does not promise. Revision-2 PostgreSQL 18 runs for all five passed their contract cells and retained the exact desired-behavior labels under `implementationFindings`; their IDs are recorded in EP-9.
- EP-10 Shibuya findings: the retry/success counter gap is a documented mapping, not a bug; local `docs/findings/14-shibuya-retry-and-success-counters-are-indistinguishable.md` and owner `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-8` track the requested additive retry count. The transient handler readiness failure is separately tracked by `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-7`. The reproduced historical core, metrics and adapter failures below have owner dispositions. Startup cancellation still needs a clean historical reproduction or deterministic injection before an owner bug report; longer soaks may produce further findings.
- EP-10 duplicate-processor-ID finding: [local finding](../findings/18-shibuya-duplicate-processor-ids-drop-a-live-handle.md); owner `mori://shinzui/shibuya/okf/bug-reports/concepts/BUG-2`. The 0.9.0.3 application accepted two processors under one ID and lost one live handle; Hackage 0.10.0.0 rejects the duplicate before source pull.
- EP-10 nonpositive-concurrency finding: [local finding](../findings/19-shibuya-nonpositive-concurrency-removes-handler-bound.md); owner `mori://shinzui/shibuya/okf/bug-reports/concepts/BUG-3`. The 0.9.0.3 application accepted zero and negative limits, allowing concurrency above the configured bound; Hackage 0.10.0.0 passes the probe.
- EP-10 keyed worker failure finding: [local finding](../findings/20-shibuya-keyed-worker-failure-awaits-input-exhaustion.md); owner request `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-6`. The direct internal scheduler probe reproduces on 0.9.0.3 and passes on 0.10.0.0; owner REV-5 does not establish a public API contract breach.
- EP-10 idle-intake halt finding: [local finding](../findings/21-shibuya-halt-does-not-wake-idle-intake.md); owner `mori://shinzui/shibuya/okf/bug-reports/concepts/BUG-4`. The 0.9.0.3 application finalizes `AckHalt` but cannot wake idle nonserial intake; Hackage 0.10.0.0 controls pass.
- EP-10 finalizer-failure masking finding: [local finding](../findings/22-shibuya-exhausted-finalizer-is-reported-as-graceful-halt.md); owner `mori://shinzui/shibuya/okf/bug-reports/concepts/BUG-5`. The 0.9.0.3 application treats an exhausted finalizer as graceful completion under `StopAllOnFailure`; Hackage 0.10.0.0 passes the fail-loud probe.
- EP-10 blocking adapter-shutdown finding: [local finding](../findings/23-shibuya-blocking-adapter-shutdown-has-no-total-deadline.md); owner request `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-6`. The stronger total-deadline behavior passes on 0.10.0.0; owner REV-2 limits the older documented timeout to draining.
- EP-10 throwing adapter-shutdown finding: [local finding](../findings/24-shibuya-throwing-adapter-shutdown-skips-siblings.md); owner `mori://shinzui/shibuya/okf/bug-reports/concepts/BUG-6`. A throwing shutdown skips sibling signalling and cleanup on 0.9.0.3; Hackage 0.10.0.0 passes.
- EP-10 startup-cancellation evidence gap: [local finding](../findings/25-shibuya-startup-cancellation-historical-evidence-gap.md); owner review `mori://shinzui/shibuya/okf/reviews/concepts/REV-3` and request `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-6`. Source and one dirty run indicate a historical risk; the clean released revision-2 sweep passed, so a reproducible owner bug report remains open.
- EP-10 stale activity finding: [local finding](../findings/26-shibuya-stale-activity-marks-healthy-work-stuck.md); owner `mori://shinzui/shibuya/okf/bug-reports/concepts/BUG-7`. Healthy progress appears stuck and unready on 0.9.0.3; Hackage 0.10.0.0 passes.
- EP-10 terminal health finding: [local finding](../findings/27-shibuya-health-probes-ignore-terminal-lifecycle.md); owner `mori://shinzui/shibuya/okf/bug-reports/concepts/BUG-8`. The 0.9.0.3 health endpoints remain ready after worker failure and live after master stop; Hackage 0.10.0.0 passes.
- EP-10 WebSocket slot finding: [local finding](../findings/28-shibuya-websocket-disconnect-leaks-slots.md); owner `mori://shinzui/shibuya/okf/bug-reports/concepts/BUG-9`. Connection churn leaks a slot on metrics 0.9.0.3; Hackage 0.10.0.0 passes.
- EP-10 WebSocket flag finding: [local finding](../findings/29-shibuya-disabled-websocket-still-upgrades.md); owner `mori://shinzui/shibuya/okf/bug-reports/concepts/BUG-10`. Disabled upgrades are accepted on metrics 0.9.0.3; Hackage 0.10.0.0 passes.
- EP-10 WebSocket unsubscribe finding: [local finding](../findings/30-shibuya-websocket-unsubscribe-still-delivers-updates.md); owner `mori://shinzui/shibuya/okf/bug-reports/concepts/BUG-11`. Excluded updates continue on metrics 0.9.0.3; Hackage 0.10.0.0 passes.
- EP-10 PGMQ long-poll starvation finding: [local finding](../findings/15-shibuya-pgmq-long-poll-pool-starvation.md); upstream `mori://shinzui/shibuya-pgmq-adapter/okf/bug-reports/concepts/BUG-1`. Historical and current releases reproduce acknowledgement starvation when long polls occupy the shared pool.
- EP-10 forced-stop late-finalization finding: [local finding](../findings/17-shibuya-forced-stop-can-finalize-late.md); upstream `mori://shinzui/shibuya/okf/bug-reports/concepts/BUG-1`. Clean historical 0.9.0.3 (`runs/01a0e449-8bb4-746f-86ca-3be1b8aadd6a/run-result.json`) and current 0.10.0.0 (`runs/01a0e44b-aea0-7459-966a-150ea1340c27/run-result.json`) runs each left four handlers alive at stop return and finalized seven messages after the gate reopened, with all 30 messages eventually conserved.
- EP-10 Kiroku same-member duplicate-work finding: [local finding](../findings/16-shibuya-kiroku-same-member-duplicate-work.md); owner adapter request `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-17`, dependent on the lifetime store guard in `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-15`. Duplicate work is consistent with the documented at-least-once behavior and is an improvement request, not a bug report.
- EP-10 PGMQ acknowledgement-hook finding: [local finding](../findings/31-shibuya-pgmq-exhausted-acknowledgement-skips-hook.md); owner `mori://shinzui/shibuya-pgmq-adapter/okf/bug-reports/concepts/BUG-2`. Historical adapter 0.16.0.0 omits the failure hook after exhausted acknowledgement; published 0.16.1.0 passes on PostgreSQL 17 and 18.
- EP-10 PGMQ dead-letter duplicate finding: [local finding](../findings/32-shibuya-pgmq-dead-letter-retry-duplicates-copy.md); owner `mori://shinzui/shibuya-pgmq-adapter/okf/bug-reports/concepts/BUG-3`. Pinned historical 0.16.0.0 produced two and nine extra copies under backend faults; published 0.16.1.0 passes on PostgreSQL 17 and 18. Two later clean historical reruns did not trigger the timing-dependent defect.
- EP-10 Kiroku partial-group acquisition finding: [local finding](../findings/33-shibuya-kiroku-partial-group-acquisition-leaks.md); owner `mori://shinzui/kiroku/okf/bug-reports/concepts/BUG-4`. Historical 0.5.1.2 strands acquired members and replaces the primary exception; published 0.5.1.3 passes on PostgreSQL 17 and 18.

- EP-13 handler-call counter finding: [local finding 51](../findings/51-inbox-handler-counter-counts-an-unused-sequence.md); owner is this repository. The sequence start value falsely represented one invocation before handler entry. An initial-zero guard fails the old query in five table-backed controls; the repaired query and stronger rollback/recovery probes pass all seven durable arms. No upstream owner issue is added.

- EP-13 outbox broker finding: [local finding 52](../findings/52-outbox-best-effort-fixture-propagates-key-failures.md); owner is this repository. The terminal fixture applied key-ordered failure propagation under best-effort publishing. Policy-aware callback grouping repairs the mismatch; the isolated witness, four regressions and all sixteen durable controls pass. No upstream owner issue is added.

- EP-13 retry-budget oracle finding: [local finding 53](../findings/53-outbox-terminal-oracle-rejects-single-attempt-exhaustion.md); owner is this repository. A transient failure correctly ends dead when only one attempt is allowed. The repaired terminal oracle and independent replay accept that boundary and reject premature exhaustion at two attempts; sixteen policy/key/budget controls pass. No upstream owner issue is added.

- EP-13 terminal replay identity gap: [local finding 54](../findings/54-terminal-replay-accepts-duplicate-final-row-substitution.md); owner is this repository. The recomputer previously accepted a same-size final-row substitution. Exact final identity coverage and four policy-specific mutations now address that local gap; no upstream owner issue is added.
- EP-13 polling recovery gap: [local finding 55](../findings/55-polling-recovery-reuses-pre-fault-completions.md). Revision 3 now requires fresh work after every fault, including the last, and independently replays lifecycle and SQL coverage. Nineteen controls and the full verification gate pass their expected outcomes; short interruptions reproduce existing owner failures while explicit restart recovers after five long outages. Six clean polling investigations now have confirmed independent attestations, preserving four failures and two explicit-restart passes.

## Decision Log

- Decision: Maintain a dated technical baseline report during the initial
  released-cohort pass, with a final handoff only after child acceptance and
  selected evidence publication. Include the planned soaks, owner issue
  status, uncertainty, and priority without changing immutable run records.
  Rationale: The platform owner needs the as-is issue inventory to prioritize
  repairs now and a comparable reference set for a later fixed-cohort rerun.
  A working report must expose incomplete coverage and attestations rather
  than imply that this checkpoint is the final baseline.
  Date: 2026-09-29

- Decision: A scenario with independent confirmed owner defects may declare a group of scoped known defects, while a failure label outside every applicable entry remains blocking.
  Rationale: Kafka rebalance runs can reproduce both BUG-4's worker exit and BUG-6's ordering regression. The single-reference contract could not preserve both owners without misattribution; the grouped result and evidence record now do so. ADR-14 records the durable classification rule.
  Date: 2026-09-27

- Decision: Count distinct owner OKF bug-report and improvement-request URIs separately from numbered local findings. A filed or reused owner record is a reporting disposition, not a fix or a Kenshou verification of a fix.
  Rationale: Several scenarios can cite one owner issue, while one finding can cite a bug report and a complementary improvement request. Keeping both counts and the unmatched findings visible prevents duplicate filings and makes the baseline handoff measurable.
  Date: 2026-09-27

- Decision: Complete the initial released-cohort baseline and account for each finding with its existing or newly filed owner-repository OKF bug report, improvement request, or documented non-bug disposition. The respective projects own fixes; this MasterPlan resumes fix verification only when the platform owner asks to return to it.
  Rationale: Baseline evidence and correctly classified owner records are this initiative's current deliverables. The reporting workflow is already underway, so matching records are reused rather than filed again. Repair planning and implementation belong to the projects that own the runtime libraries. Deferring the rerun keeps the current acceptance work from silently expanding into a cross-repository repair program.
  Date: 2026-09-27
  Status: Fix verification moved to [MasterPlan 2](2-close-the-verification-and-repair-loop-for-the-keiro-runtime-in-rounds.md) on 2026-10-01. It runs the verification and repair loop in rounds; owner projects still own the repairs.

- Decision: Use PostgreSQL 18 as the sole database major for the first repair-and-rerun checkpoint; perform remaining PostgreSQL 17 compatibility acceptance in a later pass.
  Rationale: Repeating every fault and cohort matrix on both majors is slowing the feedback loop from a discovered defect to a verified fix. PostgreSQL 18 is the runtime's required major, and retaining 17 as a supported dimension preserves the broader suite without making it part of this checkpoint.
  Date: 2026-09-26
  Status: Superseded in part by the 2026-09-27 decision above. PostgreSQL 18 remains the focus for the initial baseline and reporting checkpoint; repair and rerun are deferred.

- Decision: File confirmed broken runtime behavior as an OKF `Bug Report` in the repository that owns it, with its exact affected version, replayable Kenshou steps and evidence, and the canonical Mori URI of this MasterPlan as `origin`. Track each finding in this repository and record the upstream bug concept's canonical Mori URI locally. Audit findings already discovered as well as future failures; reuse an existing equivalent report and keep hypotheses blocking until confirmed.
  Rationale: An improvement request describes desired work, while a bug report gives the owner a versioned, reproducible record of a broken provision claim. The source plan remains traceable without duplicating reports or hiding unrelated failures behind `KnownDefect`.
  Date: 2026-09-23

- Decision: Organise the repository as one cabal package per runtime layer, with correctness, concurrency, soak and benchmark as module subtrees and scenario tags, instead of the README's sketched top-level `correctness/`, `concurrency/`, `bench/` directories. EP-1 updates the README.
  Rationale: Isolating a failure to a component and selecting runs by what changed both need the layer to be the unit of build and selection.
  Date: 2026-09-20

- Decision: Group the work into nineteen child plans in five phases rather than forcing it into seven plans.
  Rationale: The initiative spans a harness, four toolkits, seven coverage areas, cloud infrastructure in another repository, and an evidence format in a third. Merging further would produce plans with more than five milestones across unrelated modules, which the ExecPlan specification warns against; the phases keep coordination tractable.
  Date: 2026-09-20

- Decision: Coverage plans hard-depend on the kernel and on all four toolkits.
  Rationale: Every coverage plan contains benchmarks, correctness checks, a leak-judged soak and both telemetry dimensions. Clean waves are worth more than the small amount of parallelism lost.
  Date: 2026-09-20

- Decision: Layer packages never import one another; only `kenshou-runtime` and `kenshou-cli` may depend on layer packages.
  Rationale: Keeps layers independently buildable, makes a red layer attributable, and lets five coverage plans proceed in parallel.
  Date: 2026-09-20

- Decision: Lift ideas and roughly five hundred lines from `kiroku-bench` (the delivery ledger, the writer loop, the mode taxonomy, the methodology rules) instead of depending on it; leave `keiro-benchmarks` untouched and adopt its IR-1 as the specification of the `list`/`run`/`compare` protocol.
  Rationale: Both are stale against the current cohort; the ledger design and the protocol specification are the durable value.
  Date: 2026-09-20

- Decision: Extend `load-testing-infra` in place (EP-16) rather than copying its NixOS modules and Pulumi components here.
  Rationale: Its own IR-1 requests the leased-cell model; the repository is generic by name and design; two copies would drift. The existing disposable characterization lane must keep working.
  Date: 2026-09-20

- Decision: After the in-flight EP-16 health-gate deployment, choose new implementation work from the EP-11 and EP-12 prerequisites of EP-15, then the assembled-runtime verification in EP-15. Record a concrete critical-path blocker before taking another EP-16 follow-up.
  Rationale: The dependency graph identifies EP-12 and EP-15 on the critical path, with EP-11 a hard prerequisite of EP-15; EP-16 is a separate integration lane. Recent work followed EP-16's remaining acceptance list from one adjacent item to the next while EP-15 stayed Not Started. This decision restores the plan's stated order.
  Date: 2026-09-29

- Decision: Evidence records in OKF carry identity, provenance, verdict and digest-pinned links to data in durable object storage; they never contain measurements. Include the OKF `Attested Computation` type for definitions, alongside new `Verification Run` and `Attestation` types.
  Rationale: Confirmed with the platform owner on 2026-09-20. okf by design stores definitions and not run artifacts; links plus digests keep the bundle small and the data attestable.
  Date: 2026-09-20

- Decision: Author the evidence corpus here against a local profile first (EP-18), then upstream the profile to `okf-profiles` (EP-19).
  Rationale: `okf-profiles` accepts only shapes observed in a real repository, and its ADR-6 names this as the right first move for the `Attested Computation` type.
  Date: 2026-09-20

- Decision: Stakeholder reports, `kotei` orchestration, fixes to runtime defects, keiki, keiro-dsl and online read-model rebuilds are out of scope.
  Rationale: Each is either explicitly deferred by the owner, owned by another repository, or large enough to be its own initiative.
  Date: 2026-09-20

- Decision: Child plans were drafted in parallel by separate agents from this MasterPlan and the research reports, then reviewed here for cross-plan consistency.
  Rationale: The master-plan skill recommends parallel drafting for five or more child plans; the Integration Points section is the contract that keeps them aligned.
  Date: 2026-09-20

- Decision: A known defect keeps the true outcome `failed`, is marked `blocking: false`, exits 0 unless `--strict-known-defects`, and carries a cohort scope evaluated against the resolved cohort identity.
  Rationale: Two drafts (shibuya and Kafka) independently needed "defect on released, must pass on head"; one declarative mechanism in the kernel is recorded in every run result and avoids per-layer workarounds. Keeping the true outcome satisfies the fixed outcome vocabulary.
  Date: 2026-09-20

- Decision: Every soak is two scenarios from one implementation, `<name>` (tier `soak`, placement `cell`) and `<name>-reduced` (tier `extended`, placement `either`).
  Rationale: A scenario has exactly one tier, and the owner requires that soaks be runnable locally at a reduced duration. All seven coverage drafts converged on double registration; only the suffix differed.
  Date: 2026-09-20

- Decision: The kernel's `PostgresEnv` exposes a key=value connection string, a TCP endpoint, stop/start/crash control and optional additional named servers; the run result carries the harness revision and dirty flag, a `comparisonKey` without the cohort and a `seriesKey` with it; comparisons accept a list of varying axes.
  Rationale: Each was required by a consuming draft (the correctness toolkit's proxy and crash injectors, kiroku's connection tagging, the two-context reference system, the evidence record, candidate-versus-baseline comparison, and telemetry overhead across two dimensions). Putting them in the owning plan keeps every shared type single-owner.
  Date: 2026-09-20

- Decision: The local Kafka-protocol broker is a private run-owned Redpanda 26.2.1 container; the cell broker is provisioned separately and passed as an external address. This supersedes the Apache Kafka child-process default drafted on 2026-09-20.
  Rationale: The owner approved Redpanda and the unfree `rpk` package, and supplied an Apple Container derivation. Isolated private containers started on both Apple Container and Docker. A cell has no internet egress, so its broker must already be provisioned. The run records the backend and broker version.
  Date: 2026-09-24

- Decision: EP-17, not EP-16, owns the translation from the cell's generic environment, health observations and fault hooks to kenshou's inputs.
  Rationale: The cell protocol must stay generic so that `load-testing-infra` can serve other projects; everything named `KENSHOU_*` belongs to this repository.
  Date: 2026-09-20

- Decision: Coverage plans may additively touch a short, enumerated list of shared places (registry registration, their schemas and policies, their layer guide, ADRs, system packages in `flake.module.nix`, and their own selectors in the component graph).
  Rationale: The original "three-line edit only" rule proved too strict for four drafts; enumerating the exceptions preserves single ownership of everything else.
  Date: 2026-09-20

- Decision: Treat the relevant `mori://shinzui/haskell-jitsurei` CLI documents as the interaction standard for `kenshou`, with EP-1 owning Git-aware release identity and EP-2 owning grouped parsers, embedded terminal-aware help, parser-derived completions, explicit standard-input document sources and output-channel discipline.
  Rationale: Nineteen plans grow one executable into a large human and machine interface. One early implementation and extension seam prevents divergent help, input and output conventions, while the selected patterns are directly useful to operators and automation. Hierarchical Dhall configuration is legacy in the catalog, and aliases, FZF, clipboard and agent commands add no value to a deterministic verification protocol, so they remain out of scope.
  Date: 2026-09-20

- Decision: Use `mori://shinzui/settei` for any persistent or layered operator configuration, with precedence built-ins < ordered strict-YAML files < explicitly bound environment variables < named flags; never use it as an ambient source of scenario knobs, dimensions, seeds, policies, or versioned documents.
  Rationale: Settei gives typed declarations, deterministic precedence, origin explanations and secret-safe diagnostics, removing ad hoc configuration code from the CLI. The boundary preserves the suite's central reproducibility guarantee: everything that can change the experiment is explicit in a versioned effective document before work starts.
  Date: 2026-09-20


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision. Before marking the MasterPlan complete,
distill durable project context from this MasterPlan and its child ExecPlans into
docs/adr/. Keep task-local execution and coordination details here.

- EP-10 now registers all five planned Shibuya benchmarks and the core batch-key soak pair, exposing 61 scenarios. The Kiroku benchmark's direct callback, ack-coupled stream and adapter controls passed locally, including four static group members with separate checkpoint evidence. Its paired local p99 result remains inconclusive, so no adapter latency budget is accepted before controlled cell calibration. The new soak has an eight-second wiring result only; duration verdicts, three more soak pairs, and the remaining telemetry and finding audits still govern EP-10 completion.

- EP-17 has a `kenshou-remote` package with file and GCS object stores. The file store fences create-only claims across processes and handles; the GCS adapter covers generation preconditions, pinned and atomic downloads, paged listing, server time, retries and 8 MiB resumable chunks. Credential selection checks an explicit token, VM metadata, then a cached `gcloud` token. The cell lease client adds exclusive claim, expiry and takeover, renewal, release, reattachment, cancellation, quarantine handling and a generation-fenced run sequence. All 15 owner cell schemas and examples are pinned and validate offline; typed codecs cover the main submission, execution, and result documents. One hundred focused remote examples and 32 CLI examples pass. Its payload descriptor covers the complete cell payload and Nix cohort identity, and clean released and head Linux closures are published by SHA-256 in GCS. Four matching-seed scenarios now pass locally and on `cell-alpha`: PostgreSQL round trip, worker IPC, a cell-environment probe, and Kiroku transaction correctness. Their parity reports have zero unexpected differences. The live probe wrote a descriptor-keyed capability cache identical to the verified nested fingerprint and found `pg_partman` available. `cell pair` interleaves arms under one lease, and the repaired alpha cell passed the default five-pair A/A control with ten verified cold resets, one lease, consecutive sequences, and five passing metrics. `cell overhead` now uses the telemetry planner with single-run submissions under one lease; a file-backed six-slot test verified links, one lease, consecutive manifest sequences, and resume without resubmission. A live six-slot alpha trial used the deployed OTLP file endpoint; all six nested benchmarks passed and verified, and analysis of three paired blocks passed after the comparison declared the cell-derived endpoint as a varying factor. The collector received spans, and three later verified SDK OTLP runs each sealed an exact-window metrics export with increasing accepted-span counters. A further three-slice file-sink trial sealed distinct per-run trace files with over 13,000 in-window spans each and no trace ID overlap. The operator guide and two cell ADRs are committed and pass strict ADR validation. The recorder now verifies and links the sealed outer cell manifest and applies the cell effective outcome; the attester rechecks that outcome while recomputing the nested scenario. A read-only live record linked the outer manifest, and direct GCS verification passed. Diagnostic payloads and the wider acceptance matrix remain open.

- EP-19 moved the observed three-type evidence contract into okf-profiles v0.19.0 and repointed this repository's bundle to its hash-pinned export. The shared contract keeps runtime-specific vocabularies open; the local overlay narrows them without editing historical evidence. ADR-18 now names the published contract, while the local evidence checker continues to verify storage and byte-level properties beyond the profile language.

- EP-1 established the reproducible repository foundation and the two contracts every later plan consumes: a package layout that isolates layer verification libraries, and a released/head runtime cohort whose resolved identity is stable and machine-checkable. The Cabal and Nix builds expose the same Git-aware CLI identity; every pinned runtime package links in one test component; and the live proof composes the keiro, kiroku, and pgmq migrations in one ledger, round-trips Kiroku and PGMQ data, and opens a librdkafka producer. The repository now has strict ADR governance, complete Mori dependency registration, a released-cohort CI gate, and a clean-clone `just verify` acceptance path. Commit `fa691b7` passed that path with 9 unit examples and 4 live link-proof examples. EP-2 can now add packages through the existing glob and extend the established CLI without revisiting bootstrap or cohort selection.

- EP-2 established the executable verification protocol consumed by every later child plan: validated layer bundles, scenario selection, typed knobs and dimensions, effective run documents, a real PostgreSQL 17/18 environment with one composed migration ledger, child-process worker roles, immutable evidence directories, canonical compatibility keys, and schema-validated results. Seven self-test scenarios exercise all outcomes, known defects, both PostgreSQL durability arms, and worker IPC. The completion gate is `just verify`: 29 core examples, 3 CLI examples, 4 runtime link-proof examples, strict ADR validation, golden/fresh schema validation, and the full self-test recipe all pass. EP-3, EP-4, and EP-5 are now unblocked against concrete kernel APIs rather than document-only contracts.

- EP-3 established the change-aware planning and resumable execution protocol. A checked component graph and cohort/Git change detectors select transitive dependents with machine-readable reasons; deterministic matrix expansion applies dimensions, knobs, trials, tiers and budgets; and five named suites encode common intentions. `kenshou execute` isolates runs in child processes, writes atomic plan summaries, preserves pre-assigned identities, and resumes interrupted entries with fresh UUIDv7 attempts after verifying the plan digest. Acceptance includes 51 core examples, 3 CLI examples, schema and graph checks, passing and failing real plans, and an interrupt/resume exercise. The run-plan and summary formats are now ready for EP-4's comparisons, EP-17's cell transport and EP-18's completeness checks.

- EP-5 established the independent correctness-evidence toolkit. `kenshou-check` contributes rotating per-incarnation ledgers, bounded external sorts, versioned verdicts, nine non-vacuous invariant folds, durable-truth SQL oracles, real process-group crash control, PostgreSQL and TCP fault injectors, virtual/database clock controls, seeded Hedgehog reports and a memoized linearizability search. Five registered self-tests exercise clean and doctored ledgers, `SIGKILL` restart, backend termination plus durable postmaster recovery, proxy latency/stall/blackhole/reset, and deterministic counter-example replay. Acceptance includes 33 package examples, live schema validation and the repository-wide `just verify` gate. ADR-8 distinguishes contract from implementation invariants; ADR-9 defines crashes as external process or backend termination.

- EP-6 established the memory-leak, concurrency-stall and bounded-profiling toolkit. Robust leak judgments cover Haskell heap after major collections, native memory, threads, descriptors and PostgreSQL resources; the watchdog combines labelled Haskell thread dumps, PostgreSQL wait graphs, pool observations and progress counters into actionable classifications. `kenshou diagnose` provides immutable offline analysis and four profiling modes, backed by schemas, golden output, all five exit-code paths and an end-to-end guide that resolves an info-table profile to `SelfTest/Leak.hs`. Seven real self-tests pass with PostgreSQL 18, all five database fixtures pass with PostgreSQL 17, each leak kind and the envelope fallback pass, and deliberately disabling either detector turns its fixture red. The repository-wide `just verify` gate passes with 32 diagnostics and 10 CLI examples in addition to the existing suites. ADR-10 fixes the major-GC heap basis; ADR-11 preserves sealed runs during offline diagnosis.


Revision note (2026-09-20): Updated the initiative and affected CLI plans to adopt the relevant `mori://shinzui/haskell-jitsurei` patterns. EP-1 now establishes Git-aware version identity; EP-2 owns grouped help, embedded terminal-aware topics, parser-derived completions, explicit stdin document inputs and stdout/stderr discipline; later command plans consume that seam. Legacy or interaction-heavy patterns that do not fit kenshou were explicitly excluded.

Revision note (2026-09-20): Added Settei 0.2.0.0 as the required implementation for layered operator configuration, while explicitly keeping experiment-defining inputs in versioned kenshou documents. Cascaded the configuration seam to the kernel, remote-cell client and evidence commands.

Revision note (2026-09-23): Defined the owner-repository OKF bug-report protocol for confirmed runtime failures, including exact affected versions, reproduction evidence and a canonical origin link to this MasterPlan. Added a local issue register that records each upstream bug concept's Mori URI, and a catch-up audit for findings already discovered while avoiding duplicate Keiro reports from the concurrent session.

Revision note (2026-09-23): Cascaded the catch-up audit into EP-8, EP-9 and EP-10 with explicit completion checks for report ownership, versioned reproduction, local Mori URI tracking and non-bug dispositions. Split the aggregate progress item by owning child plan so each audit remains visible until resolved.

Revision note (2026-09-24): Marked EP-14 in progress after its workflow, timer and shard scenario registration. Checked off the timer milestone because all six planned timer scenarios passed in both PostgreSQL durability modes; workflow, shard and benchmark/soak work remain active.

Revision note (2026-09-27): Made the baseline, owner-repository repair, and comparable rerun loop explicit across the initiative. Clarified that bug repairs belong in owning repositories and are verified here, resolving the earlier scope contradiction.

Revision note (2026-09-27): Corrected that wording after owner clarification. This MasterPlan fills the baseline and tracks owner-profile bug reports and improvement requests; each owning project separately plans and implements fixes. Post-fix verification here waits for a later request. Added deduplicated owner-issue counts and numbered-finding coverage to the register.

Revision note (2026-09-27): Extended the shared known-defect seam to preserve independent owner reports from one scenario, and applied it to Kafka rebalance classification without weakening new-failure blocking.

Revision note (2026-09-27): Recorded clean Kafka rebalance and stability-soak baselines, preserved their incomplete attestations, and narrowed VC-2 references to runs with a replayable measurement summary.

Revision note (2026-09-27): Resolved finding 16's owner-report gap with Kiroku IR-17, dependent on the existing lifetime member-guard request IR-15, and updated the distinct-issue register.

Revision note (2026-09-29): Added a dated technical baseline report and reconciled the issue register with five existing Keiro owner reports, the Kiroku publisher-leak duplicate disposition, and later Shibuya and adapter filings. Restored EP-13's soaks to the initial baseline scope. Excluded old PGMQ read/ack controls from baseline eligibility after correcting the timed operation in scenario revision 3; the new five-pair alpha A/A control passed, and the local slow-handler p50 sensitivity check reported regression.

Revision note (2026-09-29): Excluded the busy-host slow-handler ratios from the quantitative baseline pending a leased-cell sensitivity run. Added local harness finding 39 for a stale GCS CLI token that interrupted a layer-ladder cell A/A; journal recovery retained the evidence, but its cancelled slice and second lease make the comparison ineligible. Recorded the one-time token refresh repair and fresh single-lease rerun gate in EP-17.

Revision note (2026-09-29): The post-repair layer-ladder cell A/A completed all ten verified slices on one lease, but its five-pair p99 confidence interval remains inconclusive. Its initial comparison was produced from a documentation-dirty worktree, so the report awaits clean replay of those sealed runs; no policy limit was relaxed.

Revision note (2026-09-29): Clean replay of the layer-ladder run trees preserved the inconclusive p99 verdict. A separate five-pair invisible-backlog alpha A/A passed all four metrics. Clean cell execution reproduced Keiro's stale-outbox-claim BUG-5. A brokerless alpha Kafka run exposed local catalog finding 40 and is excluded from owner-defect evidence. The baseline report also marks 17 findings whose cited local runs are dirty-harness only; they need clean selection before immutable baseline recording.

Revision note (2026-09-29): Recorded the clean Keiro outbox cell run in the immutable OKF bundle. Its attestation passes five integrity and provenance checks but remains incomplete without a Keiro VC-1 oracle. Added local recorder finding 41 after cell base-URI rejection occurred after unrelated uploads; moved that validation ahead of writes and corrected the operator guide.

Revision note (2026-09-29): Excluded a grouped-read cell A/A that failed because its revision-2 benchmark raced sends and reads and ignored its declared workload controls. Local finding 42 tracks the corrected revision-3 preloaded drain and the pending fresh cell control; no owner runtime report or performance conclusion was drawn from the invalid slices.

Revision note (2026-09-29): Published three clean Keiro queue cell records. BUG-4 reproduced under long polling; the pool-isolation characterization passed while observing the BUG-6 saturation pattern; BUG-3 did not reproduce after five backend terminations and needs timing isolation. The remaining Keiro matrix and its unimplemented outbox, inbox, and queue soaks take precedence over PGMQ benchmark-control cleanup. A short grouped-read revision-3 smoke used an undersized preload, exhausted the queue, and is excluded from performance conclusions; the grouped A/A gate remains pending.

Revision note (2026-09-29): The corrected five-minute write-side cell replay verified the effective diagnosis window and passed every business check at 20 commands/second; its router leak signal remains associated with the existing Kiroku report. Registered EP-13's outbox table-growth soak pair and passed a functional local smoke, with process-isolated kills, controlled endurance runs, and the inbox and queue soak pairs still pending. A same-seed twenty-minute low-rate write-side control is running to classify the default-rate quiescence failure before filing any new owner issue.

Revision note (2026-09-29): The same-seed twenty-minute low-rate write-side control passed all ten business checks on a clean released-cohort cell. Its command-writer heap signal is finding 46, still unattributed pending writer-only isolation; a revised default-rate replay is running to classify the original timeout. EP-13's inbox dedupe-window soak pair is registered and passed its local functional smoke, with controlled runs pending. A reset failure before scenario execution is excluded from runtime conclusions.

Revision note (2026-09-29): The revised default-rate write-side replay again missed its fixed two-minute quiescence deadline; explicit transfer, bonus, and activity stage counts show substantial pending work, so finding 44 remains a throughput or drain-budget investigation rather than an owner data-loss report. EP-13 now registers all three planned soak pairs. The queue/DLQ pair passed short functional smokes with maintenance on and off; controlled duration, process-isolated worker diagnosis, and the wider non-soak matrix remain open.

Revision note (2026-09-29): Added finding 47 for an alpha driver guest termination and lease loss that cancelled the first outbox table-growth cell attempt before its nested run sealed. Partial verdicts are excluded; a same-seed longer-lease retry sealed and verified with all eight outbox business checks holding. The historical bundle now includes the revised default-rate write-side replay, which reproduces the quiescence deadline failure with explicit stage counts.

Revision note (2026-09-30): The clean five-minute inbox dedupe-window cell run sealed, verified, and was digest-linked. All eight business checks held across 621 fresh, early-redelivery, and late-redelivery deliveries; retention and relation-growth bounds held. Its heap verdict is inconclusive at five minutes, so the prepared twenty-minute reduced soak remains the resource gate. The historical bundle contains 33 records. A queue/DLQ cell smoke and outbox forced-major-GC control are queued behind this cell result.

Revision note (2026-09-30): The five-minute queue/DLQ cell smoke sealed, verified, and was digest-linked with all nine business checks holding over 1,551 jobs; the twenty-minute default-rate reduced run is underway. A second outbox cell run again passed all eight business checks and showed ten added Haskell threads after ten restarts. Finding 48 records that its requested forced-GC knob was silently dropped by the planner, so it is a same-seed repeat rather than a valid GC control. The planner now rejects pins absent from every selected scenario, and a no-restart control is prepared. The historical bundle contains 35 records; the issue register contains 48 classified findings.

Revision note (2026-09-30): EP-15 has started with the `kenshou-runtime` package's shop/warehouse message contracts, an independent order/fulfilment state oracle, and Keiki-backed order and fulfilment aggregates. Its eight domain and codec tests pass. This is only the domain foundation; the two-context process topology, business flows, and end-to-end cell evidence remain to be built.

Revision note (2026-09-30): The twenty-minute default-rate queue/DLQ cell run sealed, verified, and was digest-linked with all nine business checks holding over 6,051 jobs, including 303 archived terminal jobs. Main-table size was flat and DLQ growth stayed bounded. The overall verdict remained inconclusive without eligible post-major heap samples; no Keiro owner issue is inferred. The historical bundle contains 36 records. A twenty-minute inbox cell retry is underway. The three messaging soak pairs now declare an optional forced-major-GC diagnostic knob; its controlled runs will answer heap retention questions without supplying throughput comparisons.

Revision note (2026-09-30): The twenty-minute default-rate inbox dedupe-window soak passed on clean alpha and was verified and digest-linked. All eight business checks held over 2,421 fresh, early-redelivery, and late-redelivery messages; 40 eligible post-major heap points classified the main heap stable. The reduced default-rate inbox soak gate is satisfied. The historical bundle contains 37 records; the outbox no-restart control is running.

Revision note (2026-09-30): The clean five-minute outbox no-restart control passed all eight business checks over 621 messages, and Haskell threads stayed flat at 141, unlike the two matched ten-restart arms that each added ten. Heap data remained insufficient without major collections, and a revision-2 forced-GC control is underway. Finding 3 remains a harness-versus-Keiro attribution question. The historical bundle contains 38 records.

Revision note (2026-09-30): The valid revision-2 outbox forced-GC diagnostic sealed, verified, and was digest-linked. Its requested 5-second interval yielded 40 post-major heap points; all eight business checks held over 621 messages and ten restarts, and main Haskell threads stayed within 142–144. The heap interval remained inconclusive. Collection timing now appears relevant to finding 3, but ownership and a true leak remain unproven; a twenty-minute default-rate outbox run is underway. The historical bundle contains 39 records.

Revision note (2026-09-30): The twenty-minute default-rate outbox cell run sealed, verified, and was digest-linked. All eight business checks held over 24,202 messages and 20 publisher restarts, with a drained outbox and bounded sampled table growth. Main Haskell threads rose 142 to 157, so the overall outcome failed; no post-major heap points were eligible. Finding 3 remains a local harness-versus-Keiro attribution question. The historical bundle contains 40 records. The twenty-minute queue forced-major-GC diagnostic is running on alpha.

Revision note (2026-09-30): The matched twenty-minute queue forced-major-GC diagnostic sealed, verified, and was digest-linked. All nine business checks passed over 6,051 jobs, including 303 terminal archive rows. Forty-one post-major heap samples classified the main heap stable and Haskell threads remained at 140. This resolves the reduced queue soak's heap-data gap as a diagnostic control, without making its latency a default-rate baseline. The historical bundle contains 41 records. EP-15 added versioned Keiro outbox drafts and intake validation for the shop and warehouse wire messages, keyed by order ID; 18 focused package tests pass, while the two-context process system remains open. The full four-hour inbox soak has started on alpha.

Revision note (2026-09-30): EP-15 registered its first `runtime` scenario, a broker-backed public-wire smoke spanning both run-scoped topics. It passed a low-priority local functional run, with exact shop and warehouse messages and delivery coordinates; workstation timings are excluded from the baseline. This is an interface check, not the two-database order-flow acceptance. The full inbox four-hour cell run continues on alpha.

Revision note (2026-09-30): Replaced superseded Progress snapshots with the current nine-plan work inventory, concrete coverage/infrastructure/evidence constraints, and baseline handoff gates. Clarified that owner bug repairs do not block the initial released-cohort pass; post-fix verification remains a later requested pass. EP-13 now also records queue throughput worker/polling controls and five passing local business-check arms; controlled performance acceptance remains open. Registry statuses and dependency ownership are unchanged.

Revision note (2026-09-30): EP-13 now collects and serves native queue worker metrics using the existing released Shibuya and Keiro APIs, with no upstream changes or cohort pin changes. Eight durable local correctness arms passed, including active and complete endpoint values; four throughput integration controls held every business check. These dirty workstation runs are functional evidence only. Controlled performance comparisons, outbox/inbox serving, queue fault/pre-handler depth, and full soaks remain open; plan statuses and baseline evidence counts are unchanged.

Revision note (2026-09-30): Recovered the full inbox attempt as a verified outer infrastructure failure, finding 49. The agent journal confirms a wall-clock timeout after business verdicts and before nested finalization sealed. Partial verdicts do not satisfy the full-soak gate; the finding register now contains 49 observations, with runtime-owner report counts unchanged.

Revision note (2026-09-30): Recorded all ten clean queue-worker A/A arms as digest-linked investigations and preserved the raw control comparison in the dated report. Throughput, p50 and memory metrics passed; p99 remains inconclusive. The historical bundle contains 51 run records. Execution-shape and polling trials are still running, and no performance or full-soak acceptance gate is weakened.

Revision note (2026-09-30): EP-17 now budgets ten extra finalization minutes per soak, after finding 49’s timeout and a five-minute offline diagnosis replay. One four-hour soak has a bounded four-hour-fifteen-minute cap; benchmark limits and scenario business deadlines remain unchanged. The remote suite passes 107 examples, but the full inbox rerun gate is still open. This client change needs no infrastructure-owner or runtime-owner changes.

Revision note (2026-09-30): Completed and recorded the twenty clean queue configuration trials and two clean comparisons. Both comparison attestations confirm all six checks, including independent measurement and saved-policy recomputation. Worker allocation improved while p99 remained inconclusive; 100 ms long polling reduced allocation/live memory but increased handler-start latency. The historical bundle contains 73 run/comparison records, including three comparisons. A fresh same-seed four-hour inbox retry is running with a verified 15,300-second cap. All `just verify` targets passed across foundation and evidence phases. Owner issue counts, cohort pins, and full-soak gates are unchanged.

Revision note (2026-10-01 UTC): EP-13 queue throughput revision 4 implements standard/unlogged provision variation through the released API and checks all four queue/archive relations before and after load. Ten durable local arms held every business/provision check over 7,345 exactly-once jobs, with 264 artifact hashes and sizes verified. The 41-example Keiro suite and full `nix develop -c just verify` pass. A clean controlled storage comparison remains open. These exploratory runs do not change the 73 historical run/comparison records, cohort pins, owner findings, or full-soak acceptance.

Revision note (2026-10-01 UTC): Added clean EP-13 metrics comparisons and matched restart diagnostics, with 21 new digest-linked run/comparison records and three confirmed VC-2/VC-3 attestations. Serve/A/A p99 uncertainty and short-incarnation leak insufficiency remain explicit. The [dated report](../reports/2026-10-01-outbox-metrics-and-restart-controls.md) preserves all arms and limits; plan statuses remain unchanged.

Revision note (2026-10-01 UTC): Recorded fourteen clean EP-13 inbox matrix investigations at harness `b96c37f`, including two deliberate effect-oracle failures. All 202 schema and 216 artifact integrity checks pass; independent inbox VC-1 replay remains open. The historical bundle contains 113 run/comparison records. The full four-hour default-collection outbox soak is submitted on alpha, with its session and collection command in EP-13; no full-soak outcome is claimed.

Revision note (2026-10-01 UTC): EP-13 inbox matrix revision 3 adds raw intake observations and an independent VC-1 outcome replay. All ten table-backed local controls replay identically, including the two deliberate effect failures, with 212 schema and 226 integrity checks across fourteen runs. Older and delegated inbox records remain outside the verifier coverage; clean revision-3 attestation is pending. The full repository verification gate passes. The four-hour outbox cell sealed and verified: all eight business checks held over 288,202 unique messages and 240 restarts, while heap-sample insufficiency and thread-slope uncertainty keep resource acceptance inconclusive.

Revision note (2026-10-02 UTC): Recorded ten clean revision-3 inbox matrix runs and ten confirmed VC-1 attestations, preserving eight passes and two deliberate effect failures. The full outbox run is recorded as inconclusive with every business check held. Raw schema validation exposed finding 50: legacy shared/model verdict writers omit required counters. Source repairs and an emission guard preserve historical artifacts and keep formal full-soak acceptance open. The historical bundle has 124 run/comparison records; the four-hour queue/DLQ soak is active with its older-payload qualification recorded in EP-13. Owner report counts and child statuses remain unchanged.

Revision note (2026-10-02 UTC): Strengthened revision-4 delegated inbox expectations with independent frozen receipt identities, Unicode names and source-position fallback. Fourteen local controls meet their expected outcomes; table-backed revision-3 replay remains compatible with revision 4. Published the clean repaired Linux payload at `0eda7ac` for finding 50, and queued a same-seed full inbox rerun after the active queue soak is collected. The coordinator has not submitted that rerun yet. Child statuses and historical record counts remain unchanged.

Revision note (2026-10-02): EP-13 job-outcome revision 4 seals the remaining observations and independently replays all 43 drain/worker checks. Durable capture, mutation tests and full repository verification pass; the clean run is published with a confirmed independent VC-1 attestation. Historical incomplete attestations remain unchanged.

Revision note (2026-10-02): EP-13 expands FIFO ordering to four modes with worker-kill controls and independently replayed SQL spans. All eight durable controls and the full verification gate pass, with unordered inversions retained as explicit nonblocking observations. Clean publication and scripted retry/overlap coverage remain open.
