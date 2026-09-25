# Buffered Kafka retry leaves successful successors uncommitted

Status: reproduced on the released cohort; filed as
`mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-1`.
The owner bundle passed strict OKF profile and log validation on 2026-09-24.

The private Redpanda 26.2.1 run
`01a0d5d8-a8cd-77f0-92a2-e836dad8b3b7` used
`shibuya-kafka-adapter` 0.9.0.1 from Hackage (tarball SHA-256
`1918bae0c591ab47ba45d044a50170e7a340bddb1b562752cd16f556e86314e6`),
`shibuya-core` 0.9.0.3, `kafka-effectful` 0.3.1.0, and
`hw-kafka-client` 5.3.0. It handled offsets 0–49, retried offset 20 once,
and every offset eventually returned `AckOk`. After six seconds for
auto-commit and a graceful close, the group had committed 21 against log end
50, leaving lag 29. The same scenario with `kafka.batch-size=1` passed at
run `01a0d5d9-0b9c-711d-a1bf-4e8af275067d`. A thrown handler exception
instead of `AckRetry` reproduced the lag in
`01a0d5d9-8768-76a3-a587-6a7ece9ee4a9`; the early-exit resume arm passed
in `01a0d5d9-8768-7780-a954-9fd04b50fa16`.

Reproduce from this repository with:

```bash
cabal run kenshou -- run kafka/adapter/correctness/retry-redelivers-and-never-commits-past --out runs
```

The seed of the primary run was `6789536380475474`; `kafka.batch-size=100`,
`kafka.failure-mode=retry`, `kafka.retry-delay-ms=0`, and
`kafka.exit-before-success=false`. The sealed result and broker logs are under
`mori://shinzui/keiro-runtime-kenshou` at
`runs/01a0d5d8-a8cd-77f0-92a2-e836dad8b3b7/`; an artifact-level URI for
run directories is pending. The adapter's released README says `AckRetry`
seeks back without storing the failed offset and `AckOk` stores successful
offsets. Its capability
`mori://shinzui/shibuya-kafka-adapter/okf/capabilities/concepts/CAP-2`
states the at-least-once acknowledgement contract. The buffered-successor
mechanism is analyzed in
`mori://shinzui/keiro/plans/119-fix-the-seek-barrier-ordering-and-stale-successor-execution-in-shibuya-kafka-adapter`.
