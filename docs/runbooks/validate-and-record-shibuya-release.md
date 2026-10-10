---
type: Runbook
docId: RB-1
title: Validate and record a Shibuya release against the baseline
description: Pin a published Shibuya candidate, compare its behavior with the historical released cohort, and retain sealed runs and their verification status.
owner: shinzui
projects:
  - mori://shinzui/keiro-runtime-kenshou
  - mori://shinzui/shibuya
  - mori://shinzui/shibuya-pgmq-adapter
  - mori://shinzui/kiroku
environments: [local-nix, disposable-postgresql-17, disposable-postgresql-18, tan-nb-exp-evidence]
trigger: A published Shibuya release needs regression or fix verification against the retained released cohort.
effects: [repository-change, service-change, data-change]
status: draft
tags: [shibuya, verification, baseline, release, evidence]
generated: {by: 'process:codex', at: '2026-10-10T19:57:25Z'}
sources:
  - {resource: '../guides/recording-evidence.md'}
  - {resource: '../guides/measuring-and-comparing.md'}
  - {resource: '../layers/shibuya.md'}
  - {resource: 'mori://shinzui/okf-profiles/profiles/runbooks'}
---

# Validate and record a Shibuya release against the baseline

Use this procedure from the Kenshou repository root. It covers the isolated core,
metrics, PGMQ and Kiroku lane. Kafka and assembled Keiro verification need their
own compatible cohorts. A core/metrics sweep alone does not establish adapter or
whole-runtime acceptance.

This is a draft checked against the CLI and scenario sources. Its addition does
not record an operational exercise. See the [Shibuya coverage notes](../layers/shibuya.md)
and [evidence guide](../guides/recording-evidence.md) for supporting contracts.

## Prerequisites and target checks

- Use a clean, committed harness with the locked Nix environment, Cabal, Mori,
  `jq`, Git and OKF. Commit candidate pin changes before execution.
- Obtain authority to commit selected pins and evidence. GCS recording needs
  access to the intended evidence bucket; attestation needs object read access.
- Adapter cases create disposable PostgreSQL fixtures and may terminate their
  backends or postmasters. Use the checked-in ephemeral specs and PostgreSQL
  17/18 tooling supplied by the development environment.
- Reserve a quiet host for performance evidence. Historical workstation timings
  are not a paired benchmark baseline.

```bash
nix develop
git status --short
cat cohort/active.project
jq '{name, compiler, indexState, components}' cohort/released.json
jq '{name, compiler, indexState, components}' cohort/shibuya-current.json
```

Expect an empty Git status and `import: released.project` as the active cohort.
If another cohort is selected, use `just use-cohort released`, rebuild, and
recheck. Resolve unrelated local edits before continuing.

The baseline is defined by `cohort/released.project` and `cohort/released.json`.
On 2026-10-10 it pins core/metrics 0.9.0.3, PGMQ adapter 0.16.0.0 and Kiroku
adapter 0.5.1.2. The isolated `shibuya-current` lane still pins core/metrics
0.10.0.0, PGMQ adapter 0.16.1.0 and Kiroku adapter 0.5.1.3. Read the files on
every exercise; their names do not guarantee freshness.

## 1. Resolve and pin the candidate

Locate upstream source and documentation before choosing compatibility changes:

```bash
mori registry search shibuya
mori registry show shinzui/shibuya --full
mori registry docs shinzui/shibuya
curl -fsSL https://hackage.haskell.org/package/shibuya-core/preferred.json
curl -fsSL https://hackage.haskell.org/package/shibuya-metrics/preferred.json
git ls-remote --tags https://github.com/shinzui/shibuya.git 'refs/tags/v*'
```

Check Hackage and the upstream tag together, then inspect the changelog located
through Mori. At authoring time both packages' latest normal release is 0.10.0.1;
this dated observation is not a permanent pin.

Update both exact versions in `cohort/shibuya-current.project` and its JSON
descriptor together. Keep core and metrics compatible. Set matching index states
that include the release and refresh `verifiedAt`. Run `cabal update` if the local
index lacks the release, and keep the timestamp at or below its reported ceiling.
Keep the historical released
descriptor unchanged. Preserve adapter pins when testing only core/metrics. If an
adapter must move, verify its release through its Mori project, Hackage and upstream
tags and document the additional varying component.

```bash
cabal --project-file=cohort/shibuya-current.project build kenshou-shibuya-run
git diff -- cohort/shibuya-current.project cohort/shibuya-current.json
```

Stop on solver failure or unexpected selections. Review and commit the pin changes
using a Conventional Commit message, then require a clean worktree. The isolated
runner checks its descriptor against the actual solver plan when executing. It
currently reads `dist-newstyle/cache/plan.json`: retain the default build directory
and never build the two projects concurrently.

## 2. Run the correctness and concurrency cases

```bash
just use-cohort released
bash scripts/run-shibuya-core-cohort-smoke.sh runs/shibuya-baseline
bash scripts/run-shibuya-core-current-smoke.sh \
  cohort/shibuya-current.project runs/shibuya-candidate
```

Both scripts select the 30 scenarios in
`scripts/shibuya-core-metrics-scenarios.txt`. Each emits the run ID, scenario,
outcome, blocking flag and known-defect status. Runs get unique directories under
the output root. Preserve their IDs as the exercise inventory.

The scripts stop at the first nonzero result. Keep the sealed result and distinguish
a scenario failure from infrastructure failure. If it is safe to continue, execute
the remaining scenarios individually. For a candidate core case, create a run-spec
with the scenario ID, empty dimensions and knobs, and
`environment: {placement: local}`, then use the isolated command below. Do not
report a partial sweep as complete.

Adapter coverage needs matching specs on both cohorts and both PostgreSQL versions.
For example, the PGMQ atomic dead-letter case on PostgreSQL 18 is:

```bash
cabal run -v0 kenshou -- run \
  --spec specs/shibuya-current-atomic-pg18.json --out runs/shibuya-baseline
cabal --project-file=cohort/shibuya-current.project run kenshou-shibuya-run -- \
  run specs/shibuya-current-atomic-pg18.json runs/shibuya-candidate
```

Repeat with the `pg17` spec. Select the other PGMQ/Kiroku specs from the
[README](../../README.md#getting-started) and coverage catalog, including ack mapping,
retry/restart, outage and shutdown cases relevant to the changed packages. Inventory
the selected specs before running so omitted cases stay explicit. Use the full CLI
for baseline cases; the isolated runner always loads `shibuya-current.json`.

## 3. Assess behavior against the baseline

Read each sealed result instead of interpreting shell success alone:

```bash
jq '{runId, scenario, outcome, blocking, failures, knownDefect, cohort}' \
  runs/shibuya-candidate/RUN-ID/run-result.json
```

Substitute the actual emitted ID. Match scenarios and revisions, effective knobs,
dimensions, seed and environment. Inspect `run-spec.json` and the resolved cohort
to verify the intended configuration and package versions.

The convenience sweeps choose fresh seeds. For a seed-sensitive failure or a
strictly matched replay, derive a portable spec from the sealed baseline spec:

```bash
jq '{schema, scenario, scenarioRevision, dimensions, knobs, seed, phases,
     timeoutSeconds, environment}' \
  runs/shibuya-baseline/BASELINE-RUN-ID/run-spec.json > runs/shibuya-replay-spec.json
cabal --project-file=cohort/shibuya-current.project run kenshou-shibuya-run -- \
  run runs/shibuya-replay-spec.json runs/shibuya-candidate
```

Removing the saved run ID permits a new unique run. A changed scenario revision
requires investigation rather than overriding the version check.

- A passing candidate against a reproduced baseline defect is fix evidence for
  that scenario/configuration, subject to independent verification.
- A reproduced known defect may have `outcome: failed` with exit code zero.
  Inspect failure labels and disposition; shell success is not proof of a fix.
- A new blocking failure or `different-failure` needs investigation. Preserve it,
  including when a subsequent repeat passes.
- Interrupted, missing or failed cases are not completed acceptance checks.

Write a dated report under `docs/reports/` listing selected versions, harness
commit, baseline/candidate run IDs, per-scenario results, unresolved failures and
omitted coverage. Cite owner artifacts with canonical Mori URIs. Preserve historic
baseline claims and owner classifications.

## 4. Optional performance comparison

Follow the [paired measurement rules](../guides/measuring-and-comparing.md).
Use five pairs by default, at least three, interleaving the two cohorts on one
controlled host. Build each project's executable before its arm; never invoke a
saved executable against a solver plan overwritten by the other project. Match
scenario revision, load, phases, seed, durability and environment. Vary the cohort
only. The correctness sweep is not a performance comparison.

For `specs/shibuya-concurrency-sweep-serial.json`, execute the same spec using the
two commands in step 2, in adjacent baseline/candidate pairs. This spec supplies
a starting workload: calibrate it and inspect its measured grade before claiming
benchmark acceptance. Give both arms the same explicit seed, for example:

```bash
mkdir -p runs
jq '. + {seed: 20261010}' specs/shibuya-concurrency-sweep-serial.json \
  > runs/shibuya-benchmark-spec.json
```

Use that generated spec for both arms in every pair. Verify every arm's saved measurements:

```bash
cabal run -v0 kenshou -- summarize runs/ARM/RUN-ID --verify
```

After five pairs, substitute their actual directories in pair order:

```bash
cabal run -v0 kenshou -- compare \
  --baseline runs/shibuya-baseline/B1 --candidate runs/shibuya-candidate/C1 \
  --baseline runs/shibuya-baseline/B2 --candidate runs/shibuya-candidate/C2 \
  --baseline runs/shibuya-baseline/B3 --candidate runs/shibuya-candidate/C3 \
  --baseline runs/shibuya-baseline/B4 --candidate runs/shibuya-candidate/C4 \
  --baseline runs/shibuya-baseline/B5 --candidate runs/shibuya-candidate/C5 \
  --vary cohort --policy policies/shibuya-concurrency-sweep.json \
  --out runs/shibuya-comparison.json
```

Expect an explicit verdict. Preserve regressions and inconclusive results; do not
weaken the policy to make inadequate trials pass. Other benchmarks need a policy
matching their metrics, rather than the concurrency-sweep policy.

## 5. Record sealed evidence

Rebuild the released CLI before recording or offline analysis so its own identity
matches the full project:

```bash
just use-cohort released
cabal build kenshou
gcloud config get-value project
```

Expect `tan-nb-exp` before using the destination below. Stop on a mismatch and
choose the intended destination explicitly; do not switch accounts or projects
silently. Replace the run IDs, and record the retained inventory, including failures
relevant to the decision:

```bash
cabal run -v0 kenshou -- record runs/shibuya-baseline/BASELINE-RUN-ID \
  --data-base-uri gs://kenshou-evidence-tan-nb-exp/runs \
  --project tan-nb-exp --purpose baseline --link-logs
cabal run -v0 kenshou -- record runs/shibuya-candidate/CANDIDATE-RUN-ID \
  --data-base-uri gs://kenshou-evidence-tan-nb-exp/runs \
  --project tan-nb-exp --purpose release --link-logs
```

Recording creates immutable concepts and updates indexes/logs in
`docs/verification/`; raw bytes live at digest-pinned GCS locations. An identical
repeat is safe, while conflicting objects are errors. Dirty harness runs require
`--allow-dirty` and are forced to `investigation`; they cannot replace clean release
evidence. A rehearsal uses the guide's copied bundle and scratch store.

If a performance comparison exists, record every arm before recording it:

```bash
cabal run -v0 kenshou -- record --comparison runs/shibuya-comparison.json \
  --data-base-uri gs://kenshou-evidence-tan-nb-exp/runs \
  --project tan-nb-exp --purpose release
```

Review and commit records and generated indexes/logs before attestation or further
scenario execution. New executions must retain a clean harness fingerprint.
Never modify sealed output or a committed record's historical claim.

## 6. Attest and report trust

For one target, start from a clean committed checkout:

```bash
cabal run -v0 kenshou -- attest CANDIDATE-RUN-ID --project tan-nb-exp
```

Attestation writes evidence, making the checkout dirty. For multiple targets,
use the evidence guide's clean detached verifier checkout with `--bundle` pointing
to the absolute `docs/verification` path in the working checkout. After committing
the records, create a new verifier path and run each target there:

```bash
kenshou_bundle="$PWD/docs/verification"
kenshou_verifier="$PWD/.dev/shibuya-verifier"
git worktree add --detach "$kenshou_verifier" HEAD
cd "$kenshou_verifier"
nix develop -c cabal build kenshou
nix develop -c cabal run -v0 kenshou -- attest CANDIDATE-RUN-ID \
  --bundle "$kenshou_bundle" --project tan-nb-exp
git status --short
```

Expect the verifier checkout to stay clean. Repeat the attestation command for
baseline/candidate targets and any comparison ID; keep both shell variables in
the same session. Return to the working checkout to review and commit the resulting
attestations and verification events. If the verifier path already exists, inspect
it or choose a new path rather than overwriting it.

Distinguish `confirmed`, `refuted` and `incomplete`. On 2026-10-10, Shibuya
correctness scenarios have no independent domain outcome recomputer in the attester.
Their attestations can remain `incomplete` even when sealed bytes and revisions
verify. Report that limit explicitly: recording or a passing run alone does not
establish a machine-confirmed fix. A human may review raw evidence and add their
own ordered `verified` entry following the guide. Never invent that sign-off or
use anomaly acceptance as machine confirmation.

Read reference history per scenario, for example:

```bash
cabal run -v0 kenshou -- history \
  --scenario shibuya/core-runner/concurrency/halt-wakes-idle-intake \
  --cohort-component shibuya-core=0.9.0.3 --confirmed-only --json
```

Omit `--confirmed-only` to inspect unverified evidence too. Empty confirmed history
means no qualifying trusted record, not that the scenario was never executed.
Attach run concepts and attestation outcomes to the dated report.

## Success, stop conditions and recovery

The exercise is complete when its report accounts for every selected scenario,
identifies actual cohorts, links retained records, explains trust limitations,
and supplies paired evidence for any requested performance verdict. Release
acceptance additionally needs the agreed checks to pass; completing a failed
investigation does not approve a release.

Stop the affected branch on solver/identity mismatch, a wrong GCP destination,
unexpected blocking failure, unsealed output or conflicting durable data. Diagnose
before rerunning and retain prior evidence. Infrastructure failure needs a new
run, not an edited result.

Return to `just use-cohort released` and rebuild after using the isolated project.
Clean up only the exercise's disposable fixtures through their lifecycle tooling.
Do not terminate a shared database to recover a probe. Published evidence uses
create-only writes and five-year retention: treat it as durable. For a wrong
committed claim, retain it and record corrected evidence or a refuting attestation;
follow the immutability guide rather than deleting or rewriting history.

Escalate unresolved issues to **shinzui**, the Kenshou project owner. Preserve
harness commit, actual cohort, effective specs, run IDs, manifests, logs, failure
labels, comparison policy and attestation diagnostics. File a finding or cite an
existing owner record as appropriate; Kenshou does not change another project's
owner status.

Validate documentation and evidence before closing:

```bash
just runbooks-validate
just evidence-validate evidence-check
```

Run `just verify` for the complete repository gate when closing a release exercise.
