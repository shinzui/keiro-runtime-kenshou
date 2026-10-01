---
id: 22
slug: derive-fix-verification-dispositions-from-recorded-evidence
title: "Derive fix-verification dispositions from recorded evidence"
kind: exec-plan
created_at: 2026-10-01T16:22:58Z
intention: "intention_01m3w49yheevg9mzkyfab1mqy4"
master_plan: "docs/masterplans/2-close-the-verification-and-repair-loop-for-the-keiro-runtime-in-rounds.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-01T16:22:58Z
---

# Derive fix-verification dispositions from recorded evidence

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

An owner marking a bug report `fixed` is a claim. Kenshou's job is to say whether its evidence
agrees. After this plan, a maintainer can ask, for any owner record and any cohort, what the
recorded runs show:

```bash
cabal run -v0 kenshou -- owners verify --cohort shibuya-current
cabal run -v0 kenshou -- owners verify --record mori://shinzui/shibuya/okf/bug-reports/concepts/BUG-8
```

Each owner record receives exactly one disposition per cohort, with the runs and reasons behind
it: `verified-fixed`, `still-reproduces`, `regressed`, `reproduces-as-expected`,
`not-reproduced`, `different-failure`, `not-yet-released`, `not-run`, or `unverifiable`. Each
disposition also carries the trust of its evidence: `confirmed`, `unverified`, or `local`.

The answer is derived at read time from immutable run records. Nothing is written into the
evidence bundle or into any owner repository.

This is child plan EP-3 of
`docs/masterplans/2-close-the-verification-and-repair-loop-for-the-keiro-runtime-in-rounds.md`.
It hard-depends on these two plans:
- EP-1, `docs/plans/20-report-owner-record-status-for-every-kenshou-finding.md`, for owner
  records and the owner index;
- EP-2, `docs/plans/21-reconcile-known-defect-cohort-scopes-with-owner-records.md`, for
  `scopeAppliesToPackages` and the catalog's scope data.


## Progress

- [ ] Milestone 1: an evidence loader returns, for a set of scenarios, each run's cohort
  components, outcome, trust and, when available, failure labels, from both the bundle and local
  sealed runs. Fixture tests cover each source.
- [ ] Milestone 2: the pure disposition function and its aggregation rule, with a test per
  disposition and per aggregation case.
- [ ] Milestone 3: `kenshou owners verify` (text and `--json`) with its schema. On the real
  repository it shows Shibuya BUG-8 as `verified-fixed` on the `shibuya-current` cohort, with
  `local` trust when only local runs exist. The new ADR is recorded.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Join through the scenario catalog, not the run record's `knownDefects` list.
  Rationale: `defectDisposition` in `kenshou-core/src/Kenshou/Core/Run.hs` keeps only defects
  whose scope applies to the run's cohort, and the recorder copies only those into the record's
  `knownDefects`. A passing run on a cohort that contains the fix therefore has no link to the
  record it verifies. The catalog's current declarations, evaluated against the run's recorded
  `components`, restore that link. The join deliberately uses the current declaration even for
  older runs. For example, local run `runs/01a0e479-e310-7716-8cc3-af7b54e43fca/run-result.json`
  recorded its reproduced defect as `mori://shinzui/shibuya/okf/reviews/concepts/REV-8`, before
  the owner filed `mori://shinzui/shibuya/okf/bug-reports/concepts/BUG-8`. Today's catalog
  attributes the same scenario and labels to BUG-8.
  Date: 2026-10-01

- Decision: Only `confirmed` evidence supports a headline `verified-fixed`. `unverified` and
  `local` evidence is shown with its trust label.
  Rationale: ADR-18 makes attestation the evidence of what was checked. The 2026-09-29 baseline
  report already distinguishes local sealed runs from published, attested records. Most
  finding-level runs are still local.
  Date: 2026-10-01


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Kenshou is this repository's verification harness for the keiro runtime. The terms this plan
relies on:

- **Run result:** each `kenshou run` writes a sealed run directory, by default `runs/<runId>/`.
  That directory is ignored by Git (see `.gitignore`). It contains `run-result.json` (schema
  `schemas/run-result-v1.schema.json`), produced in `kenshou-core/src/Kenshou/Core/RunResult.hs`,
  with these keys:
  - `outcome`: `passed`, `failed`, `errored`, `infrastructure-failure`, or `inconclusive`;
  - `failures`: the failure labels;
  - `knownDefect`: the applicable defect or defects with a status of `reproduced`,
    `different-failure` or `not-reproduced`, present only when an applicable defect exists;
  - `cohort`: the resolved cohort identity with every package name, version and source.
- **Evidence bundle:** `docs/verification/` is an OKF bundle of immutable `Verification Run`
  records under `runs/<layer>/<yyyy>/<mm>/<runId>.md`. Each record's frontmatter carries:
  - `scenario`, `outcome`, `cohort`;
  - `components`, a list of `{package, project, source, version}`;
  - `knownDefects`, the applicable defect URIs only;
  - `data`, digest-pinned `gs://` links, one of which is the run's `run-result.json`.

  The record carries no failure labels. Attestations live under
  `docs/verification/attestations/`.
- **History:** `Kenshou.Evidence.History` (`kenshou-evidence/src/Kenshou/Evidence/History.hs`)
  provides `history :: FilePath -> HistoryQuery -> IO (Either HistoryError HistoryDocument)`.
  Its entries carry the record as JSON, `outcome`, `startedAt`, `scenario`, and a `trust` of
  `machine-confirmed`, `human-reviewed` or `unverified`. The CLI surface is `kenshou history`,
  with filters `--scenario`, `--cohort-component PACKAGE[=VERSION]`, `--outcome`,
  `--confirmed-only` and `--json`.
- **Fetching data:** `Kenshou.Evidence.Store` exposes `fetchObject :: Text -> FilePath -> IO (Either StoreError ())`
  for `gs://` URIs. It is used by `kenshou attest`, which also checks the SHA-256 recorded in
  the data link. Reuse that path to read a record's `run-result.json` when labels are needed,
  and verify the digest.
- **Scope evaluation:** EP-2 exports `scopeAppliesToPackages :: [ScopePackage] -> CohortScope -> Bool`
  from `kenshou-core/src/Kenshou/Core/Scenario.hs`. Build `ScopePackage` values from either a
  record's `components` or a run result's `cohort`.
- **Owner index:** EP-1 exports `buildOwnerIndex` from `Kenshou.Owners.Index`, giving each
  canonical owner URI its `OwnerRecord` (with `fixedVersion`, `lastWorkingVersion`, and the
  `canonical` record for duplicates) and its citing scenario defects.

**Real data on 2026-10-01.** The bundle holds 73 records: 70 runs and 3 comparisons. Most of
the runs behind numbered findings are local only. One fix was already checked informally:
`docs/findings/27-shibuya-health-probes-ignore-terminal-lifecycle.md` cites "isolated Hackage
0.10.0.0 controls" that passed, recorded as local `runs/...` paths, for
`mori://shinzui/shibuya/okf/bug-reports/concepts/BUG-8`. The owner records `fixedVersion: "0.10.0.0"`.

Relevant ADRs:
- [ADR-18](../adr/0018-keep-verification-records-immutable-and-derive-baselines.md): records
  are immutable, the bundle has exactly three concept types, and conclusions such as baselines
  are derived at read time. A disposition is such a conclusion.
- [ADR-14](../adr/0014-distinguish-documented-limitations-from-known-defects.md): defects cover
  only their labels and cohorts.
- [ADR-2](../adr/0002-every-result-carries-a-resolved-cohort-identity.md): every result
  carries its resolved cohort identity, which is what makes the scope evaluation possible.


## Plan of Work

### Milestone 1: an evidence loader

Add `Kenshou.Owners.Evidence` to `kenshou-owners` (add `kenshou-evidence` to its
`build-depends`). Define `Observation`:

```haskell
data Observation = Observation
  { runId :: Text, scenario :: ScenarioId, startedAt :: UTCTime, cohortName :: Text
  , packages :: [ScopePackage], outcome :: Outcome, failures :: Maybe [Text]
  , trust :: Trust }   -- Trust = Confirmed | Unverified | Local
```

Load observations for a set of scenario identifiers from two sources:
- **The bundle.** Query `history` per scenario. Take `components` from the entry's record. Map
  `machine-confirmed` and `human-reviewed` to `Confirmed`, and `unverified` to `Unverified`.
  Only with `--fetch-labels`, fetch `run-result.json` through `Store.fetchObject`, verify its
  digest, and read `failures`. Without it, `failures = Nothing` for failed runs.
- **Local sealed runs, when `--include-local DIR` is given.** Read `DIR/*/run-result.json`. Map
  `cohort` to `ScopePackage` values, read `failures`, and set `trust = Local`. Skip a local run
  whose `runId` also appears in the bundle, so the published copy wins.

### Milestone 2: the disposition rule

`Kenshou.Owners.Disposition` is pure.

For one citing defect `d` (from the owner index) and one observation `o` of `d`'s scenario, let
`applies = scopeAppliesToPackages o.packages d.appliesTo`. Then:
- `applies`, `o` failed, and `failures ⊆ d.expectedFailures`: `reproduces-as-expected`.
- `applies` and `o` passed: `not-reproduced`.
- Not `applies` and `o` passed: `verified-fixed`.
- Not `applies`, `o` failed, and `failures ⊆ d.expectedFailures`: `still-reproduces`.
- `o` failed with labels outside `d.expectedFailures`, whether or not `applies`:
  `different-failure`.
- `o` failed and `failures` is `Nothing`: `unverifiable`, with the reason
  "labels unavailable; rerun with --fetch-labels".
- `o` is `errored`, `infrastructure-failure` or `inconclusive`: not counted. It is listed as
  excluded evidence.

Per record and cohort, take the latest counted observation of each citing scenario, then
aggregate in precedence order:
1. `regressed`, when the result would be `still-reproduces`, and either an earlier cohort was
   `verified-fixed` for this record or the owner record carries `lastWorkingVersion`;
2. `still-reproduces`;
3. `different-failure`;
4. `unverifiable`;
5. `reproduces-as-expected`;
6. `not-reproduced`;
7. `verified-fixed`, only when every citing scenario with a counted observation is
   `verified-fixed`.

When there are no counted observations, the result is one of these:
- `not-yet-released`, if the owner's `fixedVersion` is `Unreleased`, or no observed cohort pins
  the affected package at or above the fixed version;
- `not-run`, otherwise;
- `unverifiable`, for unresolved records or `Unparseable`/`Unknown` versions.

The record's trust is the weakest trust among the observations used. Duplicates are evaluated
through their `canonical` record and reported under both URIs.

### Milestone 3: the command and the ADR

Add a `verify` subcommand to `ownersCommand` with these options:
- `--cohort NAME` (repeatable; default: every cohort observed);
- `--record URI` (repeatable);
- `--bundle DIR` (default `docs/verification`);
- `--include-local DIR` (default off; `runs` is the usual value);
- `--fetch-labels`;
- `--json`, writing `kenshou.owner-dispositions/v1` with a schema in
  `schemas/owner-dispositions-v1.schema.json`, added to `just schemas-check`.

Text output groups records by disposition. For each record it shows the trust label, the run IDs
used, and the reason.

Create an ADR, "Derive fix-verification dispositions and never write them into owner records".
Allocate its handle with `okf id next docs/adr --profile docs/adr/profile.dhall ADR` (expected
ADR-22) and validate with `just adr-validate`. It records:
- the vocabulary;
- that dispositions are derived from records and the catalog, not stored;
- that owner records are never written;
- that only confirmed evidence counts as headline verification.


## Concrete Steps

From the repository root, inside `nix develop`:

```bash
cabal test kenshou-owners:test:kenshou-owners-test
cabal run -v0 kenshou -- owners verify --record mori://shinzui/shibuya/okf/bug-reports/concepts/BUG-8 --include-local runs
cabal run -v0 kenshou -- owners verify --cohort shibuya-current --include-local runs --json > /tmp/dispositions.json
check-jsonschema --schemafile schemas/owner-dispositions-v1.schema.json /tmp/dispositions.json
just adr-validate
```

Expected, abbreviated:

```text
verified-fixed (local)  mori://shinzui/shibuya/okf/bug-reports/concepts/BUG-8
  cohort shibuya-current: shibuya-metrics 0.10.0.0 is outside VersionBelow "shibuya-metrics" "0.10.0.0"
  runs: 01a0e459-1935-7206-baa0-82f79790af66 (passed), 01a0e458-8a23-7078-b5b3-bc97aaa8e42c (passed)
reproduces-as-expected (local)  mori://shinzui/shibuya/okf/bug-reports/concepts/BUG-8
  cohort released: shibuya-metrics 0.9.0.3 is inside the scope; labels REV-8-F1 matched
```

If the local runs named in finding 27 are no longer present on the implementer's machine, the
first block reads `not-run`. That is correct behavior and does not fail acceptance. Show it with
the fixture tests instead.


## Validation and Acceptance

Fixture tests provide one test per disposition and per aggregation precedence step, plus these
cases:
- a `local` run shadowed by a bundle record with the same `runId`;
- a failed bundle run without labels, giving `unverifiable`;
- the same run with labels fetched from a fake store;
- a duplicate record evaluated through its canonical record.

The fixtures use small JSON and Markdown files under `kenshou-owners/test/fixtures/evidence/`.

On the real repository, `owners verify --cohort released --include-local runs` must report
`reproduces-as-expected` for at least one Kafka defect whose released-cohort failure is recorded
in the bundle. Use `kenshou history --scenario <id>` to choose one, such as the rebalance record
`docs/verification/runs/kafka/2026/09/01a0e3bd-ef03-71b4-9486-01ed1bd56a02.md`. It must report
no `verified-fixed` with `confirmed` trust that a person cannot trace to a passing confirmed
record.


## Idempotence and Recovery

The command only reads. With `--fetch-labels`, it downloads into a temporary directory removed on
exit, and it refuses a digest mismatch rather than using the bytes. Rerunning is always safe.


## Interfaces and Dependencies

These are consumed by EP-4, `docs/plans/23-define-the-round-protocol-and-its-report.md`:

```haskell
-- Kenshou.Owners.Disposition
data Disposition = VerifiedFixed | StillReproduces | Regressed | ReproducesAsExpected
                 | NotReproduced | DifferentFailure | NotYetReleased | NotRun | Unverifiable
data Trust = Confirmed | Unverified | Local
data RecordDisposition = RecordDisposition
  { record :: Text, cohort :: Text, disposition :: Disposition, trust :: Maybe Trust
  , runs :: [Text], excluded :: [Text], reasons :: [Text] }
deriveDispositions :: Map Text OwnerEntry -> [Observation] -> [Text] {- cohorts -} -> [RecordDisposition]

-- Kenshou.Owners.Evidence
loadObservations :: EvidenceSources -> Set ScenarioId -> IO [Observation]
```

The disposition vocabulary is the MasterPlan's Integration Point 4. Change it there first.
