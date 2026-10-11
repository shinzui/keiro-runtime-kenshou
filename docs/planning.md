# Planning and executing verification

`kenshou plan` turns a description of change into a versioned
`kenshou.run-plan/v1` document. `kenshou execute` runs that document one entry
at a time and maintains a resumable `kenshou.plan-summary/v1`.

## Describe the change

Use one or more of these inputs:

- `--changed COMPONENT[,COMPONENT]` names graph components or sub-components.
- `--cohort-from A --cohort-to B` compares package pins in two cohort descriptors.
- `--since REV` maps changes in this repository, including cohort descriptor updates.
- `--upstream-diff REPO=PATH@A..B` maps a revision range in an upstream checkout.
- `--all` selects the entire catalog.

The checked-in graph at `kenshou-core/data/components.json` contains both Cabal
build edges and reviewed runtime edges. Planning follows transitive dependents;
`--explain` prints the shortest path that selected each scenario. An input that
cannot be mapped safely selects everything and emits a warning. Run
`kenshou plan --graph-check` after dependency changes.

## Shape the matrix

`--dimension-policy` accepts `default-only`, `telemetry-corners`, `pairwise`, or
`full`. Telemetry-component changes automatically require at least telemetry
corners. Benchmarks always use durable PostgreSQL. `--knob-policy defaults`
uses declared defaults; `declared-variants` adds the scenario's reviewed knob
variants. `--dim NAME=VALUE` and `--set NAME=VALUE` pin individual values.

Tier, kind, placement, and time filters are controlled by `--max-tier`,
repeatable `--kind`, `--placement`, and `--budget-minutes`. Benchmarks use at
least three interleaved trials and are admitted or skipped as a whole.

## Named suites

The files under `suites/` encode common intentions:

- `smoke`: quick local pre-push evidence.
- `change`: standard-cost evidence selected from a described change.
- `nightly`: broad pairwise correctness, concurrency, and benchmark evidence.
- `weekly-soak`: cell-hosted soak evidence.
- `release`: every kind and tier with five benchmark trials.

For example:

```sh
cabal run kenshou -- plan --suite change --changed kiroku-store --out plan.json
cabal run kenshou -- plan --suite smoke --out smoke.json
```

Command-line policy options override the named suite. Use `--suite-file` for an
alternate `kenshou.suite/v1` document.

## Plan identity and safe resume

A plan records its graph digest, resolved cohort plan hash, policy, seed,
selection reasons, skips, estimates, and one UUIDv7 for every planned run. With
the same inputs and seed, documents differ only in their stamped identifiers
and creation time.

Execute locally with:

```sh
cabal run kenshou -- execute --plan plan.json --out results
```

The executor copies the exact plan to `results/run-plan.json`, writes child
specifications under `results/specs/`, and atomically refreshes
`results/plan-summary.json` after every attempt. Resume only with the identical
plan:

```sh
cabal run kenshou -- execute --plan plan.json --out results --resume
```

A digest mismatch is refused. Completed entries are skipped; an interrupted
entry receives a fresh run ID so an earlier run directory is never overwritten.
The summary's exit code is 0 for passed, 1 for failed, 3 for inconclusive, and 4
for errored or infrastructure failure. Reproduced known defects do not block.


## Bounded runtime performance planning

`kenshou perf plan` resolves immutable baseline and candidate commits through the
registered Mori HTTPS upstream and writes a new directory of pinned inputs:

```sh
cabal run kenshou -- perf plan --request request.json --out perf-planning
```

The request uses `kenshou.perf-request/v1` (see
`schemas/kenshou.perf-request.v1.schema.json`). Its target components are IDs from
the cohort descriptor. Both source manifests are inspected independently; the
generated descriptors retain every non-target pin. The output includes the
request, source snapshots, graph, effective profiles, comparison policies,
`plan.json`, both generated cohort descriptors, and an artifact manifest.
Planning does not build payloads or acquire a cell.

The candidate core and PGMQ profiles in
`policies/performance/catalog.v1.json` describe fixed-load latency with full raw
samples, count-bound steady work, zero warm-up/cooldown, and cold reset. Their
cost estimates include both arms, five pairs, and two replacement pairs. They
are currently uncalibrated. A normal gating request therefore reports incomplete
coverage; `purpose: "calibration"` can retain explicitly selected profiles, with
`gatingEligible: false`. An explicit `control: "aa"` requires identical commits
and a nonempty profile list, which is retained even when the diff is empty.

`coverageMode: "selected-profiles"` requires an explicit profile list and reports
its completion separately from `changeCoverage`. An unknown source input selects
conservatively; only explicit documentation paths outside this project's source
roots can establish `not-applicable`. Budget exclusions omit whole configurations
and remain visible. Exit zero from `perf plan` means that a planning document was
written successfully; inspect coverage and eligibility before treating it as
performance acceptance.


`kenshou perf prepare --request request.json --out .dev/perf-preparation` requires a
clean committed harness. It creates a detached harness clone, immutable generated
flake inputs, independent Cabal bounds plans, and Linux Nix build inventories.
It rejects unrelated dependency or flag drift before publishing either payload.
Successful output names `.dev/perf-preparation/evidence/prepared.json`; the sibling
`work` directory retains preparation logs, including failures. `--cache` selects
a payload descriptor cache; every cache hit checks the recorded cohort/harness
identity and downloads the content-addressed bundle to verify its digest and size.
The active cohort and its Cabal build directory are not modified.

Preparation is still awaiting the same-source cache and candidate-only live
acceptance in Plan 25. Current Shibuya commits cannot be combined with a historical
full-runtime template merely by lifting downstream bounds. A preparation failure
is reported as exit 4, with the failing stage log retained. Successful preparation
establishes build inputs and payloads; calibrated performance acceptance still
requires the remaining execution and live calibration milestones.
