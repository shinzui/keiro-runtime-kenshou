---
type: Attested Computation
title: Steady-window latency and throughput summary
description: How Kenshou derives operation percentiles, throughput, and evidence grade from samples and series.
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
algorithm: kenshou-summary
algorithmVersion: 1
appliesTo: [benchmark, soak]
computationId: VC-2
implementation: Kenshou.Measure.Summary
inputs: [samples, series, run-result]
produces: summary
---

# Steady-window latency and throughput summary

# Computation

```text
steady histogram count / steady seconds = operation throughput
steady latency histogram quantiles = p50, p90, p99, p99.9
```

`Kenshou.Measure.Summary.summarizeRunDirWithHealth` locates the steady and drain boundaries in `series/load.csv`. For every operation metadata file it decodes the latency and service histograms, checks a required full raw sample file when configured, and derives p50, p90, p99, p99.9, maximum, and mean from the steady histogram. Throughput divides the steady histogram's count by steady seconds. The summary also derives runtime, process, and PostgreSQL metrics from the steady rows of their series files and evaluates health gates. Missing or truncated required samples prevent a summary. The grade is `benchmark` only when no grade or health reason remains; otherwise it is `exploratory`.

The algorithm name and version are written in `kenshou.measurements/v1`; the input files and the resulting summary remain in the sealed run directory.
