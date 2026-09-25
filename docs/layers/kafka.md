# Kafka transport verification

`kenshou-kafka` owns the Kafka broker fixture. A local run starts a private
Redpanda 26.2.1 container with a run-specific name and free host ports. On
macOS it uses Apple Container; on Linux it uses Docker. One to four TCP proxy
lanes can sit between clients and the broker for fault injection. The fixture
uses a private `rpk` configuration and always passes an explicit broker
address. It never uses the shared `127.0.0.1:9092` broker.

Run the fixture checks from the repository root:

```bash
cabal run kenshou -- run kafka/broker/correctness/fixture-roundtrip --out runs
cabal run kenshou -- run kafka/broker/concurrency/kill-and-restart --out runs
```

The roundtrip writes and commits 100 records, checks group lag, and removes
the run's topics and groups. The restart case acknowledges 500 records, kills
the container, attempts a bounded write during the outage, restarts the same
container and data, then checks that 1,000 acknowledged records remain. Broker
logs are saved as `logs/kafka-broker.log` in the run directory.

## Broker configuration

An absent `environment.kafka` object selects one proxied private Redpanda
lane. A run specification may set it explicitly:

```json
{
  "environment": {
    "kafka": {
      "backend": "redpanda-container",
      "lanes": 2,
      "readyTimeoutSeconds": 90,
      "keepData": false
    }
  }
}
```

For a provisioned cell, give the cell's broker address. Its control commands
are optional and are required only by scenarios that terminate a broker.

```json
{
  "environment": {
    "kafka": {
      "backend": "external",
      "brokers": ["10.0.0.12:9092"],
      "lanes": 0
    }
  }
}
```

Every topic and consumer group includes the run prefix. The external backend
removes those resources when the run ends. The private backend removes its
container and temporary work directory. To inspect the private container and
data after a run, set `"keepData": true`; the work directory is
`$TMPDIR/kenshou-kafka-<run-id-without-dashes>/` and contains the container
name. Remove retained data deliberately after the investigation.

The fixture decision is [ADR-17](../adr/0017-keep-kafka-brokers-private-to-a-run.md).
The remaining transport scenario work is tracked in the repository-local
[Kafka ExecPlan](../plans/11-cover-the-kafka-transport-edge-with-a-disposable-broker.md).

## Current adapter and producer checks

`kafka/adapter/correctness/ack-ok-commits-and-resumes` uses Shibuya's
`runApp` and the Kafka adapter. Its `kafka.partitions` and `kafka.messages`
knobs default to four partitions and 500 records. It checks that every
payload is handled once, each partition's handler offsets increase, group
lag reaches zero, and a new session in the same group sees no old records.

`kafka/producer/correctness/acked-offsets-and-batch-loop` checks ten
`produceMessageSync` offsets, 1,000 `produceMessageBatch` enqueues and their
readback after flush, and ten `produceMessage'` delivery callbacks.

`kafka/producer/concurrency/batch-loop-reports-enqueue-not-delivery` kills
the run-owned broker, enqueues 100 records in a worker, waits for its flush,
restarts the broker, and reads the topic. The current API reports zero
enqueue failures although none of the 100 records was delivered. This is
the documented nonblocking limitation tracked by
`mori://shinzui/keiro/plans/120-add-an-acked-batch-publish-api-to-kafka-effectful-and-a-reference-outbox-bridge`.

`kafka/producer/correctness/transactions-commit-and-abort` checks that a
read-committed consumer sees ten committed records and none from an aborted
transaction. It then kills a consume-transform-produce worker after output
and input offsets are staged but before commit. A replacement with the same
transactional ID commits the replay; the output contains exactly one record
per input and the input group reaches zero lag. Both worker process IDs and
the visible counts are recorded in the verdict summary.

`kafka/adapter/correctness/multi-topic-partition-key` consumes two
single-partition topics through one adapter. Message IDs are distinct, but
the envelope partition key is `"0"` for both. The scenario records the
collision as the documented, nonblocking defect at
`mori://shinzui/shibuya-kafka-adapter/okf/capabilities/concepts/CAP-3`.

`kafka/adapter/correctness/retry-redelivers-and-never-commits-past` retries
offset 20 of a 50-record partition and samples the group commit boundary.
It supports `retry` and `throw` failure modes, a retry delay, an early-exit
resume arm, and poll batch sizes 1, 10, 100, or 1,000. With the released
adapter and default batch size, all handlers succeed but the group remains
behind the log end. This is the scoped known defect
`mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-1`;
other retry failures still block the run.

`kafka/adapter/correctness/halt-leaves-offset-uncommitted` publishes to two
partitions, halts on partition zero offset 30, and checks that no later
handler runs, the group's committed offset remains 30, and a second session
receives offset 30 first on that partition.

`kafka/adapter/concurrency/non-serial-finalization-commits-past-halt` repeats
the halt boundary with `Ahead` or `Async` handlers. Both modes committed
offset 53 and resumed there in the local released-cohort runs, crossing the
halt at 30. The known nonblocking limitation is
`mori://shinzui/shibuya-kafka-adapter/okf/capabilities/concepts/CAP-1`.

`kafka/adapter/correctness/dead-letter-drops-record` runs the adapter in a
child worker so its standard error is captured. Five poison records by
default return `AckDeadLetter`; the scenario checks every other ID, one
warning per drop, zero lag, no redelivery, and no prefixed DLQ topic. The
verdict summary records the actual drop count as `documentedLoss`.

`kafka/adapter/concurrency/buffered-successors-run-before-retry` retries
offset 3 of a single partition. On the released adapter, handlers for offsets
4–9 succeed before offset 3 is redelivered. The scoped nonblocking finding is
`mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-2`.
The `kafka.batch-size=1` control passes.

`kafka/adapter/concurrency/sigkill-redelivery-window` runs the adapter in a
worker process, kills it three times by default, records the consumer group's
committed offsets before each restart, and compares handler facts across
process incarnations. The default local run acknowledged 20,000 records,
recorded 20,233 handler facts, lost no IDs, replayed no offset below a sampled
commit boundary, and stayed inside the declared duplicate bounds.

`kafka/adapter/concurrency/auto-offset-store-loses-on-crash` blocks the handler
at offset 10 for three commit intervals before killing it. With automatic
offset storage enabled, the group committed the log end at 100 and a
replacement saw no record. The paired manual-store control committed 10 and
resumed at 10. The automatic-store loss is the nonblocking KFK-5 limitation at
`mori://shinzui/keiro/plans/121-enforce-consumer-offset-store-configuration-and-correct-the-kafka-transport-docs`.

`kafka/consumer/concurrency/static-membership-restart-without-revoke` starts
two raw consumers with prefixed static member IDs, kills A, then restarts it
after three seconds. In the local released-cohort run A regained its original
partitions, B logged no revoke during the window, and the group reached zero
lag. `kafka/consumer/concurrency/static-membership-fencing-is-observable`
starts A′ with A's member ID. A′ handled records, while A remained alive
without a fatal error on Hackage `hw-kafka-client` 5.3.0. That scoped,
nonblocking result tracks
`mori://shinzui/keiro/masterplans/23-make-the-kafka-consumer-streaming-stack-surface-fatal-errors-and-close-deterministically`.

`kafka/adapter/concurrency/halt-holds-assignment-past-max-poll-interval`
keeps a consumer open after `AckHalt` at offset 10 and adds a second member.
The first member retained the partition for 26 seconds, beyond the configured
poll and session timeout window, with 90 records of lag. Its group commit
remained at 10; after the first member was killed, the second handled offset
10 and drained the partition. The assignment claim is the nonblocking CAP-2
limitation at `mori://shinzui/shibuya-kafka-adapter/okf/capabilities/concepts/CAP-2`.

`kafka/adapter/concurrency/broker-outage-and-reconnect` injects a broker kill
or a proxy blackhole while two adapter workers and an open-loop producer stay
active. The reduced blackhole arm recovered with all 1,000 acknowledged IDs
handled. Broker-kill arms instead saw both workers exit with backlog; the
released 0.9.0.1 result is tracked as
`mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-3`.
Replacement workers are run as a control after this failure. One control
recovered every ID; another reached zero lag with nine IDs lacking handler
facts, which remains a blocking, separately labeled result.

`kafka/adapter/concurrency/group-rebalance-with-inflight` changes membership
four times while an open-loop producer sends acknowledged records. It checks
no loss, assignment-period offset order, duplicate windows, disjoint
ownership, and group lag. Two reduced runs on the released adapter recorded
surviving workers ending normally before stop. That scoped exit is tracked at
`mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-4`.
Offset-order reversals in both runs and duplicates beyond the declared
windows in one remain blocking, separately labeled results.

`kafka/adapter/concurrency/stale-barrier-after-partition-roundtrip` keeps
offset 50 pending on both partitions, moves one partition to a second member,
then returns it and produces 100 new records there. With the adapter's
rebalance callback installed, A handled all 100 new records at offsets
300–399. With `kafka.rebalance-handler=absent`, the same live check failed
only `roundtrip-new-records`: the stale barrier discarded the new records.
This demonstrates why callers must install the callback.

`kafka/keiro-records/correctness/roundtrip-through-broker` publishes 200
Keiro integration events through the neutral record conversion and checks
their decoded events, Kafka delivery references, all six required wire
headers, and each `MissingHeader` error. Inputs include optional fields,
non-ASCII text, and payloads up to 64 KiB.
