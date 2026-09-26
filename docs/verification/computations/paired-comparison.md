---
type: Attested Computation
title: Paired benchmark comparison
description: How Kenshou compares compatible baseline and candidate runs under a versioned policy.
status: stable
runtime: kenshou
parameters:
  - name: baselineRuns
    type: paths
    required: true
  - name: candidateRuns
    type: paths
    required: true
executor:
  resource: /references/executors/kenshou-run.sh
  receipt: [run-spec.json, run-result.json, manifest.json]
attester:
  resource: /references/attesters/kenshou-attest.sh
generated:
  by: codex/gpt-6
  at: 2026-09-26T19:50:17Z
algorithm: paired-bootstrap-t-envelope
algorithmVersion: 1
appliesTo: [benchmark]
computationId: VC-3
implementation: Kenshou.Measure.Compare
inputs: [run-result, samples, comparison]
produces: comparison
---

# Paired benchmark comparison

# Computation

```text
paired compatible run summaries + policy
  -> metric confidence intervals + run-level reasons -> comparison verdict
```

`Kenshou.Measure.Compare.compareRuns` requires equal, nonempty baseline and candidate lists and checks compatibility except for the declared varying axes. It recomputes each run's measurement summary when the sealed result does not contain one, rejects mismatched machine fingerprints, and checks outcome, health, evidence grade, checkpoint asymmetry, pair count, and required interleaving. For each selected metric it applies the policy's paired bootstrap and Student-t envelope to ratios and deltas, then combines metric statuses and run-level reasons into `pass`, `regression`, `inconclusive`, or `infrastructure-failure`. The policy records the resampling seed, iteration count, confidence level, thresholds, and comparison design. The result names `paired-bootstrap-t-envelope` version 1 in `kenshou.comparison/v1`.
