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

`kafka/adapter/correctness/ack-state-machine-model` runs the released
adapter's `kafkaSource`, `dropStaleRecords`, `mkIngested`, and `mkAckHandle`
against an in-memory `KafkaConsumer` interpreter. The default 2,000-case
run found replayable violations of commit safety, first-success order, and
completion at log end. A fixed depth-ten schedule with offsets 3 and 4 each
retrying once skipped offset 3 and stopped with stored offset 5 of 10.
The reference depth-one acknowledgement handler passes the same three
properties in `kenshou-kafka-test`. The released-cohort model result is scoped
to `mori://shinzui/keiro/masterplans/18-make-the-kafka-transport-edge-production-safe-surfaced-by-the-2026-07-transport-review`.

`kafka/adapter/concurrency/barrier-overwrite-loses-record` reproduces KFK-1
through a real consumer and private broker. One poll returns offsets 0–9;
the adapter finalizes retries at 3 and 4 before the next poll. The broker
redelivers 4–9 and the group commits 10 without any successful decision for
offset 3. The known, released-cohort failure is
`mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-5`.

`kafka/producer/benchmark/produce-modes` measures four modes against a private
broker with `kafka.produce-mode`, `kafka.messages`, `kafka.payload-bytes`,
`kafka.prop.acks`, `kafka.prop.linger.ms`, and
`kafka.prop.enable.idempotence`. It checks the entire produced ID set through
an independent consumer. Sync and callback histograms measure broker
acknowledgements; asynchronous and batch-loop histograms measure enqueue and
flush, because those APIs do not provide per-record delivery facts. A local
100-record exploratory run gave 479 records/s and 0.57 ms p50, 6.48 ms p99
acknowledgement latency for sync. Async-flush gave 726 records/s, batch-loop
564 records/s, and callback 687 records/s; the callback acknowledgement p50
was 10.18 ms and p99 10.48 ms. These four single runs are exploratory, not
cell throughput claims. Their IDs are `01a0d663-575e-769b-91ec-44cdc38e08dc`,
`01a0d663-97f1-7506-87f3-c58c0b605ba8`,
`01a0d663-c641-746a-b976-992fe7baf749`, and
`01a0d663-f453-73ca-b38b-f0690d7b6724` respectively.

`kafka/adapter/benchmark/poll-cap-latency` drives the released adapter's
`kafkaSource` with open-loop intended timestamps. Knobs are
`kafka.rate-per-second`, `kafka.poll-timeout-ms`, `kafka.batch-size`, and
`kafka.messages`. It records intended-to-poll p50/p90/p99/p99.9 through the
measurement toolkit, then checks every broker-acknowledged ID and zero group
lag. Three local, 100-record, 100-record/s exploratory runs all passed:
batch 100 and requested timeout 1000 ms yielded p50 242 ms, p99 496 ms;
batch 100 and timeout 50 ms yielded p50 207 ms, p99 536 ms; batch 1 and
timeout 1000 ms yielded p50 9.93 s and p99 19.38 s, at only 4.84 records/s.
The last result is much slower than the drafted batch-size-one expectation;
the short runs include assignment and catch-up effects, so they do not
establish a steady-state latency curve. The run IDs are
`01a0d667-fbf6-732d-b479-4ef6adb3279d`,
`01a0d668-b342-71f2-92f7-4369d9da9ba7`, and
`01a0d668-4921-754d-8dc4-6db197914ac7` respectively. Idle consumer CPU
still needs a process-isolated measurement.

`kafka/pipeline/benchmark/produce-consume-throughput` exercises three paths
with `kafka.consume-path`: the Shibuya runner (`adapter-runapp`), the adapter
stream (`adapter-stream`), and a raw consumer poll (`raw-poll`). Knobs cover
partitions, consumers, batch and inbox sizes, payload size, record count,
acknowledgement policy, linger, compression, and fetch queue settings. It
timestamps each acknowledged send and handler entry, then requires the full
ID set and zero lag. In three local 100-record exploratory runs with four
partitions and two consumers, raw poll handled about 525 records/s (p50
5.9 ms, p99 11.1 ms), adapter stream 375 records/s (p50 203 ms, p99 258 ms),
and the Shibuya runner 10.9 records/s (p50 3.55 s, p99 9.08 s). These
single short runs include consumer assignment and do not establish sustained
capacity. Their IDs are `01a0d66d-ecb0-7525-9eae-e42def1afb15`,
`01a0d66e-39a3-75d4-b47b-85ecd21ff80b`, and
`01a0d671-03cb-7047-b6c3-1efe2bf257c9`. The runner path initially
crashed when the harness canceled its thread; a graceful adapter shutdown
removed the crash in one and two consumer controls. The leaked private
containers from those two unsealed crash probes were stopped and deleted.

`kafka/telemetry/correctness/context-leak-regression` uses the in-memory SDK
arm and one traced Kafka batch containing a record with `traceparent`, a
headerless record, and a second independent `traceparent`. It requires three
consumer spans, the two inbound trace IDs, a new root for the headerless
record, and unchanged ambient context after the batch. Private broker run
`01a0d67a-a345-70d5-99da-01b3f611938e` passed. The first probe showed
three isolated root spans because the toolkit had configured W3C only on its
provider. `startTracing` now installs the same W3C propagator globally for
active tracing arms, as required by the traced kafka-effectful interpreters.

`kafka/telemetry/correctness/w3c-context-continuity` sends inside a parent
span through `runKafkaProducerTraced`, reads `traceparent` back from the
broker, and checks the producer span's trace and span IDs. A Shibuya runner
span must be a child of that producer span and carry Kafka system, partition,
and offset attributes. The `kafka.consumer-tracing` knob selects `shibuya`,
`kafka-effectful`, or `both`; the latter also checks the traced consumer's
parent and trace ID. Default run `01a0d67d-0a52-7567-a42f-2c2a7f2c3134`
and `both` run `01a0d67d-479f-7454-914d-067b5d6598c0` passed.

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

`kafka/adapter/concurrency/partitioned-consumer-becomes-zombie` uses two
broker-proxy lanes and blackholes A's lane for twice its session timeout.
In a reduced 2,000-record run, B took over A's partitions, every
acknowledged ID had a handler fact, and sampled committed offsets did not
decrease. Both workers nevertheless ended normally before stop, leaving
lag 388 on each of A's former partitions. This matches the scoped
rebalance-exit report `mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-4`.
There were 312 duplicate facts against a proxy bound of 241 computed from
A's uncommitted handler facts and two 100-record poll batches. The worker
does not expose exact buffer occupancy, so that bound remains a blocking
estimate rather than a confirmed adapter contract violation.

`kafka/keiro-records/correctness/roundtrip-through-broker` publishes 200
Keiro integration events through the neutral record conversion and checks
their decoded events, Kafka delivery references, all six required wire
headers, and each `MissingHeader` error. Inputs include optional fields,
non-ASCII text, and payloads up to 64 KiB.
