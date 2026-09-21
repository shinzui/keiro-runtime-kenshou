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
