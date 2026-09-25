# Buffered Kafka successors run before a retried record

Status: reproduced on the released cohort; filed as
`mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-2`.
The owner bundle passed strict OKF profile and log validation on 2026-09-25.

The private Redpanda 26.2.1 run
`01a0d5ec-3cf3-7625-a9f8-1ec2c2d9c916` used seed
`1402572546415582` and the released cohort with
`shibuya-kafka-adapter` 0.9.0.1 from Hackage, `shibuya-core` 0.9.0.3,
`kafka-effectful` 0.3.1.0, and `hw-kafka-client` 5.3.0. In one partition
the handler retried offset 3 once. The adapter delivered offsets
`[0,1,2,3,4,5,6,7,8,9,3]`; successful handlers ran in the order
`[0,1,2,4,5,6,7,8,9,3]`. Thus successors 4–9 ran before offset 3's
successful redelivery despite serial processing.
With `--set kafka.batch-size=1`, run
`01a0d5ee-9490-70b0-adb7-eaafedff1583` passed the same ordering rule.

Reproduce from this repository with:

```bash
cabal run kenshou -- run kafka/adapter/concurrency/buffered-successors-run-before-retry --out runs
```

The sealed result and broker logs are under
`mori://shinzui/keiro-runtime-kenshou` at
`runs/01a0d5ec-3cf3-7625-a9f8-1ec2c2d9c916/`; an artifact-level URI for
run directories is pending. The existing mechanism analysis and proposed fix
are in
`mori://shinzui/keiro/plans/119-fix-the-seek-barrier-ordering-and-stale-successor-execution-in-shibuya-kafka-adapter`.
The separate commit-lag behavior is tracked in
`mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-1`.
