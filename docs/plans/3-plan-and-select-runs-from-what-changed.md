---
id: 3
slug: plan-and-select-runs-from-what-changed
title: "Plan and select runs from what changed"
kind: exec-plan
created_at: 2026-09-20T17:15:35Z
intention: "intention_01m2zvy0gje40tdsdragvzr3tq"
master_plan: "docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-20T17:15:35Z
---

# Plan and select runs from what changed

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

The verification suite in this repository will eventually hold hundreds of scenarios across six layers of the keiro runtime, some of which take hours. The platform owner's requirement is blunt: "turn on different knobs and run only a subset based on what changed, since running everything all the time is very time-consuming." This plan delivers that. After it, a maintainer can tell the `kenshou` executable what changed — two cohort descriptors (for example the released pins against the unreleased heads), a list of component names, a git revision of this repository, or a revision range inside an upstream repository such as keiro — and receive a run plan: an ordered JSON document of complete run specifications that covers the changed components and everything built on top of them, and nothing else, with the reason for every inclusion written next to it. The same command expands the matrix: it turns the cross-cutting dimensions (tracing, metrics, PostgreSQL durability and version) and each scenario's knobs into concrete runs under a named policy, repeats benchmarks as interleaved trials, filters by cost tier, evidence kind and placement, and trims the result to a time budget. A second command executes a run plan sequentially, one child process per run, can be interrupted and resumed, and ends with one summary document and one exit code that a script or the house CI platform can branch on.

To see it working after the last milestone, run the following from the repository root inside the Nix development shell. The first command plans what a kiroku upgrade deserves, the second runs the always-available self-test scenarios through the executor.

```bash
cabal run kenshou -- plan --suite change --changed kiroku-store --explain --catalog kenshou-core/test/fixtures/plan/catalog-planned.json
cabal run kenshou -- plan --all --select 'selftest/kernel/**' --out /tmp/kenshou-demo/plan.json
cabal run kenshou -- execute --plan /tmp/kenshou-demo/plan.json --out /tmp/kenshou-demo/results; echo "exit=$?"
```

The first prints the changed component, every dependent component with the dependency path that reached it, and the selected scenarios; nothing under `pgmq/` or `kafka/` appears. The `--catalog` option makes it plan against a checked-in description of the scenarios the coverage plans intend to write, because when this plan is implemented only the `selftest` layer is linked into the binary; once the coverage plans land, the same command without `--catalog` plans against the real registry. The last command prints `exit=1`, because the self-test bundle deliberately contains a failing scenario, and leaves `/tmp/kenshou-demo/results/plan-summary.json` naming the worst outcome as `failed`.


## Progress

Milestone 1 — The component graph of the runtime

- [ ] Confirm the prerequisites from `docs/plans/1-…` and `docs/plans/2-…` (build, `kenshou list`, self-test scenarios, `docs/adr/profile.dhall`) and record the real EP-2 type and function names in Surprises & Discoveries.
- [ ] Add `Kenshou.Plan.Selector` (selector grammar, parser, matcher) with unit tests.
- [ ] Add `Kenshou.Plan.Catalog` (`ScenarioInfo`, projection from `Scenario`, decoder for `kenshou list --json`) and the fixture catalog `kenshou-core/test/fixtures/plan/catalog-planned.json`.
- [ ] Write `kenshou-core/data/components.json` and `schemas/component-graph.v1.schema.json`; embed the file in `Kenshou.Plan.Components`.
- [ ] Implement graph validation (unknown references, acyclicity, duplicate packages) and the dependents closure with shortest paths; unit tests including the two acceptance selections.
- [ ] Implement `Kenshou.Plan.Components.Check`: drift check against `dist-newstyle/cache/plan.json` and lint against a catalog.
- [ ] Add `kenshou plan --graph-show` and `kenshou plan --graph-check`; reconcile the `kenshou-harness` edges with what the check reports.

Milestone 2 — Change detection from cohort diffs, named components and repository paths

- [ ] Add `Kenshou.Plan.Change` (change records, union, selection with reasons).
- [ ] Add `Kenshou.Plan.Change.Cohort` (normalise two `kenshou.cohort/v1` descriptors to package maps and diff them).
- [ ] Add `Kenshou.Plan.Change.Git` (`--since` path mapping including the automatic cohort-file diff, and `--upstream-diff`).
- [ ] Wire `--changed`, `--cohort-from/--cohort-to`, `--since`, `--upstream-diff`, `--all`, `--select`, `--exclude`, `--catalog`, `--graph` and `--explain` into `kenshou plan`.
- [ ] Unit tests with a temporary git repository and descriptor fixtures; the five acceptance selections pass.

Milestone 3 — Matrix expansion, tier budgets and `kenshou plan`

- [ ] Add `Kenshou.Plan.Policy` and `Kenshou.Plan.Matrix` (four dimension policies, two knob policies, pinned values, benchmark durability rule, pairwise generator) with property tests.
- [ ] Add `Kenshou.Plan.RunPlan` (document types, ordering, trials, seeds, estimates, budget, skipped list) and `schemas/run-plan.v1.schema.json` with a golden fixture.
- [ ] Make `kenshou plan` emit `kenshou.run-plan/v1` to `--out` or standard output; validate every generated run specification with EP-2's validator.
- [ ] Record the ADR for change-based selection.

Milestone 4 — Named suites and resumable `kenshou execute`

- [ ] Add `Kenshou.Plan.Suite`, `schemas/suite.v1.schema.json` and the five files in `suites/`; unit test that every checked-in suite parses and plans.
- [ ] Add `Kenshou.Plan.Summary` and `Kenshou.Plan.Execute` (child process per run, atomic summary, lock file, `--resume`, `--fail-fast`, `--environment`, opt-in timeout) and `schemas/plan-summary.v1.schema.json`.
- [ ] Add `kenshou execute`; if `kenshou run` cannot take a run identifier, add `--run-id` to it.
- [ ] End-to-end check: plan and execute `selftest/kernel/**`, interrupt, resume, and observe exit codes 1 and 0 as described in Validation and Acceptance.
- [ ] Add `docs/planning.md` (user guide: inputs, policies, suites, reading a plan) and the ADR distillation pass.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The component graph, the suites and both new documents are JSON, not Dhall.
  Rationale: The kernel already depends on `aeson` and publishes JSON Schemas in `schemas/`; the `dhall` Haskell library would add a very large dependency to every build of the one `kenshou` binary; and the house CI platform consumes JSON. `dhall` stays available in the development shell for people who want to generate these files.
  Date: 2026-09-20

- Decision: The graph distinguishes build edges (a cabal `build-depends` between library stanzas) from runtime edges (a coupling cabal cannot see: a store running against the schema its migrations package installs, a library talking to PostgreSQL), and only build edges are machine-verified.
  Rationale: `kiroku-store` has no cabal dependency on `kiroku-store-migrations`, yet a migrations release changes the schema every kiroku scenario runs against. Without runtime edges a migrations bump would select nothing under `kiroku/`.
  Date: 2026-09-20

- Decision: Edges and changes may target sub-components of `keiro` and of `shibuya-core`, and the graph must stay acyclic.
  Rationale: The MasterPlan records that keiro's process-manager and router workers use shibuya's types but never its runner, while `keiro-pgmq` calls `Shibuya.App.runApp`. A component-level edge cannot express that; an edge from `keiro` sub-components `process-manager`, `router` and `inbox` to `shibuya-core:contract` can. `Keiro.Telemetry` imports four type-only modules from `Keiro.Inbox`, `Keiro.Outbox` and `Keiro.Workflow`; those imports are deliberately not modelled, because modelling them would create cycles that make every outbox change select every keiro scenario.
  Date: 2026-09-20

- Decision: Add components the brief did not list because the cabal files require them: `hw-kafka-streamly` (a direct dependency of `shibuya-kafka-adapter`), `kiroku-cli` (a direct dependency of `kiroku-metrics`), `keiki` (a direct dependency of `keiro-core` and `keiro`), `hs-opentelemetry`, `ephemeral-pg`, `keiro-test-support`, and two pseudo-components for this repository (`kenshou-harness`, `runtime-assembly`).
  Rationale: A cohort diff reports package changes; a package the graph does not know cannot be mapped. Verifying keiki is out of scope for the suite, but a keiki upgrade still changes what keiro does.
  Date: 2026-09-20

- Decision: When the planner cannot map an input (an unknown package in a cohort diff, a repository path with no rule, a cohort project file that changed without its descriptor), it selects everything and writes a warning into the plan.
  Rationale: Under-selection silently removes evidence; over-selection only costs time and is visible.
  Date: 2026-09-20

- Decision: A change that originates in an observability component (`kiroku-otel`, `kiroku-metrics`, `shibuya-metrics`, `hs-opentelemetry`, `keiro:telemetry`, `shibuya-core:telemetry`) raises the dimension policy of everything it selects to at least `telemetry-corners`.
  Rationale: With both telemetry dimensions `off`, which is the default, the changed code is not on the execution path, so a default-only run would be evidence of nothing.
  Date: 2026-09-20

- Decision: Multi-operand options are encoded in one argument: `--upstream-diff REPO=PATH@REVA..REVB`, and the cohort diff is the pair `--cohort-from X --cohort-to Y`.
  Rationale: `optparse-applicative` options take exactly one argument. The brief's `--upstream-diff <component> <repo-path> <revA> <revB>` names a component; this plan names the repository instead and lets the changed paths decide which of that repository's components are affected, because one keiro revision range normally touches several packages.
  Date: 2026-09-20

- Decision: `kenshou execute` runs every entry as a child process of the same binary (`kenshou run --spec … --run-id …`) instead of calling the runner in-process.
  Rationale: Leak verdicts and benchmarks depend on the state of the GHC runtime's heap; sequential in-process runs would contaminate one another. A child per run also confines crashes and lets each run carry its own runtime flags. This matches Integration Point 8's one-binary rule.
  Date: 2026-09-20

- Decision: A run plan pre-assigns a run identifier to every entry; a retry of an interrupted entry mints a new identifier and the summary records both.
  Rationale: Pre-assigned identifiers make the plan a complete manifest of the results to expect, which is what a later verifier needs to tell a complete result set from a truncated one. Minting a new identifier on retry honours the rule that a later run never writes into an earlier run's directory.
  Date: 2026-09-20

- Decision: Knob variants are taken one at a time from each knob's enumerated allowed values and only at the default dimension assignment; trial seeds depend on the plan seed, the scenario and the trial index, never on the arm.
  Rationale: One-at-a-time keeps growth linear instead of multiplicative. Equal seeds across arms give paired arms the same generated workload, which is what the measurement toolkit's paired comparison needs.
  Date: 2026-09-20

- Decision: The worst-outcome order for a plan is `failed`, then `errored`, then `infrastructure-failure`, then `inconclusive`, then `passed`; entries that never completed count as `errored`; runs flagged as known defects never count.
  Rationale: A definite failure is the most actionable fact and must not be masked by an unrelated infrastructure error; the exit code contract has only one code for "could not evaluate".
  Date: 2026-09-20


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This repository, `keiro-runtime-kenshou`, is a verification suite for the keiro runtime. The keiro runtime is not one package but a cohort — an exact set of versions that services link together — of Haskell libraries: `pgmq-hs` (a client for PGMQ, a message queue made of PostgreSQL tables), `kiroku` (an event store on PostgreSQL, that is, an append-only log of events grouped into streams), `shibuya` (a framework that pulls messages from a source, hands them to a handler and acknowledges them) with adapters for PGMQ, kiroku and Kafka, and `keiro`, which builds a command processor, process managers, routers, durable workflows, timers, an inbox, an outbox and a job queue on top of the others. The whole initiative is described in `docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md`; this plan is its third child.

When this plan was drafted the repository contained no Haskell code at all. Two earlier plans must be complete before this one starts. `docs/plans/1-bootstrap-the-kenshou-repository-and-pin-the-runtime-cohort.md` creates the Nix flake and development shell (GHC 9.12.4, cabal 3.16, PostgreSQL 18 and 17), one cabal project whose `cabal.project` lists packages with the glob `kenshou-*/*.cabal`, the cohort files under `cohort/` (`released.project`, `head.project`, the one-line selector `active.project`, and the machine-readable descriptors `released.json` and `head.json` with `"schema": "kenshou.cohort/v1"`, each mapping every runtime component to its `mori://` project URI, its packages and its version or git commit), the module `Kenshou.Core.Cohort` that parses cabal's solver output, the command `kenshou cohort show`, and `docs/adr/` as an OKF bundle. `docs/plans/2-build-the-harness-kernel-for-scenarios-dimensions-run-specs-and-results.md` creates, in the package `kenshou-core`, the scenario model and the runner, and in `kenshou-cli` the `kenshou list` and `kenshou run` commands, the hidden `kenshou worker` command and the registry module `kenshou-cli/src/Kenshou/Cli/Registry.hs`. This plan adds the namespace `Kenshou.Plan.*` to `kenshou-core`, two commands to `kenshou-cli`, the directory `suites/`, and four schema files to `schemas/`. It creates no new package.

Check those prerequisites before writing code. From the repository root, inside the development shell (`nix develop`, or automatically through `direnv`), `cabal build all` must succeed, `cabal run kenshou -- list --json` must print a JSON array of scenarios that includes `selftest/kernel/correctness/always-pass`, `selftest/kernel/correctness/always-fail`, `selftest/kernel/correctness/errors`, `selftest/kernel/correctness/postgres-roundtrip` and `selftest/kernel/concurrency/worker-echo`, `cabal run kenshou -- cohort show --json` must print the resolved cohort identity, and `docs/adr/profile.dhall` and `cohort/released.json` must exist. If any of these is missing, stop: the dependency is not finished.

The kernel contracts this plan relies on are restated here so that the plan can be read alone. A scenario identifier is a four-segment path `<layer>/<component>/<kind>/<name>`, for example `kiroku/append/concurrency/expected-version-race`. The layer is one of `selftest`, `pgmq`, `kiroku`, `shibuya`, `kafka`, `keiro`, `runtime`. The kind is the sort of evidence: `correctness`, `concurrency`, `soak` (a long run watched for leaks and drift) or `benchmark`. Every scenario declares a cost tier — `smoke` (under one minute), `standard` (under ten minutes), `extended` (under one hour), `soak` (hours) — a placement (`local`, `cell` for a leased cloud machine set, or `either`), its knobs, the dimension values it supports, and optionally a known-defect reference that turns an expected failure into a reported, non-blocking outcome. A knob is a typed per-scenario parameter described by a `KnobSpec` (name, type, default, allowed values), such as `kiroku.pool-size`. A dimension is a cross-cutting switch with a closed value set that every layer honours: `telemetry.tracing` takes `off`, `noop`, `sdk-inmemory`, `sdk-otlp`; `telemetry.metrics` takes `off`, `collect`, `serve`, `serve-scraped`; `pg.durability` takes `fsync-off` and `durable` (mandatory for benchmarks and crash scenarios); `pg.version` takes `17` and `18`. Each layer package exports one `bundle :: LayerBundle`, and the registry module is the single list of bundles linked into the executable. A run specification (`kenshou.run-spec/v1`) names a scenario, its knob values, its dimension values, its environment, a seed, its phases and a cohort expectation; `kenshou run` executes one and writes a run directory `<out>/<run-id>/` containing `run-spec.json`, `run-result.json` (`kenshou.run-result/v1`), `manifest.json` and the evidence files. A run identifier is a UUIDv7 (a time-ordered universally unique identifier) in lowercase text, and a later run never writes into an earlier run's directory. Outcomes are `passed`, `failed`, `errored` (the scenario could not be evaluated), `inconclusive` and `infrastructure-failure`. Exit codes are part of the contract: 0 for passed, 1 for failed, 2 for a usage error, 3 for inconclusive, 4 for errored or infrastructure-failure. Every document is JSON with a `schema` field `kenshou.<name>/v<N>` and a JSON Schema in `schemas/`. This plan owns `kenshou.run-plan/v1`, which the MasterPlan defines as an ordered list of run specifications with a reason for each inclusion, and adds `kenshou.plan-summary/v1`, `kenshou.component-graph/v1` and `kenshou.suite/v1`.

The exact Haskell names EP-2 chose are not known to this plan, because the two were drafted at the same time. The expected shape is: `Kenshou.Core.Scenario` exporting `ScenarioId`, `Layer`, `Kind`, `Tier` (ordered `smoke < standard < extended < soak`), `Placement`, `KnownDefect` and the record `Scenario {id, summary, knobs, dimensions, tier, placement, requires, run}`; `Kenshou.Core.Knob` exporting `KnobSpec` and typed values; `Kenshou.Core.Dimension` exporting the four dimensions and `DimensionSupport`; `Kenshou.Core.Bundle` exporting `LayerBundle {layer, scenarios, roles}`; `Kenshou.Core.RunSpec`, `Kenshou.Core.RunResult`, `Kenshou.Core.Outcome` (five outcomes and the exit-code mapping) and `Kenshou.Core.Run` (the runner). To keep this plan robust against naming differences, exactly three of its modules touch those names: `Kenshou.Plan.Catalog` adapts the scenario model, `Kenshou.Plan.Change.Cohort` adapts the cohort descriptor, and `Kenshou.Plan.Execute` adapts `kenshou run`. Where a name below differs from what EP-2 shipped, EP-2's name wins and the adaptation goes in those modules.

Several terms recur. A component is a unit of the runtime that can change on its own: usually one cabal package (`kiroku-store`), sometimes a family released in lock-step (`pgmq-hs`, five packages), once a service (`postgresql`). The component graph is a checked-in data file listing components and the directed edges "A depends on B". A build edge is one that appears as `build-depends` in the library stanza of a cabal file; a runtime edge is a dependency that cabal cannot see. The transitive dependents of a component are all components that reach it by following edges; they are what must be re-verified when it changes. A selector is a glob over scenario identifiers, such as `shibuya/pgmq-adapter/**`. cabal's solver writes the build plan it chose to `dist-newstyle/cache/plan.json`; its `install-plan` array has one object per unit with `id`, `pkg-name`, `pkg-version`, `component-name` and `depends` (a list of unit identifiers). On macOS cabal shortens unit identifiers (`krk-str-0.8.0.1-8c49cfa0` is kiroku-store and `shby-pgmq-dptr-0.16.0.0-583edd60` is shibuya-pgmq-adapter), so a dependency must always be resolved by looking its identifier up in the install plan, never by parsing the string. An arm is one configuration of a scenario (one assignment of knobs and dimensions) and a trial is one repetition of an arm. Pairwise coverage means choosing a small set of dimension assignments such that every pair of values of every two dimensions occurs together at least once. OKF (Open Knowledge Format) is a directory of Markdown files with YAML frontmatter validated by the house tool `okf`; an ADR (Architecture Decision Record) is one such file; `mori` is the house registry that gives every project and document a `mori://` URI.

The real dependency edges were verified on 2026-09-20 by reading the library stanzas of the cabal files in the sibling checkouts and cross-checking them against the solver plan of the keiro checkout (`/Users/shinzui/Keikaku/bokuno/keiro/dist-newstyle/cache/plan.json`). These repositories are read-only for this work. The sources were `mori://shinzui/keiro` at `/Users/shinzui/Keikaku/bokuno/keiro` (packages at 0.17.0.0, commit `67b1ab00`), `mori://shinzui/kiroku` at `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` (`758b81a`; kiroku-store 0.8.0.1, kiroku-otel 0.2.0.8, kiroku-metrics 0.1.0.8, kiroku-cli 0.2.0.6, shibuya-kiroku-adapter 0.5.1.2, and kiroku-store-migrations already at 0.5.0.0 on pg-migrate 1.2 while the released cohort pins 0.4.0.0), `mori://shinzui/shibuya` at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya` (shibuya-core and shibuya-metrics 0.9.0.3; the head moved twice during drafting, so never hard-code it), `mori://shinzui/shibuya-pgmq-adapter` (0.16.0.0), `mori://shinzui/shibuya-kafka-adapter` (0.9.0.1), `mori://shinzui/pgmq-hs` at `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs` (0.6.1.0), `mori://shinzui/kafka-effectful` (0.3.1.0), `mori://shinzui/hw-kafka-streamly` (0.2.0.0), `mori://shinzui/hw-kafka-client` (the house fork, commit `6caed63`), `mori://shinzui/pg-migrate` and `mori://shinzui/keiki`. Package-level URIs have the form `mori://shinzui/kiroku/packages/kiroku-store` and resolve with `mori path`. The findings that shape the graph are these. `kiroku-store` depends on no first-party package at all; it talks to PostgreSQL through `hasql`. `keiro-core` depends on `keiki` and `kiroku-store`. `keiro` depends on `keiro-core`, `keiki`, `keiki-codec-json`, `kiroku-store`, `shibuya-core` and `hs-opentelemetry-api`, and on none of the PGMQ packages, adapters or Kafka packages. `keiro-pgmq` depends on `keiro-core` — not on `keiro` — and on `pgmq-config`, `pgmq-core`, `pgmq-effectful`, `pgmq-hasql`, `shibuya-core` and `shibuya-pgmq-adapter`. `keiro-migrations` depends on `kiroku-store-migrations` and the pg-migrate packages. Inside `keiro`, only `Keiro/ProcessManager.hs`, `Keiro/ProcessManager/Reaction.hs`, `Keiro/Router.hs`, `Keiro/Router/Selection.hs` and `Keiro/Inbox/Types.hs` import shibuya, and only the modules `Shibuya.Adapter` and `Shibuya.Core.*`; the workers drain the adapter's stream themselves with `Streamly.fold Fold.drain`. `keiro-pgmq/src/Keiro/PGMQ/Job.hs` imports `Shibuya.App` and calls `runApp`. keiro reads kiroku subscriptions through `Kiroku.Store.Subscription.Stream.subscriptionAckStream` in `Keiro/Subscription/Shard/Worker.hs`. `shibuya-pgmq-adapter` imports shibuya's contract and telemetry modules and three pgmq packages; `shibuya-kiroku-adapter` additionally imports `Shibuya.App`; `shibuya-kafka-adapter` imports only the contract modules and depends on `kafka-effectful`, `hw-kafka-streamly` and `hw-kafka-client`; `shibuya-metrics` imports `Shibuya.App` and `Shibuya.Core.Metrics`; `kiroku-metrics` depends on `kiroku-store` and on `kiroku-cli` (it imports `Kiroku.Cli.Subscription.Status`).

Two statements in the research notes this initiative started from are wrong and must not be copied into the graph: a layering diagram draws an arrow from `keiro-pgmq` to `keiro` (the cabal file has only `keiro-core`), and the same diagram omits `hw-kafka-streamly` under the Kafka adapter and `kiroku-cli` under kiroku-metrics. The Mori manifest of keiro also claims that `keiro-migrations` depends on `kiroku-store`; only its legacy test suite does.

There is no local ADR corpus to consult yet beyond the two records EP-1 writes (layer packages never import one another; every result carries a resolved cohort identity and both cohorts are first-class); read them in `docs/adr/` by scanning file names and headings first. No ADR in any registered repository covers change-based selection (searched with `mori registry concepts --search` for "affected", "selective", "change detection" and "cohort"). Three cross-repository records frame this plan. `mori://shinzui/keiro-benchmarks/okf/improvement-requests/concepts/IR-1` specifies the `list`/`run`/`compare` protocol this suite adopts, including the rule that results are comparable only when suite version, scenario, knobs, dimensions, cohort and machine profile match; that is why trials of one arm share everything except the trial index. `mori://shinzui/kotei/okf/improvement-requests/concepts/IR-3` and `mori://shinzui/kotei/okf/use-cases/concepts/UC-1` describe the CI platform that will call `kenshou plan` and `kenshou execute` and branch on their exit codes; orchestration itself is out of scope here. `mori://shinzui/kiroku/okf/adrs/concepts/ADR-5` makes paired candidate-versus-baseline runs, not single numbers, the authoritative performance evidence, which is why a benchmark is never planned with fewer than three trials. The shibuya record at `mori://shinzui/shibuya` path `docs/adr/0002-require-candidate-bound-machine-checkable-release-evidence.md` (artifact-level URI pending, because shibuya's ADRs are not an OKF bundle) is the precedent for binding evidence to exact commits and a solver plan hash, which the run plan repeats as its cohort expectation. This plan owns one new ADR, "Select runs from a checked-in component graph and over-select when unsure", covering the build/runtime edge split, machine verification of build edges against `plan.json`, the fail-safe rule and the telemetry policy upgrade. Create it with `okf id next docs/adr --profile docs/adr/profile.dhall ADR`, and validate with `okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce`.


## Plan of Work

### Milestone 1 — The component graph of the runtime

This milestone delivers the data and the pure functions everything else stands on: a selector language over scenario identifiers, a metadata view of scenarios that does not need runnable code, the checked-in component graph with its validation, the computation of transitive dependents, and two checks that keep the graph honest. At the end, `cabal run kenshou -- plan --graph-show` prints the graph, `cabal run kenshou -- plan --graph-check` compares every build edge with the solver's `plan.json` and lints the selectors against the linked registry, and `cabal test kenshou-core-test` passes with the new specs.

Create `kenshou-core/src/Kenshou/Plan/Selector.hs`. A selector is a `/`-separated pattern of at most four segments where a segment is a literal, `*` (exactly one segment) or, only in last position, `**` (all remaining segments, at least one). `pgmq/**`, `shibuya/pgmq-adapter/**`, `*/*/soak/*` and a full identifier are all selectors. The parser rejects empty segments, `**` anywhere but last, and more than four segments.

```haskell
module Kenshou.Plan.Selector where

data SelectorSegment = Literal Text | AnyOne | AnyRest
newtype Selector = Selector [SelectorSegment]

parseSelector  :: Text -> Either Text Selector
renderSelector :: Selector -> Text
matches        :: Selector -> ScenarioId -> Bool
```

Create `kenshou-core/src/Kenshou/Plan/Catalog.hs`. Planning needs only metadata, so the planner works on `ScenarioInfo` values and can therefore plan for scenarios that are not linked into the current binary, which is how this plan's acceptance examples are tested before any coverage plan exists. `fromBundles` projects the registry; `readCatalogFile` decodes the output of `kenshou list --json` (check the real shape in `schemas/` and adapt the decoder here only). Check in `kenshou-core/test/fixtures/plan/catalog-planned.json`, a hand-written catalog of about forty entries that uses the component segments the coverage plans intend: for `pgmq` the segments `queue`, `send`, `read`, `ack`, `vt`, `fifo`, `topics`, `notify`, `config`, `effectful`; for `kiroku` the segments `append`, `read`, `subscription`, `consumer-group`, `dead-letter`, `lifecycle`, `transaction`, `notifier`, `retention`, `metrics`, `otel`; for `shibuya` the segments `core-runner`, `core-ordering`, `core-batch`, `pgmq-adapter`, `kiroku-adapter`, `metrics`; for `kafka` the segments `adapter` and `producer`; for `keiro` the segments `command`, `process-manager`, `router`, `outbox`, `inbox`, `queue`, `workflow`, `timer`, `shard`; for `runtime` the segments `end-to-end` and `failure-matrix`; plus the five real `selftest/kernel` scenarios. Give the fixture a spread of tiers, kinds, placements, at least one benchmark with an enumerated knob, and at least one scenario that supports only `pg.version=18`.

```haskell
module Kenshou.Plan.Catalog where

data ScenarioInfo = ScenarioInfo
  { id          :: ScenarioId
  , tier        :: Tier
  , placement   :: Placement
  , knobs       :: [KnobSpec]
  , dimensions  :: DimensionSupport
  , knownDefect :: Maybe KnownDefect
  }

fromScenario    :: Scenario -> ScenarioInfo
fromBundles     :: [LayerBundle] -> [ScenarioInfo]
readCatalogFile :: FilePath -> IO (Either Text [ScenarioInfo])
```

Create `kenshou-core/data/components.json` with `"schema": "kenshou.component-graph/v1"`, list it under `extra-source-files` in `kenshou-core/kenshou-core.cabal`, and embed it at compile time with the `file-embed` package (`embedFile` with `makeRelativeToProject`), so that the single binary that EP-17 ships to a cell carries its graph; `--graph FILE` overrides it. A component has an `id`, a `kind` (`library`, `migrations`, `service`, `harness`, `assembly`), a `uri` (null for PostgreSQL, which Mori does not register), a `repository` identifier with `sourceRoots` relative to that repository's root, its `packages`, its `selectors`, an optional `changeImplies.minDimensionPolicy`, a `verifiedAgainst` note, optional `subcomponents` (each with `id`, `pathPrefixes`, `selectors`, `uses` — sibling sub-components it imports — and its own optional `changeImplies`), and `dependsOn` edges. An edge has `to`, `kind` (`build` or `runtime`), and the optional narrowing lists `toSubs` (the edge concerns only these sub-components of the target) and `fromSubs` (only these sub-components of the source are dependents). The file also has a top-level `ignoredPackages` list — `pg-migrate-test-support`, `kiroku-test-support`, `keiro-dsl`, `keiro-ops` — naming packages that may appear in a cohort descriptor but are not under verification, so that a change to one of them produces a note instead of the fail-safe "select everything". `pg-migrate-test-support` is deliberately kept out of the `pg-migrate` component: it depends on `ephemeral-pg`, and including it would make every PostgreSQL-backed scenario a dependent of the test fixture library. The shape, with two complete entries:

```json
{
  "schema": "kenshou.component-graph/v1",
  "components": [
    { "id": "keiro-pgmq", "kind": "library", "uri": "mori://shinzui/keiro/packages/keiro-pgmq",
      "repository": "keiro", "sourceRoots": ["keiro-pgmq/src/", "keiro-pgmq/keiro-pgmq.cabal"],
      "packages": ["keiro-pgmq"], "selectors": ["keiro/queue/**"], "verifiedAgainst": "keiro-pgmq 0.17.0.0",
      "dependsOn": [
        { "to": "keiro-core", "kind": "build" },
        { "to": "pgmq-hs", "kind": "build" },
        { "to": "shibuya-pgmq-adapter", "kind": "build" },
        { "to": "shibuya-core", "kind": "build", "toSubs": ["contract", "runner", "telemetry"] },
        { "to": "hs-opentelemetry", "kind": "build" } ] },
    { "id": "shibuya-core", "kind": "library", "uri": "mori://shinzui/shibuya/packages/shibuya-core",
      "repository": "shibuya", "sourceRoots": ["shibuya-core/src/", "shibuya-core/shibuya-core.cabal"],
      "packages": ["shibuya-core"], "selectors": [], "verifiedAgainst": "shibuya-core 0.9.0.3",
      "subcomponents": [
        { "id": "contract", "selectors": ["shibuya/**"], "uses": [],
          "pathPrefixes": ["shibuya-core/src/Shibuya/Core.hs", "shibuya-core/src/Shibuya/Core/", "shibuya-core/src/Shibuya/Adapter.hs", "shibuya-core/src/Shibuya/Adapter/", "shibuya-core/src/Shibuya/Handler.hs", "shibuya-core/src/Shibuya/Policy.hs"] },
        { "id": "telemetry", "selectors": ["shibuya/**"], "uses": [], "changeImplies": { "minDimensionPolicy": "telemetry-corners" },
          "pathPrefixes": ["shibuya-core/src/Shibuya/Telemetry.hs", "shibuya-core/src/Shibuya/Telemetry/"] },
        { "id": "runner", "selectors": ["shibuya/**", "kafka/**"], "uses": ["contract", "telemetry"],
          "pathPrefixes": ["shibuya-core/src/Shibuya/App.hs", "shibuya-core/src/Shibuya/Internal/", "shibuya-core/src/Shibuya/Batch.hs", "shibuya-core/src/Shibuya/Stream.hs"] } ],
      "dependsOn": [ { "to": "hs-opentelemetry", "kind": "build" } ] }
  ],
  "repositoryPaths": []
}
```

The complete content follows; `->` is a build edge, `~>` a runtime edge, square brackets are `toSubs`, and "from" introduces `fromSubs`. Write every line of it into the file.

```text
postgresql               service     no packages                                        selectors: none
pg-migrate               library     pg-migrate, pg-migrate-embed, pg-migrate-cli, pg-migrate-import-codd,
                                     pg-migrate-import-hasql-migration                               ~> postgresql
ephemeral-pg             harness     ephemeral-pg                    ~> postgresql       selectors: selftest/kernel/**
hs-opentelemetry         library     hs-opentelemetry-api, -sdk, -exporter-otlp, -exporter-in-memory, -propagator-w3c,
                                     -semantic-conventions (uri mori://iand675/hs-opentelemetry)
                                     selectors: selftest/telemetry/**      changeImplies: telemetry-corners
pgmq-hs                  library     pgmq-core, pgmq-hasql, pgmq-effectful, pgmq-config, pgmq-migration
                                     -> pg-migrate, hs-opentelemetry   ~> postgresql     selectors: pgmq/**
kiroku-store-migrations  migrations  -> pg-migrate   ~> postgresql
kiroku-store             library     ~> kiroku-store-migrations, postgresql              selectors: kiroku/**
kiroku-cli               library     -> kiroku-store
kiroku-otel              library     -> kiroku-store, hs-opentelemetry     selectors: kiroku/otel/**     changeImplies: telemetry-corners
kiroku-metrics           library     -> kiroku-store, kiroku-cli           selectors: kiroku/metrics/**  changeImplies: telemetry-corners
shibuya-core             library     -> hs-opentelemetry      sub-components contract, telemetry, runner (above)
shibuya-metrics          library     -> shibuya-core [contract, runner]    selectors: shibuya/metrics/** changeImplies: telemetry-corners
shibuya-pgmq-adapter     library     -> shibuya-core [contract, telemetry], pgmq-hs      selectors: shibuya/pgmq-adapter/**
shibuya-kiroku-adapter   library     -> shibuya-core [contract, telemetry, runner], kiroku-store, hs-opentelemetry
                                     selectors: shibuya/kiroku-adapter/**   (uri mori://shinzui/kiroku/packages/shibuya-kiroku-adapter)
hw-kafka-client          library     selectors: kafka/**
hw-kafka-streamly        library     -> hw-kafka-client                                   selectors: kafka/**
kafka-effectful          library     -> hw-kafka-client, hs-opentelemetry                 selectors: kafka/**
shibuya-kafka-adapter    library     -> shibuya-core [contract], kafka-effectful, hw-kafka-streamly, hw-kafka-client,
                                     hs-opentelemetry                                     selectors: kafka/**
keiki                    library     keiki, keiki-codec-json                              selectors: none
keiro-core               library     -> keiki, kiroku-store                               selectors: none
keiro                    library     -> keiro-core, keiki, kiroku-store, hs-opentelemetry
                                     -> shibuya-core [contract] from process-manager, router, inbox
                                     ~> keiro-migrations                                  sub-components below
keiro-pgmq               library     (above)
keiro-migrations         migrations  -> kiroku-store-migrations, pg-migrate   ~> postgresql
keiro-test-support       harness     -> ephemeral-pg, keiro-migrations, kiroku-store, kiroku-store-migrations, pg-migrate
                                     selectors: selftest/kernel/**
kenshou-harness          harness     kenshou-core    -> pg-migrate, kiroku-store-migrations, keiro-migrations, pgmq-hs, kiroku-store,
                                     ephemeral-pg (reconcile with --graph-check)  selectors: selftest/kernel/correctness/postgres-roundtrip
runtime-assembly         assembly    kenshou-runtime -> keiro, keiro-pgmq, keiro-migrations, kiroku-store, kiroku-otel, kiroku-metrics,
                                     pgmq-hs, shibuya-metrics, shibuya-kafka-adapter, kafka-effectful    selectors: runtime/**
```

The sub-components of `keiro` map module path prefixes under the keiro repository root to scenario selectors; `uses` comes from the real import graph. `command` owns `keiro/src/Keiro/Command.hs`, `keiro/src/Keiro/Command/` and `keiro/src/Keiro/ReplayAudit.hs`, uses `snapshot` and `telemetry`, and selects `keiro/command/**`. `snapshot` owns `keiro/src/Keiro/Snapshot.hs` and `keiro/src/Keiro/Snapshot/` and selects `keiro/snapshot/**`. `projection` owns `Projection.hs`, `Projection/`, `ReadModel.hs` and `ReadModel/` under `keiro/src/Keiro/`, uses `command` and `telemetry`, and selects `keiro/projection/**` and `keiro/command/**` (the coverage plan keeps projection scenarios with the command processor). `process-manager` owns `ProcessManager.hs` and `ProcessManager/`, uses `command`, `projection`, `timer` and `telemetry`, and selects `keiro/process-manager/**`. `router` owns `Router.hs` and `Router/`, uses `command`, `process-manager`, `projection` and `telemetry`, and selects `keiro/router/**`. `outbox` owns `Outbox.hs` and `Outbox/`, uses `telemetry`, and selects `keiro/outbox/**`. `inbox` owns `Inbox.hs` and `Inbox/`, uses `command`, `process-manager` and `telemetry` (`Keiro/Inbox/Delegated.hs` imports both), and selects `keiro/inbox/**`. `workflow` owns `Workflow.hs` and `Workflow/`, uses `timer`, `wake`, `snapshot` and `telemetry`, and selects `keiro/workflow/**`. `timer` owns `Timer.hs` and `Timer/`, uses `telemetry`, and selects `keiro/timer/**`. `shard` owns `keiro/src/Keiro/Subscription/` and selects `keiro/shard/**`. `wake` owns `keiro/src/Keiro/Wake.hs` and selects `keiro/wake/**`. `telemetry` owns `keiro/src/Keiro/Telemetry.hs`, selects `keiro/**` and implies `telemetry-corners`. A changed keiro path that matches no prefix — `Keiro.hs`, `Connection.hs`, `DeterministicId.hs`, `ReplayDigest.hs`, `DeadLetter*`, `Integration/`, the cabal file — marks the whole component as changed.

The `repositoryPaths` section maps paths of this repository to effects for `--since`; the longest matching prefix wins and an unmatched path selects everything with a warning. `kenshou-core/src/Kenshou/Plan/`, `kenshou-core/data/`, `kenshou-cli/`, `kenshou-remote/`, `kenshou-evidence/`, `schemas/`, `suites/` and `policies/` affect `selftest/**`. `kenshou-core/` otherwise, `kenshou-measure/`, `kenshou-check/`, `kenshou-diagnose/`, `kenshou-telemetry/`, `cabal.project`, `flake.` (prefix of `flake.nix`, `flake.lock`, `flake.module.nix`) and `nix/` affect `all`, because a toolkit or toolchain change can alter any result. `kenshou-pgmq/` affects `pgmq/**`, `kenshou-kiroku/` affects `kiroku/**`, `kenshou-shibuya/` affects `shibuya/**`, `kenshou-runtime/` affects `runtime/**`. `kenshou-kafka/` affects `kafka/**` and `runtime/**`, and `kenshou-keiro/` affects `keiro/**` and `runtime/**`, because `kenshou-runtime` reuses the Kafka broker fixture and the keiro fixture domain; the narrower prefixes `kenshou-keiro/src/Kenshou/Suite/Keiro/<Area>/` for `Command`, `ProcessManager`, `Router`, `Outbox`, `Inbox`, `Queue`, `Workflow`, `Timer` and `Shard` affect only `keiro/<area>/**`, while `…/Keiro/Fixture/` keeps the wide effect. `cohort/` has the effect `cohort`, explained in Milestone 2. `docs/`, `agents/`, `.seihou/`, `.github/`, `.claude/`, `.agents/`, `mori/`, `README.md`, `mori.dhall`, `mina.kdl`, `Justfile` and `process-compose.yaml` affect nothing.

Create `kenshou-core/src/Kenshou/Plan/Components.hs`. Nodes of the traversal are references: a whole component or one sub-component. The closure is a breadth-first search over reversed edges that remembers each node's predecessor, so every affected node carries the shortest dependency path from a changed node, and that path becomes the reason shown to the user. The rules are: a changed whole component also changes all its sub-components; a changed reference `(c, s)` affects every sibling sub-component whose `uses` contains `s`; and it affects, through each edge of another component `d` to `c` whose `toSubs` is empty or contains `s` (or when the whole of `c` changed), either the whole of `d` when `fromSubs` is empty or exactly the listed sub-components of `d`. Selectors of a component fire only when the whole component is affected; selectors of a sub-component fire when it is. The `origin` of an affected node is the reference the user's change named: a whole-component change keeps the whole component as origin even for the sub-components it expands to, so a sub-component's `changeImplies` fires only when a change targets that sub-component itself (`--changed keiro:telemetry`, or an upstream diff touching `Keiro/Telemetry.hs`), and an ordinary keiro version bump does not quadruple every keiro run. One imprecision is accepted and documented in `docs/planning.md`: the Kafka layer round-trips keiro's `Keiro.Outbox.Kafka` and `Keiro.Inbox.Kafka` records through a real broker, but no selector ties `keiro:outbox` or `keiro:inbox` to that scenario because its identifier is not known yet; add the selector when `docs/plans/11-cover-the-kafka-transport-edge-with-a-disposable-broker.md` names it. `validateGraph` rejects unknown `to`, `toSubs`, `fromSubs` and `uses` references, a package listed by two components, unparsable selectors, and cycles (use `Data.Graph.stronglyConnComp` over the reference nodes).

```haskell
module Kenshou.Plan.Components where

newtype ComponentId = ComponentId Text
newtype SubId       = SubId Text
data ComponentRef   = ComponentRef { component :: ComponentId, sub :: Maybe SubId }   -- rendered "keiro:outbox"
data EdgeKind       = Build | Runtime
data Affected       = Affected { ref :: ComponentRef, origin :: ComponentRef, path :: [ComponentRef], distance :: Int }

embeddedGraph :: Either GraphError ComponentGraph
loadGraphFile :: FilePath -> IO (Either GraphError ComponentGraph)
validateGraph :: ComponentGraph -> [GraphProblem]
parseRef      :: ComponentGraph -> Text -> Either Text ComponentRef
dependents    :: ComponentGraph -> Set ComponentRef -> Map ComponentRef Affected
graphDigest   :: ComponentGraph -> Text                                              -- "sha256:…" of the file bytes
```

Create `kenshou-core/src/Kenshou/Plan/Components/Check.hs` with two checks. `checkAgainstPlanJson` reads the install plan (reuse EP-1's parser in `Kenshou.Core.Cohort` if it exposes units and `depends`; otherwise decode the four fields named above), keeps units whose `component-name` is `lib` or whose `components` object has a `lib` key, resolves `depends` through the identifier map, and reports, for every ordered pair of components, a build edge declared but not observed (`ExtraEdge`) or observed but not declared (`MissingEdge`); packages absent from the build plan (for example `kenshou-runtime` before EP-15) are reported as informational. `lintAgainstCatalog` reports an error for every scenario of a layer other than `selftest` that no selector matches (it could never be selected by a change), and a warning for every selector whose layer has registered scenarios but which matches none (the coverage plan named its components differently). The integration point that lets a coverage plan touch only three lines outside its package means coverage authors will not edit the graph; this lint, run by `--graph-check` and by `just verify`, is what surfaces the drift so the graph's owner can fix it.

```haskell
module Kenshou.Plan.Components.Check where

data EdgeDrift   = MissingEdge ComponentId ComponentId [PackageName] | ExtraEdge ComponentId ComponentId | NotInBuildPlan PackageName
data LintFinding = OrphanScenario ScenarioId | DeadSelector ComponentRef Selector

checkAgainstPlanJson :: ComponentGraph -> FilePath -> IO (Either Text [EdgeDrift])
lintAgainstCatalog   :: ComponentGraph -> [ScenarioInfo] -> [LintFinding]
```

In `kenshou-cli`, create `kenshou-cli/src/Kenshou/Cli/Plan.hs`, register a `plan` subcommand beside `list` and `run` in the module where EP-2 builds the `optparse-applicative` command tree, and implement only `--graph-show [--json]`, `--graph-check`, `--graph FILE` and `--catalog FILE` for now. `--graph-check` exits 1 when there is a `MissingEdge`, an `ExtraEdge`, an `OrphanScenario` or a validation problem, and 0 otherwise. Add `kenshou-core/test/Kenshou/Plan/SelectorSpec.hs`, `CatalogSpec.hs`, `ComponentsSpec.hs` and `ComponentsCheckSpec.hs` to the `kenshou-core-test` suite: parser round-trips as a Hedgehog property; the embedded graph validates; the closure of `pgmq-hs` is exactly `shibuya-pgmq-adapter`, `keiro-pgmq`, `kenshou-harness` and `runtime-assembly`; the closure of `shibuya-core:runner` contains `keiro-pgmq`, `shibuya-metrics`, `shibuya-kiroku-adapter` and `runtime-assembly` and contains neither `keiro` nor any `keiro:` reference; the closure of `shibuya-core:contract` contains `keiro:process-manager`, `keiro:router` and `keiro:inbox` and does not contain `keiro:command`, `keiro:outbox` or `keiro:workflow`; and the drift check finds a planted missing edge in a small fixture `plan.json` that uses shortened unit identifiers.

### Milestone 2 — Change detection from cohort diffs, named components and repository paths

This milestone turns four kinds of input into one set of changed references and from there into selected scenarios with reasons. At the end, `kenshou plan … --explain` prints, for any combination of inputs, the changes it understood, the affected components with their paths, the selected scenario identifiers with their reasons and any warnings. No run specifications are produced yet.

Create `kenshou-core/src/Kenshou/Plan/Change.hs`. A `Change` names a reference, a source and a human-readable detail. `selectScenarios` runs the closure and matches selectors against the catalog; a scenario reached several ways keeps all reasons, ordered by distance, and its smallest distance later drives ordering. `--all` and a suite in mode `all` bypass change detection with the single reason `all`. `--select GLOB` restricts and `--exclude GLOB` removes; both apply after selection.

```haskell
module Kenshou.Plan.Change where

data ChangeSource = Named | CohortDiff | Since | UpstreamDiff | Everything
data Change   = Change { ref :: ComponentRef, source :: ChangeSource, detail :: Text }
data Reason   = Reason { change :: Change, via :: [ComponentRef], selector :: Selector, distance :: Int }
data Selected = Selected { scenario :: ScenarioInfo, reasons :: NonEmpty Reason, minPolicy :: Maybe DimensionPolicy }

selectScenarios :: ComponentGraph -> [ScenarioInfo] -> [Change] -> [Selected]
selectAll       :: [ScenarioInfo] -> [Selected]
```

The first input is explicit: `--changed kiroku-store,keiro:outbox`, repeatable, each name parsed with `parseRef`; an unknown name is a usage error (exit 2) whose message lists the valid names.

The second input is a cohort diff, in `kenshou-core/src/Kenshou/Plan/Change/Cohort.hs`. `--cohort-from X --cohort-to Y` each accept a cohort name (`released` resolves to `cohort/released.json`), a file path, or a git object such as `origin/master:cohort/released.json` (read with `git show`). The module normalises a descriptor to a map from package name to source — a Hackage version, or a git location with a commit — and this normalisation is the only place that knows the descriptor's layout, so read `cohort/released.json` and its schema before writing it; when a descriptor entry pins a whole repository to one commit, every package of that entry gets that commit. The diff reports every package whose source differs or which exists on one side only; each maps to the component that lists it in `packages`, with a detail such as `pgmq-core 0.6.1.0 -> 0.6.2.0` or `shibuya-core 0.9.0.3 -> git a7af0db`. A package no component lists produces the `Everything` change and the warning `unmapped package <name>`.

```haskell
module Kenshou.Plan.Change.Cohort where

data PackageSource = FromHackage Version | FromGit { location :: Text, rev :: Text }

readCohortPackages :: CohortInput -> IO (Either Text (Map PackageName PackageSource))
diffCohorts        :: ComponentGraph -> Map PackageName PackageSource -> Map PackageName PackageSource -> ([Change], [Warning])
```

The third input is `--since REV`, in `kenshou-core/src/Kenshou/Plan/Change/Git.hs`. The changed paths are the output of `git diff --name-only REV` (which compares the revision with the working tree and therefore includes uncommitted edits) plus `git ls-files --others --exclude-standard` (untracked files), both run with `System.Process.readProcessWithExitCode` in the repository root (found by walking up from the working directory to the directory containing `cabal.project`). Each path is mapped through `repositoryPaths`. The effect `all` yields the `Everything` change with the path as its detail; a selector effect yields selections with the reason source `Since`; `nothing` is dropped. The effect `cohort` is the useful one: for a changed `cohort/<name>.json` the planner reads the old descriptor with `git show REV:cohort/<name>.json` and the new one from disk and runs the cohort diff, so that a commit which bumps the pins selects exactly what the bump affects; a changed `cohort/active.project`, a descriptor that did not exist at `REV`, or a changed `cohort/<name>.project` whose descriptor did not change, yields `Everything` with a warning.

The fourth input is `--upstream-diff REPO=PATH@REVA..REVB`, repeatable, where `REPO` is a `repository` identifier from the graph (`keiro`, `kiroku`, `shibuya`, `pgmq-hs`, …) and `PATH` a local checkout. The planner runs `git -C PATH diff --name-only REVA REVB`. A path under a sub-component's `pathPrefixes` changes that sub-component; a path under a component's `sourceRoots` but under no prefix changes the whole component; any other path (tests, benchmarks, documentation, change logs) is ignored and counted in the explanation. This is what lets a maintainer ask what a specific keiro commit range deserves before it is released.

```haskell
module Kenshou.Plan.Change.Git where

changesSince        :: ComponentGraph -> FilePath -> Text -> IO (Either Text ([Change], [Selector], [Warning]))
changesFromUpstream :: ComponentGraph -> UpstreamDiff -> IO (Either Text ([Change], Int))   -- Int: ignored paths
```

Extend `Kenshou.Cli.Plan` with these options and with `--explain`, which prints a plain-text report to standard output. When no change input, no `--all` and no suite in mode `all` is given, exit 2 with a message naming the five ways to say what changed. When the inputs are valid but select nothing (only documentation changed), report an empty selection and exit 0. Add `ChangeSpec.hs`, `ChangeCohortSpec.hs` and `ChangeGitSpec.hs`; the git tests create a throw-away repository under the system temporary directory with `git init`, commit a miniature tree (`kenshou-kiroku/x`, `kenshou-measure/y`, `docs/z`, `cohort/released.json`) and assert the mapping, including the automatic cohort diff. The five acceptance selections of Validation and Acceptance are unit tests over the fixture catalog.

### Milestone 3 — Matrix expansion, tier budgets and `kenshou plan`

This milestone turns selected scenarios into concrete, ordered, budgeted run specifications and defines the run-plan document. At the end, `kenshou plan` writes a `kenshou.run-plan/v1` document that validates against `schemas/run-plan.v1.schema.json`, and any single `spec` cut out of it is accepted by `kenshou run`.

Create `kenshou-core/src/Kenshou/Plan/Policy.hs`. `PlanPolicy` carries `maxTier` (default `standard`), `kinds` (default all four), `placement` (`local`, the default, keeps scenarios placed `local` or `either`; `cell` keeps `cell` or `either`), `dimensionPolicy` (default `default-only`), `knobPolicy` (default `defaults`), `trials` (default 3; values below 3 are a usage error), `budgetMinutes` (optional), `tierMinutes` (defaults: smoke 1, standard 10, extended 60, soak 240 — the upper bound of each tier, and a nominal four hours for soaks), `seed` (default: drawn at random and recorded), pinned knob values from `--set k=v`, and pinned dimension values from `--dim name=value`. Policies merge in the order built-in defaults, suite file, command-line flags.

Create `kenshou-core/src/Kenshou/Plan/Matrix.hs`. The dimension policies are ordered `default-only < telemetry-corners < pairwise < full`, and the effective policy for a scenario is the larger of the plan's policy and the scenario's `minPolicy` from change detection. `default-only` yields one assignment: each dimension at the default declared by the scenario's `DimensionSupport`, falling back to `telemetry.tracing=off`, `telemetry.metrics=off`, `pg.version=18`, and `pg.durability=fsync-off` except for kind `benchmark`. `telemetry-corners` yields up to four assignments, the corners of tracing and metrics with the other dimensions at their defaults, where "on" means the first supported value of `sdk-inmemory`, `sdk-otlp`, `noop` for tracing and of `serve-scraped`, `serve`, `collect` for metrics; a scenario that supports only `off` for one of them yields fewer corners. `pairwise` yields a covering set computed greedily: enumerate the full product of supported values (at most 64 rows), repeatedly pick the row that covers the most still-uncovered value pairs, break ties by the lexicographic order of the rendered row, and stop when every pair is covered; for a scenario supporting every value this gives about sixteen rows instead of sixty-four. `full` yields the product. Two rules apply to every policy: for kind `benchmark` the value `fsync-off` is removed (Integration Point 4 makes `durable` mandatory, and a benchmark scenario that does not support `durable` is a lint error reported as a skip with reason `benchmark-without-durable`); a pinned dimension value replaces that dimension's value set, and a scenario that does not support it is skipped with reason `unsupported-dimension`. The knob policy `defaults` uses every knob's default; `declared-variants` adds, for each knob whose allowed values are an explicit enumeration of at most eight values, one configuration per non-default value with all other knobs at their defaults, generated at the default dimension assignment only. A pinned knob applies to every scenario that declares it and is validated against its `KnobSpec`; if no selected scenario declares it the plan carries a warning.

```haskell
module Kenshou.Plan.Matrix where

data DimensionPolicy = DefaultOnly | TelemetryCorners | Pairwise | Full  deriving (Eq, Ord, Enum, Bounded)
data KnobPolicy      = KnobDefaults | KnobDeclaredVariants
data Config          = Config { knobs :: Map KnobName KnobValue, dimensions :: Map DimensionName DimensionValue, isDefault :: Bool }

expandScenario :: PlanPolicy -> Selected -> ([Config], [Skipped])
pairwiseCover  :: [(DimensionName, [DimensionValue])] -> [Map DimensionName DimensionValue]
```

Create `kenshou-core/src/Kenshou/Plan/RunPlan.hs`. `buildPlan` is pure and deterministic; `stampPlan` adds the plan identifier, the creation time and one fresh UUIDv7 per entry using the kernel's generator. Filtering happens first and every exclusion is recorded in `skipped` with a reason (`tier`, `kind`, `placement`, `excluded`, `unsupported-dimension`, `benchmark-without-durable`, `over-budget`). Ordering puts the most relevant and cheapest evidence first: scenarios sort by smallest reason distance, then tier, then kind in the order `correctness`, `concurrency`, `benchmark`, `soak`, then identifier; within a scenario the default configuration comes first and the rest follow in the order of their canonical JSON. Non-benchmark scenarios contribute one entry per configuration. A benchmark scenario is a trial group: for trial index `i` from 0 to `trials - 1` its configurations (its arms) appear in forward order when `i` is even and in reverse when `i` is odd, which for two arms is the A-B-B-A interleaving that cancels linear drift such as a PostgreSQL checkpoint landing in one arm's window; the plan records the strategy name `alternating/v1`, each entry carries `trial {group, arm, index, of}`, and the statistical pairing itself belongs to the measurement toolkit (`docs/plans/4-build-the-measurement-toolkit-for-load-latency-sampling-and-comparison.md`). The seed of an entry is a 64-bit hash of the plan seed, the scenario identifier and the trial index (0 for non-benchmarks), so paired arms replay the same workload. The estimate of an entry is its tier's minutes. The budget is applied by walking the ordered list with a running total: a non-benchmark entry that does not fit is skipped as `over-budget` and the walk continues, and a benchmark group is kept or skipped as a whole, because a partial set of trials must never be quoted. Every generated specification is checked with EP-2's run-specification validator when the scenario is linked into the binary, and with the `KnobSpec` and `DimensionSupport` metadata otherwise. The environment of each specification is EP-2's default environment for the placement; `kenshou execute --environment` replaces it at run time. The cohort expectation is the resolved identity of the planning build as `Kenshou.Core.Cohort` reports it.

```haskell
module Kenshou.Plan.RunPlan where

data TrialInfo  = TrialInfo { group :: Text, arm :: Text, index :: Int, of_ :: Int }
data PlannedRun = PlannedRun { ordinal :: Int, runId :: RunId, estimateMinutes :: Int, reasons :: NonEmpty Reason, trial :: Maybe TrialInfo, spec :: RunSpec }
data Skipped    = Skipped { scenario :: ScenarioId, reason :: SkipReason, detail :: Text }

buildPlan :: PlanInputs -> PlanPolicy -> [Selected] -> PlanSkeleton
stampPlan :: PlanSkeleton -> IO RunPlan
```

The document, abridged to one entry:

```json
{
  "schema": "kenshou.run-plan/v1",
  "planId": "0199a3f2-7c1e-7b8a-9d41-3e5f6a7b8c9d",
  "createdAt": "2026-10-02T09:14:07Z",
  "suite": "change",
  "graphDigest": "sha256:5d0c…",
  "cohort": { "name": "released", "planHash": "sha256:91ab…" },
  "inputs": { "changed": ["pgmq-hs"], "cohortDiff": null, "since": null, "upstreamDiffs": [], "select": [], "exclude": [] },
  "policy": { "maxTier": "standard", "kinds": ["correctness", "concurrency"], "placement": "local", "dimensionPolicy": "default-only", "knobPolicy": "defaults", "trials": 3, "trialOrdering": "alternating/v1", "budgetMinutes": 45, "seed": 8675309 },
  "changes": [ { "component": "pgmq-hs", "source": "named", "detail": "--changed pgmq-hs" } ],
  "affected": [ { "component": "keiro-pgmq", "distance": 1, "path": ["pgmq-hs", "keiro-pgmq"] } ],
  "runs": [
    { "ordinal": 1, "runId": "0199a3f2-7c20-7f00-8a11-0c0d0e0f1011", "estimateMinutes": 1, "trial": null,
      "reasons": [ { "component": "pgmq-hs", "source": "named", "via": ["pgmq-hs"], "selector": "pgmq/**", "distance": 0 } ],
      "spec": { "schema": "kenshou.run-spec/v1", "scenario": "pgmq/vt/correctness/expiry-redelivers" } }
  ],
  "skipped": [ { "scenario": "pgmq/send/benchmark/batch-throughput", "reason": "kind", "detail": "benchmark not in policy kinds" } ],
  "warnings": [],
  "estimateMinutes": 37
}
```

Write `schemas/run-plan.v1.schema.json` following the file-naming convention EP-2 used in `schemas/`, reference the run-specification schema for `spec` rather than copying it, and add the golden fixture `kenshou-core/test/fixtures/plan/run-plan.golden.json` produced from the fixture catalog with a fixed seed and an injected identifier generator. Complete `kenshou plan`: `--suite NAME`, `--suite-file FILE`, `--max-tier`, `--budget-minutes`, `--kind a,b`, `--placement`, `--dimension-policy`, `--knob-policy`, `--set`, `--dim`, `--trials`, `--seed`, `--out FILE` (default standard output), with a one-paragraph summary on standard error (counts by layer, kind and tier, the estimate, the number skipped). Add `MatrixSpec.hs` (properties: `pairwiseCover` covers every pair and never exceeds the product; every policy's output is a subset of `full`; no benchmark configuration has `fsync-off`) and `RunPlanSpec.hs` (the golden fixture; the alternating order for two and three arms; a benchmark group is never split by the budget; equal seeds across arms of one trial; the JSON round-trips and validates against the schema).

### Milestone 4 — Named suites and resumable `kenshou execute`

This milestone gives the common intentions names and makes plans executable. At the end `suites/` holds five suite files, `kenshou plan --suite smoke` works without further flags, and `kenshou execute --plan FILE --out DIR [--resume]` runs a plan to a `kenshou.plan-summary/v1` document and a contract exit code.

Create `kenshou-core/src/Kenshou/Plan/Suite.hs` and `schemas/suite.v1.schema.json`. A suite file has `schema` (`kenshou.suite/v1`), `name`, `description`, `selection` (`mode` of `all` or `changed`; `always`, selectors included regardless of change; `exclude`, a list of `{select, why}`), `policy` (any field of `PlanPolicy`), and optionally `directlyChanged` (policy fields applied to scenarios whose smallest reason distance is 0). `--suite NAME` resolves to `suites/NAME.json` under the repository root. Every suite excludes `selftest/kernel/correctness/always-fail` and `selftest/kernel/correctness/errors`, which exist to prove that failures are reported. The five suites are as follows. `smoke` selects everything at tier `smoke`, kinds `correctness` and `concurrency`, placement `local`, `default-only`, `defaults`, with a budget of 20 minutes; it is the pre-push check. `change` is in mode `changed` and refuses to plan without a change input; it takes tiers up to `standard`, kinds `correctness` and `concurrency`, placement `local`, `default-only` and `defaults` with a budget of 45 minutes, and its `directlyChanged` block raises the directly changed components to `telemetry-corners` and `declared-variants`. `nightly` selects everything up to tier `extended`, kinds `correctness`, `concurrency` and `benchmark`, placement `cell`, `pairwise`, `declared-variants`, three trials, no budget. `weekly-soak` selects kind `soak` up to tier `soak`, placement `cell`, `telemetry-corners`, `defaults`. `release` selects every kind up to tier `soak`, placement `cell`, `pairwise`, `declared-variants`, five trials. Until cells exist, any suite can be planned for a laptop by adding `--placement local`.

```json
{
  "schema": "kenshou.suite/v1",
  "name": "change",
  "description": "What a change deserves before it merges: the changed components and their dependents, cheap tiers, correctness first.",
  "selection": { "mode": "changed", "always": ["selftest/kernel/correctness/postgres-roundtrip"],
                 "exclude": [ { "select": "selftest/kernel/correctness/always-fail", "why": "fails by design" },
                              { "select": "selftest/kernel/correctness/errors", "why": "errors by design" } ] },
  "policy": { "maxTier": "standard", "kinds": ["correctness", "concurrency"], "placement": "local",
              "dimensionPolicy": "default-only", "knobPolicy": "defaults", "trials": 3, "budgetMinutes": 45 },
  "directlyChanged": { "dimensionPolicy": "telemetry-corners", "knobPolicy": "declared-variants" }
}
```

Create `kenshou-core/src/Kenshou/Plan/Summary.hs`, `kenshou-core/src/Kenshou/Plan/Execute.hs`, `kenshou-cli/src/Kenshou/Cli/Execute.hs` and `schemas/plan-summary.v1.schema.json`. The output directory of an execution has this shape, with EP-2's run directories as children:

```text
<out>/
  run-plan.json        a byte copy of the plan being executed
  plan-summary.json    kenshou.plan-summary/v1, rewritten atomically after every attempt
  .execute.lock        process id of the running executor
  specs/<ordinal>.json the effective run specification handed to the child
  <run-id>/            one run directory per attempt (layout owned by EP-2)
```

`executePlan` proceeds as follows. It validates the plan against its schema (exit 2 on failure). If `<out>/run-plan.json` exists, `--resume` is required and its SHA-256 must equal that of `--plan`; otherwise the command exits 2 without touching anything, so one directory never mixes two plans. It takes the lock, refusing to start when the recorded process is alive and replacing a stale one. For each entry in order it skips entries whose summary status is `completed`; for the rest it writes the effective specification (the plan's `spec`, with the `environment` object replaced by the contents of `--environment FILE` when given — this is how a cell points runs at its own PostgreSQL and broker), chooses the run identifier (the planned one on the first attempt; a fresh UUIDv7 when the summary already lists an attempt, because an interrupted run's directory must never be written again), marks the entry `running` in the summary, and spawns `kenshou run --spec <file> --out <out> --run-id <id>` using `System.Environment.getExecutablePath`, with inherited standard streams. If EP-2's `kenshou run` has no `--run-id`, add it: one option in its parser and one `Maybe RunId` passed to the runner. When the child exits, the executor reads `<out>/<id>/run-result.json`; its `outcome` and known-defect flag are authoritative, and a missing result records the attempt as `crashed` with the child's exit status and counts as `errored`. With `--timeout-factor F` (absent by default, because a soak's real length comes from its knobs) a child that runs longer than `F` times its estimate receives `SIGTERM`, then `SIGKILL` thirty seconds later, and counts as `errored`. `--fail-fast` stops after the first blocking `failed`. On `SIGINT` or `SIGTERM` the executor forwards the signal to the child, waits for it, writes the summary and exits. The summary lists every entry with its ordinal, scenario, status (`pending`, `running`, `completed`) and attempts (`runId`, start and finish times, outcome, known-defect flag, child exit code), plus counts per outcome, `worstOutcome` and `exitCode`. The worst outcome follows the order `failed`, `errored`, `infrastructure-failure`, `inconclusive`, `passed`; known-defect runs are counted separately and never contribute; any entry not `completed` at exit contributes `errored`. The exit code is EP-2's mapping of the worst outcome: 0, 1, 3 or 4. An empty plan completes immediately with exit 0.

```haskell
module Kenshou.Plan.Execute where

data ExecuteOptions = ExecuteOptions
  { planFile :: FilePath, outDir :: FilePath, resume :: Bool, failFast :: Bool
  , environment :: Maybe FilePath, timeoutFactor :: Maybe Double }

executePlan :: ExecuteOptions -> IO PlanSummary

module Kenshou.Plan.Summary where

worstOutcome    :: PlanSummary -> Outcome
summaryExitCode :: PlanSummary -> ExitCode
writeSummary    :: FilePath -> PlanSummary -> IO ()   -- temporary file in the same directory, then rename
```

Add `SuiteSpec.hs` (every file in `../suites/` parses, validates and plans against the fixture catalog; `change` without input is a usage error), `SummarySpec.hs` (the worst-outcome table, including a known-defect `failed` that leaves the plan `passed`) and `ExecuteSpec.hs`, which drives `executePlan` through an injectable `spawnRun` function so that completion, a crash without a result, resume after an interrupted entry with a fresh identifier, the plan-digest mismatch and the lock are tested without real scenarios. Finish with `docs/planning.md`, a guide for users of the two commands, and add `cabal run kenshou -- plan --graph-check` to the `verify` recipe of the `Justfile`.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro-runtime-kenshou`, inside the development shell. Transcripts are illustrative; counts and identifiers will differ.

Confirm the prerequisites.

```bash
cabal build all
cabal run kenshou -- list --json | jq -r '.[].id' | grep '^selftest/kernel/'
cabal run kenshou -- cohort show --json | jq '.planHash'
ls docs/adr/profile.dhall cohort/released.json cohort/head.json schemas/
```

After Milestone 1:

```bash
cabal test kenshou-core-test --test-show-details=direct --test-options='--match "/Kenshou.Plan/"'
cabal run kenshou -- plan --graph-show
cabal run kenshou -- plan --graph-check; echo "exit=$?"
```

```text
26 components, 12 keiro and 3 shibuya-core sub-components, 66 edges (58 build, 8 runtime)
build edges verified against dist-newstyle/cache/plan.json: 0 missing, 0 extra
not in build plan (informational): kenshou-runtime
lint against 5 registered scenarios: 0 orphan scenarios, 0 dead selectors (6 layers not registered yet)
exit=0
```

If the check reports a missing or extra edge for `kenshou-harness`, correct `kenshou-core/data/components.json` to match what `kenshou-core` really links and rerun. If it reports drift for a runtime library, the upstream package changed its dependencies: update the graph and the `verifiedAgainst` note, and record the finding in Surprises & Discoveries.

After Milestone 2, against the fixture catalog:

```bash
cabal run kenshou -- plan --catalog kenshou-core/test/fixtures/plan/catalog-planned.json --changed pgmq-hs --explain
```

```text
changed    pgmq-hs                     named: --changed pgmq-hs
affected   shibuya-pgmq-adapter        pgmq-hs <- shibuya-pgmq-adapter
affected   keiro-pgmq                  pgmq-hs <- keiro-pgmq
affected   kenshou-harness             pgmq-hs <- kenshou-harness
affected   runtime-assembly            pgmq-hs <- runtime-assembly
selected   17 scenarios: pgmq 10, shibuya 2 (pgmq-adapter), keiro 2 (queue), runtime 2, selftest 1
not selected: every scenario under kiroku/, kafka/, shibuya/core-*, shibuya/kiroku-adapter, shibuya/metrics
```

```bash
cabal run kenshou -- plan --cohort-from released --cohort-to head --explain
cabal run kenshou -- plan --since origin/master --explain
cabal run kenshou -- plan --upstream-diff keiro=/Users/shinzui/Keikaku/bokuno/keiro@keiro-0.17.0.0..HEAD --explain
```

After Milestone 3:

```bash
cabal run kenshou -- plan --catalog kenshou-core/test/fixtures/plan/catalog-planned.json --changed kiroku-otel --max-tier standard --out /tmp/kenshou-demo/otel-plan.json
jq '[.runs[].spec.dimensions."telemetry.tracing"] | unique' /tmp/kenshou-demo/otel-plan.json
```

```text
planned 8 runs over 2 scenarios (kiroku 2), estimate 44 min, 3 skipped (2 tier, 1 kind)
[ "off", "sdk-inmemory" ]
```

After Milestone 4:

```bash
mkdir -p /tmp/kenshou-demo
cabal run kenshou -- plan --all --select 'selftest/kernel/**' --out /tmp/kenshou-demo/plan.json
cabal run kenshou -- execute --plan /tmp/kenshou-demo/plan.json --out /tmp/kenshou-demo/results; echo "exit=$?"
jq '{worstOutcome, exitCode, counts}' /tmp/kenshou-demo/results/plan-summary.json
cabal run kenshou -- plan --suite smoke --out /tmp/kenshou-demo/smoke.json
cabal run kenshou -- execute --plan /tmp/kenshou-demo/smoke.json --out /tmp/kenshou-demo/smoke; echo "exit=$?"
```

```text
[1/5] selftest/kernel/correctness/always-pass        passed
[2/5] selftest/kernel/correctness/always-fail        failed
[3/5] selftest/kernel/correctness/errors             errored
[4/5] selftest/kernel/correctness/postgres-roundtrip passed
[5/5] selftest/kernel/concurrency/worker-echo        passed
exit=1
{ "worstOutcome": "failed", "exitCode": 1, "counts": { "passed": 3, "failed": 1, "errored": 1 } }
...
exit=0
```

Commit after each milestone with a Conventional Commits subject, for example `feat(plan): add the runtime component graph and its drift check`, and end every commit message with the three trailers:

```text
MasterPlan: docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md
ExecPlan: docs/plans/3-plan-and-select-runs-from-what-changed.md
Intention: intention_01m2zvy0gje40tdsdragvzr3tq
```

Create the ADR during Milestone 3 and validate the bundle.

```bash
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```


## Validation and Acceptance

Five selections are the heart of the acceptance and exist both as unit tests in `ChangeSpec.hs` and as commands against the fixture catalog. First, when only the PGMQ family changed (`--changed pgmq-hs`, or a cohort diff in which only `pgmq-*` versions differ), the selection is every scenario under `pgmq/`, `shibuya/pgmq-adapter/`, `keiro/queue/` and `runtime/` plus `selftest/kernel/correctness/postgres-roundtrip`, and nothing under `kiroku/`, `kafka/`, `shibuya/core-runner/`, `shibuya/core-ordering/`, `shibuya/core-batch/`, `shibuya/kiroku-adapter/` or any other `keiro/` component. Second, when `kiroku-store` changed, the selection is everything under `kiroku/`, `shibuya/kiroku-adapter/`, every `keiro/` component including `keiro/queue/` (through `keiro-core`), `runtime/` and `selftest/kernel/`, and nothing under `pgmq/`, `kafka/`, `shibuya/pgmq-adapter/` or the three `shibuya/core-*` components. Third, an upstream diff of shibuya that touches only `shibuya-core/src/Shibuya/Internal/Runner/Master.hs` selects `shibuya/**`, `kafka/**`, `keiro/queue/**` and `runtime/**` and selects no scenario under `keiro/process-manager/`, `keiro/router/` or `keiro/inbox/`; the same diff touching `shibuya-core/src/Shibuya/Core/Ack.hs` does select those three, and still selects nothing under `keiro/command/`, `keiro/outbox/` or `keiro/workflow/`. Fourth, an upstream diff of keiro touching only `keiro/src/Keiro/Outbox/Schema.hs` selects `keiro/outbox/**` and `runtime/**` only, and one touching only `keiro/test/` or `docs/` selects nothing and reports the ignored paths. Fifth, `--since` over a change confined to `kenshou-kiroku/` selects `kiroku/**` only, over `kenshou-measure/` selects every scenario, over `docs/` selects nothing and exits 0, and over a commit that changes only the `kiroku-store` pin in `cohort/released.json` equals the second selection.

For the matrix, a plan for `--changed kiroku-otel` contains telemetry corners even though the policy says `default-only`, and its reasons name `kiroku-otel`; a plan with `--dimension-policy pairwise` for a scenario supporting all values has at most twenty configurations and covers every value pair; no entry of kind `benchmark` has `pg.durability=fsync-off`; every benchmark appears exactly `trials` times per arm with arm order alternating between consecutive trial indices; with `--budget-minutes 5` the `skipped` list contains `over-budget` entries and no benchmark group is partially present; planning twice with the same `--seed` gives documents that differ only in `planId`, `createdAt` and `runId` values (`jq 'del(.planId, .createdAt, .runs[].runId)'` of both are identical). Cutting any `spec` out of a plan with `jq '.runs[0].spec'` and giving it to `kenshou run --spec` is accepted.

For execution, the transcript in Concrete Steps must hold: the self-test plan exits 1 with worst outcome `failed`, and the `smoke` suite exits 0. To prove resumption, start the self-test plan, press Control-C during the fourth entry, and observe that `plan-summary.json` shows three completed entries and one `running`; run the same command with `--resume` and observe that the first three are reported as skipped, the fourth runs under a new run identifier while the interrupted directory is untouched, and the summary lists two attempts for it. Running `kenshou execute` without `--resume` into the same directory, or with a different plan, exits 2 and changes nothing. `cabal test kenshou-core-test` passes, and `cabal run kenshou -- plan --graph-check` exits 0.


## Idempotence and Recovery

`kenshou plan` has no side effects beyond the file named by `--out`, reads git with read-only commands (`git diff --name-only`, `git ls-files`, `git show`) and never checks anything out, in this repository or in an upstream checkout; it can be rerun freely. All code changes are additive: new modules under `Kenshou/Plan/`, new files in `schemas/` and `suites/`, one data file, two subcommands, and at most one new option on `kenshou run`. If the build breaks half-way through a milestone, the new modules can be removed from `exposed-modules` in `kenshou-core/kenshou-core.cabal` without affecting EP-2's code.

`kenshou execute` is safe to repeat only with `--resume`; without it, a non-empty output directory is refused rather than overwritten. The summary is always written to a temporary file in the same directory and renamed, so a crash cannot leave a truncated summary; if the executor is killed with `SIGKILL` between a child's exit and the summary write, the resumed execution re-runs that entry under a new identifier and the orphaned run directory remains as extra, valid evidence. A stale `.execute.lock` is detected by checking whether the recorded process is alive. Child processes own their PostgreSQL instances through the kernel and clean them up themselves; after a hard kill, look for leftovers with `pgrep -fl 'postgres.*kenshou'` and remove stale temporary data directories as the kernel's plan describes. Unit tests that create git repositories do so under the system temporary directory and delete them in a `bracket`.

If upstream packages change their dependencies, `--graph-check` fails until `kenshou-core/data/components.json` is corrected; that failure is the intended signal, not something to silence. If the two cohorts legitimately have different edges, declare the union, because over-selection is safe.


## Interfaces and Dependencies

Libraries, all already in the build plan through the kernel unless noted: `aeson` for every document, `containers` (`Data.Map`, `Data.Set`, `Data.Graph`), `text`, `bytestring`, `directory`, `filepath`, `time`, `process` (git and child processes; a GHC boot library), `unix` (signals, process liveness), the kernel's SHA-256 and UUIDv7 helpers (reuse whatever `Kenshou.Core.Manifest` and the runner use; do not add a second hashing library), `optparse-applicative` in `kenshou-cli`, and one new dependency, `file-embed`, for the embedded graph. Tests use `hspec`, `hspec-hedgehog` and `temporary`. No runtime library of the cohort is imported by `Kenshou.Plan.*`.

From `docs/plans/1-bootstrap-the-kenshou-repository-and-pin-the-runtime-cohort.md` this plan consumes `cohort/released.json` and `cohort/head.json` (`kenshou.cohort/v1`), `Kenshou.Core.Cohort` (the resolved identity and, if exposed, the `plan.json` decoder) and the `Justfile`. From `docs/plans/2-build-the-harness-kernel-for-scenarios-dimensions-run-specs-and-results.md` it consumes the scenario, knob, dimension, bundle, run-specification, run-result and outcome types, the run-specification validator, the default environment per placement, the exit-code mapping, `Kenshou.Cli.Registry`, `kenshou list --json` and `kenshou run --spec`.

At the end of Milestone 1 these must exist: `Kenshou.Plan.Selector` (`parseSelector`, `renderSelector`, `matches`), `Kenshou.Plan.Catalog` (`ScenarioInfo`, `fromBundles`, `readCatalogFile`), `Kenshou.Plan.Components` (`ComponentGraph`, `ComponentRef`, `embeddedGraph`, `loadGraphFile`, `validateGraph`, `parseRef`, `dependents`, `graphDigest`), `Kenshou.Plan.Components.Check` (`checkAgainstPlanJson`, `lintAgainstCatalog`), `kenshou-core/data/components.json`, `schemas/component-graph.v1.schema.json`, and `kenshou plan --graph-show|--graph-check`. At the end of Milestone 2: `Kenshou.Plan.Change` (`Change`, `Reason`, `Selected`, `selectScenarios`, `selectAll`), `Kenshou.Plan.Change.Cohort` (`readCohortPackages`, `diffCohorts`), `Kenshou.Plan.Change.Git` (`changesSince`, `changesFromUpstream`), and `kenshou plan --explain` with every change input. At the end of Milestone 3: `Kenshou.Plan.Policy` (`PlanPolicy`, `mergePolicy`), `Kenshou.Plan.Matrix` (`DimensionPolicy`, `KnobPolicy`, `expandScenario`, `pairwiseCover`), `Kenshou.Plan.RunPlan` (`RunPlan`, `PlannedRun`, `TrialInfo`, `Skipped`, `buildPlan`, `stampPlan`, JSON instances), `schemas/run-plan.v1.schema.json`, and the ADR. At the end of Milestone 4: `Kenshou.Plan.Suite` (`Suite`, `readSuite`, `applySuite`), `Kenshou.Plan.Summary` (`PlanSummary`, `worstOutcome`, `summaryExitCode`, `writeSummary`), `Kenshou.Plan.Execute` (`ExecuteOptions`, `executePlan`), `schemas/suite.v1.schema.json`, `schemas/plan-summary.v1.schema.json`, `suites/{smoke,change,nightly,weekly-soak,release}.json`, `kenshou execute`, and `docs/planning.md`.

Other plans consume this one as follows. Every coverage plan (`docs/plans/8-…` to `docs/plans/15-…`) gets its scenarios selected by naming its component segments as listed in Milestone 1; `kenshou plan --graph-check` tells its author when a scenario is an orphan, and the fix is a selector in `kenshou-core/data/components.json`, made by whoever maintains this plan's code. `docs/plans/4-build-the-measurement-toolkit-for-load-latency-sampling-and-comparison.md` reads `trial {group, arm, index, of}` and `trialOrdering` to pair runs, and may register a further ordering strategy. `docs/plans/7-add-telemetry-arms-and-measure-observability-overhead.md` can obtain its arms from the `telemetry-corners` policy. `docs/plans/17-run-kenshou-on-leased-cells-with-payloads-submission-and-retrieval.md` submits a run plan as the cell's work file and invokes `kenshou execute --plan <work file> --out <output directory> --environment <cell environment>`; the directory layout above is what the cell publishes. `docs/plans/18-record-runs-and-attestations-in-a-historic-okf-evidence-bundle.md` can use the pre-assigned run identifiers and `plan-summary.json` to tell a complete result set from a truncated one. The house CI platform calls `kenshou plan --suite change --since <base>` and `kenshou execute` and branches on exit codes 0, 1, 2, 3 and 4.
