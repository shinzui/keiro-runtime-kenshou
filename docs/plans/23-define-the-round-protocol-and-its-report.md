---
id: 23
slug: define-the-round-protocol-and-its-report
title: "Define the round protocol and its report"
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

# Define the round protocol and its report

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Owners fix defects that kenshou found, and release those fixes on their own schedules. A *round*
is one pass of the loop that checks those fixes:

1. Freeze what the round compares against.
2. Pin a candidate cohort that contains released fixes.
3. Rerun the affected scenarios.
4. Derive one disposition per owner record.
5. Publish a dated report.

Today this happens ad hoc. A finding mentions in prose that "isolated Hackage 0.10.0.0 controls"
passed, and the conclusion lives nowhere a tool can find it.

After this plan, a maintainer runs a round with four commands and gets a report:

```bash
cabal run -v0 kenshou -- owners round open --round 1 --base released --candidate round-1
cabal run -v0 kenshou -- owners round plan --round 1 --out rounds/1/plan.json
# switch to the candidate cohort, rebuild, then execute with the existing executor
cabal run -v0 kenshou -- owners round report --round 1 --include-local runs
```

The round's progress is visible in Rei as one intention under this initiative, which depends on
the owner intentions carrying the fixes.

This is child plan EP-4 of
`docs/masterplans/2-close-the-verification-and-repair-loop-for-the-keiro-runtime-in-rounds.md`.
It hard-depends on EP-3, `docs/plans/22-derive-fix-verification-dispositions-from-recorded-evidence.md`,
and through it on EP-1 (`docs/plans/20-report-owner-record-status-for-every-kenshou-finding.md`)
and EP-2 (`docs/plans/21-reconcile-known-defect-cohort-scopes-with-owner-records.md`).


## Progress

- [ ] Milestone 1: the `kenshou.round/v1` document, `round open`, and its refusal rules, with a
  schema and tests.
- [ ] Milestone 2: `round plan` produces a standard `kenshou.run-plan/v1` document that
  `kenshou execute` accepts, covering every scenario that cites an in-scope record plus
  change-aware selection between the two cohorts.
- [ ] Milestone 3: `round report` writes `docs/reports/<date>-round-<n>.md` and
  `kenshou.round-report/v1`, including new blocking failures. Rei wiring is printed by default
  and applied with `--apply-rei`. The guide and the ADR are written.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: A round freezes its base as an explicit list of run IDs captured at `round open`,
  not as a run plan.
  Rationale: MasterPlan 1's released-cohort baseline was accumulated over many plans, cells and
  local runs, so no single run plan describes it. Listing the latest counted observation per
  scenario at open time is exact and immutable. Comparing against a moving "latest" would let a
  base change underneath an open round.
  Date: 2026-10-01

- Decision: `round open` refuses while `owners scopes --strict` reports an error for an in-scope
  record, unless `--allow-scope-errors` is given and recorded in the round file.
  Rationale: A stale scope makes the candidate run lie. An owner-fixed defect whose scope still
  covers the fixed version stays non-blocking even when it still reproduces.
  Date: 2026-10-01

- Decision: Rei changes are printed by default and applied only with `--apply-rei`.
  Rationale: Rei is shared personal state outside this repository. A dry-run default lets a
  person review the intentions and dependencies before they appear, matching how the rest of
  the house tooling treats outward-facing writes.
  Date: 2026-10-01


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Kenshou is this repository's verification harness for the keiro runtime. The terms this plan
relies on:

- **Cohort.** A cohort is a named, exact set of runtime package versions. It is described by
  `cohort/<name>.json` (schema `kenshou.cohort/v1`, with components, their `mori://` URIs, and
  package versions) and `cohort/<name>.project` (the cabal solver input). See
  [ADR-2](../adr/0002-every-result-carries-a-resolved-cohort-identity.md).
  - The harness links one cohort at build time. `cohort/active.project` imports exactly one
    cohort, and the only supported switch is `just use-cohort <name>`, which also clears cabal's
    cached plan.
  - Cell payloads for remote runs are built per cohort (see
    [ADR-20](../adr/0020-pin-cell-payloads-to-verified-cohort-identities.md) and
    `docs/guides/running-on-gcp.md`).
  - Cohorts present on 2026-10-01: `released`, `head`, `shibuya-current`.
- **Planning and execution.** `kenshou plan` writes a `kenshou.run-plan/v1` document. Its
  options are described in `docs/planning.md`:
  - `--cohort-from A --cohort-to B` selects scenarios affected by the package differences
    between two cohort descriptors, following the component graph in
    `kenshou-core/data/components.json`;
  - `--changed`, `--suite`, `--dimension-policy`, `--max-tier` and `--budget-minutes` shape the
    selection.

  `kenshou execute --plan P --out DIR` runs a plan entry by entry and maintains
  `DIR/plan-summary.json`. Resuming with `--resume` requires the identical plan. The planning
  library is under `kenshou-core/src/Kenshou/Plan/`. Read `Kenshou.Plan.Change` and
  `Kenshou.Plan.Suite` before building a plan programmatically.
- **Owner tooling from EP-1 to EP-3,** in package `kenshou-owners`:
  - `buildOwnerIndex` gives each canonical owner URI its record, citing findings, citing
    scenario defects, and citing owner plans with their Rei intention IDs.
  - `reconcileScopes` reports scope errors.
  - `loadObservations` and `deriveDispositions` give one disposition per record and cohort,
    with trust (`confirmed`, `unverified`, `local`) and run IDs.

  The `owners` command (`Kenshou.Owners.Cli.ownersCommand`, group `Analysis`) already has the
  subcommands `status`, `scopes` and `verify`.
- **Reports.** `docs/reports/` holds dated, mutable working readings of evidence, such as
  `docs/reports/2026-09-29-runtime-baseline.md`. They are not immutable records. Raw data and
  conclusions stay traceable to run IDs.
- **Rei.** Rei is the house intention tracker, whose CLI is `rei`. This initiative's intention
  is `intention_01m3w49yheevg9mzkyfab1mqy4`, a child of
  `intention_01m2zvm3y8e0hsjn98n3sbzekk` ("Add extensive verification to the keiro runtime").
  The commands this plan uses, verified on 2026-10-01:

  ```bash
  rei project create KEY --label LABEL [--description TEXT] [--json]
  rei intention create TITLE --parent ID
  rei project scope add PROJECT ENTITY
  rei dependency add --from ID --on ID --note TEXT
  ```

  A project created with `rei project create` has no `mori` reference. Under Rei's proposed
  planning-target rule, `mori://shinzui/rei/okf/adrs/concepts/ADR-45`, such a project is never
  chosen as the repository an intention's plans belong to. So scoping owner intentions to it, to
  get a program-wide rollup, cannot create planning-target ties with their own repository
  projects. Rei's richer automation is proposed but not shipped:
  `mori://shinzui/rei/okf/improvement-requests/concepts/IR-6`,
  `mori://shinzui/rei/okf/improvement-requests/concepts/IR-7`, and
  `mori://shinzui/rei/plans/231-resolve-an-intention-s-planning-target-from-project-scope`. This
  plan must not depend on them.

Relevant ADRs:
- [ADR-18](../adr/0018-keep-verification-records-immutable-and-derive-baselines.md): a round
  never edits a record. Its report is a dated reading.
- [ADR-5](../adr/0005-select-runs-from-a-checked-in-component-graph.md): selection over-selects
  when unsure.
- [ADR-14](../adr/0014-distinguish-documented-limitations-from-known-defects.md): new failures
  outside a defect's labels block.
- The ADR created by EP-3 (expected ADR-22): the disposition vocabulary.


## Plan of Work

### Milestone 1: the round document and `round open`

Define `kenshou.round/v1` in `Kenshou.Owners.Round`, with a schema at
`schemas/round-v1.schema.json` added to `just schemas-check`. The document has these fields:

```json
{ "schema": "kenshou.round/v1", "round": 1, "openedAt": "2026-10-02T00:00:00Z",
  "base": { "cohort": "released", "runs": [ { "scenario": "...", "runId": "...", "trust": "local" } ] },
  "candidate": { "cohort": "round-1", "descriptorDigest": "sha256:..." },
  "records": [ "mori://shinzui/shibuya/okf/bug-reports/concepts/BUG-8" ],
  "allowScopeErrors": false,
  "rei": { "program": "keiro-runtime-hardening", "intention": null } }
```

`owners round open` takes these options:
- `--round N`, `--base COHORT`, `--candidate COHORT`;
- `--record URI`, repeatable;
- `--include-local DIR`, `--allow-scope-errors`, `--apply-rei`.

It writes `rounds/N.json` and refuses to overwrite an existing round. It selects records as
follows:
- all records named with `--record`;
- otherwise, every owner record whose base-cohort disposition is `reproduces-as-expected`,
  `different-failure` or `still-reproduces`, and whose owner status is `fixed` with a released
  `fixedVersion` that the candidate descriptor pins for the affected package;
- plus every record previously `verified-fixed` in an earlier round whose scenarios are selected
  again, to catch regressions.

It freezes the base by listing, per scenario citing a selected record, the latest counted
observation on the base cohort, with its trust. It then runs `reconcileScopes` and refuses on
errors for selected records unless `--allow-scope-errors` is given.

Finally, it prints the Rei commands (see Milestone 3) and runs them only with `--apply-rei`,
recording the created intention ID back into the round file.

### Milestone 2: `round plan`

`owners round plan --round N --out FILE [--suite NAME] [--budget-minutes M]` builds one
`kenshou.run-plan/v1` from the union of two selections:
- the change-aware selection between the base and candidate descriptors, computed with the same
  library path `kenshou plan --cohort-from/--cohort-to` uses;
- every scenario that cites an in-scope record.

Use the default suite `change`. Record the round number in the plan's selection reasons so the
executor's summary shows why each entry was selected. The output must be accepted unchanged by
`kenshou execute --plan FILE`. The plan does not switch cohorts. The guide states the switch:
`just use-cohort <candidate>` and rebuild locally, or publish the candidate payload for a cell
run.

### Milestone 3: `round report`, Rei wiring, guide and ADR

`owners round report --round N [--include-local DIR] [--fetch-labels] [--json] [--write]`
derives dispositions for the in-scope records on both the base and candidate cohorts, using EP-3.

It also finds **new blocking failures**: candidate-cohort runs of selected scenarios that failed
with labels no applicable defect covers. These are the round's new findings. They are listed
with run IDs, but no finding or owner report is filed automatically. Filing follows MasterPlan
1's Integration Point 11 procedure, which is cited in the report.

With `--write`, the command writes `docs/reports/<yyyy-mm-dd>-round-<n>.md`. Without it, the
Markdown goes to standard output. The Markdown contains:
- a headline count of dispositions, counting only `confirmed` evidence as headline
  `verified-fixed`;
- a table of records with owner status, base disposition, candidate disposition, trust and runs;
- the new blocking failures;
- scope errors that were allowed;
- the exact commands that produced it.

`--json` writes `kenshou.round-report/v1`, with a schema in
`schemas/round-report-v1.schema.json`.

The Rei wiring is printed by `round open`, and by `round report` for any additions. Commands
appear in this order:
1. `rei project create keiro-runtime-hardening --label "Keiro runtime hardening rounds"`, only
   if `rei project show keiro-runtime-hardening` fails;
2. `rei intention create "Round N: verify owner fixes on <candidate>" --parent intention_01m3w49yheevg9mzkyfab1mqy4`;
3. `rei project scope add keiro-runtime-hardening <round intention>`;
4. for each in-scope record, each citing owner plan that carries an `intention`:
   `rei dependency add --from <round intention> --on <owner intention> --note "<record URI>"`,
   and `rei project scope add keiro-runtime-hardening <owner intention>`.

Write `docs/guides/running-a-repair-verification-round.md`, the operator procedure: open, plan,
switch cohort, execute (local or cell), report, file new findings, close the round's intention.
Create ADR "Verify owner repairs in numbered rounds against frozen base run sets", allocating the
handle with `okf id next docs/adr --profile docs/adr/profile.dhall ADR`. Run `just adr-validate`.


## Concrete Steps

From the repository root, inside `nix develop`. The existing `shibuya-current` cohort, which
pins the Shibuya 0.10.0.0 fixes, serves as the candidate for a throwaway test round numbered 99:

```bash
cabal test kenshou-owners:test:kenshou-owners-test
cabal run -v0 kenshou -- owners round open --round 99 --base released --candidate shibuya-current --include-local runs
cat rounds/99.json | jq '.records | length'
cabal run -v0 kenshou -- owners round plan --round 99 --out /tmp/round-99-plan.json
check-jsonschema --schemafile schemas/run-plan.v1.schema.json /tmp/round-99-plan.json
cabal run -v0 kenshou -- owners round report --round 99 --include-local runs | head -30
rm rounds/99.json   # the test round is not kept
```

`kenshou execute` has no dry-run mode (checked 2026-10-01). Schema validation is the
pre-execution check; the real execution belongs to EP-5.


## Validation and Acceptance

Unit tests cover:
- record selection for each inclusion rule;
- the refusal on scope errors, and its override recorded in the file;
- the refusal to overwrite a round;
- base freezing, choosing the latest counted observation per scenario and ignoring
  `inconclusive`;
- plan union and reasons;
- report rendering from fixture dispositions, including new blocking failures;
- the exact printed Rei command sequence for a fixture with two owner plans, one carrying an
  intention and one not.

On the real repository, the test round 99 above must select at least the Shibuya records fixed
in `0.10.0.0` that `shibuya-current` pins. It must produce a run plan that validates against
`schemas/run-plan.v1.schema.json`, and a report whose table lists every selected record. No Rei
write happens without `--apply-rei`.


## Idempotence and Recovery

`round open` refuses an existing round number, so a mistaken round is deleted by removing
`rounds/N.json` before any Rei command is applied. `--apply-rei` is safe to rerun:
- `rei project create` is skipped when the project exists;
- `rei project scope add` is idempotent in Rei;
- an existing dependency is detected with `rei dependency show <round intention>` before adding.

`round plan` and `round report` only read, except for `--write`, which overwrites the dated
report for the same day. That is intended for a mutable working report.


## Interfaces and Dependencies

These are consumed by EP-5,
`docs/plans/24-run-the-first-repair-verification-round-against-a-fixed-cohort.md`:

```haskell
-- Kenshou.Owners.Round
data Round = Round { number :: Int, openedAt :: UTCTime, base :: RoundBase, candidate :: RoundCandidate
                   , records :: [Text], allowScopeErrors :: Bool, rei :: RoundRei }
openRound :: RoundOptions -> IO (Either RoundError Round)
planRound :: Round -> PlanOptions -> IO (Either Text RunPlan)
reportRound :: Round -> EvidenceSources -> IO RoundReport
reiCommands :: Round -> Map Text OwnerEntry -> [Text]
```

Files: `rounds/<n>.json` (checked in), `docs/reports/<date>-round-<n>.md` (checked in),
`schemas/round-v1.schema.json`, `schemas/round-report-v1.schema.json`.
