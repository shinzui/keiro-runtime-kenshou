# Kafka group rebalances end adapter consumers

Status: reproduced twice on the released cohort; filed as
`mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-4`.
The owner bug-report bundle passed strict OKF profile and log validation on
2026-09-25.

The `kafka/adapter/concurrency/group-rebalance-with-inflight` scenario starts
three serial adapter workers and an open-loop producer, then adds a worker,
stops one gracefully, kills one, and restarts it. Every worker installs the
caller-provided `kafkaRebalanceHandler` and logs assignment and revoke
callbacks. Two private Redpanda 26.2.1 runs on Hackage adapter 0.9.0.1
recorded surviving workers returning `Right ()` before a stop command.

Reduced run `01a0d639-dce0-7333-9256-3ee15d0e29c0` acknowledged 3,000
records, recorded 1,695 handler facts for 1,477 distinct IDs, and retained
lag on eleven of twelve partitions after the deadline. Three workers ended
normally before stop. Run `01a0d63c-dfb0-762c-a9e6-c3f23156afc5` used a
slower three-second membership cadence; two workers ended unexpectedly, but
the remaining group eventually handled all 4,000 acknowledged IDs and
reached zero lag. The wrong exit is repeatable; unhandled records depend on
the schedule.

The scenario also recorded within-assignment offset reversals in both runs,
and duplicate delivery beyond the declared membership windows in the second.
Those separate checks remain blocking until isolated. The BUG-4 known-defect
scope covers only the unexpected worker exit and its immediate no-loss and
lag consequences on Hackage adapter 0.9.0.1. Versions above 0.9.0.1 are not
verified here.

Reproduce with:

```bash
cabal run kenshou -- run kafka/adapter/concurrency/group-rebalance-with-inflight --out runs --set kafka.messages=3000 --set kafka.membership-interval-seconds=1 --set kafka.service-ms=5
```

The sealed results and worker control logs are under
`mori://shinzui/keiro-runtime-kenshou` at the named run directories; an
artifact-level Mori URI for run directories is pending. The source-level
stream termination path remains to be isolated.
