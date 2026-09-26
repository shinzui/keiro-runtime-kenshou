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

The foundations are complete. The harness kernel, the change-aware planner, and
the measurement, correctness, diagnostics, and telemetry toolkits all work (EP-1
to EP-7). Coverage of the individual layers (EP-8 to EP-14) is in progress and
has already found runtime defects, which are recorded under `docs/findings/`.
Assembled-runtime verification, leased GCP cells, and the OKF evidence bundle
(EP-15 to EP-19) have not started. The master plan's Exec-Plan Registry
([`docs/masterplans/1-…`](docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md))
is the source of truth for plan status.

```text
cabal.project       imports the active cohort; discovers every kenshou-* package
cohort/             released/head solver inputs and machine-readable descriptors
kenshou-core/       done: cohort identity, harness kernel, component graph, planner
kenshou-cli/        done: `kenshou` CLI (list, plan, execute, compare, …) and link-proof
kenshou-measure/    done: load generators, recorder, samplers, paired comparison
kenshou-check/      done: ledgers, invariants, fault injection, process control
kenshou-diagnose/   done: leak verdicts, stall watchdog, profiling variants
kenshou-telemetry/  done: tracing/metrics arms and overhead measurement
kenshou-pgmq/       in progress: isolated PGMQ coverage (leak and comparison gates open)
kenshou-kiroku/     in progress: isolated Kiroku coverage (network-partition miss open)
kenshou-shibuya/    in progress: Shibuya core and PGMQ/Kiroku adapter coverage
kenshou-kafka/      in progress: private Redpanda fixture and first transport checks
kenshou-keiro/      in progress: fixture domain; command side, outbox/inbox/queue,
                    durable execution, timers, and sharded subscriptions
kenshou-runtime/    planned: assembled-system end-to-end and soak verification
schemas/            versioned JSON Schemas for specs, results, plans, and suites
suites/             named run suites: smoke, change, nightly, weekly-soak, release
policies/           verdict and comparison policies
docs/adr/           durable architecture decisions
docs/findings/      runtime defects found by the suite
docs/guides/        operator guides: measuring, diagnosing, telemetry arms
docs/layers/        per-layer coverage notes
docs/planning.md    planning and executing verification runs
```

## Getting started

Enter the locked development environment with `nix develop`, build the workspace
with `cabal build all`, and inspect the resolved dependency identity with
`cabal run kenshou -- cohort show`. Use `just use-cohort head` to select the
head cohort safely, and return to released before committing. Run the complete
local gate with `just verify`.

The current Hackage Shibuya releases have an isolated Cabal project because the
full Keiro cohort still bounds Shibuya below 0.10. To run a live Shibuya scenario
with that project from the repository root, use a versioned run spec:

```bash
nix develop -c cabal --project-file=cohort/shibuya-current.project run kenshou-shibuya-run -- run specs/shibuya-current-atomic-pg18.json runs
```

The same spec for PostgreSQL 17 is
`specs/shibuya-current-atomic-pg17.json`. The runner records the resolved
`cohort/shibuya-current.json` identity and writes the usual run result and
manifest under `runs/`.

The isolated executable also handles the hidden `worker --role` protocol used
by Shibuya's child-process scenarios. Calling `run` starts those workers
automatically. Checked-in specs cover every registered PGMQ scenario on
PostgreSQL 17 and 18.

The Kiroku adapter smoke cases use `specs/shibuya-kiroku-depth-pg18.json` and
`specs/shibuya-kiroku-ack-mapping-pg18.json`, with matching `pg17` specs. They
check persisted checkpoints and dead-letter rows on both supported PostgreSQL
versions.

PostgreSQL outage and backend termination comparisons use the same runner with
`specs/shibuya-current-outage-pg18.json` and
`specs/shibuya-current-backend-termination-pg18.json`; corresponding `pg17`
specs are checked in. The backend termination scenario has a scoped known
PGMQ disconnect-classification defect. Its exit code is zero when the only
failure matches that defect; inspect `knownDefect.status` and `failures` in
`run-result.json` for the actual verdict.

## Related

- `mori://shinzui/keiro` — the runtime family under verification
- `mori://shinzui/keiro-runtime-jitsurei` — runnable example bounded contexts
- `mori://shinzui/keiro-runtime-patterns` — implementation standards
- `mori://shinzui/keiro-runtime-docs` — documentation site
