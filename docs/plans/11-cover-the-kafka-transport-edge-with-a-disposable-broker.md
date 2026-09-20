---
id: 11
slug: cover-the-kafka-transport-edge-with-a-disposable-broker
title: "Cover the Kafka transport edge with a disposable broker"
kind: exec-plan
created_at: 2026-09-20T17:15:35Z
intention: "intention_01m2zvy0gje40tdsdragvzr3tq"
master_plan: "docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-20T17:15:35Z
---

# Cover the Kafka transport edge with a disposable broker

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Services built on the keiro runtime exchange integration events with one another over Apache Kafka. That edge is a stack of four Haskell libraries on top of the C client `librdkafka` — `hw-kafka-client` (the binding), `hw-kafka-streamly` (error classification), `kafka-effectful` (producer and consumer effects, traced interpreters) and `shibuya-kafka-adapter` (the bridge into the shibuya message-processing framework) — plus keiro's pure conversions between integration events and Kafka records. Today nothing tests that stack with more than one consumer in a group, with a real process crash, with a broker outage, or under sustained load, and the only live tests that exist talk to a machine-global broker at `127.0.0.1:9092` that is shared by every project on the machine and must never be killed or purged.

After this plan a maintainer can do three things they cannot do today. First, any scenario in this repository can ask for a private Kafka broker that belongs to one run: it is started for the run on free ports, can be killed with `SIGKILL` and restarted on the same data, can sit behind a fault-injecting TCP proxy, and is thrown away afterwards; on a Google Cloud verification cell the same code uses the cell's broker named in the run specification instead. Second, they can run thirty-one `kafka/...` scenarios that turn the adapter's documented guarantees, its documented limitations and its known open defects into pass/fail evidence: at-least-once delivery under `SIGKILL` with a bounded duplicate window, consumer-group rebalances with messages in flight, static group membership and fencing, broker outages, the two seek-barrier defects known upstream as KFK-1 and KFK-2 (both as a model-based test and as live reproductions), end-to-end throughput and latency benchmarks that do not exist anywhere today, and soaks judged for leaks in the Haskell heap and in librdkafka's native memory. Third, the assembled-runtime plan (`docs/plans/15-verify-the-assembled-runtime-end-to-end-and-under-soak.md`) can import the broker fixture to connect its two bounded contexts.

To see it working after implementation, run the following from the repository root inside the development shell. The first command starts a private broker, round-trips one hundred records and exits 0; the second kills a consumer process mid-stream and proves that nothing was lost and that duplicates stayed inside the commit window.

```bash
cabal run kenshou -- run kafka/broker/correctness/fixture-roundtrip --out runs
cabal run kenshou -- run kafka/adapter/concurrency/sigkill-redelivery-window --out runs
```


## Progress

Milestone 1 — The disposable broker fixture

- [ ] Confirm the hard dependencies are complete and the development shell links librdkafka (checks in Concrete Steps).
- [ ] Spike: start Apache Kafka 4.x in KRaft mode by hand from the development shell; record the working `server.properties`, the `kafka-storage.sh format` form, the start-up time, and that `rpk` can create, describe and delete against it.
- [ ] Add `pkgs.apacheKafka` and `pkgs.redpanda-client` to the development shell through `flake.module.nix`.
- [ ] Create the `kenshou-kafka` package with its `kenshou-kafka-test` suite.
- [ ] `Kenshou.Env.Kafka.Spec` and `Kenshou.Env.Kafka.Naming` with unit tests (run-spec fragment decoding, refusal of the machine-global address, prefix shape).
- [ ] `Kenshou.Env.Kafka.ApacheKafka`: port allocation, properties rendering, format, start, readiness, kill, stop, start-again, log capture, stale-broker sweep.
- [ ] Proxy lanes through the correctness toolkit's TCP proxy (one broker listener per lane).
- [ ] `Kenshou.Env.Kafka.Admin` over `rpk`: topics with N partitions, run-scoped deletion, committed offsets, lag, group membership; golden tests for the JSON parsing.
- [ ] `Kenshou.Env.Kafka.External` (brokers and control hooks from the run specification) and `Kenshou.Env.Kafka.RedpandaContainer` (opt-in).
- [ ] `schemas/kenshou.kafka-env.v1.json` and the `kafka` summary section with backend, broker version and broker properties.
- [ ] Scenarios `kafka/broker/correctness/fixture-roundtrip` and `kafka/broker/concurrency/kill-and-restart`; `Kenshou.Suite.Kafka.bundle`; the three-line registration in `kenshou-cli`; first version of `docs/layers/kafka.md`; the fixture ADR.

Milestone 2 — Kafka adapter correctness and rebalance scenarios (with the producer path and keiro's record conversions)

- [ ] Worker roles `kafka-adapter-consumer`, `kafka-raw-consumer`, `kafka-producer`; `HandlerPolicy`; ledger fact encoders; `kafka.prop.*` pass-through.
- [ ] `kafka/adapter/correctness/ack-ok-commits-and-resumes`.
- [ ] `kafka/adapter/correctness/retry-redelivers-and-never-commits-past`.
- [ ] `kafka/adapter/correctness/dead-letter-drops-record`.
- [ ] `kafka/adapter/correctness/halt-leaves-offset-uncommitted`.
- [ ] `kafka/adapter/concurrency/non-serial-finalization-commits-past-halt` (known defect).
- [ ] `kafka/adapter/correctness/multi-topic-partition-key` (known defect).
- [ ] `kafka/adapter/concurrency/group-rebalance-with-inflight`.
- [ ] `kafka/adapter/concurrency/stale-barrier-after-partition-roundtrip`.
- [ ] `kafka/producer/correctness/acked-offsets-and-batch-loop`, `kafka/producer/concurrency/batch-loop-reports-enqueue-not-delivery` (known defect), `kafka/producer/correctness/transactions-commit-and-abort`.
- [ ] `kafka/keiro-records/correctness/roundtrip-through-broker`.

Milestone 3 — Kafka crash, outage and model-based scenarios

- [ ] `kafka/adapter/concurrency/sigkill-redelivery-window`.
- [ ] `kafka/adapter/concurrency/auto-offset-store-loses-on-crash` (known defect).
- [ ] `kafka/adapter/concurrency/halt-holds-assignment-past-max-poll-interval` (known defect).
- [ ] `kafka/consumer/concurrency/static-membership-restart-without-revoke`.
- [ ] `kafka/consumer/concurrency/static-membership-fencing-is-observable` (known defect on the released cohort only).
- [ ] `kafka/adapter/concurrency/broker-outage-and-reconnect`.
- [ ] `kafka/adapter/concurrency/partitioned-consumer-becomes-zombie`.
- [ ] Simulated `KafkaConsumer` interpreter, schedule generator and `kafka/adapter/correctness/ack-state-machine-model` (known defect), with the non-vacuity unit test against a reference ack handler.
- [ ] `kafka/adapter/concurrency/barrier-overwrite-loses-record` and `kafka/adapter/concurrency/buffered-successors-run-before-retry` (known defects).

Milestone 4 — Kafka benchmarks, soak and telemetry arms

- [ ] `Kenshou.Suite.Kafka.Telemetry`: tracing and metrics arms for producer, consumer and shibuya runner.
- [ ] `kafka/pipeline/benchmark/produce-consume-throughput`, `kafka/adapter/benchmark/poll-cap-latency`, `kafka/producer/benchmark/produce-modes`.
- [ ] `kafka/telemetry/correctness/w3c-context-continuity` and `kafka/telemetry/correctness/context-leak-regression`.
- [ ] One recorded `kenshou overhead` comparison for the layer.
- [ ] `kafka/pipeline/soak/consumer-memory-and-fd-stability` and `kafka/consumer/soak/rebalance-churn-native-memory` (known defect on the released cohort only).
- [ ] Finish `docs/layers/kafka.md`; ADR distillation pass; update the MasterPlan registry and progress.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The default local broker is Apache Kafka 4.x in KRaft single-node mode, run as a child process from the Nix development shell. Redpanda is supported as an opt-in container backend and as the external broker of a cell.
  Rationale: The MasterPlan's Integration Point 7 says "a private Redpanda started for the run", but the pinned nixpkgs has no Redpanda server package (`redpanda` is an alias of `redpanda-client`, which is only the `rpk` command-line tool) and Redpanda has no macOS build, so a Redpanda broker needs a container runtime on both operating systems. The house Seihou option `nix.redpanda=true` was verified to be macOS-only (Apple Container). `apacheKafka` 4.3.1 is in the pinned nixpkgs for `aarch64-darwin` and `x86_64-linux`, needs nothing but a JVM, gives the harness a real process id to `SIGKILL`, and binds whatever ports it is told to. The system under test is the client stack, which speaks the same wire protocol to both brokers; the backend and its version are recorded in every result so runs on different brokers are never compared.
  Date: 2026-09-20

- Decision: Topic, group and offset administration goes through the `rpk` command-line tool, always with an explicit `-X brokers=` and a private empty configuration file.
  Rationale: The admin API (`Kafka.Topic`) exists only on the hw-kafka-client fork's base (upstream main); Hackage 5.3.0 has none, and the fixture must work identically under both cohorts. `rpk` uses only Kafka-protocol admin requests, so it works against Apache Kafka and Redpanda, and `rpk group describe --format json` gives committed offsets, log end offsets, lag and members in one call. An explicit broker flag and a private configuration file make it impossible for an operator's `rpk` profile to point the fixture at the shared broker.
  Date: 2026-09-20

- Decision: Whether `hw-kafka-client` is the Hackage release or the house fork is never a knob. Cohort-sensitive scenarios read the resolved cohort identity and scope their known-defect reference to the released cohort.
  Rationale: Integration Point 2 makes the fork part of the cohort. The fencing and native-leak scenarios must fail (non-blocking) on `released` and pass on `head`; that is the visible fork-versus-Hackage difference the platform owner asked for. The kernel expresses this declaratively: `KnownDefect.appliesTo = OnlyWhen (ResolvedFromHackage "hw-kafka-client" :| [])` (see `CohortScope` in `docs/plans/2-build-the-harness-kernel-for-scenarios-dimensions-run-specs-and-results.md`). When the scope does not hold for the run's cohort the kernel treats the scenario as having no known defect, so no in-scenario branching is needed; use the in-scenario fallback described later only if the kernel's scope type turns out not to cover a case.
  Date: 2026-09-20

- Decision: `kafka.prop.<name>` knobs are a closed, declared list per scenario, generated by one helper; the text after `kafka.prop.` is the librdkafka property name and the value is passed through verbatim with `extraProp`. An empty value means "leave librdkafka's default".
  Rationale: The kernel's `KnobSpec` is a named, typed parameter with a default and allowed values; an open-ended prefix family is not part of Integration Point 4. A closed list keeps validation, `kenshou list` output and the compatibility key exact while still naming knobs after the real configuration property.
  Date: 2026-09-20

- Decision: The model-based test runs the adapter's real `Shibuya.Adapter.Kafka.Internal` code against a simulated `KafkaConsumer` interpreter, rather than re-modelling the adapter.
  Rationale: `Internal` is an exposed module and `KafkaConsumer` is a dynamic effect (the adapter's own `AckHandleTest` already swaps the interpreter). Testing the shipped code means the scenario turns green by itself when the upstream fix lands, and a re-model could drift from the implementation.
  Date: 2026-09-20

- Decision: The native-memory soak judges a derived series (resident set size minus the GHC runtime's memory in use) in addition to live bytes after major garbage collection.
  Rationale: librdkafka allocates outside the GHC heap, so the message leak in Hackage hw-kafka-client 5.3.0 is invisible to the diagnostics toolkit's primary signal. This is a deliberate, narrow exception to the MasterPlan's "never resident memory" rule and is reported to the MasterPlan as a contract gap.
  Date: 2026-09-20

- Decision: keiro's Kafka record conversions are verified in this layer, with `kenshou-kafka` depending on the runtime packages `keiro` and `keiro-core` (never on the layer package `kenshou-keiro`).
  Rationale: keiro has no Kafka dependency; its conversions are pure and only meet a broker at this edge. Depending on a runtime package does not break the rule that layer packages never import one another.
  Date: 2026-09-20

- Decision: This plan edits `flake.module.nix` (two packages added to the development shell) in addition to the three-line registration.
  Rationale: Integration Point 3 calls the registration "the only file outside its own package that a coverage plan touches", but a broker fixture is useless without a broker binary and `rpk` on `PATH`. The edit is additive and is reported to the MasterPlan.
  Date: 2026-09-20

- Decision: The `pg.durability` and `pg.version` dimensions are declared not applicable for every scenario in this layer; benchmarks default `kafka.prop.acks` to `all` and record the broker's flush settings in the result instead.
  Rationale: No scenario here opens a database. The analogue of database durability is broker acknowledgement, which is a client property and therefore a knob.
  Date: 2026-09-20

- Decision: Milestone 2 also carries the producer-path and record-conversion correctness scenarios, and Milestone 4 carries the traced-interpreter correctness scenarios; the milestone count and meaning otherwise follow the MasterPlan.
  Rationale: The MasterPlan's four milestones do not name those scenario groups; they are correctness work that needs only the fixture (Milestone 2) or the telemetry arms (Milestone 4).
  Date: 2026-09-20


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### What this repository is and what must exist before you start

`keiro-runtime-kenshou` is a verification suite for the "keiro runtime", a cohort of Haskell libraries. At the time of writing the repository holds only documents; the code this plan builds on is delivered by other plans, all under `docs/plans/`. Before starting, open each of the following and confirm its Progress section is complete, then read its Interfaces and Dependencies section for the exact signatures, because this plan was drafted in parallel with them and names their modules as intended rather than as built: `docs/plans/1-bootstrap-the-kenshou-repository-and-pin-the-runtime-cohort.md` (the cabal project, the Nix development shell with GHC 9.12.4 and librdkafka, the pinned cohorts), `docs/plans/2-build-the-harness-kernel-for-scenarios-dimensions-run-specs-and-results.md` (package `kenshou-core`, the `kenshou` executable), `docs/plans/4-build-the-measurement-toolkit-for-load-latency-sampling-and-comparison.md` (`kenshou-measure`), `docs/plans/5-build-the-correctness-toolkit-for-ledgers-invariants-faults-and-process-control.md` (`kenshou-check`), `docs/plans/6-build-the-diagnostics-toolkit-for-memory-leaks-and-concurrency-stalls.md` (`kenshou-diagnose`) and `docs/plans/7-add-telemetry-arms-and-measure-observability-overhead.md` (`kenshou-telemetry`). The coordinating document is `docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md`; its "Integration Points" are binding and the parts this plan relies on are restated below.

### Contracts this plan relies on

The repository is one cabal project that finds packages with the glob `kenshou-*/*.cabal`, so creating the directory `kenshou-kafka/` with a cabal file adds the package. All modules live under `Kenshou`. This plan owns the package `kenshou-kafka` with two namespaces: `Kenshou.Env.Kafka` (the broker fixture) and `Kenshou.Suite.Kafka.*` (scenarios, with the evidence kinds as subtrees `Correctness`, `Concurrency`, `Bench`, `Soak`). Layer packages depend on the kernel and toolkits and never on one another; only `kenshou-runtime` and `kenshou-cli` may depend on `kenshou-kafka`.

A scenario is a value registered in a layer bundle, not a test-suite test. Its identifier has four segments, `<layer>/<component>/<kind>/<name>`; here the layer is `kafka`, the kind is one of `correctness`, `concurrency`, `soak`, `benchmark`, and the components are `broker` (the fixture itself), `adapter` (`shibuya-kafka-adapter`), `consumer` and `producer` (`kafka-effectful` over `hw-kafka-client`), `telemetry` (the traced interpreters), `keiro-records` (keiro's conversions) and `pipeline` (produce through consume, end to end). Each scenario declares a cost tier (`smoke` under one minute, `standard` under ten, `extended` under an hour, `soak` hours), a placement (`local`, `cell`, `either`), its knobs (typed parameters, `KnobSpec`, with a name, type, default and allowed values), the dimension values it supports, and optionally a known-defect reference: a `mori://` URI that turns an expected failure into a reported, non-blocking outcome. The package exports exactly one `bundle :: LayerBundle` carrying its scenarios and worker roles, and registers it with a three-line edit: one import and one list element in `kenshou-cli/src/Kenshou/Cli/Registry.hs`, one `build-depends` entry in `kenshou-cli/kenshou-cli.cabal`.

Dimensions are cross-cutting switches with closed value sets. `telemetry.tracing` takes `off` (the library gets no tracer), `noop` (a tracer from a provider with no span processors), `sdk-inmemory` (the OpenTelemetry SDK with an in-memory exporter) and `sdk-otlp` (the SDK exporting to a collector). `telemetry.metrics` takes `off`, `collect` (instruments live, nothing served), `serve` (HTTP endpoints up) and `serve-scraped` (endpoints scraped by the harness). A layer obtains handles from `Kenshou.Telemetry.withTelemetry` and adapts them to its component. Measurement never flows through the feature being toggled: latencies and counts are recorded in-process by the measurement toolkit and written to files. `pg.durability` and `pg.version` exist but do not apply to this layer.

A run writes a directory `<out>/<run-id>/` containing `run-spec.json`, `run-result.json`, `manifest.json`, `samples/`, `series/*.csv`, `verdicts/<checker>.json` (one `kenshou.verdict/v1` per invariant checker), `diagnosis/*.json` and `logs/`. Outcomes are `passed`, `failed`, `errored` (could not be evaluated), `inconclusive` and `infrastructure-failure`; `kenshou run` exits 0, 1, 4, 3 and 4 respectively, and 2 for a usage error. The run specification carries a seed that drives every random choice. Integration Point 7 assigns this plan the Kafka half of "environments": a private broker started for the run, or external brokers named by the run specification, with per-run topic and consumer-group prefixes. Integration Point 8 says crash scenarios run their workers as child processes of the same `kenshou` binary (`kenshou worker --role <name>`), spawned, signalled and log-captured by `Kenshou.Check.Process`, because the runtime's crash guarantees are about `SIGKILL` (the operating-system signal that ends a process immediately with no clean-up) and not about Haskell exceptions.

A cohort is the exact set of runtime package versions a build links. `cohort/released.project` pins Hackage versions (here: `shibuya-kafka-adapter` 0.9.0.1, `kafka-effectful` 0.3.1.0, `hw-kafka-client` 5.3.0, `hw-kafka-streamly` 0.2.0.0, `shibuya-core` 0.9.0.3, `keiro` 0.17.0.0); `cohort/head.project` replaces chosen components by commit. Every run result embeds the resolved `CohortIdentity`. The choice between Hackage `hw-kafka-client` and the house fork belongs to the cohort. For this plan's cohort-sensitive scenarios to be meaningful, `cohort/head.project` must pin `hw-kafka-client` to `https://github.com/shinzui/hw-kafka-client.git` at commit `6caed636898a78e9f6e5a9c93eeb5562cbb2580a` and `hw-kafka-streamly` to a commit at or after `42163022038be4734cff64e96b83360be9c78318` (head today is `d27d9321584e40deba243e27cdfaaaf2b7c0293d`); check this in `cohort/head.project` and, if it is missing, raise it against `docs/plans/1-bootstrap-the-kenshou-repository-and-pin-the-runtime-cohort.md` rather than working around it. The adapter's and kafka-effectful's repository heads are their released versions today, so those two do not differ between cohorts.

### Kafka in one page

Apache Kafka is a log server. A broker is one server process. A topic is a named log split into numbered partitions; each record in a partition has an offset, a position that only grows. A producer appends records; a record has an optional key (records with equal keys go to the same partition), a value and headers (ordered name/value byte pairs). A consumer reads partitions in offset order. Consumers that share a `group.id` form a consumer group: the broker assigns each partition to exactly one member, and a rebalance is the reassignment that happens whenever members join, leave or time out (`session.timeout.ms` without a heartbeat). A group remembers one committed offset per partition, the position a member resumes from. The high watermark (log end offset) is the next offset to be written, and lag is the high watermark minus the committed offset. At-least-once delivery means every record is processed one or more times: duplicates are allowed, losses are not. With librdkafka a consumer first stores an offset locally (`storeOffsetMessage`) and a background timer commits stored offsets every `auto.commit.interval.ms` (default 5000); the stored offset is last-write-wins with no gap tracking, and storing an offset for a partition that is not currently assigned fails with `RD_KAFKA_RESP_ERR__STATE` (verified in librdkafka's `src/rdkafka_offset.h`). Static membership means a consumer sets `group.instance.id`, so that a restart within the session timeout reclaims its partitions without a rebalance; if two live consumers use the same identifier the broker fences the older one, which librdkafka reports as a permanent fatal error. Redpanda is a Kafka-protocol-compatible broker; KRaft is Apache Kafka's built-in consensus mode that needs no ZooKeeper; `rpk` is Redpanda's command-line client, which also works against Apache Kafka.

### The libraries under test, verified against source on 2026-09-20

`shibuya-kafka-adapter` is `mori://shinzui/shibuya-kafka-adapter`, on disk at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter`. Modules `Shibuya.Adapter.Kafka`, `.Config`, `.Convert`, `.Internal`. The entry points are `kafkaAdapter :: (KafkaConsumer :> es, Error KafkaError :> es, IOE :> es) => KafkaAdapterConfig -> Eff es (Adapter es (Maybe ByteString))` and `kafkaAdapterWith :: KafkaAdapterState -> KafkaAdapterConfig -> ...`, used inside `runKafkaConsumer props sub` from kafka-effectful; every consumer property (brokers, group, offset reset, commit interval, static identity) belongs to the caller. The only configuration record is `KafkaAdapterConfig {topics :: [TopicName], pollTimeout :: Timeout, batchSize :: BatchSize}` with `defaultConfig` giving `Timeout 1000` and `BatchSize 100`. `Internal.hs` caps every poll and seek timeout at `maxPollHoldMillis = 100`, so a `pollTimeout` above 100 ms has no effect, and serialises every librdkafka call behind `consumerLock :: MVar ()` because concurrent batch-consume and seek on one handle crashed natively. The adapter turns shibuya's four acknowledgement decisions into Kafka actions: `AckOk` stores the offset unless a seek barrier suppresses it; `AckRetry (RetryDelay d)` sleeps `d` on the finalizing thread, records a per-partition seek barrier with a plain `Map.insert`, and seeks the partition back to the failed offset without storing; `AckDeadLetter` prints `[shibuya-kafka-adapter] WARNING: dead-lettered message DROPPED (no DLQ producer): ...` to standard error and then stores the offset, so the record is lost to the group (there is no dead-letter queue, a side topic where failed records would be kept); `AckHalt` pauses the partition and never resumes it. The source drops records above a pending barrier (`dropStaleRecords`). Acknowledgement failures are retried three times 50 ms apart and then recorded in a `fatalError` slot that ends the stream at its next poll. The caller must set `noAutoOffsetStore` and nothing checks it. The envelope gets `partition = Just (show partitionId)` (the topic is not part of the key), `messageId = "{topic}-{partition}-{offset}"`, `attempt = Nothing` always, and span attributes `messaging.system = "kafka"`, `messaging.kafka.destination.partition`, `messaging.kafka.message.offset`. `kafkaRebalanceHandler :: KafkaAdapterState -> KC.KafkaConsumer -> RebalanceEvent -> IO ()` is optional; on `RebalanceRevoke` it deletes barriers for the revoked partitions. The documented guarantee is at-least-once under a caller contract of serial processing: shibuya's `Async n` and `Ahead n` concurrency are forbidden by documentation only. The adapter's own live tests hard-code `BrokerAddress "127.0.0.1:9092"`, shell out to `rpk topic create`, never delete topics, and cover one consumer only.

`shibuya-core` 0.9.0.3 (`mori://shinzui/shibuya`, `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`) supplies `Shibuya.App.runApp`, `defaultAppConfig` (`inboxSize = 100`), `mkProcessor` (ordering `Unordered`, concurrency `Serial`), `QueueProcessor {adapter, handler, ordering, concurrency}`, `Shibuya.Policy.Concurrency (Serial | Ahead n | Async n)`, and the mandatory tracing effect run with `Shibuya.Telemetry.Effect.runTracing tracer` or `runTracingNoop`. The runner pulls the adapter's stream into a bounded inbox ahead of the handler, substitutes `AckRetry (RetryDelay 0)` for a handler that throws, and on `AckHalt` stops the whole processor, not just one partition. `shibuya-metrics` 0.9.0.3 provides `startMetricsServer :: MetricsServerConfig -> Master -> IO MetricsServer` (default port 9090; the harness must choose a free port).

`kafka-effectful` 0.3.1.0 (`mori://shinzui/kafka-effectful`, `/Users/shinzui/Keikaku/bokuno/kafka-effectful`) defines the dynamic effects `KafkaConsumer` and `KafkaProducer`. Consumer operations: `pollMessage`, `pollMessageEither`, `pollMessageBatch`, `commitOffsetMessage`, `commitAllOffsets`, `commitPartitionsOffsets`, `storeOffsets`, `storeOffsetMessage`, `assign`, `pausePartitions`, `resumePartitions`, `seekPartitions`, `committed`, `position`, `assignment`, `subscription`, `askConsumerHandle`; interpreter `runKafkaConsumer :: ConsumerProperties -> Subscription -> Eff (KafkaConsumer : es) a -> Eff es a`, which closes the consumer on every exit path. Producer operations: `produceMessage`, `produceMessage'` (per-record delivery callback), `produceMessageSync :: ProducerRecord -> Eff es Offset` (blocks for the broker acknowledgement), `produceMessageBatch :: [ProducerRecord] -> Eff es [(ProducerRecord, KafkaError)]` (documented as a per-record loop that reports enqueue failures, not broker acknowledgements), `flushProducer`, and transactions (`initTransactions`, `beginTransaction`, `commitTransaction`, `abortTransaction`, `commitOffsetMessageTransaction`). `Kafka.Effectful.OpenTelemetry` exports `runKafkaProducerTraced` and `runKafkaConsumerTraced`, which inject and extract W3C trace context (the `traceparent` and `tracestate` headers that carry a distributed trace across processes); 0.3.1.0 fixed a defect where one record's extracted context leaked into the next record. Property builders re-exported from hw-kafka-client include `brokersList`, `groupId`, `noAutoOffsetStore`, `extraProp`, `setCallback`, `rebalanceCallback`, `offsetCommitCallback`, `statsCallback` and `callbackPollMode`.

`hw-kafka-streamly` (`mori://shinzui/hw-kafka-streamly`, `/Users/shinzui/Keikaku/bokuno/hw-kafka-streamly`) contributes only `isFatal` and `skipNonFatal` to the adapter. In the released 0.2.0.0, `isFatal` has no arm for `RdKafkaRespErrFatal`, so the adapter's `skipNonFatal` silently drops librdkafka's generic fatal error; the arm exists only at repository head (commit `4216302`).

`hw-kafka-client` exists twice: Hackage 5.3.0 (`mori://haskell-works/hw-kafka-client`) and the house fork `mori://shinzui/hw-kafka-client` at `/Users/shinzui/Keikaku/bokuno/hw-kafka-client`, one commit (`mori://shinzui/hw-kafka-client/commits/6caed636898a78e9f6e5a9c93eeb5562cbb2580a`) on top of upstream main. In the default `CallbackPollModeAsync` a background thread polls librdkafka's consumer queue every 100 ms. On Hackage 5.3.0 that loop discards what it polls with `void`, so a fatal error such as fencing is unobservable at every layer, and each discarded message is leaked because nothing destroys it. The research brief said "every polled message leaks"; the fork's commit message is narrower and is what this plan uses: what leaks is every consumer error and every fetched record that raced a partition-queue redirect, which happens around assignments. The fork reports a raised fatal in-band from `pollMessage` and `pollMessageBatch` as `Left (KafkaResponseError RdKafkaRespErrFatal)`, adds `consumerFatalError`, and destroys what the loop consumes. Two further consequences matter here. The same background loop resets librdkafka's `max.poll.interval.ms` watchdog every 100 ms whether or not the application polls, and `pollMessageBatch` (which the adapter uses) is unavailable in `CallbackPollModeSync`; therefore an application using the adapter can never be evicted for not polling, which contradicts the adapter's documentation of `AckHalt`. The admin module `Kafka.Topic` is on upstream main only, not in Hackage 5.3.0. keiro's decision record `mori://shinzui/keiro/okf/adrs/concepts/ADR-11` documents the fatal-observability design.

keiro (`mori://shinzui/keiro`, `/Users/shinzui/Keikaku/bokuno/keiro`) has no Kafka client dependency. `Keiro.Outbox.Kafka` (package `keiro`) offers `integrationEventToKafkaRecord :: IntegrationEvent -> KafkaProducerRecord` with fields `topic` (taken from the event's `destination`), `key`, `payload`, `headers`; `Keiro.Inbox.Kafka` offers `integrationEventFromKafka :: KafkaInboundRecord -> Either KafkaDecodeError (IntegrationEvent, KafkaDeliveryRef)`. Header names come from `Keiro.Integration.Event` in package `keiro-core`; the six required ones are `keiro-message-id`, `keiro-source`, `keiro-destination`, `keiro-event-type`, `keiro-schema-version` and `content-type`, and the optional ones include `keiro-occurred-at`, `keiro-attributes`, `traceparent` and `tracestate`.

Known open work upstream, used as known-defect references: keiro's Kafka transport review, `mori://shinzui/keiro/masterplans/18-make-the-kafka-transport-edge-production-safe-surfaced-by-the-2026-07-transport-review` (not started), names KFK-1 (a stale successor's own retry overwrites the barrier and seeks forward past the still-unprocessed failed offset, so the failed record is committed past and lost), KFK-2 (after a retry, records already buffered in shibuya's inbox still run their handlers before the failed record is redelivered, inverting processing order), KFK-3 (no shipped producer API reports broker acknowledgements for a batch) and KFK-5 (`noAutoOffsetStore` is not enforced), with child plans `mori://shinzui/keiro/plans/119-fix-the-seek-barrier-ordering-and-stale-successor-execution-in-shibuya-kafka-adapter`, `mori://shinzui/keiro/plans/120-add-an-acked-batch-publish-api-to-kafka-effectful-and-a-reference-outbox-bridge` and `mori://shinzui/keiro/plans/121-enforce-consumer-offset-store-configuration-and-correct-the-kafka-transport-docs`. The consumer-stack review, `mori://shinzui/keiro/masterplans/23-make-the-kafka-consumer-streaming-stack-surface-fatal-errors-and-close-deterministically` (complete, but its hw-kafka-client half ships only in the fork), names KSC-3 (fatal blindness and the message leak). `mori://shinzui/shibuya-kafka-adapter/plans/15-support-kafka-static-membership-deployments` (not started) plans live fencing tests. These plan and masterplan URIs do not resolve through the local Mori registry yet; use them as written. The adapter's capability records do resolve: `mori://shinzui/shibuya-kafka-adapter/okf/capabilities/concepts/CAP-1` (serial only), `.../CAP-2` (offset semantics, dropped dead letters, the halt eviction claim) and `.../CAP-3` (envelope mapping).

Three hazards were inferred from source while drafting and are not recorded upstream. They are hypotheses for scenarios to confirm, not facts. First, a record from a revoked partition that is finalized after the revoke calls `storeOffsetMessage`, librdkafka answers `ERR__STATE`, the adapter retries three times and records a fatal error, so a rebalance with messages in flight may terminate a healthy consumer. Second, if `kafkaRebalanceHandler` is not installed and a partition leaves a consumer while a barrier is pending, is advanced by another member, and later returns, `dropStaleRecords` drops every record of that partition on the first consumer until it restarts. Third, the halt eviction claim above. When one of these reproduces, record it in Surprises & Discoveries, file it through the owning repository's improvement-request process in a separate commit there that cites this plan as `mori://shinzui/keiro-runtime-kenshou/plans/11-cover-the-kafka-transport-edge-with-a-disposable-broker`, and attach the resulting URI to the scenario as its known-defect reference; until then use the capability record named in the scenario.

### How a private broker can be provisioned

Verified on 2026-09-20 against the nixpkgs revision the house development shells pin (`d5dfd8e6716dde34398bc14bc87c10dece9c8c68`, through `haskell-nix-dev`): `apacheKafka` is 4.3.1 (Scala 2.13) and available on `aarch64-darwin` and `x86_64-linux`; `redpanda-client` (`rpk`) is 26.2.2 on both; `rdkafka` is 2.15.0; there is no Redpanda server package. The Seihou module `nix-haskell-flake` (`/Users/shinzui/Keikaku/bokuno/seihou-modules/modules/haskell/nix-haskell-flake`) offers `nix.redpanda=true`, which generates `nix/redpanda.nix` with `redpanda-local-{up,down,status,logs,purge}` scripts for a private Redpanda on Apple Container at fixed host ports (Kafka 39092, admin 39644); the module itself states it is macOS-only and contributes nothing elsewhere. The machine-global broker at `127.0.0.1:9092` is a shared Redpanda managed from the owner's dotfiles and must never be used, killed or purged by this suite. `mori://shinzui/load-testing-infra` has no broker role today; `docs/plans/16-provide-leased-verification-cells-in-load-testing-infra.md` adds one.

### Architecture decision records

There is no local ADR corpus yet; `docs/adr/` is created by `docs/plans/1-bootstrap-the-kenshou-repository-and-pin-the-runtime-cohort.md` as a profile-governed OKF bundle (OKF, the Open Knowledge Format, is a directory of Markdown files with YAML frontmatter validated by the `okf` tool; a profile is the Dhall descriptor that says which fields a record type needs). Scan `docs/adr/` when you start and read anything about layers, cohorts, crash semantics, invariant classes, leak verdicts or telemetry. Relevant cross-repository records: `mori://shinzui/keiro/okf/adrs/concepts/ADR-11` (fatal errors in-band in both poll modes; also states that `max.poll.interval.ms` never evicts an async-mode consumer), `mori://shinzui/keiro-runtime-patterns/okf/adrs/concepts/ADR-3` (Kafka is chosen for cross-context streaming and the application accepts serial consumption, no attempt counter and no built-in dead-letter queue — exactly the limits this plan turns into scenarios), `mori://shinzui/keiro/okf/adrs/concepts/ADR-25` (worker loops survive per-item failures, tested here by outage scenarios), and `mori://shinzui/kiroku/okf/adrs/concepts/ADR-5` (only structural checks and controlled A/B workloads are authoritative performance evidence, which is why benchmarks here are paired). This plan creates one ADR, "The Kafka broker fixture is private to a run: Apache Kafka in KRaft mode locally, the cell's broker on a cell, never the machine-global broker", and contributes evidence to the diagnostics ADR on leak verdicts (the native-memory exception). Allocate the handle with `okf id next docs/adr --profile docs/adr/profile.dhall ADR` and validate with `okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce`.


## Plan of Work

### Milestone 1 — The disposable broker fixture

Scope: everything needed to hand a scenario a broker it owns. At the end the package `kenshou-kafka` exists, `Kenshou.Env.Kafka` starts, controls and removes a private broker, two fixture scenarios prove it, and the bundle is registered so `kenshou list` shows the `kafka` layer. Commands: `cabal test kenshou-kafka-test`, then the two `kenshou run` commands in Concrete Steps. Acceptance: both scenarios pass on the implementer's machine, the run's `logs/` contains the broker log, no process survives the run, and the machine-global broker is provably untouched.

Begin with a spike, because nothing in the house has run Apache Kafka before. In the development shell, by hand: generate a cluster id with `kafka-storage.sh random-uuid`, write the properties file shown in Concrete Steps into a scratch directory, format it with `kafka-storage.sh format`, start `kafka-server-start.sh`, create a topic with `rpk topic create t -p 3 -X brokers=127.0.0.1:<port>`, describe a group, and stop it. Record in Surprises & Discoveries the exact `format` invocation that works with the static `controller.quorum.voters` form on 4.3.1 (if it insists on a dynamic quorum, the fallback is `controller.quorum.bootstrap.servers` plus `format --standalone`), the start-up time, and whether the start script replaces itself with the JVM (so that the spawned process id is the broker). If `rpk` misbehaves against Apache Kafka, fall back to the scripts that ship in the same Nix package (`kafka-topics.sh`, `kafka-consumer-groups.sh`) behind the same Haskell interface; they are slower by a JVM start per call. The spike is promoted when a record produced with `kcat` or `rpk topic produce` is consumed back.

Add the two binaries to the development shell by extending the unmanaged `flake.module.nix` that the bootstrap plan created, inside its `perSystem` block: `haskellProject.extraDevPackages = [ pkgs.apacheKafka pkgs.redpanda-client ];` (merge with the existing list). This is the only edit outside the package besides the registration and the documents named below.

Create `kenshou-kafka/kenshou-kafka.cabal` in the house style (cabal-version 3.0, `default-language: GHC2024`, the `common warnings` stanza and default extensions used by the other `kenshou-*` packages). The library depends on `kenshou-core`, `kenshou-measure`, `kenshou-check`, `kenshou-diagnose`, `kenshou-telemetry`, `shibuya-kafka-adapter`, `kafka-effectful`, `hw-kafka-client`, `hw-kafka-streamly`, `shibuya-core`, `shibuya-metrics`, `keiro`, `keiro-core`, `effectful-core`, `streamly`, `streamly-core`, `hs-opentelemetry-api`, `aeson`, `bytestring`, `containers`, `text`, `time`, `network`, `process`, `directory`, `filepath`, `unix`, `stm`, `async`, `hedgehog`, without version bounds tighter than the cohort's (the cohort project file decides versions). The test suite `kenshou-kafka-test` uses `hspec` and `hspec-hedgehog`.

`kenshou-kafka/src/Kenshou/Env/Kafka/Spec.hs` defines the specification and how it is read from the run specification's `environment.kafka` object (schema `schemas/kenshou.kafka-env.v1.json`, added by this plan). An absent object means the default: private Apache Kafka, one proxied lane. The decoder rejects, with a usage-style error, any broker address whose host is `127.0.0.1`, `localhost` or `::1` and whose port is 9092, for every backend, with no override; the private backends never bind 9092 either. Check the completed kernel plan for how a scenario reads the run specification's environment object and whether its schema admits extension members; if it does not, ask for the member to be reserved through the MasterPlan's Integration Point 5 rather than smuggling the address through a knob.

```haskell
data BrokerBackend = ApacheKafkaProcess | RedpandaContainer | ExternalBrokers

data BrokerControlHooks = BrokerControlHooks
  { killCommand :: [Text] -- argv that ends the broker process with SIGKILL on its host
  , stopCommand :: [Text] -- argv for a clean stop
  , startCommand :: [Text] -- argv that starts it again on the same data
  }

data KafkaEnvSpec = KafkaEnvSpec
  { backend :: BrokerBackend
  , brokers :: [BrokerAddress] -- ExternalBrokers only
  , controlHooks :: Maybe BrokerControlHooks -- ExternalBrokers only
  , lanes :: Int -- 0 = clients reach the broker directly; 1..4 = that many proxied listeners
  , brokerProps :: Map Text Text -- server.properties overrides, private backends only
  , readyTimeoutSeconds :: Int -- default 90
  , keepData :: Bool -- default False
  }

kafkaEnvSpecFromRunSpec :: RunContext -> Either Text KafkaEnvSpec
```

`kenshou-kafka/src/Kenshou/Env/Kafka/Naming.hs` derives the run prefix `kenshou-<run id with dashes removed>` and the helpers `topicName :: KafkaEnv -> Text -> TopicName` and `groupName :: KafkaEnv -> Text -> ConsumerGroupId`, which return `<prefix>-<name>` and reject names outside `[a-z0-9-]` (Kafka warns when topic names mix `.` and `_`, so neither is used). Every topic, group, `transactional.id` and `group.instance.id` a scenario creates must go through these helpers; that is what makes clean-up and isolation on a shared external broker possible.

`kenshou-kafka/src/Kenshou/Env/Kafka/ApacheKafka.hs` is the default backend. It creates a work directory `$TMPDIR/kenshou-kafka-<run id>/` (outside the run directory so broker data never enters the manifest), writes `harness.pid` and later `broker.pid`, and for each lane starts the correctness toolkit's TCP proxy on an ephemeral port first, because the broker must advertise the proxy's address. It allocates the broker's own listener ports by binding port 0 and closing, renders `server.properties` (combined `broker,controller` roles, one listener per lane named `LANE0`…, `advertised.listeners` pointing at the proxy ports or at the listener itself when `lanes = 0`, a `CONTROLLER` listener, `log.dirs` in the work directory, replication factors and minimum in-sync replicas of 1 for the offsets and transaction-state topics with 4 partitions each, `group.initial.rebalance.delay.ms=0`, `auto.create.topics.enable=false`, then `brokerProps` overrides), formats storage, and spawns `kafka-server-start.sh` in its own process group with `KAFKA_HEAP_OPTS=-Xms256m -Xmx768m` and standard output and error redirected to `<run dir>/logs/kafka-broker.log`. If start-up fails with an address-in-use error it reallocates ports and retries up to three times. Readiness is proven in-process through the client stack: create an hw-kafka-client producer against lane 0's advertised address and call `Kafka.Metadata.allTopicsMetadata` until it succeeds or `readyTimeoutSeconds` passes (an `infrastructure-failure`). `kill` sends `SIGKILL` to the process group and waits for exit; `stop` sends `SIGTERM`; `start` spawns again with the same properties, data and ports and waits for readiness. On entry the backend sweeps stale work directories whose `harness.pid` names a dead process and kills their `broker.pid`. On exit it stops the broker (kill after ten seconds), stops the proxies, and deletes the work directory unless `keepData`.

```haskell
data BrokerLane = BrokerLane
  { laneBrokers :: [BrokerAddress] -- what clients on this lane must use
  , laneFaults :: Maybe NetworkFaults -- the correctness toolkit's proxy handle; substitute its real type
  }

data BrokerControl = BrokerControl
  { kill :: IO (), stop :: IO (), start :: IO (), isRunning :: IO Bool }

data KafkaEnv = KafkaEnv
  { backend :: BrokerBackend
  , lanes :: NonEmpty BrokerLane
  , prefix :: Text
  , control :: Maybe BrokerControl -- Nothing: this broker cannot be killed
  , brokerVersion :: Text
  , workDir :: FilePath
  }

withKafkaEnv :: RunContext -> KafkaEnvSpec -> (KafkaEnv -> IO a) -> IO a
```

`withKafkaEnv` also registers a summary section named `kafka` in the run result (backend, broker version, effective broker properties, lane count) and merges the same facts into the environment fingerprint; confirm in the completed kernel plan that fingerprint members take part in the compatibility key that gates comparisons, and if they do not, expose the backend additionally as a read-only knob `kafka.broker-backend`.

`kenshou-kafka/src/Kenshou/Env/Kafka/Admin.hs` wraps `rpk`, always invoked as `rpk --config <workDir>/rpk.yaml -X brokers=<lane 0> ...` with an empty configuration file.

```haskell
data TopicSpec = TopicSpec { name :: Text, partitions :: Int, config :: Map Text Text }

data PartitionOffsets = PartitionOffsets
  { topic :: TopicName, partition :: PartitionId
  , committed :: Maybe Int64, logEnd :: Int64, lag :: Maybe Int64 }

data GroupSnapshot = GroupSnapshot
  { group :: ConsumerGroupId, state :: Text, members :: [GroupMember], offsets :: [PartitionOffsets] }

createTopics :: KafkaEnv -> [TopicSpec] -> IO [TopicName] -- names are prefixed; replication factor 1
describeGroup :: KafkaEnv -> ConsumerGroupId -> IO GroupSnapshot -- rpk group describe --format json
awaitGroup :: KafkaEnv -> ConsumerGroupId -> Int -> (GroupSnapshot -> Bool) -> IO (Either GroupSnapshot GroupSnapshot)
deleteRunTopics :: KafkaEnv -> IO Int -- rpk topic delete -r '^<prefix>-.*'
deleteRunGroups :: KafkaEnv -> IO Int
```

`kenshou-kafka/src/Kenshou/Env/Kafka/External.hs` uses the brokers from the specification with a single unproxied lane, builds `BrokerControl` from `controlHooks` when present, and always deletes the run's topics and groups on exit. `kenshou-kafka/src/Kenshou/Env/Kafka/RedpandaContainer.hs` is opt-in (`"backend": "redpanda-container"`): on macOS it requires `redpanda-local-up` on `PATH` (present only if the bootstrap plan applied `nix.redpanda=true`), uses the fixed address `127.0.0.1:39092`, holds a lock file because only one such cluster can exist, and maps kill to the container runtime's kill; on Linux it requires `docker` or `podman` and runs `docker.io/redpandadata/redpanda:v26.2.1` with `redpanda start --mode dev-container --smp 1` on allocated ports. When the prerequisite is missing the outcome is `infrastructure-failure` with a message naming it. Lanes are limited to one. A scenario that needs `control` or a second lane and does not get one finishes `errored` with the reason `broker-control-unavailable` or `lanes-unavailable`.

Two scenarios prove the fixture. `kafka/broker/correctness/fixture-roundtrip` (tier `smoke`, placement `either`, knob `kafka.partitions` integer default 3 allowed 1–64): create topic `roundtrip`, produce 100 records with `produceMessageSync`, read them with `pollMessage` in a group, commit, then inspect. It passes when all 100 payloads are read exactly once, `describeGroup` reports lag 0 on every partition, no lane address is loopback 9092, and after clean-up `rpk topic list` shows no topic with the run prefix; class `contract`. `kafka/broker/concurrency/kill-and-restart` (tier `standard`, placement `either`, requires `control`; knob `kafka.outage-seconds` integer default 5): produce sequence numbers with `produceMessageSync` and `acks=all`, call `kill` after 500 acknowledgements, keep producing (failures are counted, not fatal), `start` after the outage, produce 500 more, then read everything. It passes when every acknowledged sequence number is present, `isRunning` was false during the outage, and the broker process id changed; class `contract`. This scenario is the non-vacuity check for every later outage scenario.

Finish the milestone with `kenshou-kafka/src/Kenshou/Suite/Kafka.hs` exporting `bundle :: LayerBundle`, the three-line registration, the first section of `docs/layers/kafka.md` (how the fixture works, the `environment.kafka` object with a local and an external example, how to keep broker data for a post-mortem), and the fixture ADR.

### Milestone 2 — Kafka adapter correctness and rebalance scenarios

Scope: the adapter's documented guarantees and limitations with one or more consumers, the producer path, and keiro's record conversions. At the end twelve scenarios exist and the shared scaffolding (roles, handler policy, facts, knobs) that Milestones 3 and 4 reuse. Commands: `kenshou run <id> --out runs` for each. Acceptance: every scenario without a known-defect reference passes on both cohorts; every scenario with one fails with a verdict that names the expected counter-example and the run exits as the kernel defines for a known defect.

Shared scaffolding. `Kenshou.Suite.Kafka.Roles` registers three worker roles, each taking a JSON argument with the lane's brokers, the prefix, topics, group, a property map and the ledger path. `kafka-adapter-consumer` runs `runKafkaConsumer` → `kafkaAdapterWith` → `runApp` with one `QueueProcessor`, a handler driven by a `HandlerPolicy`, a composed rebalance callback (record the event as a ledger fact, then call `kafkaRebalanceHandler` when `kafka.rebalance-handler=installed`) and an `offsetCommitCallback` that records committed offsets as facts; it reports the adapter's terminal `Left KafkaError`, if any, as a fact and on its control channel. `kafka-raw-consumer` is a plain `pollMessageBatch` loop that stores and commits, used as a baseline and for membership scenarios. `kafka-producer` produces tagged payloads closed-loop or open-loop through the measurement toolkit's generators and records each acknowledged `(id, partition, offset)`.

```haskell
data Decision = DecideOk | DecideRetry !Int | DecideDeadLetter | DecideHalt | DecideThrow -- retry delay in ms
data DeliveryMatch = AnyDelivery | FirstN !Int -- matches while this process has seen the message fewer than N times
data Rule = Rule
  { topic :: Maybe Text, partition :: Maybe Int, offset :: Maybe Int64, payloadTag :: Maybe Text
  , deliveries :: DeliveryMatch, decision :: Decision, serviceMicros :: Int }
newtype HandlerPolicy = HandlerPolicy { rules :: [Rule] } -- first match wins; no match means DecideOk
```

Consumed facts carry the payload id, topic, partition, offset, consumer name, decision, handler start and finalize-done times (wall clock; all processes share a host locally, and the correctness toolkit records skew bounds on a cell). Layer-wide knobs, each named after what it sets: `kafka.partitions` (integer, default 4, 1–64), `kafka.consumers` (integer, default 1, 1–8, the number of consumer processes), `kafka.batch-size` (integer, default 100, allowed 1, 10, 100, 1000; `KafkaAdapterConfig.batchSize`), `kafka.poll-timeout-ms` (integer, default 1000, 10–10000; `KafkaAdapterConfig.pollTimeout`), `shibuya.inbox-size` (integer, default 100; `AppConfig.inboxSize`), `shibuya.concurrency` (`serial` default, `ahead`, `async`) with `shibuya.concurrency-n` (integer, default 4), `kafka.rebalance-handler` (`installed` default, `absent`), `kafka.messages` (integer, per-scenario default), `kafka.payload-bytes` (integer, default 256), and the pass-through family from `Kenshou.Suite.Kafka.Props.passthroughKnobs :: [Text] -> [KnobSpec]`, of which group scenarios declare `kafka.prop.session.timeout.ms` (default `6000`), `kafka.prop.heartbeat.interval.ms` (`2000`), `kafka.prop.auto.commit.interval.ms` (empty, meaning librdkafka's 5000), `kafka.prop.max.poll.interval.ms`, `kafka.prop.partition.assignment.strategy` and `kafka.prop.group.instance.id`. `Props` routes each property to the consumer, the producer or both from a fixed table, and always adds `noAutoOffsetStore` to consumers unless a scenario explicitly asks for the misconfiguration. Unless stated otherwise every scenario below supports all values of both telemetry dimensions (the roles take their tracer and metrics wiring from `Kenshou.Suite.Kafka.Telemetry`, stubbed to the `off` arm until Milestone 4), uses `Serial`, one proxied lane, and placement `either`.

`kafka/adapter/correctness/ack-ok-commits-and-resumes` (smoke; `kafka.messages` 500). Produce keyed records over the partitions, consume with `DecideOk`, stop gracefully (adapter `shutdown`, then let `runKafkaConsumer` close), start a second session in the same group for five seconds. Passes when every produced id has exactly one `ok` fact, per-partition offsets were handled in increasing order, the committed offset equals the log end on every partition, and the second session handles nothing. Class `contract`.

`kafka/adapter/correctness/retry-redelivers-and-never-commits-past` (smoke; knobs `kafka.failure-mode` `retry` default or `throw`, `kafka.retry-delay-ms` default 0, `kafka.exit-before-success` boolean default false; `kafka.partitions` forced to 1, `kafka.messages` 50). Offset 20 fails on its first delivery (an `AckRetry`, or a thrown exception that shibuya converts to `AckRetry (RetryDelay 0)`). Passes when offset 20 is handled at least twice; the group's committed offset, sampled every 200 ms while the retry is pending, never exceeds 20; and at the end every id has an `ok` fact and committed equals log end. With `kafka.exit-before-success=true` the consumer exits right after the failure instead, and the pass rule is that a second session's first handled offset is at most 20. Processing order is deliberately not asserted here; it has its own scenario in Milestone 3. Class `contract`.

`kafka/adapter/correctness/dead-letter-drops-record` (smoke; knob `kafka.poison-count` default 5; `kafka.messages` 200). The handler returns `AckDeadLetter (PoisonPill "kenshou")` for the tagged records. Passes when the behaviour is exactly as documented: every other record has an `ok` fact, committed equals log end, a second session redelivers none of the poison records, the consumer's captured standard error holds exactly `kafka.poison-count` lines containing `dead-lettered message DROPPED`, and no topic with the run prefix holds a copy. The verdict records `dropped = 5` under a `documentedLoss` key so that loss through this path is counted in every run. Class `contract` (documented limitation, `mori://shinzui/shibuya-kafka-adapter/okf/capabilities/concepts/CAP-2`).

`kafka/adapter/correctness/halt-leaves-offset-uncommitted` (smoke; `kafka.partitions` 2). The handler returns `AckHalt (HaltFatal "kenshou")` at partition 0 offset 30. Passes when the processor stops (no further facts from either partition, because shibuya halts the whole processor), after the consumer closes the committed offset of partition 0 is exactly 30, and a second session's first record on partition 0 is offset 30. Class `contract`.

`kafka/adapter/concurrency/non-serial-finalization-commits-past-halt` (standard; knobs `shibuya.concurrency` allowed `ahead`, `async`, default `async`; `shibuya.concurrency-n` default 4; known-defect reference `mori://shinzui/shibuya-kafka-adapter/okf/capabilities/concepts/CAP-1`). One partition; the record at offset 30 has a 2-second service time and then halts, its successors succeed immediately; wait two commit intervals, close, start a second session. The oracle is the same as the serial scenario's (the second session's first offset is 30). Under `Async` successors store offset 32 and beyond before the halt, so the expected result is a failure showing the halted record was committed past. This demonstrates why the serial contract exists. Class `contract`.

`kafka/adapter/correctness/multi-topic-partition-key` (smoke; known-defect reference `mori://shinzui/shibuya-kafka-adapter/okf/capabilities/concepts/CAP-3`). One adapter subscribed to two single-partition topics. Asserts that `messageId` values are unique across both topics (`contract`) and that `Envelope.partition` distinguishes them (`implementation`). The second assertion is expected to fail because both envelopes carry `"0"`; the verdict lists the colliding keys, which is what would make a partition-keyed scheduler serialise unrelated topics.

`kafka/adapter/concurrency/group-rebalance-with-inflight` (standard; `kafka.consumers` default 3, `kafka.partitions` default 12, knob `kafka.service-ms` default 50, `kafka.messages` 20000 produced open-loop at 500 per second). With steady traffic, the scenario adds a fourth consumer at 10 s, stops one gracefully at 20 s, kills one with `SIGKILL` at 30 s and restarts it at 40 s; each membership change opens a declared duplicate window of one session timeout plus ten seconds. Passes when no produced id lacks an `ok` fact (`contract`); duplicates occur only inside declared windows (`contract`); within one consumer and one assignment period offsets are handled in increasing order (`contract`); outside the windows no partition has `ok` facts from two consumers within the same second (`implementation`, the disjoint-ownership checker); and no surviving consumer terminates with an adapter fatal error (`contract`). The last rule is the detector for the first inferred hazard.

`kafka/adapter/concurrency/stale-barrier-after-partition-roundtrip` (standard; knob `kafka.rebalance-handler`; `kafka.partitions` forced to 2, 300 records per partition produced up front). Consumer A owns both partitions and its policy retries offset 50 of every partition forever with a 200 ms delay, so a barrier is pending on both. Consumer B, whose policy succeeds on everything, joins; whichever partition the group moves to B (call it q, read from B's rebalance facts, so the scenario does not depend on the assignor's member ordering) is processed by B to its end and committed; B then leaves gracefully and the scenario produces 100 more records to q. Passes when A records `ok` facts for all 100 new records of q within 30 seconds of B leaving. Expected to pass with `installed`, because the revoke clears A's barriers. With `absent` this is the detector for the second inferred hazard: A's barrier for q still says 50, every record A now fetches from q is above it, and `dropStaleRecords` discards them all. Class `contract`.

`kafka/producer/correctness/acked-offsets-and-batch-loop` (smoke). `produceMessageSync` to one partition returns strictly increasing offsets and reading each returned offset yields that payload; `produceMessageBatch` of 1000 records on a healthy broker returns `[]` and, after `flushProducer`, all 1000 are readable; `produceMessage'` delivers exactly one `DeliverySuccess` report per record. Class `contract`.

`kafka/producer/concurrency/batch-loop-reports-enqueue-not-delivery` (standard; requires `control`; known-defect reference `mori://shinzui/keiro/plans/120-add-an-acked-batch-publish-api-to-kafka-effectful-and-a-reference-outbox-bridge`; `kafka.prop.message.timeout.ms` default `3000`). Kill the broker, call `produceMessageBatch` with 100 records, flush, restart the broker. The oracle "every record the call did not report as failed is readable" is expected to fail, because the call returns `[]` on enqueue. This is KFK-3, the reason an outbox must not mark rows sent from this API. Class `contract`.

`kafka/producer/correctness/transactions-commit-and-abort` (standard; requires `control` for its second half). With a prefixed `transactional.id`: a committed transaction of 10 records is visible to a consumer with `isolation.level=read_committed`, an aborted one is not; then a consume-transform-produce worker using `commitOffsetMessageTransaction` is killed between produce and commit and restarted. Passes when the output topic, read committed, holds exactly one output per input. Class `contract`.

`kafka/keiro-records/correctness/roundtrip-through-broker` (smoke; knob `kafka.messages` default 200). Generate `IntegrationEvent` values from the seed (every optional field present and absent, non-ASCII text, payloads up to 64 KiB, attributes), set `destination` to a prefixed topic, convert with `integrationEventToKafkaRecord`, produce as an hw-kafka-client `ProducerRecord`, consume, build `KafkaInboundRecord` from the `ConsumerRecord` (headers decoded as UTF-8) and apply `integrationEventFromKafka`. Passes when the decoded event equals the original, the `KafkaDeliveryRef` equals the record's topic, partition and offset, the six required headers are on the wire with the exact names listed in Context, and removing each required header in turn yields `MissingHeader` with that name. When the event carries its own trace context and the tracing dimension is not `off`, the scenario also records which `traceparent` wins on the wire (keiro's or the traced producer's) as an observation, not a rule. Class `contract`.

### Milestone 3 — Kafka crash, outage and model-based scenarios

Scope: real `SIGKILL`, broker termination, network faults, group-membership edge cases, and the seek-barrier defects. At the end ten scenarios exist together with the simulator. Commands: `kenshou run <id> --out runs`; the model scenario also runs inside `cabal test kenshou-kafka-test` at a small size. Acceptance: as for Milestone 2, plus the model scenario's verdict contains a shrunk schedule and a seed, and re-running with that seed reproduces the same counter-example.

`kafka/adapter/concurrency/sigkill-redelivery-window` (standard; `kafka.partitions` 4, `kafka.messages` 20000, knob `kafka.kills` default 3, `kafka.prop.auto.commit.interval.ms` default `1000`). One consumer process handles a steady stream; at seeded random instants it is killed; before each restart the scenario reads the committed offsets C_p with `describeGroup`. Passes when no id lacks an `ok` fact (`contract`); after each restart no offset below C_p is handled again (`contract`); and the number of re-handled offsets per partition is at most the `ok` facts of that partition in the last commit interval before the kill, doubled, plus one in-flight record (`implementation`, the bounded duplicate window of "auto-commit interval plus in-flight").

`kafka/adapter/concurrency/auto-offset-store-loses-on-crash` (standard; known-defect reference `mori://shinzui/keiro/plans/121-enforce-consumer-offset-store-configuration-and-correct-the-kafka-transport-docs`). The same as above with `noAutoOffsetStore` deliberately omitted and a handler that blocks on offset 10 for three commit intervals before the kill. The no-loss rule is expected to fail, because librdkafka stores offsets for the whole polled batch on delivery. This is KFK-5. Class `contract`.

`kafka/adapter/concurrency/halt-holds-assignment-past-max-poll-interval` (standard; `kafka.consumers` 2, `kafka.prop.max.poll.interval.ms` default `10000`, `kafka.prop.session.timeout.ms` `6000`; known-defect reference `mori://shinzui/shibuya-kafka-adapter/okf/capabilities/concepts/CAP-2`, with `mori://shinzui/keiro/okf/adrs/concepts/ADR-11` cited in the verdict). Consumer A halts on a record and, as a long-running service would, keeps its consumer open. Rule one (`contract`, must hold): the halted offset is never committed, and after A is finally killed B handles it within one session timeout plus ten seconds. Rule two (the documented claim): while A is alive, its partitions move to B within `max.poll.interval.ms` plus the session timeout plus ten seconds. Rule two is expected to fail, because the background poll thread keeps resetting the watchdog; the verdict records how long A held the partitions and the lag that accumulated.

`kafka/consumer/concurrency/static-membership-restart-without-revoke` (standard; role `kafka-raw-consumer`, two members with prefixed `group.instance.id` values, `kafka.prop.session.timeout.ms` default `10000`). Kill member A and restart it after three seconds. Passes when B's ledger holds no `RebalanceBeforeRevoke` or `RebalanceRevoke` fact between the kill and A's first record after restart, and A resumes its previous partitions. Class `contract` (Kafka's, exercised through the binding).

`kafka/consumer/concurrency/static-membership-fencing-is-observable` (standard; role `kafka-adapter-consumer`; known-defect reference `mori://shinzui/keiro/masterplans/23-make-the-kafka-consumer-streaming-stack-surface-fatal-errors-and-close-deterministically`, scoped to cohorts in which `hw-kafka-client` resolves to the Hackage release). Start member A, then start A′ with the same `group.instance.id`. Passes when, within one session timeout plus fifteen seconds, A's adapter stream ends with `KafkaResponseError RdKafkaRespErrFatal` and A exits; on the released cohort A instead polls an empty queue forever, which the scenario reports as the failure "fenced member still alive and idle". If the kernel's known-defect type has no cohort scope, implement the scoping inside the scenario by inspecting the resolved `CohortIdentity` from the run context. This is the scenario that makes the fork visible: the same command is red-but-known on `released` and green on `head`. Class `contract`.

`kafka/adapter/concurrency/broker-outage-and-reconnect` (standard; requires `control`; knobs `kafka.outage-seconds` default 20, `kafka.recovery-deadline-seconds` default 60, `kafka.outage-mode` `kill` default or `blackhole` using the lane's proxy). Steady open-loop produce and two consumers; the broker disappears and returns. Passes when every record acknowledged to the producer has an `ok` fact (`contract`); consumers resume without being restarted within the deadline (`contract`, in the spirit of `mori://shinzui/keiro/okf/adrs/concepts/ADR-25`); duplicates fall inside the outage window extended by one commit interval; and no consumer ends with an adapter fatal error.

`kafka/adapter/concurrency/partitioned-consumer-becomes-zombie` (standard; placement `local`; needs two lanes). Consumer A uses lane 1, consumer B lane 0; lane 1 is blackholed for twice the session timeout and healed. Passes when no id lacks an `ok` fact, B takes over A's partitions, committed offsets sampled once per second never decrease (`contract`), and the duplicate count stays within A's buffered records at the moment of the partition (`implementation`; the verdict records the observed number).

The model. `kenshou-kafka/src/Kenshou/Suite/Kafka/Model/Simulator.hs` interprets `KafkaConsumer` over an in-memory log: `PollMessageBatch` returns up to the batch size from the current position, `SeekPartitions` sets the position, `StoreOffsetMessage` sets the stored offset to the record's offset plus one (last write wins, as librdkafka does), `PausePartitions` stops delivery, and the rest are inert. A driver mimics shibuya's serial runner: it pulls up to `inboxDepth` records from the real `kafkaSource` → `dropStaleRecords` → `mkIngested` pipeline, then handles them one at a time, applying the scripted decision through the real `mkAckHandle`.

```haskell
data Schedule = Schedule
  { inboxDepth :: Int -- 1..100
  , batchSize :: Int
  , script :: Map (PartitionId, Int64) [Decision] } -- one decision per delivery; DecideOk once exhausted

runSimConsumer :: IORef SimState -> Eff (KafkaConsumer : es) a -> Eff es a
runSchedule :: Schedule -> IO Trace
propNoCommitPastUnacked, propFirstSuccessInOrder, propTerminates :: Trace -> Bool
```

`kafka/adapter/correctness/ack-state-machine-model` (standard; brokerless, so it supports only the `off` values of both telemetry dimensions; knobs `model.tests` default 2000, `model.max-offsets` default 30; known-defect reference `mori://shinzui/keiro/masterplans/18-make-the-kafka-transport-edge-production-safe-surfaced-by-the-2026-07-transport-review`). It generates schedules with the correctness toolkit's model-based support and checks three properties: the stored offset never exceeds the smallest offset whose latest decision was not success or dead-letter (violated by KFK-1); first successes per partition occur in offset order (violated by KFK-2 whenever `inboxDepth > 1`); and a finite script terminates with stored equal to log end. The verdict carries the seed and the shrunk schedule; the expected minimal counter-example for KFK-1 is "offset n retries, buffered offset n+1 retries once, everything else succeeds". A unit test in `kenshou-kafka-test` runs the same properties against a small reference ack handler written in the test (monotone barrier with `Map.insertWith min`, inbox depth 1) and must pass, proving the properties are satisfiable.

`kafka/adapter/concurrency/barrier-overwrite-loses-record` and `kafka/adapter/concurrency/buffered-successors-run-before-retry` (both smoke, one partition, real broker, known-defect reference `mori://shinzui/keiro/plans/119-fix-the-seek-barrier-ordering-and-stale-successor-execution-in-shibuya-kafka-adapter`). The first scripts offsets 3 and 4 to retry once with zero delay and passes when every offset below the final committed offset has an `ok` fact; the expected failure is that offset 3 has none. The second scripts only offset 3 to retry once with `shibuya.inbox-size=100` and passes when first-success times are in offset order; the expected failure shows offsets 4 onward succeeding before 3. Class `contract` for both.

### Milestone 4 — Kafka benchmarks, soak and telemetry arms

Scope: numbers and endurance. At the end the layer has its first end-to-end benchmarks, its telemetry arms, two tracing correctness scenarios, two soaks and a finished layer guide. Commands: `kenshou run`, `kenshou compare` and `kenshou overhead` as shown in Concrete Steps. Acceptance: benchmarks produce summaries with throughput and p50/p90/p99/p99.9 latencies and a paired comparison of two knob values returns a verdict; the overhead report lists every arm; the local soak variants finish inside the `extended` tier with a leak verdict.

`Kenshou.Suite.Kafka.Telemetry` adapts the handles from `Kenshou.Telemetry.withTelemetry`. For `telemetry.tracing=off` the roles use `runKafkaProducer`, `runKafkaConsumer` and `runTracingNoop`; for the other three values they use `runKafkaProducerTraced tracer` and shibuya's `runTracing tracer`, and the knob `kafka.consumer-tracing` (`shibuya` default, `kafka-effectful`, `both`) decides whether `runKafkaConsumerTraced` is used as well. For `telemetry.metrics`: `off` installs nothing; `collect` sets `statistics.interval.ms` (knob `kafka.stats-interval-ms`, default 5000) with a `statsCallback` that parses librdkafka's statistics JSON into counters and `series/kafka-stats.csv`; `serve` additionally starts `shibuya-metrics` on a harness-chosen free port and registers the endpoint with the telemetry toolkit; `serve-scraped` lets the toolkit scrape it. Latency and throughput never come from these; they come from the measurement toolkit's recorder.

`kafka/pipeline/benchmark/produce-consume-throughput` (standard; placement `either`, authoritative only on a cell). Closed-loop producer and `kafka.consumers` consumer processes; end-to-end latency is measured from a wall-clock timestamp in the payload to handler start. Knobs: `kafka.consume-path` (`adapter-runapp` default, `adapter-stream` which drains the adapter's stream without shibuya's runner, `raw-poll`; this ladder isolates the framework's cost), `kafka.partitions` (1, 4, 12), `kafka.consumers` (1, 2, 4), `kafka.batch-size`, `kafka.payload-bytes` (100, 1024, 16384), `shibuya.inbox-size`, `kafka.prop.acks` (default `all`), `kafka.prop.linger.ms`, `kafka.prop.compression.type`, `kafka.prop.fetch.wait.max.ms`, `kafka.prop.queued.min.messages`. Warm-up 10 s, steady 60 s, drain. The result is refused as a benchmark if the no-loss check over the steady window fails.

`kafka/adapter/benchmark/poll-cap-latency` (standard). Open-loop constant-rate arrivals with latency taken from the intended send time, so coordinated omission (a stalled system hiding its own delay by slowing the load generator) is corrected. Knobs: `kafka.rate-per-second` (10, 100, 1000 default, 5000), `kafka.poll-timeout-ms` (50, 100, 1000, 5000), `kafka.batch-size` (1, 10, 100, 1000). librdkafka's batch consume does not return until the batch is full or the timeout expires (verified in `src/rdkafka_queue.c`), and the adapter caps the timeout at 100 ms, so the expected characterisation, which the layer guide records with the measured figures, is: below `batch-size / 0.1` records per second the median sits near 50 ms and p99 near 100 ms, values of `kafka.poll-timeout-ms` from 100 upward are indistinguishable, and `kafka.batch-size=1` removes the floor at a throughput cost. The scenario also reports the consumer's CPU time while idle.

`kafka/producer/benchmark/produce-modes` (standard). Knob `kafka.produce-mode`: `sync` (`produceMessageSync`), `async-flush` (`produceMessage` then one `flushProducer`), `batch-loop` (`produceMessageBatch`), `callback` (`produceMessage'` collecting delivery reports); plus `kafka.prop.linger.ms`, `kafka.prop.acks`, `kafka.prop.enable.idempotence`, `kafka.payload-bytes`. It measures records per second and per-record acknowledgement latency, quantifying what a per-record synchronous publish costs an outbox.

`kafka/telemetry/correctness/w3c-context-continuity` (smoke; supports `telemetry.tracing=sdk-inmemory` only). A traced producer sends inside a parent span. Passes when the record on the wire carries a `traceparent` naming the producer span; shibuya's per-message consumer span has the same trace id, the producer span as parent, and the attributes `messaging.system = "kafka"`, `messaging.kafka.destination.partition` and `messaging.kafka.message.offset`; and with `kafka.consumer-tracing=kafka-effectful` the traced consumer's span joins the same trace. It uses the telemetry toolkit's continuity helpers. `kafka/telemetry/correctness/context-leak-regression` (smoke; same dimension restriction) interleaves records with and without `traceparent` in one poll batch through `runKafkaConsumerTraced`; it passes when every headerless record starts a new root trace and the ambient context after the poll equals the one before it. Class `contract` for both.

Record one overhead comparison for the layer by running `kenshou overhead kafka/pipeline/benchmark/produce-consume-throughput --arms tracing=off,noop,sdk-otlp --arms metrics=off,collect,serve-scraped` and paste the report's headline deltas into `docs/layers/kafka.md`.

`kafka/pipeline/soak/consumer-memory-and-fd-stability` (registered twice from one implementation, because a scenario has exactly one tier: this identifier with tier `soak`, placement `cell` and `soak.duration-minutes` default 240, and `kafka/pipeline/soak/consumer-memory-and-fd-stability-reduced` with tier `extended`, placement `either` and default 20; the `-reduced` suffix is the suite-wide convention for the locally runnable form of a soak). Open-loop traffic at `kafka.rate-per-second` (default 500), two consumer processes, one graceful consumer restart every `soak.restart-every-minutes` (default 5). Verdicts: the diagnostics toolkit's leak verdict per process over live bytes after major garbage collection, Haskell threads, operating-system threads and file descriptors; the native series described next; ledger no-loss; and consumer lag sampled every 10 s bounded by ten seconds of traffic outside restart windows. The ledger must stay bounded on disk.

`kafka/consumer/soak/rebalance-churn-native-memory` (registered as the same pair, this identifier and `kafka/consumer/soak/rebalance-churn-native-memory-reduced`; known-defect reference `mori://shinzui/hw-kafka-client/commits/6caed636898a78e9f6e5a9c93eeb5562cbb2580a`, scoped to cohorts with Hackage `hw-kafka-client`). A long-lived consumer with a deep backlog while a second consumer joins and leaves every `soak.churn-seconds` (default 10), forcing assignments that make fetched records race the partition-queue redirect. The judged series is `native-bytes = resident set size − GHC memory in use`, fitted with the diagnostics toolkit's slope estimator as a named series; it passes on `stable`. On the released cohort the expected verdict is `leak-suspected`, on `head` `stable`; if the leak is too small to detect at this churn rate the verdict is `insufficient-data` and the outcome `inconclusive`, and the layer guide must say so rather than claim a pass.

Finish `docs/layers/kafka.md`: every scenario with its purpose, knobs and what a pass proves; the component-to-library map for the change planner (`adapter` → shibuya-kafka-adapter and shibuya-core; `consumer`, `producer`, `telemetry` → kafka-effectful, hw-kafka-streamly, hw-kafka-client, librdkafka; `keiro-records` → keiro and keiro-core; `pipeline` and `broker` → all of them); measured characterisations; and the findings filed upstream.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro-runtime-kenshou`, inside the development shell (`direnv allow` or `nix develop`). Transcripts are illustrative; identifiers, counts and timings will differ, and `kenshou` flag spellings must be taken from the completed kernel plan.

Check the starting state.

```bash
ls -d kenshou-core kenshou-measure kenshou-check kenshou-diagnose kenshou-telemetry kenshou-cli
cabal build all
cabal run kenshou -- list --json | jq -r '.[].id' | grep '^selftest/' | head
cabal run kenshou -- cohort show --json | grep -i -A3 'hw-kafka-client'
pkg-config --modversion rdkafka
```

```text
kenshou-check  kenshou-cli  kenshou-core  kenshou-diagnose  kenshou-measure  kenshou-telemetry
selftest/kernel/correctness/always-pass
...
2.15.0
```

After editing `flake.module.nix`, reload the shell and confirm the tools.

```nix
perSystem = { pkgs, ... }: {
  haskellProject.extraDevPackages = [ pkgs.apacheKafka pkgs.redpanda-client ];
};
```

```bash
command -v kafka-server-start.sh kafka-storage.sh rpk
rpk --version
```

The spike, by hand, in a scratch directory (replace the three ports with free ones).

```text
process.roles=broker,controller
node.id=1
controller.quorum.voters=1@127.0.0.1:19093
listeners=LANE0://127.0.0.1:19092,CONTROLLER://127.0.0.1:19093
advertised.listeners=LANE0://127.0.0.1:19092
listener.security.protocol.map=LANE0:PLAINTEXT,CONTROLLER:PLAINTEXT
inter.broker.listener.name=LANE0
controller.listener.names=CONTROLLER
log.dirs=/path/to/scratch/data
offsets.topic.replication.factor=1
offsets.topic.num.partitions=4
transaction.state.log.replication.factor=1
transaction.state.log.min.isr=1
transaction.state.log.num.partitions=4
group.initial.rebalance.delay.ms=0
auto.create.topics.enable=false
```

```bash
CLUSTER_ID="$(kafka-storage.sh random-uuid)"
kafka-storage.sh format -t "$CLUSTER_ID" -c server.properties
KAFKA_HEAP_OPTS="-Xms256m -Xmx768m" kafka-server-start.sh server.properties &
touch rpk.yaml
rpk --config rpk.yaml -X brokers=127.0.0.1:19092 topic create spike -p 3
rpk --config rpk.yaml -X brokers=127.0.0.1:19092 group describe nobody --format json
kill %1
```

Build, unit-test and register.

```bash
cabal build kenshou-kafka
cabal test kenshou-kafka-test
cabal run kenshou -- list --json | jq -r '.[].id' | grep '^kafka/' | wc -l
```

```text
31
```

Run the fixture scenarios and look at the evidence.

```bash
cabal run kenshou -- run kafka/broker/correctness/fixture-roundtrip --out runs; echo "exit=$?"
cabal run kenshou -- run kafka/broker/concurrency/kill-and-restart --out runs --set kafka.outage-seconds=5; echo "exit=$?"
RUN="$(ls -t runs | head -1)"; jq '.outcome, .summaries.kafka' "runs/$RUN/run-result.json"; ls "runs/$RUN/logs"
pgrep -fl 'kenshou-kafka-' || echo "no broker left behind"
```

```text
exit=0
exit=0
"passed"
{ "backend": "apache-kafka", "brokerVersion": "4.3.1", "lanes": 1, ... }
harness.log  kafka-broker.log  worker-kafka-producer-0.log
no broker left behind
```

Run against an external broker (the cell case) by putting the address in a run specification.

```json
{ "environment": { "kafka": { "backend": "external", "brokers": ["10.128.0.12:9092"], "control": null } } }
```

Representative runs for the later milestones.

```bash
cabal run kenshou -- run kafka/adapter/concurrency/sigkill-redelivery-window --out runs --set kafka.kills=3
cabal run kenshou -- run kafka/adapter/correctness/ack-state-machine-model --out runs --set model.tests=2000
cabal run kenshou -- run kafka/adapter/benchmark/poll-cap-latency --out runs --set kafka.rate-per-second=100 --set kafka.batch-size=100
cabal run kenshou -- overhead kafka/pipeline/benchmark/produce-consume-throughput --arms tracing=off,noop,sdk-otlp --arms metrics=off,collect,serve-scraped --out runs
cabal run kenshou -- run kafka/pipeline/soak/consumer-memory-and-fd-stability --out runs --set soak.duration-minutes=20
```

```text
kafka/adapter/correctness/ack-state-machine-model  failed (known defect: mori://shinzui/keiro/masterplans/18-...)
  propNoCommitPastUnacked: counter-example after 37 tests, 12 shrinks, seed 0x5eed...
    inboxDepth = 2, script = {(0,0): [retry 0], (0,1): [retry 0]}
```

Commit after each green step. Commits follow Conventional Commits with the scope `kafka` (for example `feat(kafka): add the disposable Apache Kafka broker fixture`) and carry these three trailers.

```text
MasterPlan: docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md
ExecPlan: docs/plans/11-cover-the-kafka-transport-edge-with-a-disposable-broker.md
Intention: intention_01m2zvy0gje40tdsdragvzr3tq
```

When an ADR is created or changed, validate the bundle.

```bash
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```


## Validation and Acceptance

Milestone 1 is accepted when `cabal test kenshou-kafka-test` passes (including the test that a specification naming `127.0.0.1:9092`, `localhost:9092` or `[::1]:9092` is rejected for every backend); both fixture scenarios exit 0 on the implementer's operating system and, if available, on the other one; `kafka/broker/concurrency/kill-and-restart` shows a different broker process id after the restart and `isRunning = false` during the outage; the run directory's `logs/kafka-broker.log` is non-empty and listed in `manifest.json`; `pgrep -fl kenshou-kafka-` prints nothing afterwards; and, with the machine-global broker running, `rpk topic list -X brokers=127.0.0.1:9092` shows no topic beginning with `kenshou-` after a full run of the layer. Killing the harness itself with `SIGKILL` in the middle of a run and starting another run must show the sweep removing the orphaned broker.

Milestones 2 and 3 are accepted when every scenario without a known-defect reference passes three consecutive runs with different seeds on the `released` cohort, and again on `head`; every scenario with a reference fails with a verdict whose counter-example matches the one predicted in this plan, and the run is reported as a known defect rather than a blocking failure; `kafka/consumer/concurrency/static-membership-fencing-is-observable` is red-but-known on `released` and green on `head`; and each oracle has been shown not to be vacuous by one deliberate sabotage recorded in the plan's Surprises section or in a unit test — for example, running the no-loss checker against a ledger with one produced fact removed, or running `retry-redelivers-and-never-commits-past` with a handler that returns `DecideOk` for the failing offset and observing the "handled at least twice" rule fail.

Milestone 4 is accepted when each benchmark writes `samples/` and a summary with throughput and the five latency percentiles; `kenshou compare` on two runs of `poll-cap-latency` that differ only in `kafka.batch-size` (1 versus 100, at 100 records per second) returns a verdict, and the measured medians are recorded in `docs/layers/kafka.md` next to the predicted characterisation; the overhead report contains one comparison per arm; the two tracing scenarios pass with `--dim telemetry.tracing=sdk-inmemory`; and both soaks complete locally at the reduced duration with a leak verdict in `diagnosis/` for every process.

The plan as a whole is accepted when `kenshou list` shows thirty-one `kafka/` scenarios, `kenshou-runtime` can import `Kenshou.Env.Kafka` without importing anything from `Kenshou.Suite.Kafka.*` (compile a three-line module to prove it), `docs/layers/kafka.md` is complete, the ADR validates, and the MasterPlan's registry row and four progress entries for this plan are updated.


## Idempotence and Recovery

Every run writes to a new run directory and to broker names carrying the run identifier, so any scenario can be repeated without clean-up. The private broker's data lives in `$TMPDIR/kenshou-kafka-<run id>/` and is deleted on exit; pass `"keepData": true` in `environment.kafka` to keep it for a post-mortem and delete it by hand afterwards. If the harness dies without clean-up, the next run's sweep kills brokers whose `harness.pid` is dead; to do it by hand, `pkill -KILL -f kenshou-kafka-` and remove the directories. The Apple Container backend holds one fixed-port cluster; recover it with `redpanda-local-down` and, if it is wedged, `redpanda-local-purge` (these act only on the project-local cluster, never on the shared one). On an external broker a crashed run leaves topics and groups with its prefix; while you hold the cell's lease, remove them with `rpk topic delete -r '^kenshou-.*' -X brokers=<address>` and `rpk group delete` for each `kenshou-` group. Never run those commands against `127.0.0.1:9092`.

The `flake.module.nix` and registry edits are additive and safe to re-apply. If the spike shows Apache Kafka cannot be started as described on one operating system, do not switch the default silently: record the evidence in Surprises & Discoveries, add a Decision Log entry, make the working backend the default for that platform in `Kenshou.Env.Kafka.Spec`, and keep the interface unchanged so no scenario notices. If a toolkit module this plan names does not exist under that name, use the name from the completed toolkit plan and note the mapping in Interfaces and Dependencies; do not reimplement toolkit functionality inside `kenshou-kafka`. A scenario that fails unexpectedly is never "fixed" by loosening its oracle: decide first whether the runtime or the harness is wrong, and if it is the runtime, file it upstream and attach the known-defect reference.


## Interfaces and Dependencies

Runtime libraries, from the pinned cohort: `shibuya-kafka-adapter` 0.9.0.1 (modules `Shibuya.Adapter.Kafka`, `.Config`, `.Internal`), `kafka-effectful` 0.3.1.0 (`Kafka.Effectful.Consumer`, `.Producer`, `.OpenTelemetry`), `hw-kafka-client` 5.3.0 from Hackage on `released` and the fork at `6caed636898a78e9f6e5a9c93eeb5562cbb2580a` on `head` (`Kafka.Consumer`, `Kafka.Producer`, `Kafka.Metadata`; never `Kafka.Topic`, which the release lacks), `hw-kafka-streamly` 0.2.0.0 or head, `shibuya-core` and `shibuya-metrics` 0.9.0.3, `keiro` and `keiro-core` 0.17.0.0, `effectful-core` (below 2.7 as the cohort requires), `streamly` 0.11, `hs-opentelemetry-api` 1.0. System tools from the development shell: librdkafka 2.15.0 (`rdkafka`), Apache Kafka 4.3.1 (`apacheKafka`), `rpk` 26.2.2 (`redpanda-client`). Test libraries: `hspec`, `hspec-hedgehog`, `hedgehog`.

Consumed from the kernel (`docs/plans/2-…`): `Kenshou.Core.Scenario` (`Scenario`, `ScenarioId`, `Tier`, `Placement`, `KnownDefect`), `Kenshou.Core.Knob` (`KnobSpec`), `Kenshou.Core.Dimension`, `Kenshou.Core.Bundle` (`LayerBundle`), `Kenshou.Core.Role` (`WorkerRole`, `RoleContext`), `Kenshou.Core.Run` (`RunContext`: resolved knobs and dimensions, seed, output directory, logger, summary sections, phase markers, the run specification's environment object, the resolved `CohortIdentity`). From measurement (`docs/plans/4-…`): the latency recorder, closed-loop and open-loop generators, the runtime and process samplers that write `series/rts.csv` and `series/proc.csv`, summaries and `kenshou compare`. From correctness (`docs/plans/5-…`): the bounded ledger, the checkers for no-loss, windowed duplicates, per-key and monotonic order, disjoint ownership and monotonic checkpoints, `Kenshou.Check.Process` (spawn, control channel, `SIGTERM`/`SIGKILL`, crash-window bookkeeping, log capture), the in-process TCP proxy with latency, stall, blackhole and reset, and the model-based support that writes seed and shrunk counter-example into a verdict. From diagnostics (`docs/plans/6-…`): the leak verdict over named series, including a caller-supplied derived series. From telemetry (`docs/plans/7-…`): `Kenshou.Telemetry.withTelemetry`, endpoint registration, the scraper, trace-continuity helpers and `kenshou overhead`.

At the end of Milestone 1 these must exist: `Kenshou.Env.Kafka` re-exporting `BrokerBackend`, `BrokerControlHooks`, `KafkaEnvSpec`, `kafkaEnvSpecFromRunSpec`, `BrokerLane`, `BrokerControl`, `KafkaEnv`, `withKafkaEnv`, `TopicSpec`, `topicName`, `groupName`, `createTopics`, `PartitionOffsets`, `GroupSnapshot`, `describeGroup`, `awaitGroup`, `deleteRunTopics`, `deleteRunGroups`, with the signatures given in Plan of Work; `Kenshou.Suite.Kafka.bundle :: LayerBundle`; and `schemas/kenshou.kafka-env.v1.json`. At the end of Milestone 2: `Kenshou.Suite.Kafka.Roles` (roles `kafka-adapter-consumer`, `kafka-raw-consumer`, `kafka-producer`), `Kenshou.Suite.Kafka.Handler` (`Decision`, `DeliveryMatch`, `Rule`, `HandlerPolicy`), `Kenshou.Suite.Kafka.Facts`, `Kenshou.Suite.Kafka.Knobs`, and the property helpers below. At the end of Milestone 3: `Kenshou.Suite.Kafka.Model.Simulator` (`Schedule`, `runSimConsumer`, `runSchedule`) and `Kenshou.Suite.Kafka.Model.Properties`. At the end of Milestone 4: `Kenshou.Suite.Kafka.Telemetry`.

```haskell
-- Kenshou.Suite.Kafka.Props
passthroughKnobs :: [Text] -> [KnobSpec] -- "session.timeout.ms" becomes the knob "kafka.prop.session.timeout.ms"
consumerProps :: BrokerLane -> ConsumerGroupId -> OffsetStoreMode -> Map Text Text -> ConsumerProperties
producerProps :: BrokerLane -> Map Text Text -> ProducerProperties
data OffsetStoreMode = ManualStore | AutoStoreMisconfigured -- the second exists only for the KFK-5 scenario
```

Other plans consume the following from this one. `docs/plans/15-verify-the-assembled-runtime-end-to-end-and-under-soak.md` imports `Kenshou.Env.Kafka` for the broker between its two contexts, including `BrokerControl` for its broker-restart case and lanes for its network-partition case; it must not import `Kenshou.Suite.Kafka.*`. `docs/plans/3-plan-and-select-runs-from-what-changed.md` maps the runtime components `shibuya-kafka-adapter`, `kafka-effectful`, `hw-kafka-streamly`, `hw-kafka-client` and keiro's record modules to the selectors `kafka/adapter/**`, `kafka/consumer/**`, `kafka/producer/**`, `kafka/telemetry/**`, `kafka/keiro-records/**`, with `kafka/pipeline/**` and `kafka/broker/**` selected by any of them. `docs/plans/16-provide-leased-verification-cells-in-load-testing-infra.md` and `docs/plans/17-run-kenshou-on-leased-cells-with-payloads-submission-and-retrieval.md` supply, on a cell, the broker address and optional control hooks that fill the `environment.kafka` object of each run specification; nothing in the cell protocol needs to know about Kafka beyond that.
