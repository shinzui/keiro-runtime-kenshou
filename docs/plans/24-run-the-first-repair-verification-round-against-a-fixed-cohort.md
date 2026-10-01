---
id: 24
slug: run-the-first-repair-verification-round-against-a-fixed-cohort
title: "Run the first repair-verification round against a fixed cohort"
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

# Run the first repair-verification round against a fixed cohort

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Owners have already released fixes for many defects kenshou reported. On 2026-10-01 the owner
records said:
- ten Shibuya bug reports fixed in `shibuya-core`/`shibuya-metrics` 0.10.0.0;
- two Shibuya PGMQ adapter reports fixed in 0.16.1.0;
- a kiroku Shibuya adapter report fixed in 0.5.1.3;
- a kiroku store report fixed in 0.9.0.1;
- a Kafka adapter report fixed in 0.9.1.0.

None of those fixes has been verified by kenshou under comparable conditions. This plan runs
round 1 for real, end to end, with the tooling built by EP-1 to EP-4. It produces a checked-in
round definition `rounds/1.json`, a candidate cohort descriptor, sealed and (where the scenario
supports it) published evidence, and the report `docs/reports/<date>-round-1.md`. The report
gives one disposition per in-scope owner record, plus any new blocking failures. It is the first
time the platform owner can read "these fixes are verified, these still reproduce" from evidence
rather than from owners' statements.

This is child plan EP-5 of
`docs/masterplans/2-close-the-verification-and-repair-loop-for-the-keiro-runtime-in-rounds.md`.
It hard-depends on EP-4, `docs/plans/23-define-the-round-protocol-and-its-report.md`. It softly
depends on MasterPlan 1's coverage plans for Shibuya (EP-10), Kafka (EP-11) and Keiro messaging
(EP-13). Records whose scenarios are unfinished are reported as `not-run`, not hidden.


## Progress

- [ ] Milestone 1: a candidate cohort `round-1` that pins only released fixes, is solvable, and
  passes `just cohort-check`. The descriptor and project files are checked in.
- [ ] Milestone 2: `owners scopes --strict` passes for every in-scope record, after scope
  corrections are reviewed and committed, and round 1 is opened with its Rei wiring applied.
- [ ] Milestone 3: the round plan is executed on the candidate cohort (local, or cell for tiers
  that require it), and its sealed runs are published to the evidence bundle where publishable.
- [ ] Milestone 4: the round report is written. New blocking failures have local findings and,
  where warranted, owner reports filed per MasterPlan 1's Integration Point 11. The round's Rei
  intention is completed or left open with a stated reason.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The candidate cohort contains only released fixes; `unreleased` fixes wait for a
  later round or a head cohort.
  Rationale: A release is what services consume, and the bug-report profile reserves
  `unreleased` for a fix on the default branch only. Verifying a git pin proves a commit, not
  the artifact consumers will install. pgmq-hs BUG-1 (`fixedVersion: unreleased` on 2026-10-01)
  is therefore reported `not-yet-released` in round 1.
  Date: 2026-10-01


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Kenshou is this repository's verification harness for the keiro runtime. By the time this plan
starts, EP-1 to EP-4 have added these subcommands of `kenshou owners`:
- `status`: owner-record state, citing findings, scenarios and owner plans;
- `scopes`: `KnownDefect` cohort scopes that disagree with owner records, with proposed scopes;
- `verify`: dispositions per record and cohort;
- `round open`, `round plan` and `round report`.

The operator procedure is `docs/guides/running-a-repair-verification-round.md`, written by
EP-4. Read it first.

**Cohorts.** A cohort is described by `cohort/<name>.json` (schema
`schemas/kenshou.cohort.v1.schema.json`) and `cohort/<name>.project`, and is switched only with
`just use-cohort <name>` (see [ADR-2](../adr/0002-every-result-carries-a-resolved-cohort-identity.md)).
The cohorts on 2026-10-01 are:
- `released`: the historical baseline of 2026-09-20, with keiro 0.17.0.0, shibuya 0.9.0.3,
  shibuya-pgmq-adapter 0.16.0.0, shibuya-kafka-adapter 0.9.0.1, kiroku-store 0.8.0.1 and
  shibuya-kiroku-adapter 0.5.1.2;
- `head`: selected unreleased fixes as git pins;
- `shibuya-current`: an isolated Shibuya release lane with shibuya 0.10.0.0,
  shibuya-pgmq-adapter 0.16.1.0 and shibuya-kiroku-adapter 0.5.1.3. It lacks the Kafka adapter
  and is not a whole-runtime cohort.

The Keiro source checkout reports version 0.19.0.0. Whether a whole-runtime cohort containing
every released fix is solvable, and with which keiro version, must be established in Milestone 1
against Hackage at a fresh `index-state`. Do not assume it.

**Cells.** Soak and benchmark tiers run on leased GCP cells with payloads pinned per cohort.
Follow `docs/guides/running-on-gcp.md` and
[ADR-20](../adr/0020-pin-cell-payloads-to-verified-cohort-identities.md).

**Evidence.** Sealed runs land under `runs/` (ignored by Git). Publishable runs are recorded into
the `docs/verification/` OKF bundle with `kenshou record` and attested with `kenshou attest`.
Follow `docs/guides/recording-evidence.md` and
[ADR-18](../adr/0018-keep-verification-records-immutable-and-derive-baselines.md).

**Filing new defects.** Follow MasterPlan 1's Integration Point 11, in
`docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md`, and
[ADR-14](../adr/0014-distinguish-documented-limitations-from-known-defects.md):
1. Reproduce.
2. Confirm against a published contract.
3. Reuse an existing owner record if one exists.
4. Otherwise file a `Bug Report` in the owner's `coordination.bugReports` bundle with
   `origin: mori://shinzui/keiro-runtime-kenshou/masterplans/2-close-the-verification-and-repair-loop-for-the-keiro-runtime-in-rounds`.
   Note that it is this MasterPlan, not MasterPlan 1, for round-discovered defects.
5. Run `mori register --path <owner checkout>` afterwards, so `mori path` can resolve the new
   record.

**Rei.** Round 1's intention is created under `intention_01m3w49yheevg9mzkyfab1mqy4` by
`round open --apply-rei`. It depends on the owner intentions found in owner plans that cite
in-scope records. For example, keiro's
`docs/plans/300-poll-pgmq-client-side-for-long-poll-job-workers-to-fix-bug-4-and-bug-6.md` and
shibuya-pgmq-adapter's `docs/plans/8-fix-long-poll-acknowledgement-starvation-on-a-shared-pool.md`
jointly carry the fix for `mori://shinzui/shibuya-pgmq-adapter/okf/bug-reports/concepts/BUG-1`.


## Plan of Work

### Milestone 1: the candidate cohort

1. Start from `released`. List every in-scope fix with
   `cabal run -v0 kenshou -- owners status --json`, filtered to `status == fixed` with a
   released `fixedVersion`.
2. For each affected package, choose the smallest released version greater than or equal to
   `fixedVersion` that solves with the rest of the cohort.
3. Create `cohort/round-1.json` and `cohort/round-1.project` following the existing descriptors
   and ADR-2: exact constraints, `extra-packages`, and a reachable `index-state`.
4. Run `just use-cohort round-1`, `cabal build all`, and `just cohort-check`.

If the fixes force a keiro major move, for example from 0.17 to 0.19, record it in Surprises &
Discoveries. Selection will then legitimately cover most of the catalog, per
[ADR-5](../adr/0005-select-runs-from-a-checked-in-component-graph.md). If some fix cannot solve
with the others, split it into a later round and record why.

### Milestone 2: reconcile scopes and open the round

1. Run `owners scopes`.
2. Apply the proposed scope corrections for in-scope records in the cited source files, as a
   reviewed commit. Expected on 2026-10-01: the shibuya-kafka-adapter BUG-5 bound moves from
   `0.9.0.2` to `0.9.1.0`.
3. Decide the `bound-without-owner-fix` warnings for shibuya-kafka-adapter BUG-3 and BUG-4, and
   record the decision in this plan's Decision Log.
4. Run `owners scopes --strict` until it passes for the in-scope records.
5. Rehearse `owners round open` with a scratch round number and review the printed Rei
   commands. Delete the scratch round, then run `owners round open --round 1 --base released
   --candidate round-1 --include-local runs --apply-rei`.
6. Commit `rounds/1.json`.

### Milestone 3: execute

1. Run `owners round plan --round 1 --out rounds/1/plan.json`.
2. Execute local tiers with `cabal run -v0 kenshou -- execute --plan rounds/1/plan.json --out .dev/round-1`.
3. Execute cell tiers according to `docs/guides/running-on-gcp.md`, with a `round-1` payload.
4. Record and attest the runs that the recording guide says are publishable.

Keep run IDs in this plan's Progress notes as evidence.

### Milestone 4: report and follow-through

1. Run `owners round report --round 1 --include-local .dev/round-1 --fetch-labels --write`.
2. For each new blocking failure, create a local finding in `docs/findings/` and file or reuse
   an owner record per the procedure above.
3. Complete the round's Rei intention if every in-scope record has a final disposition
   (`verified-fixed`, `still-reproduces`, `regressed` or `different-failure`). Otherwise leave it
   open, naming the records that are `not-run` and why.
4. Update the MasterPlan's Progress and Outcomes.


## Concrete Steps

From the repository root, inside `nix develop`:

```bash
cabal run -v0 kenshou -- owners status --json > /tmp/owner-status.json
just use-cohort round-1 && cabal build all && just cohort-check
cabal run -v0 kenshou -- owners scopes --strict
# Rehearse with a scratch round number, review the printed Rei commands, then discard it
cabal run -v0 kenshou -- owners round open --round 99 --base released --candidate round-1 --include-local runs
rm rounds/99.json
# Open round 1 for real and apply the reviewed Rei wiring
cabal run -v0 kenshou -- owners round open --round 1 --base released --candidate round-1 --include-local runs --apply-rei
cabal run -v0 kenshou -- owners round plan --round 1 --out rounds/1/plan.json
cabal run -v0 kenshou -- execute --plan rounds/1/plan.json --out .dev/round-1
cabal run -v0 kenshou -- owners round report --round 1 --include-local .dev/round-1 --fetch-labels --write
just use-cohort released   # return the working tree to the baseline cohort
```


## Validation and Acceptance

The plan is accepted when all of the following hold:
- `rounds/1.json` and `docs/reports/<date>-round-1.md` are committed.
- Every in-scope record has a disposition.
- Every `verified-fixed` in the headline counts traces to a `confirmed` bundle record that a
  reader can open.
- Every new blocking failure has a local finding with an owner disposition.
- The round's Rei intention shows its dependencies with
  `rei dependency show <round intention>`.

A reader comparing the round report with `docs/reports/2026-09-29-runtime-baseline.md` can see,
for each Shibuya 0.10.0.0 record, its released-cohort reproduction and its round-1 result side
by side.


## Idempotence and Recovery

Cohort switching is reversible with `just use-cohort released`. Execution resumes with
`kenshou execute --resume` against the identical plan. Recording refuses identity collisions, so
re-recording is safe. Before Rei is applied, a mistaken round is removed by deleting
`rounds/1.json`. After Rei is applied, abandon the round's intention in Rei rather than reusing
the number.


## Interfaces and Dependencies

This plan consumes everything EP-1 to EP-4 export and adds no new interfaces. It produces the
artifacts `cohort/round-1.json`, `cohort/round-1.project`, `rounds/1.json`,
`rounds/1/plan.json`, `docs/reports/<date>-round-1.md`, bundle records under
`docs/verification/runs/`, and, if needed, new local findings and owner reports.
