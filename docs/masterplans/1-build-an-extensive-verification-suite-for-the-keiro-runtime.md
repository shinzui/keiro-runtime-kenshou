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
---

# Build an extensive verification suite for the keiro runtime

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

The keiro runtime is not one package. It is a cohort of Haskell libraries that real services link together: `pgmq-hs` (a client for PGMQ, a message queue built on PostgreSQL tables), `kiroku` (a PostgreSQL event store), `shibuya` (a message-processing framework) with its adapters for PGMQ queues, the kiroku store and Kafka, and at the top `keiro` itself, which turns those pieces into a command processor, process managers, routers, durable execution (workflows and timers), an inbox, an outbox, and a job queue. The platform already runs in less critical microservices and is about to be rolled out to important ones. Each library has its own unit tests, but nothing anywhere exercises the runtime across packages, across operating-system processes, under real crashes, for hours at a time, or comparably across releases. This repository, `keiro-runtime-kenshou` (検証, "verification"), exists to produce that evidence.

When this initiative is complete, a maintainer can do the following from this repository. They can list every verification scenario, each identified by the layer it isolates (`pgmq`, `kiroku`, `shibuya`, `kafka`, `keiro`, or the assembled `runtime`), the component inside that layer, the kind of evidence it produces (`correctness`, `concurrency`, `soak`, or `benchmark`), and its cost tier. They can ask the tool which scenarios are worth running given what changed — a new kiroku release, a single keiro component, or an edit inside this repository — and receive a run plan that covers the changed component and everything built on top of it, and nothing else. They can turn knobs: every scenario declares the configuration variants of the component it exercises (ordering policies, batch sizes, pool sizes, retry policies, polling versus push wake-up, and so on), and two dimensions cut across every layer — whether OpenTelemetry tracing is enabled and whether the metrics endpoints are enabled — so that the overhead and the side effects of the observability stack are themselves measured. They can run correctness scenarios on a laptop or on Google Cloud Platform (GCP) with the same command, and run benchmarks and soaks on leased, controlled GCP machines so that results are not polluted by other workloads. When something goes wrong, the same harness is the base for diagnosis: a soak that leaks memory yields a leak verdict with the evidence series behind it, and a run that stalls yields Haskell thread dumps and a PostgreSQL lock graph captured at the moment of the stall. Finally, every recorded run leaves a small, immutable record in an OKF bundle (OKF, the Open Knowledge Format, is a directory of Markdown files with YAML frontmatter that the house tools `okf` and `mori` validate and index). The record names exactly what ran, against which revision of every runtime component, where, with which knobs, what the verdict was, and links by content digest to the raw data held in durable object storage; a separate attestation record states that a deterministic verifier re-checked that data. The bundle accumulates history so that a later initiative can generate stakeholder reports from it.

The executable is also a durable operator and automation interface, not merely a collection of parsers. Its human-facing discovery surface follows the current patterns in `mori://shinzui/haskell-jitsurei`: commands and options are grouped by user intent, long-form topics are embedded in the binary and wrap to a terminal-aware width without changing piped bytes, Bash/Zsh/Fish completions are derived from the actual `optparse-applicative` parser tree, and `--version` includes the build's Git revision. Document-valued inputs accept `-` explicitly for standard input, while machine-readable modes reserve standard output for the requested document and send diagnostics to standard error. Repeated operator defaults are resolved with `mori://shinzui/settei` from an explicit, inspectable source order; scenario knobs, dimensions, run specifications and run plans remain versioned evidence inputs rather than ambient configuration. These rules let a person discover a large command tree and let `kotei` call the same binary without scraping presentation text.

The scope boundary is deliberate. Included: the harness and its toolkits; isolated coverage for pgmq-hs, kiroku, shibuya and its three adapters, the Kafka transport, and every keiro component the platform owner named (command processor, process manager, router, durable execution, inbox, outbox, queue) together with the pieces they cannot be separated from (snapshots and projections with the command processor, timers and sharded subscriptions with durable execution); an assembled two-context reference system for end-to-end and soak runs; leased GCP verification cells built by extending the existing `load-testing-infra` repository; and the OKF evidence bundle plus the shared profile that governs it in `okf-profiles`.

Excluded: generating stakeholder reports (a future plan will consume the evidence bundle); orchestrating runs from a CI/CD system (the house CI platform `kotei` owns that under `mori://shinzui/kotei/okf/improvement-requests/concepts/IR-3`; this initiative only guarantees a machine-consumable command-line protocol for it to call); fixing defects that the suite finds in the runtime libraries (they are filed against the owning repository as bug reports or improvement requests, and the scenario that found them stays in the suite marked as a known defect); unit tests that belong inside a runtime package; verification of `keiki` (the pure state-machine library) and of the `keiro-dsl` toolchain; keiro's online versioned read-model rebuild machinery; and comparisons of kiroku against other event stores, which remain the business of `mori://shinzui/keiro-benchmarks`.


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
| 4 | Build the measurement toolkit for load, latency, sampling and comparison | docs/plans/4-build-the-measurement-toolkit-for-load-latency-sampling-and-comparison.md | EP-2 | None | In Progress |
| 5 | Build the correctness toolkit for ledgers, invariants, faults and process control | docs/plans/5-build-the-correctness-toolkit-for-ledgers-invariants-faults-and-process-control.md | EP-2 | None | Not Started |
| 6 | Build the diagnostics toolkit for memory leaks and concurrency stalls | docs/plans/6-build-the-diagnostics-toolkit-for-memory-leaks-and-concurrency-stalls.md | EP-2, EP-4 | EP-5 | Not Started |
| 7 | Add telemetry arms and measure observability overhead | docs/plans/7-add-telemetry-arms-and-measure-observability-overhead.md | EP-2, EP-4 | EP-6 | Not Started |
| 8 | Cover pgmq-hs in isolation | docs/plans/8-cover-pgmq-hs-in-isolation.md | EP-2, EP-4, EP-5, EP-6, EP-7 | EP-3 | Not Started |
| 9 | Cover kiroku in isolation | docs/plans/9-cover-kiroku-in-isolation.md | EP-2, EP-4, EP-5, EP-6, EP-7 | EP-3 | Not Started |
| 10 | Cover shibuya core and its PGMQ and kiroku adapters | docs/plans/10-cover-shibuya-core-and-its-pgmq-and-kiroku-adapters.md | EP-2, EP-4, EP-5, EP-6, EP-7 | EP-3, EP-8, EP-9 | Not Started |
| 11 | Cover the Kafka transport edge with a disposable broker | docs/plans/11-cover-the-kafka-transport-edge-with-a-disposable-broker.md | EP-2, EP-4, EP-5, EP-6, EP-7 | EP-3, EP-10 | Not Started |
| 12 | Cover the keiro command processor, process managers and routers | docs/plans/12-cover-the-keiro-command-processor-process-managers-and-routers.md | EP-2, EP-4, EP-5, EP-6, EP-7 | EP-3, EP-9 | Not Started |
| 13 | Cover the keiro outbox, inbox and job queue | docs/plans/13-cover-the-keiro-outbox-inbox-and-job-queue.md | EP-12 | EP-3, EP-8, EP-10 | Not Started |
| 14 | Cover keiro durable execution, timers and sharded subscriptions | docs/plans/14-cover-keiro-durable-execution-timers-and-sharded-subscriptions.md | EP-12 | EP-3, EP-9 | Not Started |
| 15 | Verify the assembled runtime end to end and under soak | docs/plans/15-verify-the-assembled-runtime-end-to-end-and-under-soak.md | EP-11, EP-12 | EP-3, EP-13, EP-14, EP-17 | Not Started |
| 16 | Provide leased verification cells in load-testing-infra | docs/plans/16-provide-leased-verification-cells-in-load-testing-infra.md | None | EP-2 | Not Started |
| 17 | Run kenshou on leased cells with payloads, submission and retrieval | docs/plans/17-run-kenshou-on-leased-cells-with-payloads-submission-and-retrieval.md | EP-2, EP-3, EP-4, EP-7, EP-16 | EP-5 | Not Started |
| 18 | Record runs and attestations in a historic OKF evidence bundle | docs/plans/18-record-runs-and-attestations-in-a-historic-okf-evidence-bundle.md | EP-2, EP-4 | EP-5, EP-16, EP-17 | Not Started |
| 19 | Publish the verification evidence profile in okf-profiles | docs/plans/19-publish-the-verification-evidence-profile-in-okf-profiles.md | EP-18 | None | Not Started |

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

Integration Point 3 — scenario identity, tags and registration. Owner: EP-2. A scenario identifier is the four-segment path `<layer>/<component>/<kind>/<name>`, for example `kiroku/append/concurrency/expected-version-race`. The layer is one of `selftest`, `pgmq`, `kiroku`, `shibuya`, `kafka`, `keiro`, `runtime`. The kind is one of `correctness`, `concurrency`, `soak`, `benchmark`. Each scenario also declares a cost tier — `smoke` (under one minute), `standard` (under ten minutes), `extended` (under one hour), `soak` (hours) — a placement (`local`, `cell`, or `either`), the knobs it accepts with their defaults and allowed values, the dimension values it supports, and optionally a known defect. A known defect names a reference (a `mori://` URI or upstream issue), the failure labels it explains, and a cohort scope (`appliesTo`, for example "only when `shibuya-core` was resolved from Hackage"), because many defects exist in the released cohort and are fixed at head. When the scope holds and every reported failure label is explained, the run keeps the true outcome `failed` but is marked `blocking: false` and `kenshou run` exits 0 (`--strict-known-defects` restores exit 1); when the scope does not hold, or a failure is not explained, the failure blocks as usual. "Known defect on released, must pass on head" therefore needs no second scenario. A scenario has exactly one tier, so every soak is registered twice from one implementation: `<name>` with tier `soak` and placement `cell`, and `<name>-reduced` with tier `extended` and placement `either`. Each layer package exports exactly one value, `bundle :: LayerBundle`, carrying its scenarios and its worker roles; several bundles may share the layer `selftest` (one per toolkit), and only scenario identifiers and role names must be unique across the registry. `kenshou-cli/src/Kenshou/Cli/Registry.hs` is the single list of bundles; a coverage plan registers itself by adding one import, one list element, and one `build-depends` entry in `kenshou-cli/kenshou-cli.cabal`. Beyond that three-line edit, a coverage plan may touch only these shared places, each additively: its own files under `schemas/` and `policies/`, its layer guide `docs/layers/<layer>.md`, new records in `docs/adr/`, system packages in `flake.module.nix` that its environment needs (EP-11's broker, for example), and the selectors of its own components in EP-3's component graph (`kenshou-core/data/`), after which `kenshou plan --graph-check` must report no orphan scenarios and no dead selectors. The vocabulary of component segments inside a layer is owned by that layer's plan.

Integration Point 4 — dimensions and knobs. Owner: EP-2 for the vocabulary, EP-7 for the telemetry behaviour. Dimensions are cross-cutting switches with closed value sets that every layer must honour. `telemetry.tracing` takes `off` (the library is handed no tracer, which for this runtime means `Nothing` or the no-op interpreter), `noop` (a tracer from a provider with no span processors), `sdk-inmemory` (the OpenTelemetry SDK with an in-memory exporter) and `sdk-otlp` (the SDK exporting over OTLP to a collector). `telemetry.metrics` takes `off`, `collect` (instruments and collectors are live in the process but nothing is served), `serve` (the HTTP endpoints are up: kiroku-metrics on its port, shibuya-metrics on its port, and whatever the layer exposes) and `serve-scraped` (the endpoints are also scraped by the harness at the run specification's scrape interval). `pg.durability` takes `fsync-off` (the ephemeral-pg default, fast, unrealistic) and `durable` (`fsync` and `synchronous_commit` on; mandatory for benchmarks and crash scenarios). `pg.version` takes `17` and `18`; keiro requires 18, kiroku supports both. Knobs, by contrast, are per-scenario typed parameters (`KnobSpec` with a name, a type, a default and allowed values) such as `kiroku.pool-size`, `outbox.ordering-policy` or `pgmq.visibility-timeout-seconds`; each coverage plan names its component's knobs after the configuration record fields they set. Scenarios declare which values they support, and not every value means something in every layer: pgmq-hs has no metrics endpoint, so its layer supports only `off` and `collect`; shibuya's in-process counters cannot be disabled, so `off` and `collect` behave identically there; keiro has no HTTP endpoint of its own, so `serve` for keiro means kiroku-metrics served over the workers' store; keiro's timer and shard workers accept no tracer, so their scenarios support `telemetry.tracing=off` only. On GCP the PostgreSQL major version is a property of the cell, so `pg.version` is satisfied by choosing which cell to lease. The registry refuses a `benchmark` scenario that needs PostgreSQL and claims to support `fsync-off`. A layer asks EP-7's `Kenshou.Telemetry.withTelemetry` for handles (`Maybe Tracer`, `Maybe Meter`, and a scrape registrar) and adapts them to its component — keiro's `Maybe KeiroMetrics`, kiroku's composed `eventHandler`, shibuya's `runTracing` versus `runTracingNoop`, pgmq-hs's `runPgmq` versus `runPgmqTraced`. Measurement never flows through the feature being toggled: latency and throughput are recorded in-process by EP-4 and written to files, so a run with every telemetry dimension `off` is still fully measured. EP-7 records this rule as an ADR.

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

Integration Point 7 — environments and the migrated database. Owner: EP-2. A scenario never opens a database by itself; it asks the kernel for a `PostgresEnv`, which is either an ephemeral server started with `ephemeral-pg` (honouring `pg.durability` and `pg.version`) or an external server named by a connection string in the run specification (the GCP case). The kernel migrates it with one `pg-migrate` plan composed from the components the scenario requests — kiroku (`Kiroku.Store.Migrations.kirokuMigrations`), keiro (`Keiro.Migrations.keiroMigrations`) and PGMQ (`Pgmq.Migration.pgmqMigrations`) — because all components must share one ledger and keiro's own `keiro-migrate` executable omits PGMQ. PGMQ is installed without the PostgreSQL extension by that migration, so no extension is needed — with one exception: PGMQ's partitioned queues need `pg_partman`, so EP-8's partitioned-queue scenarios probe for it and end `errored` with a remediation message where it is absent, and the environment fingerprint records whether it is present. Four properties of `PostgresEnv` are load-bearing for other plans: the connection string is in libpq key=value form so a layer can append `application_name` or keepalive options; an ephemeral server also listens on TCP and exposes that endpoint, so EP-5's fault proxy can sit in front of it; "PostgreSQL crashed" means an immediate-mode stop followed by a start on the same data directory and port, through `ServerControl`; and a scenario may require additional, independently restartable servers by name (`extraPostgres`), which only EP-15 uses. The Kafka broker fixture is the same idea for Kafka and is owned by EP-11 (`Kenshou.Env.Kafka`: a private, killable Kafka-protocol broker started for the run, or external brokers named by the run specification, with per-run topic and consumer-group prefixes and optional proxied listeners so one client can be partitioned from the broker). The pinned nixpkgs has no Redpanda server package, so the local default is Apache Kafka in KRaft mode run as a child process; on a cell the broker role is a digest-pinned Redpanda container. Both speak the Kafka protocol, and the fingerprint records which one served the run.

Integration Point 8 — worker roles and multi-process runs. Owner: EP-2 for the `WorkerRole` type and the `kenshou worker` dispatch, EP-5 for supervision. The runtime scales out by running more operating-system processes, and its crash guarantees are about `SIGKILL`, not about Haskell exceptions, so concurrency and crash scenarios run their workers as child processes of the same `kenshou` binary (one binary is also what makes cell deployment simple). A role is a named entry point registered in the layer's bundle. EP-5's `Kenshou.Check.Process` spawns roles, talks to them over a line-delimited JSON control channel, and delivers signals; EP-5's fault injectors act on PostgreSQL (terminating backends by `application_name`, restarting the postmaster of a durable fixture), on the network (an in-process TCP proxy that can add latency, stall, or reset connections), and on wake-ups (keiro's `neverWake` seam for keiro workers; for kiroku, whose notifier has no such seam, by disabling the notify triggers).

Integration Point 9 — the cell protocol. Owner: EP-16, in `mori://shinzui/load-testing-infra`; consumer: EP-17. A cell is a long-lived, named set of GCP machines (PostgreSQL, one or more drivers, optional Redpanda, monitoring with an OpenTelemetry collector) that is leased exclusively, reset deterministically, and given work at run time rather than baked into a machine image. The protocol is generic and knows nothing about kenshou: a submission is a content-addressed payload (a compressed `nix-store --export` bundle named by its SHA-256 and loaded with `nix-store --import`, because Nix has no released Google Cloud Storage store; plus an entry point), an opaque work file, and an output contract (the entry point is invoked with the work file and an output directory; whatever it writes there is published, immutably and with digests, under the submission's prefix in the cell's results bucket together with the cell's own fingerprint, reset evidence and health observations). There are two buckets: a mutable control bucket for leases, heartbeats and submissions, and a retention-locked results bucket that nothing can overwrite. A cell run identifier names one submission; for kenshou the work file is a run plan and the entry point is `kenshou cell exec`, a wrapper that reads the cell's environment file and then executes the plan, so one submission's output holds many kenshou run directories, and EP-17 defines how they nest and how `kenshou cell fetch` and `kenshou record` address one of them. A kenshou run directory is already sealed by its manifest when the cell publishes it, so cell facts that arrive later are never merged into `run-result.json`: the run carries `fingerprint.cell` captured at run time, and a derived `cell-run.json` beside the fetched tree carries each run's effective outcome after the cell's health gates. EP-16 in turn grants the run role the right to create databases (the kernel's external mode makes one fresh database per run), and publishes an optional generic fault hook, a measured clock-offset bound and the PostgreSQL extension inventory in its environment file and fingerprint. Additional named PostgreSQL servers degrade on a cell to separate databases on the cell's one server, so scenarios that need to restart one server independently stay `local`. EP-17 also owns the mapping from the cell's generic environment file, health observations and fault hooks to kenshou's inputs: the cohort identity and harness revision captured at payload build time, `KENSHOU_HEALTH_NOTICES` (EP-4's health gates), `KENSHOU_CELL_FAULT_HOOK` and `KENSHOU_CLOCK_SKEW_BOUND_MICROS` (EP-5's cell-only fault injectors and cross-machine ledgers), and the PostgreSQL and broker endpoints. Commits made in `load-testing-infra` under EP-16 reference this initiative as `mori://shinzui/keiro-runtime-kenshou/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime` and the child plan as `mori://shinzui/keiro-runtime-kenshou/plans/16-provide-leased-verification-cells-in-load-testing-infra`.

Integration Point 10 — the evidence bundle and its profile. Owner: EP-18 for the bundle and the local profile, EP-19 for the shared profile. The bundle lives at `docs/verification/` and is registered in `mori.dhall` as the OKF bundle `verification`, so a run record is addressable as `mori://shinzui/keiro-runtime-kenshou/okf/verification/concepts/<path>`. It holds three concept types. An `Attested Computation` (the OKF v0.2 type) defines how one verdict or headline figure is computed from raw data, which command runs it, and which deterministic verifier checks it. A `Verification Run` is an immutable event record: run identifier, scenario, kind, cohort components with their `mori://` URIs and exact revisions, environment fingerprint, knobs and dimensions, outcome, and a list of data links, each with a URI, a SHA-256 digest, a media type and a size. It contains no measurements; the data stays in durable object storage. An `Attestation` states that a named verifier at a named revision fetched the linked data, confirmed the digests, recomputed the verdict under a named computation, and what it concluded; the run's OKF `verified` list gains a machine entry at the same time, and a human sign-off is a `human:` entry. Baselines and trends are derived by readers and never stored. EP-18 develops the profile as a local Dhall descriptor beside the bundle; EP-19 moves it into `okf-profiles` as the export `assurance.verificationEvidence` and repoints the bundle at the published, hash-pinned version. Because the profile language cannot check digests, commit hashes or decimal numbers, EP-18 owns a repository-local check that does (`kenshou evidence check`). Three facts, verified against okf 0.9.0.0 while drafting, constrain the design. A committed corpus is immutable, so field and type names are frozen from the first recorded run (`computationId` with handle prefix `VC`; the discriminator `recordKind` with values `run` and `comparison`) and the shared profile may later relax rules but never rename. A closed-type profile rejects any Markdown file it has no type for, so the executor and attester resources of an `Attested Computation` are non-Markdown files under `references/`. And the vocabularies that are specific to this runtime (`layer`, `tier`) stay open in the shared profile and are re-closed here, so the final `docs/verification/profile.dhall` is the published import plus a local overlay, bound in `mori.dhall` as a derived profile.

The following cross-plan decisions should become ADRs in `docs/adr/` when the owning plan implements them: layer packages never import one another (EP-1); every result carries a resolved cohort identity, and released and head cohorts are both first-class (EP-1); results are recorded through a channel independent of the feature under test (EP-7, with EP-4); crash means `SIGKILL` of a process or termination of a backend, never a thrown exception (EP-5); invariants are labelled as contract invariants or implementation invariants, and only the former block a release (EP-5, first exercised by EP-9's gapless-position check); leak verdicts are judged on live bytes after major garbage collections, not on resident memory, with a separate lower-confidence native-memory probe for leaks the Haskell heap cannot see (EP-6); what "selected because it changed" means — changed components plus transitive dependents over build and declared run-time edges, with the reason recorded (EP-3); GCP infrastructure is extended in `load-testing-infra` rather than copied (EP-16); the Nix-built payload pins the cohort with a local overlay and refuses to run unless the identity it resolved equals the cabal-resolved identity, because the shared `haskell-nix` lock lags the cohort and strips version bounds (EP-17); evidence records are immutable events that link to data and never contain it, and baselines are derived, not stored (EP-18); and this repository, not `keiro-benchmarks`, owns the runtime-facing benchmark protocol (EP-2, with EP-4).


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan and the milestone.

- [x] EP-1: Scaffold the repository, development shell and formatting hooks
- [x] EP-1: Pin the released and head cohorts, print the resolved cohort identity, and establish Git-aware CLI release identity
- [x] EP-1: Prove the whole cohort links and migrates in one build
- [x] EP-1: Adopt the ADR bundle, update mori.dhall and the README, add CI
- [x] EP-2: Scenario model, layer bundles, registry, `kenshou list`, the shared CLI discovery surface, and the Settei configuration seam
- [x] EP-2: Dimensions, knobs and the run specification
- [x] EP-2: Environments, the composed migration plan and worker roles
- [x] EP-2: The runner, the run directory, the manifest and exit codes
- [x] EP-2: Published JSON Schemas, golden fixtures and the self-test scenarios
- [x] EP-3: The component graph of the runtime
- [x] EP-3: Change detection from cohort diffs, named components and repository paths
- [x] EP-3: Matrix expansion, tier budgets and `kenshou plan`
- [x] EP-3: Named suites and resumable `kenshou execute`
- [ ] EP-4: Clocks, the latency recorder and warm-up exclusion
- [ ] EP-4: Closed-loop and open-loop load generators
- [ ] EP-4: Runtime, process and PostgreSQL samplers
- [ ] EP-4: Summaries and paired comparison with verdicts
- [ ] EP-4: Health gates that separate infrastructure trouble from regressions
- [ ] EP-5: The bounded ledger and the verdict document
- [ ] EP-5: The invariant checker library
- [ ] EP-5: Process control for worker roles
- [ ] EP-5: PostgreSQL, network and wake-up fault injectors
- [ ] EP-5: Model-based testing support with replayable seeds
- [ ] EP-6: The leak verdict over sampled series
- [ ] EP-6: The stall watchdog with thread dumps and lock graphs
- [ ] EP-6: Profiling build variants and bounded event logs
- [ ] EP-6: `kenshou diagnose` recipes and the diagnosis guide
- [ ] EP-6: Seeded leak and deadlock self-tests that prove the detectors fire
- [ ] EP-7: Tracing arms
- [ ] EP-7: Metrics arms and the harness scraper
- [ ] EP-7: The paired overhead protocol and `kenshou overhead`
- [ ] EP-7: Detectors for telemetry-induced problems
- [ ] EP-8: pgmq-hs correctness scenarios
- [ ] EP-8: pgmq-hs concurrency and crash scenarios
- [ ] EP-8: pgmq-hs benchmarks
- [ ] EP-8: pgmq-hs soak and telemetry arms
- [ ] EP-9: kiroku correctness scenarios
- [ ] EP-9: kiroku concurrency, crash and known-defect scenarios
- [ ] EP-9: kiroku benchmarks lifted from kiroku-bench
- [ ] EP-9: kiroku soak and telemetry arms
- [ ] EP-10: shibuya core lifecycle, ordering, batching and metrics-truthfulness scenarios
- [ ] EP-10: PGMQ adapter scenarios
- [ ] EP-10: kiroku adapter scenarios
- [ ] EP-10: shibuya benchmarks, soak and telemetry arms
- [ ] EP-11: The disposable broker fixture
- [ ] EP-11: Kafka adapter correctness and rebalance scenarios, with the producer path and keiro's record conversions
- [ ] EP-11: Kafka crash, outage and model-based scenarios
- [ ] EP-11: Kafka benchmarks, soak and telemetry arms
- [ ] EP-12: The keiro fixture domain
- [ ] EP-12: Command processor scenarios with snapshots and projections
- [ ] EP-12: Process manager scenarios
- [ ] EP-12: Router scenarios
- [ ] EP-12: Write-side benchmarks, soak and telemetry arms
- [ ] EP-13: Outbox scenarios
- [ ] EP-13: Inbox scenarios
- [ ] EP-13: Job queue scenarios
- [ ] EP-13: Messaging benchmarks, soak and telemetry arms
- [ ] EP-14: Durable workflow scenarios
- [ ] EP-14: Timer scenarios
- [ ] EP-14: Sharded subscription scenarios
- [ ] EP-14: Durable-execution benchmarks, soak and telemetry arms
- [ ] EP-15: The two-context reference system
- [ ] EP-15: End-to-end correctness invariants
- [ ] EP-15: The whole-runtime failure matrix
- [ ] EP-15: Gated soaks of one, four and twenty-four hours
- [ ] EP-15: End-to-end benchmarks and whole-system telemetry overhead
- [ ] EP-16: A parameterised, multi-instance cell stack
- [ ] EP-16: The generic cell agent and run-time payload delivery
- [ ] EP-16: Leases, deterministic reset and health gates
- [ ] EP-16: The immutable results bucket and artifact manifest
- [ ] EP-16: Broker and collector roles, with the disposable lane still working
- [ ] EP-17: The content-addressed kenshou payload
- [ ] EP-17: `kenshou cell` lease, submit, watch and fetch
- [ ] EP-17: Paired comparisons inside one lease
- [ ] EP-17: Proof that one correctness scenario passes identically locally and on a cell
- [ ] EP-18: The bundle, the local profile and the first computation definitions
- [ ] EP-18: `kenshou record` and the digest and revision check
- [ ] EP-18: `kenshou attest` and the verified trail
- [ ] EP-18: `kenshou history`, validation gates and the seeded corpus
- [ ] EP-19: The improvement request and the profile with its fixtures
- [ ] EP-19: Generated documentation, the amended ADR and the release
- [ ] EP-19: Repointing the bundle at the published profile


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

Research before decomposition surfaced facts that every child plan author should know.

- `keiro-benchmarks` does not benchmark keiro. Its single executable compares Message DB with kiroku appends, pins nothing, and would fail at run time against kiroku-store 0.8 because it expects `withStore` to create the schema. Evidence: `/Users/shinzui/Keikaku/bokuno/keiro-benchmarks/app/Main.hs` and its own improvement request's non-goals.
- The workload binaries that `load-testing-infra` deploys live in a third repository, `kiroku-bench`, which is not registered in Mori, is pinned to kiroku-store 0.2.0.0, and has a disabled shibuya executable and a conflict mode that produces zero appends.
- Most of keiro bypasses shibuya's runner: process-manager and router workers drain an adapter's stream serially and finalize acknowledgements themselves, and keiro reads kiroku through `subscriptionAckStream` directly. Only `keiro-pgmq` calls `Shibuya.App.runApp`. Shibuya's guarantees therefore have to be verified at the shibuya layer and cannot be assumed of keiro's workers.
- Two different shibuya-cores exist: Hackage 0.9.0.3, which keiro resolves, and an unreleased repository head with a breaking lifecycle fix. Several known defects reproduce only on the released version. The cohort mechanism exists for exactly this.
- Every existing suite in the runtime runs PostgreSQL with `fsync=off`, as superuser, under the C locale, inside one process; "crash" means a thrown exception or `killThread`. keiro's own MasterPlan 22 (`mori://shinzui/keiro/masterplans/22-make-the-test-infrastructure-exercise-real-crash-and-production-semantics`, not yet resolvable through Mori) planned real crash tests and never started them.
- The dominant benchmark noise source recorded by `load-testing-infra` was PostgreSQL checkpoints (one roughly 270-second checkpoint per 600-second window, giving plus or minus twenty percent run to run), not GHC and not GCP. Paired, interleaved runs inside one lease are the remedy, not longer single runs.
- The metrics endpoint was load-bearing for measurement in the old harness, which would make a "metrics off" arm impossible. This is the origin of the rule in Integration Point 4.
- `hasql-opentelemetry` and `servant-health` are not part of the runtime cohort, and `hasql-opentelemetry` cannot link with it (it bounds `hs-opentelemetry-api` below 0.4 while the cohort requires 1.0). The metrics endpoints to evaluate are kiroku-metrics (default port 9091) and shibuya-metrics (default port 9090); keiro itself exposes OpenTelemetry instruments and no HTTP endpoint.
- okf stores definitions, never run artifacts, and the profile language cannot validate decimal numbers, digests or commit hashes. This is why the evidence design uses links plus a repository-local check.

Drafting the child plans against real source corrected the research in ways that cross plan boundaries. Each child plan records its own findings; these are the ones more than one plan depends on.

- The duplicate window after a crash is not always bounded by the subscription `batchSize` (100). A live, non-group `$all` kiroku subscription is fed by the shared publisher in batches of up to `publisherBatchSize = 1000` and checkpoints only at the batch tail, so its budget is 1000. EP-9 and EP-10 encode a per-path budget; any plan that asserts a duplicate bound must name the delivery path.
- The cohort as first listed did not resolve: published `keiro-test-support` 0.17.0.0 bounds `ephemeral-pg` below 0.3 (the research read keiro's unreleased working tree). EP-1 resolved both cohorts in a dry run with one package-qualified `allow-newer`. `kiroku-cli` must also be pinned because `kiroku-metrics` links it.
- Released and head `shibuya-core` both report version 0.9.0.3, so neither version bounds nor the C preprocessor can tell them apart. This is why a known defect's cohort scope is expressed by where a package was resolved from, and why layer code must compile unchanged against every cohort.
- The pinned nixpkgs has no Redpanda server package and the Seihou Redpanda option is macOS-only, so the local broker is Apache Kafka in KRaft mode; on cells Redpanda runs as a digest-pinned container inside the machine image, because cell machines have no internet egress.
- Nix has no released Google Cloud Storage store, so payloads travel as `nix-store --export` bundles; and a retention-locked results bucket cannot hold lease heartbeats, so the cell has a second, mutable control bucket.
- `ephemeral-pg` 0.3.1.0 restarts a server from its default configuration rather than the original one, and listens on a Unix socket unless told otherwise; the kernel therefore owns re-applying settings across a restart and enabling a TCP listener for the fault proxy.
- The `haskell-nix` revision the Seihou flake module pins locks keiro 0.16 and kiroku-store 0.8.0.0 with version bounds stripped, so a Nix build does not reproduce the cabal cohort by itself; EP-17's payload therefore uses a local cohort overlay plus an identity gate, and the solver plan hash is undefined under Nix (the cohort identity gains an optional resolver member).
- The cell's PostgreSQL role as first drafted could not create databases and was trusted on one database only, while the kernel's external mode creates one fresh database per run; EP-16 now grants `CREATEDB` and subnet-wide access and its reset drops every database the role owns.
- A scenario has one tier but every soak must run both locally and on a cell; all coverage plans converged on registering each soak twice, and the suffix was normalised to `-reduced`.
- okf 0.9.0.0 rejects any Markdown file a closed-type profile has no type for (so `references/` targets are non-Markdown), always permits core keys such as `status`, and its YAML reader turns an unquoted `off` into `false` and a digest made of digits and the letter e into a number, so the evidence writer must quote scalars.
- keiro's workflow and shard leases are judged by the worker's clock, while the crash backoff is written with the database clock and compared with the worker's; and the keiro timer and shard worker APIs accept no tracer. Both shape what the durable-execution scenarios can assert.
- Reading source for the coverage plans surfaced suspected defects that no upstream document records yet, each encoded as a probe scenario rather than asserted: a child workflow's completion and its parent's wake are separate transactions; `ensureShards` commits mismatched rows before throwing; outbox finalization is not fenced against a re-claim by another publisher; router dead-letter rows are unique on a positional index while dispatch identity is keyed by target; with the Kafka adapter's required background poll mode a halted consumer is never evicted after `max.poll.interval.ms`; and storing an offset on a revoked partition can kill a healthy consumer. Confirmed ones are to be filed against the owning repository, per the scope boundary.
- Mori exposes `shinzui/haskell-jitsurei` as the active CLI pattern catalog and shows it adopted by existing house tools. Its current catalog requires `optparse-applicative` 0.19 for option groups, uses `file-embed` for topics, uses `terminal-size` rather than `ansi-terminal` for non-blocking ioctl width detection, derives completions from the parser tree, and treats hierarchical Dhall configuration as legacy. Hackage on 2026-09-20 lists `githash` 0.1.7.0, `file-embed` 0.0.16.0 and `terminal-size` 0.3.4; upstream tags confirm `githash-0.1.7.0` and `terminal-size` 0.3.4, while `file-embed`'s upstream tag list stops at 0.0.15.0, so EP-1 must record the Hackage-versus-tag discrepancy when it refreshes and pins harness dependencies.
- Mori exposes `shinzui/settei` as the house typed, layered, provenance-aware configuration family. Hackage on 2026-09-20 lists 0.2.0.0 as the latest release of `settei`, `settei-env`, `settei-optparse-applicative`, and `settei-yaml`, and upstream has the matching annotated `v0.2.0.0` tag. Its reference CLI uses built-ins below ordered files below explicit environment bindings below named CLI sources, preserves shadowed origins, redacts secret settings, and reserves stdout for requested JSON. That model fits operator defaults but not run-defining evidence, which must be frozen into kenshou documents.
- EP-3's checked graph contains 26 whole components, 15 sub-components and 65 edges after reconciliation with Cabal's real solver plan. The important cross-plan consequence is that later coverage plans can add scenarios without changing planner code: they register a bundle and keep their owned component selectors current. The executor also proved that an interrupted attempt can remain immutable while a resumed attempt receives a fresh UUIDv7, which is the identity behavior EP-17 and EP-18 consume.


## Decision Log

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

- Decision: The local Kafka-protocol broker is Apache Kafka in KRaft mode as a child process; the cell broker is a digest-pinned Redpanda container.
  Rationale: nixpkgs carries no Redpanda server, and cell machines have no internet egress. Both speak the Kafka protocol and the fingerprint records which served a run.
  Date: 2026-09-20

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

- EP-1 established the reproducible repository foundation and the two contracts every later plan consumes: a package layout that isolates layer verification libraries, and a released/head runtime cohort whose resolved identity is stable and machine-checkable. The Cabal and Nix builds expose the same Git-aware CLI identity; every pinned runtime package links in one test component; and the live proof composes the keiro, kiroku, and pgmq migrations in one ledger, round-trips Kiroku and PGMQ data, and opens a librdkafka producer. The repository now has strict ADR governance, complete Mori dependency registration, a released-cohort CI gate, and a clean-clone `just verify` acceptance path. Commit `fa691b7` passed that path with 9 unit examples and 4 live link-proof examples. EP-2 can now add packages through the existing glob and extend the established CLI without revisiting bootstrap or cohort selection.

- EP-2 established the executable verification protocol consumed by every later child plan: validated layer bundles, scenario selection, typed knobs and dimensions, effective run documents, a real PostgreSQL 17/18 environment with one composed migration ledger, child-process worker roles, immutable evidence directories, canonical compatibility keys, and schema-validated results. Seven self-test scenarios exercise all outcomes, known defects, both PostgreSQL durability arms, and worker IPC. The completion gate is `just verify`: 29 core examples, 3 CLI examples, 4 runtime link-proof examples, strict ADR validation, golden/fresh schema validation, and the full self-test recipe all pass. EP-3, EP-4, and EP-5 are now unblocked against concrete kernel APIs rather than document-only contracts.

- EP-3 established the change-aware planning and resumable execution protocol. A checked component graph and cohort/Git change detectors select transitive dependents with machine-readable reasons; deterministic matrix expansion applies dimensions, knobs, trials, tiers and budgets; and five named suites encode common intentions. `kenshou execute` isolates runs in child processes, writes atomic plan summaries, preserves pre-assigned identities, and resumes interrupted entries with fresh UUIDv7 attempts after verifying the plan digest. Acceptance includes 51 core examples, 3 CLI examples, schema and graph checks, passing and failing real plans, and an interrupt/resume exercise. The run-plan and summary formats are now ready for EP-4's comparisons, EP-17's cell transport and EP-18's completeness checks.


Revision note (2026-09-20): Updated the initiative and affected CLI plans to adopt the relevant `mori://shinzui/haskell-jitsurei` patterns. EP-1 now establishes Git-aware version identity; EP-2 owns grouped help, embedded terminal-aware topics, parser-derived completions, explicit stdin document inputs and stdout/stderr discipline; later command plans consume that seam. Legacy or interaction-heavy patterns that do not fit kenshou were explicitly excluded.

Revision note (2026-09-20): Added Settei 0.2.0.0 as the required implementation for layered operator configuration, while explicitly keeping experiment-defining inputs in versioned kenshou documents. Cascaded the configuration seam to the kernel, remote-cell client and evidence commands.
