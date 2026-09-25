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

`kafka/keiro-records/correctness/roundtrip-through-broker` publishes 200
Keiro integration events through the neutral record conversion and checks
their decoded events, Kafka delivery references, all six required wire
headers, and each `MissingHeader` error. Inputs include optional fields,
non-ASCII text, and payloads up to 64 KiB.
