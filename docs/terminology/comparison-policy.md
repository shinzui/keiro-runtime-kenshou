---
type: Term
title: comparison policy
description: The versioned thresholds and evidence requirements used to judge paired performance trials.
generated: {by: 'process:codex', at: '2026-09-27T21:51:02Z'}
termId: TERM-30
status: current
tags: [measurement]
related: [TERM-20, TERM-22]
anchors:
  - {kind: file, resource: schemas/comparison-policy-v1.schema.json}
  - {kind: file, resource: policies/default.json}
---

# comparison policy

The policy supplies minimum pairs, metric direction, regression limits, and
other rules that `kenshou compare` applies to a
[paired comparison](paired-comparison.md). The comparison saves the policy it
used, so an [attestation](attestation.md) can replay the same judgment. A
statistically adverse movement without enough practical effect does not meet
the regression rule in [ADR-6](../adr/0006-comparison-verdicts-require-controlled-benchmark-evidence.md).
