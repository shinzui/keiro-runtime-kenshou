# Kafka rebalance replays committed offsets out of order

Status: reproduced twice on the released cohort; filed as
`mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-6`.
The owner bug-report bundle passed strict OKF profile and log validation on
2026-09-25. The owner report is committed as `bef1328`.

`kafka/adapter/concurrency/group-rebalance-with-inflight` runs serial
`AckOk` handlers with the adapter's rebalance callback installed. It changes
group membership four times during an acknowledged open-loop produce. The
worker records each handler fact immediately before returning `AckOk`, and
the scenario samples committed offsets before each membership change.

Run `01a0d6b3-b843-7149-a2b2-981e6a1734ef` handled all 4,000
acknowledged IDs and reached zero group lag. Member 3's third assignment
included partition 4 at 03:55:10.613Z. Within that assignment it handled
offset 200 at 03:55:11.271Z, then offset 165 at 03:55:11.282Z. The
partition's committed position had been 173 at 03:55:09.687Z. Independent
run `01a0d6ae-5461-7105-9306-89c743515865` handled partition 0 offset
235 then 168 within one assignment; its sampled committed position was 197.
The exact source-level path through the adapter and Shibuya runner remains
unknown. This is distinct from the early adapter exit filed as
`mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-4`.

Reproduce with:

```bash
cabal run kenshou -- run kafka/adapter/concurrency/group-rebalance-with-inflight --out runs --set kafka.consumers=3 --set kafka.membership-interval-seconds=3 --set kafka.messages=4000 --set kafka.partitions=12 --set kafka.service-ms=10
```

The sealed results and worker control logs are under
`mori://shinzui/keiro-runtime-kenshou` at the named run directories; an
artifact-level Mori URI for run directories is pending. The scenario still
returns a blocking `rebalance-assignment-order` failure because its current
`KnownDefect` field can identify only BUG-4's separate early-exit behavior.
