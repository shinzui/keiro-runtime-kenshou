---
type: Runbook
docId: RB-2
title: Compare performance between exact runtime revisions
description: Prepare immutable baseline and candidate payloads, execute a bounded cell comparison, recover interruptions, and verify its durable report.
owner: shinzui
projects:
  - mori://shinzui/keiro-runtime-kenshou
  - mori://shinzui/shibuya
  - mori://shinzui/shibuya-pgmq-adapter
environments: [local-nix, x86_64-linux-builder, tan-nb-exp-verification-cells, tan-nb-exp-evidence]
trigger: A consuming project needs performance evidence for two compatible runtime source commits.
effects: [service-change, data-change]
status: draft
tags: [performance, runtime-changes, payloads, verification-cells, recovery, evidence]
generated: {by: 'codex/gpt-6.1-sol', at: '2026-10-12T14:05:49Z'}
sources:
  - {resource: '../guides/validating-runtime-change-performance.md'}
  - {resource: '../guides/running-on-gcp.md'}
  - {resource: '../plans/25-provide-quick-and-reliable-performance-validation-for-runtime-changes.md'}
  - {resource: 'mori://shinzui/okf-profiles/profiles/runbooks'}
---

# Compare performance between exact runtime revisions

Run this procedure from the Kenshou repository root when another project needs
an exact-revision comparison through `kenshou perf`. It generates isolated
cohorts and leaves the active and released cohort files unchanged. The operator
chooses the revisions and scope; Kenshou prepares, leases, measures, publishes
and verifies the resulting evidence.

This runbook is checked against the command implementation and operator guide.
Its draft status does not claim a live benchmark exercise. The initial core and
PGMQ profiles are uncalibrated, so the example produces exploratory evidence
with `gatingEligible: false`. No calibration batch is required to use that mode.
See the [performance guide](../guides/validating-runtime-change-performance.md)
for calibration admission and caller CI setup.

## Prerequisites and target checks

- Use a clean, committed harness and its locked Nix development environment.
  Git, Mori, Cabal, `jq` and an authenticated `gcloud` must be available.
- Register the source project in Mori on the operator host. Obtain two compatible
  full lowercase 40-character Git commits available from its registered HTTPS
  upstream. All varying target components must belong to that one project.
- Have a native `x86_64-linux` Nix builder or a configured remote builder.
  Preparation may require a substantial cold build; the execution budget does
  not promise a source-build duration.
- Have permission to lease the selected cell, read/create control and evidence
  objects, and read cell results. Starting a stopped cell requires the additional
  authority represented by `--start`.
- Retain current cell capability evidence matching the cloud descriptor in
  `.dev/cells`, or set `KENSHOU_CELL_CAPABILITIES_DIR` explicitly. After an image
  or descriptor change, follow the [cell probe procedure](../guides/running-on-gcp.md#probe-plan-and-route)
  using a published payload containing the environment probe scenario.

Enter the environment and build the operator executable:

```bash
nix develop
git status --short
cabal build kenshou
kenshou_cli=$(cabal list-bin kenshou)
mori registry show shinzui/shibuya --full
mori registry docs shinzui/shibuya
```

Expect an empty Git status. Resolve local edits before preparing payloads. For
another source project, substitute its registered qualified name and canonical
`mori://` URI throughout the request.

The following settings select the existing deployment without changing the
user's global GCP configuration:

```bash
export CLOUDSDK_CORE_PROJECT=tan-nb-exp
export KENSHOU_GCP_ALLOWED_PROJECTS=tan-nb-exp
export KENSHOU_CELL_CAPABILITIES_DIR="$PWD/.dev/cells"
CONTROL_BUCKET=tan-nb-exp-cells-control
EVIDENCE_URI=gs://kenshou-evidence-tan-nb-exp/performance
"$kenshou_cli" cell status --cell alpha
```

Check the identity, selected cell and destination before execution. A missing or
stale capability record needs a probe, not an edited capability file. Use the
cell owner's lifecycle tooling for machine changes; see the GCP guide.

## 1. Create and inspect the request

Choose unused output paths and keep these variables in the same shell:

```bash
mkdir -p .dev
kenshou_request=.dev/perf-request-1.json
kenshou_plan=.dev/perf-plan-1
kenshou_preparation=.dev/perf-preparation-1
kenshou_session=.dev/perf-session-1
```

Write the following JSON to `.dev/perf-request-1.json`, replacing both revision
placeholders with the chosen commits:

```json
{
  "schema": "kenshou.perf-request/v1",
  "project": "mori://shinzui/shibuya",
  "baselineRevision": "<full-baseline-commit>",
  "candidateRevision": "<full-candidate-commit>",
  "cohortTemplate": "cohort/released.json",
  "targetComponents": ["shibuya"],
  "suite": "change-performance",
  "coverageMode": "selected-profiles",
  "purpose": "calibration",
  "control": "none",
  "profiles": ["shibuya-core-quick", "shibuya-pgmq-quick"],
  "seed": 20261012,
  "cells": ["alpha"],
  "waitSeconds": 90,
  "budgetMinutes": 30
}
```

This varies Shibuya while exercising core and fixed PGMQ adapter paths. An
adapter-source change needs its owning project and component instead. Use
different commits with `control: "none"`; an A/A control uses equal commits and
explicit `control: "aa"`. Use `purpose: "gating"` only after the selected profiles
have verified calibration admission.

```bash
"$kenshou_cli" perf plan --request "$kenshou_request" --out "$kenshou_plan"
cat "$kenshou_plan/plan.json"
cat "$kenshou_plan/inputs.json"
```

Planning builds no payload and acquires no lease. Check source identities,
generated cohorts, selected/excluded profiles, estimates and uncovered scenarios.
`selected-profiles` assesses the named scope; `affected` requires complete
affected-scenario coverage. The report records requested `coverage` separately
from whole-change `changeCoverage`. Stop if the scope or revisions are wrong.
Correct the request and plan into a new directory; preserve sealed prior inputs.

## 2. Prepare both payloads before leasing

```bash
"$kenshou_cli" perf prepare --request "$kenshou_request" \
  --out "$kenshou_preparation" --cache .dev/perf-payload-cache \
  --control-bucket "$CONTROL_BUCKET"
cat "$kenshou_preparation/evidence/preparation-summary.json"
```

Expect `evidence/prepared.json` with both payload descriptors and independently
checked dependency inventories. Preparation rejects unrelated dependency or
toolchain drift before leasing. Cache hits retrieve and hash the bundle and
check its inventory identity. Keep the cache for later comparisons.

On failure, retain `work/` diagnostics and fix the reported source, solver,
builder or storage problem. Repeat preparation with the same request/cache and
a fresh output directory. Preparation failure has no execution session to resume.

## 3. Execute and retain the outcome

```bash
perf_run_exit=0
"$kenshou_cli" perf run \
  --prepared "$kenshou_preparation/evidence/prepared.json" \
  --evidence-base-uri "$EVIDENCE_URI" --out "$kenshou_session" \
  --control-bucket "$CONTROL_BUCKET" --start || perf_run_exit=$?
printf 'Performance run exit: %s\n' "$perf_run_exit"
"$kenshou_cli" perf status --session "$kenshou_session"
```

Omit `--start` if stopped instances must not be started. The client checks payload
and evidence access before leasing, then runs matched pairs with bounded
replacement allowances. Capture nonzero exits as outcomes needing inspection.
If preflight fails before creating the session, retain diagnostics and resolve
the failure before a new `run`; do not resume a nonexistent session.

## 4. Recover an interrupted session

```bash
"$kenshou_cli" perf status --session "$kenshou_session"
"$kenshou_cli" perf resume --session "$kenshou_session"
```

Allow only one mutating client per session. Resume reconciles retained submission
and lease identities, reuses completed verified work, and preserves the original
deadline, admission allowance and replacement counts. It does not restart the
budget. A timed-out lease claim is reconciled using its saved proposal ID; a lost
lease creates a separate attempt whose pairs are not pooled with the old lease.
A completed session reuses its verified receipt without dispatching more trials.

Retain `session.json`, preparation, logs and all work files. Do not delete journals,
edit sealed results, reset a shared database, or seize/release unrelated leases.
Cleanup targets only the exact owned work after terminal sealing or rejection;
ambiguous work remains fenced. If recovery cannot establish that state, stop and
escalate with the retained session rather than starting overlapping work.

## 5. Verify and read the published report

```bash
"$kenshou_cli" perf verify --session "$kenshou_session"
"$kenshou_cli" perf verify --session "$kenshou_session" --offline
```

Online verification retrieves the durable evidence graph; offline verification
replays the retained sealed graph and receipt without storage access. Both check
the raw evidence and recompute comparison semantics. A verified regression or
inconclusive result can still return a nonzero outcome; inspect the diagnostics.
A missing receipt means publication is incomplete: use status/resume before
attempting to read a final report.

After verification, locate the sealed snapshot through its receipt:

```bash
kenshou_snapshot=$(jq -r '.snapshot' "$kenshou_session/receipt.json")
cat "$kenshou_session/$kenshou_snapshot/report.md"
jq '{purpose, gatingEligible, coverage, changeCoverage}' \
  "$kenshou_session/$kenshou_snapshot/result.json"
```

Read the complete report for runtime blockers, exclusions, effect intervals,
thresholds and artifact references. A retained runtime defect remains a blocker
even if its process exited zero or performance statistics passed.

| Exit | Operator interpretation |
| --- | --- |
| 0 | Verified scoped pass or explicit documentation-only not-applicable result; calibration mode remains exploratory. |
| 1 | Performance regression or retained runtime correctness blocker. |
| 2 | Malformed request or command usage; correct the input. |
| 3 | Inconclusive statistics, incomplete coverage or insufficient remaining budget. |
| 4 | Infrastructure, preparation, publication or verification failure; no verified pass. |

Infrastructure failure takes precedence over a blocker/regression, then
inconclusive coverage, then pass. All underlying outcomes remain in the report.
Gate acceptance additionally requires `purpose: "gating"`, `gatingEligible: true`
and the agreed complete scope. An exploratory exit zero is not release approval.

## Completion, stop conditions and escalation

The operation is complete when the verified report accounts for the requested
scope, identifies both source commits, retains durable evidence references and
states gating eligibility. Record the request, harness commit, session location,
receipt, exit outcome and unresolved exclusions in the consuming project's
decision record. A completed investigation may have a failed or inconclusive
outcome; preserve it rather than retrying valid measurements until they pass.

Stop on wrong identities/destinations, inventory drift, unverified publication,
tampered evidence or ambiguous owned work. Use supported resume for interruption
or publication recovery within the original budget. Budget exhaustion does not
authorize extending a retained session; investigate and resolve owned work before
planning a separate operation.

Escalate unresolved preparation, lease or verification failures to **shinzui**,
the Kenshou project owner, with the request, harness commit, preparation summary,
session journal, lease/submission IDs, receipt and diagnostics. Keep raw evidence
and immutable published objects intact.
