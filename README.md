# Keiro Runtime Kenshou

**検証** — *kenshou*: verification, validation, examination. The act of putting a
claim to the test and recording whether it held.

| 漢字 | Reading | Sense                                              |
| ---- | ------- | -------------------------------------------------- |
| 検   | ken     | to examine, to inspect, to verify                  |
| 証   | shou    | proof, evidence, attestation                       |

The name is deliberate. This repository is not a playground and not a sample
application — it exists to produce **evidence** about the Keiro runtime, under
conditions harsher than any single bounded context will meet in production, and
to keep producing it as the runtime changes. A green run here is a claim that
has been examined; a red run is the platform telling you something before a
service does.

It follows the naming precedent of `keiro-runtime-jitsurei` (実例, "real
examples").

## Why this exists

The Keiro runtime is becoming load-bearing for an expanding set of bounded
contexts. Each service has its own test suite, but no service exercises the
runtime hard enough, or adversarially enough, to establish that the runtime
itself is sound under concurrency, under load, and across releases. That
evidence belongs in one place, owned by the runtime rather than by any of its
consumers.

## Scope

Three axes, verified together rather than in separate efforts:

- **Correctness** — the runtime's guarantees stated as executable properties:
  replay determinism, append/commit atomicity, checkpoint and subscription
  lifecycle, idempotent dispatch, workflow and timer durability across restart.
  Property-based and model-based where the guarantee admits it.
- **Concurrency** — the same guarantees under interleaving: concurrent writers
  to one stream, competing consumers, partition and lease contention,
  crash/restart in the middle of a transaction boundary, clock skew. Failures
  here are the ones that never reproduce in a single-threaded suite.
- **Benchmarking** — throughput, latency distributions, and resource behavior
  measured with enough rigor to be compared **across releases**, not just
  reported once. Regression detection is the point; a number without a baseline
  is not evidence.

## Non-goals

This repository is not the home for:

- **Worked examples or reference architecture** — that is
  `keiro-runtime-jitsurei` (two bounded contexts, documentation-grade, runnable).
- **Implementation standards and prescriptive guidance** — that is
  `keiro-runtime-patterns`.
- **Product-oriented explanation and the docs site** — that is
  `keiro-runtime-docs`.
- **Store-level comparisons against other event stores** — that is
  `keiro-benchmarks` (`message-db-vs-kiroku`), which answers a different
  question: which substrate, not is-this-runtime-sound.

Unit tests that belong to a runtime package stay in that package. What lands
here is what cannot live in a single package: cross-package, multi-process,
multi-run, and comparative-over-time verification.

## Status

New repository. Nothing has been built yet — the structure below is the intended
shape, not a description of what exists.

```text
correctness/   executable properties for the runtime's stated guarantees
concurrency/   interleaving, contention, crash-restart, and fault injection
bench/         benchmarks with retained baselines for cross-release comparison
docs/          methodology, baselines, and findings
```

## Related

- `mori://shinzui/keiro` — the runtime family under verification
- `mori://shinzui/keiro-runtime-jitsurei` — runnable example bounded contexts
- `mori://shinzui/keiro-runtime-patterns` — implementation standards
- `mori://shinzui/keiro-runtime-docs` — documentation site
