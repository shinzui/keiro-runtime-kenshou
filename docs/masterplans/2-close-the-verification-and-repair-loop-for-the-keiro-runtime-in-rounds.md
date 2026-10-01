---
id: 2
slug: close-the-verification-and-repair-loop-for-the-keiro-runtime-in-rounds
title: "Close the verification and repair loop for the keiro runtime in rounds"
kind: master-plan
created_at: 2026-10-01T16:21:09Z
intention: "intention_01m3w49yheevg9mzkyfab1mqy4"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-01T16:21:09Z
---

# Close the verification and repair loop for the keiro runtime in rounds

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

[MasterPlan 1](1-build-an-extensive-verification-suite-for-the-keiro-runtime.md) builds the
verification suite and records an initial baseline against the pinned released cohort. A
*cohort* is the exact, named set of runtime package versions a build links, described by
`cohort/<name>.json` and `cohort/<name>.project` (see
[ADR-2](../adr/0002-every-result-carries-a-resolved-cohort-identity.md)). While building the
suite, MasterPlan 1 found defects in the libraries it verifies and filed them in the
repositories that own those libraries, as OKF bug reports and improvement requests. An *owner
record* is one such filed report: a Markdown file with YAML frontmatter in the owning repository,
addressed by a canonical `mori://` URI such as
`mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-1`. MasterPlan 1 deliberately
does not own the fixes. Its Decision Log (2026-09-27) says owners plan and implement repairs, and
that verifying those repairs waits until the platform owner asks for it.

This MasterPlan is that request, turned into a repeatable process. It does not take over repair.
It owns the loop around repair. One pass of the loop is a *round*:

1. Freeze the run set the round compares against.
2. Owners fix and release, on their own schedules and under their own plans.
3. Kenshou pins a candidate cohort that contains the released fixes.
4. Kenshou reruns only the affected scenarios.
5. Kenshou assigns every owner record in scope a disposition, collects any new findings, and
   publishes a round report.
6. The next round starts from that report.

When this initiative is complete, a maintainer can do the following from this repository. Run
one command, `kenshou owners status`, that prints every owner record kenshou's findings and
scenarios cite. For each record it shows the owner's current lifecycle status and versions
(following `duplicate` records to their canonical record), which owner plans cite it and the Rei
intentions those plans carry, and which local findings and scenarios depend on it. This replaces
the hand-maintained "Upstream issue register" table in MasterPlan 1.

The maintainer can run `kenshou owners scopes` to learn which `KnownDefect` cohort scopes in the
scenario catalog disagree with what the owner records now say, and what scope each should have.
They can ask, for any owner record and any cohort, whether the recorded evidence shows it
verified fixed, still reproducing, regressed, not yet released, or simply not yet run. Finally,
they can open a numbered round, plan its reruns from the base and candidate cohorts, execute
them, and publish a dated round report with one disposition per owner record. None of these
paths call a language model. Each is a deterministic join over files on disk and Mori lookups.

Included:

- the owner-record reader and the status report;
- known-defect scope reconciliation;
- disposition derivation from immutable evidence;
- the round definition, planning and report;
- the Rei wiring that lets a round wait on owner work;
- one real round, executed against a candidate cohort built from fixes owners have already
  released.

Excluded:

- **Fixing defects in owner repositories.** Owners keep repair authority.
- **Writing into owner records.** Kenshou never edits an owner's status, version fields or body.
  The owner's lifecycle is the owner's authority.
- **Automatic editing of Haskell `KnownDefect` declarations.** The scope check proposes; a person
  commits.
- **CI orchestration.** The house CI platform `kotei` owns that, as in MasterPlan 1.
- **An autonomous agent.** A shikigami "round steward" that reacts to owner releases is future
  work, and the report this initiative builds is the tool such an agent would call.
- **Rei features that are not shipped yet.** This initiative must work with Rei as it is today.


## Decomposition Strategy

The work splits along the data each step adds to the join. Each child plan produces a command
whose output a person can check by hand, and each later plan consumes the previous plan's data
types rather than re-deriving them.

The first plan, the owner-record ledger (EP-1, `docs/plans/20-report-owner-record-status-for-every-kenshou-finding.md`), gathers references.
It reads `docs/findings/*.md` and the scenario catalog's `KnownDefect` references. It resolves
each URI through `mori path`, parses the owner record's frontmatter, follows `duplicateOf`, and
locates owner plans that cite the record. That alone answers "where has everything got to?" and
retires the hand-maintained register.

The second plan (EP-2, `docs/plans/21-reconcile-known-defect-cohort-scopes-with-owner-records.md`) compares each scenario's declared `KnownDefect`
cohort scope with the owner record's `fixedVersion` and `affects` package. This is the step that
turns an owner's "fixed" into a verifiable claim. Once the scope excludes the fixed version, a
scenario that still fails on the fixed cohort becomes blocking, which is exactly how
`defectDisposition` in `kenshou-core/src/Kenshou/Core/Run.hs` already treats an inapplicable
defect.

The third plan (EP-3, `docs/plans/22-derive-fix-verification-dispositions-from-recorded-evidence.md`) derives, per owner record and cohort, a
disposition from the immutable run records in `docs/verification/`.

The fourth plan (EP-4, `docs/plans/23-define-the-round-protocol-and-its-report.md`) wraps those three into a round: a checked-in round
definition, round planning on top of `kenshou plan --cohort-from/--cohort-to`, a generated round
report, and the Rei wiring.

The fifth plan (EP-5, `docs/plans/24-run-the-first-repair-verification-round-against-a-fixed-cohort.md`) runs round 1 for real against a candidate cohort
assembled from fixes already on Hackage.

Two alternatives were rejected:

- **Merging EP-1 to EP-3 into one "status" plan.** It would hide three different trust levels:
  what the owner says, what the scope declares, and what the evidence shows. Those must stay
  separately checkable.
- **Recording dispositions as a fourth OKF concept type in `docs/verification/`.**
  [ADR-18](../adr/0018-keep-verification-records-immutable-and-derive-baselines.md) fixes the
  bundle at three types (`Attested Computation`, `Verification Run`, `Attestation`) and derives
  baselines at read time. A disposition is the same kind of derived conclusion as a baseline. It
  is derived from records, and the dated round report is the human-readable artifact that states
  it. Adding a stored type would also require an additive release of the shared profile
  `mori://shinzui/okf-profiles/profiles/verification-evidence` first, as ADR-18 states for any
  record-shape change.

Relevant local ADRs:

- [ADR-2](../adr/0002-every-result-carries-a-resolved-cohort-identity.md) (cohort identity) and
  [ADR-20](../adr/0020-pin-cell-payloads-to-verified-cohort-identities.md) (cell payloads pin
  verified cohorts). A round's base and candidate are cohorts in exactly this sense.
- [ADR-5](../adr/0005-select-runs-from-a-checked-in-component-graph.md). Rerun selection reuses
  the component graph and its over-select-when-unsure rule.
- [ADR-14](../adr/0014-distinguish-documented-limitations-from-known-defects.md).
  Known-defect references are canonical owner URIs; unpromised behavior is an implementation
  finding, not a defect; and only the scenario's specific failure labels and affected cohorts are
  covered.
- [ADR-18](../adr/0018-keep-verification-records-immutable-and-derive-baselines.md). Records
  are immutable, and conclusions are derived.

Cross-repository decisions that shape this initiative:

- `mori://shinzui/rei/okf/adrs/concepts/ADR-45` (status Proposed) resolves an intention's
  project from `scoped-to` project scope and ignores project Topics without a `mori` reference
  when choosing a planning target.
- The OKF bug-report profile is published as `coordination.bugReports` in
  `mori://shinzui/okf-profiles` v0.18.0. It makes `fixedVersion` required when `status` is
  `fixed`, and `duplicateOf` required when `status` is `duplicate`. Its version keys share a
  fixed vocabulary meant for mechanical comparison: a bare released version, `unreleased`, or
  `unknown`.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Report owner-record status for every kenshou finding | docs/plans/20-report-owner-record-status-for-every-kenshou-finding.md | None | None | Not Started |
| 2 | Reconcile known-defect cohort scopes with owner records | docs/plans/21-reconcile-known-defect-cohort-scopes-with-owner-records.md | EP-1 | None | Not Started |
| 3 | Derive fix-verification dispositions from recorded evidence | docs/plans/22-derive-fix-verification-dispositions-from-recorded-evidence.md | EP-1, EP-2 | None | Not Started |
| 4 | Define the round protocol and its report | docs/plans/23-define-the-round-protocol-and-its-report.md | EP-3 | None | Not Started |
| 5 | Run the first repair-verification round against a fixed cohort | docs/plans/24-run-the-first-repair-verification-round-against-a-fixed-cohort.md | EP-4 | MasterPlan 1 EP-10, EP-11, EP-13 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3). Soft
dependencies naming MasterPlan 1 rows refer to
[MasterPlan 1's registry](1-build-an-extensive-verification-suite-for-the-keiro-runtime.md#exec-plan-registry).


## Dependency Graph

EP-1 has no dependency and can start immediately. It needs only the existing scenario catalog,
the findings directory and the `mori` CLI. Every later plan consumes its `OwnerRecord` type and
its reference index, so EP-1 is the root.

EP-2 hard-depends on EP-1 because a scope can only be reconciled against an owner record that
has already been read and canonicalized. Duplicates must be followed first, or a scope would be
checked against a record whose versions are absent by design.

EP-3 hard-depends on EP-1 for the record-to-scenario index, and on EP-2 for the
scope-evaluation function that decides whether a recorded run's cohort is inside or outside a
defect's applicable range. Without EP-2, a passing run cannot be told apart from a run on a
cohort where the defect was never expected.

EP-4 hard-depends on EP-3 because a round report is a set of dispositions plus round metadata.

EP-5 hard-depends on EP-4, and only softly on MasterPlan 1's coverage plans for Shibuya, Kafka
and Keiro messaging (EP-10, EP-11, EP-13 there). A round can verify whichever records already
have scenarios; records without scenarios are reported as `not-run`, not hidden. EP-5 does not
wait for MasterPlan 1 to finish.

EP-1 and the first milestone of EP-2 (exposing scope data in the catalog JSON) can proceed in
parallel, because that milestone touches only `kenshou-core` catalog serialization. Everything
else is sequential. The chain is short, and each step's output is the next step's input.

Cross-repository relationships are soft or integration dependencies only. Nothing here blocks on
another repository:

- **Integration with Rei's proposed IR-6 and IR-7**
  (`mori://shinzui/rei/okf/improvement-requests/concepts/IR-6`,
  `mori://shinzui/rei/okf/improvement-requests/concepts/IR-7`) and the planning-target resolver
  (`mori://shinzui/rei/plans/231-resolve-an-intention-s-planning-target-from-project-scope`).
  EP-4 uses today's `rei intention create`, `rei project scope add` and `rei dependency add`.
  When those Rei features ship, the round wiring can move to them without changing the kenshou
  side.
- **Integration with the mori registry being fresh.** Every owner lookup goes through
  `mori path`. A registry that has not re-read an owner's bundle cannot resolve a newly filed
  record. On 2026-10-01, eight cited records were unresolvable until `mori register` was rerun
  for keiro and shibuya-kafka-adapter. EP-1 reports such records as `unresolved` instead of
  guessing a path.


## Integration Points

Integration Point 1: the `kenshou-owners` package and its `OwnerRecord` type.
- **Owner:** EP-1. Consumers: EP-2, EP-3, EP-4.
- EP-1 creates a library package `kenshou-owners/`. Like every package, it is picked up by the
  `kenshou-*/*.cabal` glob in `cabal.project`; nobody edits the package list.
- It depends on `kenshou-core` (scenarios, cohort identity) and `kenshou-evidence` (run-record
  history). It never depends on a layer package such as `kenshou-shibuya`, preserving
  [ADR-1](../adr/0001-layer-packages-never-import-one-another.md). It obtains scenarios through
  the `Registry` that `kenshou-cli` passes to every command in `CliEnv`.
- Module `Kenshou.Owners.Record` defines `OwnerRecord` with these fields:
  - `uri`: canonical `mori://` URI;
  - `kind`: bug report, improvement request, or other reference;
  - `status`: the owner's raw status string;
  - `affects`: a Mori URI;
  - `affectedVersion` and `fixedVersion`: each a version vocabulary value (`Released Version`,
    `Unreleased`, `Unknown`, or `Unparseable Text`);
  - `duplicateOf`;
  - `resolvedPath`;
  - `resolution`: `Resolved`, `Unresolved reason`, or `NotARecord`.
- Module `Kenshou.Owners.Index` defines the reference index, which maps each canonical URI to
  the citing findings, scenarios (with their `KnownDefect` entries), and owner plans with their
  intention IDs.
- EP-2, EP-3 and EP-4 extend this package with new modules. They do not redefine these types.
  If a consumer needs a new field, it adds it in `Kenshou.Owners.Record` and updates this section
  first.

Integration Point 2: the `kenshou owners` command group.
- **Owner:** EP-1. EP-2 to EP-4 add subcommands.
- EP-1 registers one `CliCommand` named `owners` in group `Analysis` in
  `kenshou-cli/src/Kenshou/Cli/Registry.hs`, following the extension contract stated there:
  "tool plans add command and topic values here without changing a central sum type".
- Subcommands:
  - `status` (EP-1);
  - `scopes` (EP-2);
  - `verify` (EP-3);
  - `round open`, `round plan`, `round report` (EP-4).
- Every subcommand supports `--json`, writing a versioned document: `kenshou.owner-status/v1`,
  `kenshou.owner-scopes/v1`, `kenshou.owner-dispositions/v1`, or `kenshou.round-report/v1`. As
  with every kenshou machine-readable mode, standard output carries only that document and
  diagnostics go to standard error.

Integration Point 3: catalog scope data.
- **Owner:** EP-2. Consumers: EP-3.
- Today `kenshou list --json` emits only each scenario's known-defect reference strings
  (`kenshou-core/src/Kenshou/Core/Bundle.hs`, the `knownDefect` key).
- EP-2 adds, additively, each defect's `expectedFailures` and a serialized `appliesTo` cohort
  scope (`AllCohorts`, or `OnlyWhen` with `ResolvedFromHackage`, `ResolvedFromGit`,
  `VersionBelow`, `RevisionIs` conditions).
- EP-2 also exports a pure function that evaluates a scope against a run record's `components`
  list, mirroring `cohortScopeApplies` in `kenshou-core/src/Kenshou/Core/Scenario.hs`.
- EP-3 must use that function rather than a second implementation.

Integration Point 4: disposition vocabulary.
- **Owner:** EP-3. Consumers: EP-4, EP-5.
- One owner record at one cohort has exactly one of these dispositions, with its reasons:

  | Disposition | Meaning |
  |---|---|
  | `verified-fixed` | A confirmed run on a cohort outside the defect's applicable scope passed. |
  | `still-reproduces` | A run outside the scope failed with the defect's expected labels. |
  | `regressed` | A later cohort fails after an earlier cohort was `verified-fixed`, or the owner record carries `lastWorkingVersion`. |
  | `reproduces-as-expected` | Inside the scope, the defect reproduced. |
  | `not-reproduced` | Inside the scope, the run passed: a possible unannounced fix, or a flaky reproduction. |
  | `different-failure` | A failure carries labels the defect does not cover. |
  | `not-yet-released` | The owner's `fixedVersion` is `unreleased`, or no cohort pins the fixed version. |
  | `not-run` | No scenario cites the record, or no run exists on the cohort. |
  | `unverifiable` | Unresolved record, unparseable version, or a reference that is not an owner record. |

- Every disposition also carries an evidence trust attribute:
  - `confirmed`: a published bundle record whose `kenshou history` trust is
    `machine-confirmed` or `human-reviewed`;
  - `unverified`: a published bundle record whose history trust is `unverified`;
  - `local`: an unpublished sealed run under `runs/`.

  Only `confirmed` evidence may support `verified-fixed` in a round report's headline counts.
- Bundle records carry the outcome but not the failure labels. Telling `still-reproduces` from
  `different-failure` requires the run's `run-result.json`, read from the record's digest-pinned
  data link or a local sealed run. When labels are unavailable, the disposition is `unverifiable`
  with that reason.
- EP-4 renders these values and never adds new ones.
- Changing the vocabulary is a decision recorded here and in the ADR created by EP-3.

Integration Point 5: round definitions and reports.
- **Owner:** EP-4. Consumer: EP-5.
- A round is a checked-in JSON document `rounds/<n>.json` with schema `kenshou.round/v1`. It
  names:
  - the round number;
  - the base cohort and the frozen base run set (the base run plan's digest and the run IDs it
    produced);
  - the candidate cohort;
  - the owner records in scope;
  - the round's Rei intention ID.
- The report is generated to `docs/reports/<date>-round-<n>.md` and has the same mutable,
  dated-reading status as `docs/reports/2026-09-29-runtime-baseline.md`.

ADR candidates:

- **EP-3, likely ADR-22:** "Derive fix-verification dispositions and never write them into owner
  records". It extends ADR-14 and ADR-18.
- **EP-4, likely ADR-23:** "Verify owner repairs in numbered rounds against frozen base run
  sets". This records why MasterPlan 1's baseline is never mutated and why each round has its
  own base.
- **EP-2 may amend ADR-14** to state that a `KnownDefect` scope's upper bound comes from the
  owner record's `fixedVersion`, never from an anticipated release number.


## Progress

Coordination snapshot (2026-10-01): MasterPlan created with five child plans, all Not Started.
EP-1 can start now. MasterPlan 1 is still In Progress (EP-8 and EP-10 to EP-17 open), and its
Decision Log of 2026-09-27 defers fix verification "until the platform owner asks". This
MasterPlan is that request, and does not change MasterPlan 1's remaining work.


## Surprises & Discoveries

- Owner status has moved under the hand-maintained register. The 2026-09-29 baseline report
  counts 14 fixed, 16 reported and 2 duplicate among 32 distinct owner bug records. On
  2026-10-01, reading the owner files directly, 16 of the bug records cited from
  `docs/findings/` were `fixed`. A register written by hand goes stale between checkpoints,
  which is why EP-1 computes it.
- Some existing `KnownDefect` scope bounds were chosen without an owner version. In
  `kenshou-kafka/src/Kenshou/Suite/Kafka/Concurrency/Zombie.hs` and `BrokerOutage.hs`, the
  scopes for `mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-4` and `BUG-3`
  are `VersionBelow "shibuya-kafka-adapter" "0.9.0.2"`. Both owner records are `reported`, with
  no `fixedVersion`. `BarrierOverwrite.hs` scopes BUG-5 below `0.9.0.2`, while the owner records
  `fixedVersion: "0.9.1.0"`. This is the concrete case EP-2 exists to catch.
- Owner-record fields are less uniform than the profile intends:
  - `affects` is sometimes a package URI (`mori://shinzui/shibuya/packages/shibuya-core`) and
    sometimes a whole project (`mori://shinzui/keiro`, which ships five packages).
  - `fixedVersion` is sometimes `unreleased`.
  - One kiroku report carries `affectedVersion: "0.8.0.1 through 0.9.0.0"`, which is free text.

  EP-1 must report these as they are; EP-2 must map project-level `affects` through the cohort
  descriptor and refuse to guess for a multi-package project.
- Owner plans cite their own repository's records by local handle or file name rather than
  canonical URI. For example, keiro plan 300 is
  `docs/plans/300-poll-pgmq-client-side-for-long-poll-job-workers-to-fix-bug-4-and-bug-6.md`
  in `mori://shinzui/keiro`. Plan discovery must accept a canonical URI from any repository,
  and a local handle or record path only within the owning repository.
- The Mori registry lags owner bundles in more places than the two re-registered on 2026-10-01.
  After keiro and shibuya-kafka-adapter were re-registered, `mori path` still could not resolve
  `mori://shinzui/shibuya-pgmq-adapter/okf/bug-reports/concepts/BUG-4`, although
  `docs/bug-reports/long-poll-outlives-a-killed-client-and-consumes-a-read-attempt.md` in that
  repository carries `bugId: BUG-4`. Keiro plan 300 cites that record. EP-1 reports such records
  as `unresolved`, and the operator fix is `mori register --path <owner checkout>`.
- Owner bug-report handles live in `bugId` (`coordination.bugReports` declares
  `idField = "bugId"`), and several owners name report files by slug rather than number. Handles
  must come from frontmatter, never from file names.
- Some `KnownDefect` references are not owner records: Keiro MasterPlans, Keiro user
  documentation, a Shibuya review concept, and a kenshou plan in the selftest. EP-1 classifies
  them as `other` so they are visible and are not miscounted as bugs.
- Fix verification already happens informally. `docs/findings/27-shibuya-health-probes-ignore-terminal-lifecycle.md`
  records passing "isolated Hackage 0.10.0.0 controls" for the fixed Shibuya metrics release, in
  prose only. Rounds make that practice systematic and queryable.
- A `KnownDefect` whose scope does not apply to a cohort is not written into that run's result
  or evidence record (`applicable` in `defectDisposition`, `kenshou-core/src/Kenshou/Core/Run.hs`).
  A passing run on a fixed cohort therefore carries no link to the record it verifies. EP-3 must
  join through the scenario catalog, not through the run record's `knownDefects` field alone.


## Decision Log

- Decision: Kenshou owns the verification loop and never the repairs; owner records are read,
  never written.
  Rationale: MasterPlan 1's 2026-09-27 decision keeps repairs with the owning projects, and an
  owner record's lifecycle is its owner's authority. Writing "verified" into another
  repository's report would create two authorities for one fact.
  Date: 2026-10-01

- Decision: Dispositions are derived at read time from immutable run records and the scenario
  catalog; the dated round report states them. No new concept type is added to
  `docs/verification/`.
  Rationale: ADR-18 fixes the bundle's three types and derives baselines at read time. A stored
  disposition would go stale the moment a newer confirmed run arrives, and would require an
  additive release of the shared verification-evidence profile first.
  Date: 2026-10-01

- Decision: Scope reconciliation proposes `KnownDefect` changes; it never rewrites Haskell
  source.
  Rationale: Scopes live in scenario modules, and narrowing one changes what blocks. A person
  must review that change. Mapping a project-level `affects` to a package can also be ambiguous.
  Date: 2026-10-01

- Decision: Round progress is tracked in Rei through a program project created with
  `rei project create` (no `mori` reference), one child intention per round under this
  MasterPlan's intention, and `rei dependency add` from each round to the owner intentions that
  carry the fixes.
  Rationale: Owner fix intentions already live under their own repositories' intentions and
  projects; this keeps them there. A project Topic without a `mori` reference is ignored as a
  planning target under the proposed rule in `mori://shinzui/rei/okf/adrs/concepts/ADR-45`. So
  scoping owner intentions to it for rollup does not create planning-target ties with their own
  repository projects. It works with today's Rei and needs none of IR-6, IR-7 or plan 231.
  Date: 2026-10-01

- Decision: Five child plans, sequential after EP-1, with the first real round as its own plan.
  Rationale: Each plan adds one checkable layer of the join: owner state, scope, evidence,
  round. Making the first round a separate plan proves the loop on real fixes, such as the ten
  Shibuya records fixed in 0.10.0.0, rather than on fixtures alone.
  Date: 2026-10-01


## Outcomes & Retrospective

(To be filled during and after implementation.)
