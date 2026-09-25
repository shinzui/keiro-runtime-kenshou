# Kafka later retry overwrites an earlier seek barrier

Status: reproduced on the released cohort; filed as
`mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-5`.
The owner bug-report bundle passed strict OKF profile and log validation on
2026-09-25.

`kafka/adapter/concurrency/barrier-overwrite-loses-record` publishes offsets
0–9 to a private, one-partition Redpanda 26.2.1 topic. One real consumer poll
returns all ten records. The scenario finalizes `AckRetry` for offsets 3 and 4
through Hackage `shibuya-kafka-adapter` 0.9.0.1 `mkAckHandle` before polling
again. This isolates the per-partition barrier update from runner timing.

Sealed run `01a0d65a-4f69-733e-a3f8-cef8dcc8c63f` redelivered offsets 4–9.
Offsets 0–2 and 4–9 had successful decisions; offset 3 never did. The broker
reported committed offset 10, so the consumer group had committed past an
unhandled record. Only `barrier-overwrite-no-loss` failed. The scenario scopes
that label to BUG-5 for this released version. A newer adapter release has not
been tested.

Reproduce with:

```bash
cabal run kenshou -- run kafka/adapter/concurrency/barrier-overwrite-loses-record --out runs
```

The result is under `mori://shinzui/keiro-runtime-kenshou` at
`runs/01a0d65a-4f69-733e-a3f8-cef8dcc8c63f/`; an artifact-level Mori URI
for run directories is pending. The brokerless model run
`01a0d657-0edb-758d-9047-6f824ee5e804` independently finds a minimized
dual-retry schedule using the same released adapter code.
