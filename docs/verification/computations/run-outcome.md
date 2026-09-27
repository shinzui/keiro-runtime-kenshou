---
type: Attested Computation
title: Run outcome and known-defect disposition
description: How the runner records a scenario outcome, an execution error, and a cohort-scoped known defect in the sealed result.
status: stable
runtime: kenshou
parameters:
  - name: runDirectory
    type: path
    required: true
executor:
  resource: /references/executors/kenshou-run.sh
  receipt: [run-spec.json, run-result.json, manifest.json]
attester:
  resource: /references/attesters/kenshou-attest.sh
generated:
  by: codex/gpt-6
  at: 2026-09-26T19:50:17Z
algorithm: run-outcome
algorithmVersion: 1
appliesTo: [correctness, concurrency, soak, benchmark]
computationId: VC-1
implementation: Kenshou.Core.Run
inputs: [run-spec, run-result, verdicts, diagnosis, logs]
produces: outcome
---

# Run outcome and known-defect disposition

`Kenshou.Core.Run.executeRun` records the scenario's `ScenarioReport.outcome` as the run outcome. If the scenario body throws or times out, the runner substitutes `errored`. A cohort mismatch or failed environment provision substitutes `infrastructure-failure`. The runner does not fold checker files into the outcome; each scenario is responsible for combining its own verdicts and diagnoses before returning its report.

# Computation

```text
scenario report + execution state + cohort-scoped known defect
  -> outcome, failures, known-defect status, blocking, exit code
```

The runner first resolves the scenario and provisions its environment. It executes the scenario under its configured timeout and captures its `ScenarioReport`. It then applies `defectDisposition` to the report and the resolved cohort. A failed report is nonblocking only when an applicable known defect declares every actual failure label. The sealed `run-result.json` records the outcome, failure labels, known-defect status, `blocking`, and exit code. `Kenshou.Core.Outcome.outcomeExitCode` maps passed to 0, failed to 1, inconclusive to 3, and errored or infrastructure failure to 4; a reproduced known defect maps to exit 0 unless strict mode was selected.

# Verification limit

The sealed result and checker files can establish internal consistency and digest integrity. They cannot independently prove that an arbitrary scenario's reported outcome was true without replaying its domain-specific oracle. An attestation must mark that check incomplete when its required oracle is unavailable.

The Kafka static-member fencing oracle replays the two sealed worker control streams. It derives replacement handling, the original member's fatal error and exit, failure labels, and the cohort-scoped known-defect disposition. If the original exits without a fatal error, the control stream cannot distinguish an exit before the scenario deadline from cleanup afterward, so that case remains incomplete.
