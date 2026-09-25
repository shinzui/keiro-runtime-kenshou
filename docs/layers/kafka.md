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
The private fixture creates topics with `write.caching=false` unless a
scenario explicitly overrides that setting. Its disposable Redpanda instance
reported `write_caching_default:true`, which can acknowledge before disk
write. [Redpanda's topic-property reference](https://docs.redpanda.com/streaming/current/reference/properties/topic-properties/)
documents the override. This makes broker-kill checks of acknowledged
records meaningful; the external backend retains the cell broker's settings.

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
was 10.18 ms and p99 10.48 ms. These four single runs are exploratory. The
workstation was busy during measurement, so they are not capacity estimates.
Their IDs are `01a0d663-575e-769b-91ec-44cdc38e08dc`,
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
the short runs include assignment and catch-up effects on a busy workstation, so they do not
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
single short runs include consumer assignment on a busy workstation and do not establish sustained
capacity. Their IDs are `01a0d66d-ecb0-7525-9eae-e42def1afb15`,
`01a0d66e-39a3-75d4-b47b-85ecd21ff80b`, and
`01a0d671-03cb-7047-b6c3-1efe2bf257c9`. The runner path initially
crashed when the harness canceled its thread; a graceful adapter shutdown
removed the crash in one and two consumer controls. The leaked private
containers from those two unsealed crash probes were stopped and deleted.
These three benchmark sets predate the private topic's `write.caching=false`
default. Keep their run IDs as historical smoke evidence; collect fresh
measurements under the revised fixture before comparing any performance
figure with later runs.

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
facts. An independent raw readback in a later kill run found only 983 of
1,000 acknowledged IDs on the restarted topic while Redpanda write caching
was enabled. With caching disabled, run
`01a0d6ac-6636-716c-bd02-de4af109776f` found all 1,000 IDs on the
broker and in the combined original and replacement handler facts. Only
the scoped early-exit labels remain.

`kafka/adapter/concurrency/group-rebalance-with-inflight` changes membership
four times while an open-loop producer sends acknowledged records. It checks
no loss, assignment-period offset order, committed replay boundaries, disjoint
ownership, and group lag. Two reduced runs on the released adapter recorded
surviving workers ending normally before stop. That scoped exit is tracked at
`mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-4`.
The revised oracle samples committed offsets before each membership change
and permits replay inside declared windows or from a sampled uncommitted
position. Run `01a0d6b3-b843-7149-a2b2-981e6a1734ef` handled all 4,000
acknowledged IDs, reached zero lag, and cleared the duplicate label. It
still handled partition 4 offset 200 followed by 165 in one serial member's
assignment after the group had committed 173. The independent order finding
is filed as `mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-6`;
its failure remains blocking because the scenario's single known-defect
reference covers BUG-4's early exit.

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
The 312 repeated facts comprise 213 repeats involving A and 99 replays by
B alone, as shown by the saved worker ledgers. The proxy bound of 241 is
derived from A's uncommitted handler facts and two 100-record poll batches,
so the revised oracle applies it to the 213 A-involved repeats and reports
B's replays separately. In the live rerun
`01a0d6af-c6f6-722f-a62e-909a76e1f2a6`, 214 A-involved repeats stayed
below the 243 estimate and 60 B-only replays were reported separately.
All 2,000 acknowledged IDs had handler facts, commits did not regress, and
only the scoped early-exit label remained. Exact adapter buffer occupancy
is not exposed.

`kafka/keiro-records/correctness/roundtrip-through-broker` publishes 200
Keiro integration events through the neutral record conversion and checks
their decoded events, Kafka delivery references, all six required wire
headers, and each `MissingHeader` error. Inputs include optional fields,
non-ASCII text, and payloads up to 64 KiB.

## Soak and telemetry measurements

`kafka/pipeline/soak/consumer-memory-and-fd-stability` and its `-reduced`
variant run two adapter-stream consumer processes under open-loop producer
traffic. `soak.duration-minutes` defaults to 240 and 20 respectively;
`kafka.rate-per-second` defaults to 500, `soak.restart-every-minutes` to 5,
and `soak.sample-seconds` to 10. One member restarts on schedule while the
other remains alive for the leak window. The scenario requires every broker
acknowledgement to appear in a compact on-disk ID ledger, zero lag at the
end, bounded sampled lag outside restart windows, and no unexpected worker
exit. The diagnostics toolkit judges the long-lived member's post-GC heap,
native memory (`RSS − GHC memory in use`), Haskell threads, OS threads, and
file descriptors. Every process receives a diagnosis file; short-lived
restart processes can legitimately report `InsufficientData`.

`kafka/consumer/soak/rebalance-churn-native-memory` and its `-reduced`
variant keep one adapter-stream consumer alive while a second joins and
leaves at `soak.churn-seconds` (default 10). They use the same acknowledged
ID ledger and zero-lag checks. The long-lived member's native-memory series
is judged by the diagnostics toolkit. The released `hw-kafka-client` leak
under assignment races is tracked at
`mori://shinzui/hw-kafka-client/commits/6caed636898a78e9f6e5a9c93eeb5562cbb2580a`;
the known-defect scope applies only when that package resolves from Hackage.
If the slope cannot be judged, the result is inconclusive.

One-minute broker-backed smoke runs covered both reduced variants with
`kafka.rate-per-second=20` and `soak.sample-seconds=2`. Stability run
`01a0d687-ec96-71a6-84a8-b9a252af47f2` and churn run
`01a0d68a-f295-7426-ae48-e2859d0b0ee4` each acknowledged 1,200 IDs,
found none missing, and finished at zero lag with clean worker exits.
Their leak verdicts were `InsufficientData`, as intended for a one-minute
window. These runs verify the mechanism; they do not satisfy the 20-minute
reduced soak acceptance criterion.

The 20-minute stability run
`01a0d695-07d4-746e-a47b-77ff160bd75e` acknowledged 120,000 records at
100/s with no missing IDs, worker errors, or final lag. Its sealed leak
verdict was inconclusive because the original one-minute diagnostic windows
left fewer than 30 points. Rejudging the saved samples with the reduced
profile's corrected 30-second windows gave 41 points and a stable verdict
on all five selected probes; the sealed run is unchanged and needs a fresh
repeat to satisfy that acceptance gate.

The 20-minute churn run `01a0d6b5-212e-73ca-b1ae-70bf7f40d055` also
acknowledged 120,000 records at 100/s and completed with no missing IDs,
worker errors, or final lag. It wrote diagnoses for all 61 consumers. The
continuous member's native-memory probe used 124 samples, yielded 42
reduced points, and returned `Stable` with reason `below-growth-floor`;
the sixty short-lived members were too brief for leak estimation. This
lower-rate run did not reproduce the Hackage client's expected
redirect-race leak, and it does not establish its absence at the planned
500/s deep-backlog load. The workstation was busy during both runs, so
resource slopes remain local correctness evidence only.

The pipeline benchmark now installs the selected telemetry runtime. Tracing
arms use the traced Kafka producer and Shibuya processing spans; metrics
arms record produced and handled counters through the selected meter. A
30-record `noop` tracing plus `collect` metrics run
`01a0d68d-af9b-75e8-a1a6-b6a79c421b5f` passed the ID and lag oracles and
reported two metric instruments. Any local overhead delta should be treated
as exploratory while the workstation is busy.

An interleaved three-block local overhead run used 20 records per arm and a
one-second scrape interval. Every child run passed, the OTLP arm exported
all 40 spans per run without drops, and the scraped arm recorded seven
successful scrapes per run. The report at
`runs/overhead-01a0d690-b258-71cf-b22a-487954267828/overhead-report.json`
contains all four comparisons:

| Arm versus off | Throughput delta | p99 latency delta | Verdict |
| --- | ---: | ---: | --- |
| Metrics collect | −14.6% | −29.3% | Inconclusive |
| Metrics serve-scraped | +0.2% | +0.6% | Inconclusive |
| Tracing noop | −1.7% | −4.4% | Inconclusive |
| Tracing sdk-otlp | +0.5% | +0.2% | Inconclusive |

Each comparison is inconclusive because the 20-record runs had exploratory
measurement grade and a soft health observation. The busy workstation and
short trial length make these deltas unsuitable as overhead claims.

## Change-planner component map

| Selector | Runtime code exercised |
| --- | --- |
| `kafka/adapter/**` | `mori://shinzui/shibuya-kafka-adapter`, `mori://shinzui/shibuya` |
| `kafka/consumer/**`, `kafka/producer/**`, `kafka/telemetry/**` | `mori://shinzui/kafka-effectful`, `mori://shinzui/hw-kafka-streamly`, `mori://haskell-works/hw-kafka-client` or `mori://shinzui/hw-kafka-client`, and librdkafka |
| `kafka/keiro-records/**` | `mori://shinzui/keiro` record conversion and `mori://shinzui/keiro/packages/keiro-core` integration events |
| `kafka/pipeline/**`, `kafka/broker/**` | The assembled Kafka edge and disposable Redpanda broker |

The plan's unresolved blocking findings remain in
[the ExecPlan](../plans/11-cover-the-kafka-transport-edge-with-a-disposable-broker.md):
the outage replacement control, rebalance offset order and duplicate window,
and the zombie duplicate bound. The upstream rebalance worker-exit defect is
`mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-4`.
