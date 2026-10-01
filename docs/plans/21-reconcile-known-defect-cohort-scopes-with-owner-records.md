---
id: 21
slug: reconcile-known-defect-cohort-scopes-with-owner-records
title: "Reconcile known-defect cohort scopes with owner records"
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

# Reconcile known-defect cohort scopes with owner records

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

When a kenshou scenario reproduces a defect that an owner repository has acknowledged, the
scenario declares a `KnownDefect`. That declaration has three effects. The defect's failure
labels do not block a run. The run is reported as "reproduced". And the declaration's cohort
scope says on which runtime versions the defect is expected.

The scope is what turns an owner's "fixed" into something kenshou can check. Once the scope
excludes the fixed version, a scenario that still fails on a cohort containing the fix becomes
blocking, because kenshou only forgives a failure while an applicable defect explains it. Today
scopes are written by hand, and some already disagree with the owners. In
`kenshou-kafka/src/Kenshou/Suite/Kafka/Concurrency/BarrierOverwrite.hs`, for example,
`mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-5` is scoped below
`0.9.0.2`, while the owner records `fixedVersion: "0.9.1.0"`.

After this plan, `cabal run -v0 kenshou -- owners scopes` lists every `KnownDefect` whose scope
disagrees with its owner record, and prints the scope it should have. `--strict` makes such
disagreements fail, for use when opening a round.

This is child plan EP-2 of
`docs/masterplans/2-close-the-verification-and-repair-loop-for-the-keiro-runtime-in-rounds.md`.
It hard-depends on EP-1, `docs/plans/20-report-owner-record-status-for-every-kenshou-finding.md`,
for the `OwnerRecord` reader and the owner index.


## Progress

- [ ] Milestone 1: `kenshou list --json` additively emits each defect's `expectedFailures` and
  serialized `appliesTo`. A package-list scope evaluator is exported from `kenshou-core`, and
  `cohortScopeApplies` delegates to it with unchanged behavior, proven by the existing
  `kenshou-core` tests.
- [ ] Milestone 2: `affects` is mapped to cabal package names through the cohort descriptor,
  with an explicit `Ambiguous` result for multi-package projects.
- [ ] Milestone 3: the reconciliation rules and `kenshou owners scopes` (text, `--json`,
  `--strict`) report the 2026-10-01 discrepancies listed under Validation, and the ADR change is
  recorded.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Propose scope changes; never edit scenario source.
  Rationale: Narrowing a scope changes what blocks a run, and a project-level `affects` can be
  ambiguous. A person reviews and commits the change. The command prints the proposed Haskell
  expression and the source file that declares the reference, so the edit is mechanical.
  Date: 2026-10-01

- Decision: Keep the existing `knownDefect` key in `kenshou.scenario-list/v1` unchanged, and add
  a new `knownDefects` array beside it.
  Rationale: Consumers of `kenshou.scenario-list/v1` already read `knownDefect` as a string or
  list of strings. An additive key keeps them valid without a schema version bump.
  Date: 2026-10-01


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Kenshou is this repository's verification harness for the keiro runtime (see `README.md`). The
pieces this plan touches:

**`KnownDefect` and `CohortScope`.** These are defined in
`kenshou-core/src/Kenshou/Core/Scenario.hs`:

```haskell
data KnownDefect
  = KnownDefect { reference :: Text, summary :: Text, expectedFailures :: [Text], appliesTo :: CohortScope }
  | KnownDefectGroup (NonEmpty KnownDefect)
data CohortScope = AllCohorts | OnlyWhen (NonEmpty PackageCondition)
data PackageCondition
  = ResolvedFromHackage Text | ResolvedFromGit Text | VersionBelow Text Text | RevisionIs Text Text
cohortScopeApplies :: CohortIdentity -> CohortScope -> Bool
```

How scopes are evaluated:
- An `OnlyWhen` scope applies when every condition matches some resolved package.
- `VersionBelow name boundary` matches a package with that name whose version, parsed with
  `Data.Version.parseVersion`, is strictly below `boundary`.
- `defectDisposition` in `kenshou-core/src/Kenshou/Core/Run.hs` filters a scenario's defects to
  the applicable ones. A failure is non-blocking only when every failure label is covered by
  an applicable defect's `expectedFailures`. An inapplicable defect is simply absent, so a
  failure on a cohort outside the scope blocks.

Scopes in use on 2026-10-01 include `VersionBelow "shibuya-kafka-adapter" "0.9.0.2"` (eight
uses), `VersionBelow "shibuya-metrics" "0.10.0.0"` (four),
`VersionBelow "shibuya-pgmq-adapter" "0.16.1.0"` and `"0.16.2.0"`,
`VersionBelow "shibuya-kiroku-adapter" "0.5.1.3"`, `VersionBelow "shibuya-core" "0.10.0.0"`, and
`AllCohorts` (23 uses).

**The catalog JSON.** `kenshou list --json` writes `kenshou.scenario-list/v1`, produced in
`kenshou-core/src/Kenshou/Core/Bundle.hs`. The `knownDefect` key holds only reference strings.
Its schema is `schemas/scenario-list-v1.schema.json`.

**Cohort descriptors.** `cohort/<name>.json` (schema `kenshou.cohort/v1`) lists `components`.
Each component has an `id`, a canonical `moriUri` such as `mori://shinzui/shibuya`, and
`packages` with `name` and `version`. The kiroku component, for example, contains `kiroku-store`,
`kiroku-store-migrations`, `kiroku-otel`, `kiroku-metrics`, `kiroku-cli` and
`shibuya-kiroku-adapter`. The keiro component has five packages that share one version. The
cohorts present are `released`, `head` and `shibuya-current` (see `cohort/`).

**Owner records.** EP-1's package `kenshou-owners` provides `OwnerRecord` in
`Kenshou.Owners.Record`, with these fields:
- `status`, the raw owner string;
- `affects`, a `mori://` URI, either `.../packages/<name>` or a whole project;
- `fixedVersion` and `lastWorkingVersion`, as `VersionValue` (`Released Version`, `Unreleased`,
  `Unknown`, or `Unparseable Text`);
- `duplicateOf` and `canonical`, for duplicates.

It also provides `buildOwnerIndex` in `Kenshou.Owners.Index`, which lists the scenario defects
citing each record. The bug-report profile (okf-profiles v0.18.0 `coordination.bugReports`)
requires `fixedVersion` when `status` is `fixed`, and `duplicateOf` when `status` is
`duplicate`. Its version keys are meant for mechanical comparison. Some owners write `unreleased`
for a fix that is only on the default branch, as pgmq-hs BUG-1 and one kiroku report do.

**Relevant ADRs.**
- [ADR-14](../adr/0014-distinguish-documented-limitations-from-known-defects.md): known-defect
  references are canonical owner URIs. An upstream plan or improvement request alone does not
  make a `KnownDefect`. `KnownDefect` attaches only to the scenario's specific failure labels and
  affected cohorts.
- [ADR-2](../adr/0002-every-result-carries-a-resolved-cohort-identity.md): what a cohort is.

This plan will amend ADR-14 or add a new ADR (see Plan of Work, Milestone 3).


## Plan of Work

### Milestone 1: catalog data and a reusable evaluator

In `kenshou-core/src/Kenshou/Core/Scenario.hs`, add a function and make `cohortScopeApplies`
call it, so there is one implementation:

```haskell
data ScopePackage = ScopePackage { name :: Text, version :: Text, fromHackage :: Bool, gitRevision :: Maybe Text }
scopeAppliesToPackages :: [ScopePackage] -> CohortScope -> Bool
```

Then extend the catalog JSON:
- Add `renderCohortScope :: CohortScope -> Value`, producing for example
  `{"onlyWhen":[{"resolvedFromHackage":"shibuya-kafka-adapter"},{"versionBelow":{"package":"shibuya-kafka-adapter","version":"0.9.0.2"}}]}`
  or `"allCohorts"`.
- Add a matching `parseCohortScope`.
- In `Kenshou.Core.Bundle`, emit a new `knownDefects` array of
  `{reference, summary, expectedFailures, appliesTo}` per scenario, beside the unchanged
  `knownDefect` key.
- Extend `schemas/scenario-list-v1.schema.json` with the optional array.

Acceptance:
- `cabal test kenshou-core:tests` passes unchanged.
- A new round-trip test proves that `parseCohortScope . renderCohortScope` is the identity.
- `cabal run -v0 kenshou -- list --json | jq '[.scenarios[] | select(.knownDefects) ] | length'`
  prints a positive count. Adjust the path to the actual top-level key of the document.

### Milestone 2: map `affects` to packages

In `kenshou-owners`, add `Kenshou.Owners.Packages` with:

```haskell
affectedPackages :: CohortDescriptor -> Text -> PackageMapping
```

`PackageMapping` is `Exactly [Text]`, `Ambiguous [Text]` or `UnknownProject`. The rules:
- A `.../packages/<name>` URI maps to `Exactly [name]`.
- A project URI maps to its component's packages when there is exactly one.
- A multi-package component maps to `Ambiguous` with the candidates, with one exception: when
  the scenario's existing scope already names a `VersionBelow` package that belongs to that
  component, that package is used.

Read the descriptor with the existing cohort descriptor parser in `kenshou-core`; find it with
`grep -rn 'kenshou.cohort/v1' kenshou-core/src`. Default to `cohort/released.json`, and allow
`--descriptor` to override.

### Milestone 3: rules and the command

In `Kenshou.Owners.Scopes`, compare each citing defect against its record's canonical form and
produce a `ScopeFinding` with a severity: `error` (wrong now), `warning` (needs a decision), or
`info`.

The rules:
1. **Duplicate reference (error).** The defect references a record whose status is `duplicate`.
   Propose retargeting the `reference` to the canonical URI.
2. **Missing upper bound (error).** The owner status is `fixed` with `Released V` for package
   `P`, and the scope is `AllCohorts` or lacks `VersionBelow P _`. Propose
   `OnlyWhen (ResolvedFromHackage P :| [VersionBelow P V])`, keeping any other existing
   conditions.
3. **Bound mismatch (error).** The status is `fixed` with `Released V`, and the scope has
   `VersionBelow P W` with `W /= V`. Propose replacing `W` with `V`.
4. **Fix only on the default branch (info).** The status is `fixed` with `Unreleased`. No
   change. A head cohort can verify it with `RevisionIs`, which the round protocol handles.
5. **Bound without an owner fix (warning).** The status is `reported`, `confirmed` or
   `in-progress`, and the scope has a `VersionBelow` bound. A future release without the fix
   would make the failure blocking, with no owner basis for expecting it fixed. Propose removing
   the bound, or keeping it deliberately as a tripwire. A person decides.
6. **Owner closed without a fix (warning).** The status is `wont-fix`, `not-a-bug` or
   `cannot-reproduce`. Per ADR-14, the behavior is either unpromised, and so should become an
   implementation-class invariant, or the reproduction must be re-examined. Report the owner's
   `resolution` text.
7. **Not a bug reference (info).** The reference is an improvement request or another
   reference, such as a plan, user documentation or a review. ADR-14 says these do not by
   themselves justify a `KnownDefect`. List them for review without failing.
8. **Unverifiable (warning).** The record is unresolved, a version is `Unparseable` or
   `Unknown`, or the package mapping is `Ambiguous` or `UnknownProject`.

For each finding, locate the declaring source file by searching `kenshou-*/src/**/*.hs` for the
literal reference string, and print `file:line`.

Add the `scopes` subcommand to `ownersCommand` in `Kenshou.Owners.Cli` with these options:
- `--json`, writing `kenshou.owner-scopes/v1` with a schema in
  `schemas/owner-scopes-v1.schema.json`, added to `just schemas-check`;
- `--strict`: exit 1 if any `error` finding exists;
- `--descriptor FILE`.

Then record the rule that an upper bound comes from the owner's `fixedVersion` and never from an
anticipated release. Either append to ADR-14's Decision, or create a new ADR. Allocate the
handle with `okf id next docs/adr --profile docs/adr/profile.dhall ADR`, and validate with
`just adr-validate`.


## Concrete Steps

From the repository root, inside `nix develop`:

```bash
cabal test kenshou-core:tests
cabal test kenshou-owners:test:kenshou-owners-test
cabal run -v0 kenshou -- owners scopes
cabal run -v0 kenshou -- owners scopes --json > /tmp/owner-scopes.json
check-jsonschema --schemafile schemas/owner-scopes-v1.schema.json /tmp/owner-scopes.json
just adr-validate
```

Expected text, abbreviated (state on 2026-10-01; the exact set moves as owners work):

```text
error   bound-mismatch   mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-5
        kafka/adapter/concurrency/barrier-overwrite...  kenshou-kafka/src/Kenshou/Suite/Kafka/Concurrency/BarrierOverwrite.hs:46
        owner fixed in shibuya-kafka-adapter 0.9.1.0; scope says VersionBelow "0.9.0.2"
        propose: OnlyWhen (ResolvedFromHackage "shibuya-kafka-adapter" :| [VersionBelow "shibuya-kafka-adapter" "0.9.1.0"])
warning bound-without-owner-fix   mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-4   (owner: reported)
warning bound-without-owner-fix   mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-3   (owner: reported)
info    not-a-bug-reference       mori://shinzui/keiro/masterplans/18-make-the-kafka-transport-edge-production-safe-surfaced-by-the-2026-07-transport-review
```


## Validation and Acceptance

Unit tests in `kenshou-owners` cover each of the eight rules with an in-memory `OwnerRecord` and
`KnownDefect`. They also cover the package mapping for a package URI, a single-package project,
the five-package keiro project (`Ambiguous`), and the exception where an existing `VersionBelow`
package disambiguates.

On the real repository, `owners scopes` must report these findings:
- the BUG-5 bound mismatch above;
- `bound-without-owner-fix` for shibuya-kafka-adapter BUG-3 and BUG-4;
- no error for any of the Shibuya `shibuya-metrics`/`shibuya-core` scopes whose owner records
  say `fixedVersion: "0.10.0.0"` and whose scopes already say `VersionBelow ... "0.10.0.0"`.

Confirm each by opening the cited owner record. `--strict` must exit 1 while the BUG-5 mismatch
exists, and 0 once the scope is corrected in a scratch branch.


## Idempotence and Recovery

The command reads only. Milestone 1's evaluator refactor is behavior-preserving, and the
existing `kenshou-core` tests are the guard. If any of them changes outcome, revert the refactor
and re-derive it from `conditionApplies`.


## Interfaces and Dependencies

These are consumed by EP-3, `docs/plans/22-derive-fix-verification-dispositions-from-recorded-evidence.md`:

```haskell
-- Kenshou.Core.Scenario (kenshou-core)
data ScopePackage = ScopePackage { name :: Text, version :: Text, fromHackage :: Bool, gitRevision :: Maybe Text }
scopeAppliesToPackages :: [ScopePackage] -> CohortScope -> Bool
renderCohortScope :: CohortScope -> Value
parseCohortScope :: Value -> Parser CohortScope

-- Kenshou.Owners.Packages / Kenshou.Owners.Scopes (kenshou-owners)
data PackageMapping = Exactly [Text] | Ambiguous [Text] | UnknownProject
data Severity = ScopeError | ScopeWarning | ScopeInfo
data ScopeFinding = ScopeFinding { rule :: Text, severity :: Severity, record :: Text, scenario :: ScenarioId, location :: Maybe (FilePath, Int), proposal :: Maybe Text, detail :: Text }
reconcileScopes :: CohortDescriptor -> Map Text OwnerEntry -> [ScopeFinding]
```
