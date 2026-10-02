---
type: Verification Run
title: keiro/inbox/correctness/effectively-once-matrix failed on released
description: Recorded keiro/inbox/correctness/effectively-once-matrix run against
  cohort released with digest-pinned data.
generated:
  at: 2026-10-02T02:11:50.950948Z
  by: kenshou-record/0.1.0.0
verified:
- at: 2026-10-02T02:22:55.224387Z
  by: process:kenshou-attester/0.1.0.0
cohort: released
compatibilityKey: 4b75eccaed45f30536ca77542f08934a9e2eb1b9217668e13ad335d8927434f4
component: inbox
components:
- package: keiki
  project: mori://shinzui/keiki
  source: hackage
  version: 0.9.1.0
- package: keiki-codec-json
  project: mori://shinzui/keiki
  source: hackage
  version: 0.9.1.0
- package: kiroku-store
  project: mori://shinzui/kiroku
  source: hackage
  version: 0.8.0.1
- package: kiroku-store-migrations
  project: mori://shinzui/kiroku
  source: hackage
  version: 0.4.0.0
- package: kiroku-otel
  project: mori://shinzui/kiroku
  source: hackage
  version: 0.2.0.8
- package: kiroku-metrics
  project: mori://shinzui/kiroku
  source: hackage
  version: 0.1.0.8
- package: kiroku-cli
  project: mori://shinzui/kiroku
  source: hackage
  version: 0.2.0.6
- package: shibuya-kiroku-adapter
  project: mori://shinzui/kiroku
  source: hackage
  version: 0.5.1.2
- package: keiro
  project: mori://shinzui/keiro
  source: hackage
  version: 0.17.0.0
- package: keiro-core
  project: mori://shinzui/keiro
  source: hackage
  version: 0.17.0.0
- package: keiro-pgmq
  project: mori://shinzui/keiro
  source: hackage
  version: 0.17.0.0
- package: keiro-migrations
  project: mori://shinzui/keiro
  source: hackage
  version: 0.17.0.0
- package: keiro-test-support
  project: mori://shinzui/keiro
  source: hackage
  version: 0.17.0.0
- package: shibuya-core
  project: mori://shinzui/shibuya
  source: hackage
  version: 0.9.0.3
- package: shibuya-metrics
  project: mori://shinzui/shibuya
  source: hackage
  version: 0.9.0.3
- package: shibuya-pgmq-adapter
  project: mori://shinzui/shibuya-pgmq-adapter
  source: hackage
  version: 0.16.0.0
- package: shibuya-kafka-adapter
  project: mori://shinzui/shibuya-kafka-adapter
  source: hackage
  version: 0.9.0.1
- package: kafka-effectful
  project: mori://shinzui/kafka-effectful
  source: hackage
  version: 0.3.1.0
- package: hw-kafka-streamly
  project: mori://shinzui/hw-kafka-streamly
  source: hackage
  version: 0.2.0.0
- package: hw-kafka-client
  project: mori://haskell-works/hw-kafka-client
  source: hackage
  version: 5.3.0
- package: pgmq-core
  project: mori://shinzui/pgmq-hs
  source: hackage
  version: 0.6.1.0
- package: pgmq-hasql
  project: mori://shinzui/pgmq-hs
  source: hackage
  version: 0.6.1.0
- package: pgmq-effectful
  project: mori://shinzui/pgmq-hs
  source: hackage
  version: 0.6.1.0
- package: pgmq-config
  project: mori://shinzui/pgmq-hs
  source: hackage
  version: 0.6.1.0
- package: pgmq-migration
  project: mori://shinzui/pgmq-hs
  source: hackage
  version: 0.6.1.0
- package: pg-migrate
  project: mori://shinzui/pg-migrate
  source: hackage
  version: 1.1.0.0
- package: pg-migrate-embed
  project: mori://shinzui/pg-migrate
  source: hackage
  version: 1.1.0.0
- package: pg-migrate-cli
  project: mori://shinzui/pg-migrate
  source: hackage
  version: 1.1.0.0
- package: pg-migrate-import-codd
  project: mori://shinzui/pg-migrate
  source: hackage
  version: 1.1.0.0
- package: pg-migrate-import-hasql-migration
  project: mori://shinzui/pg-migrate
  source: hackage
  version: 1.1.0.0
- package: ephemeral-pg
  project: mori://shinzui/ephemeral-pg
  source: hackage
  version: 0.3.1.0
- package: effectful
  project: mori://effectful/effectful
  source: hackage
  version: 2.6.1.0
- package: effectful-core
  project: mori://effectful/effectful
  source: hackage
  version: 2.6.1.0
- package: hs-opentelemetry-api
  project: mori://iand675/hs-opentelemetry
  source: hackage
  version: 1.0.0.0
- package: hs-opentelemetry-sdk
  project: mori://iand675/hs-opentelemetry
  source: hackage
  version: 1.0.0.0
- package: hs-opentelemetry-propagator-w3c
  project: mori://iand675/hs-opentelemetry
  source: hackage
  version: 1.0.0.0
- package: hs-opentelemetry-exporter-in-memory
  project: mori://iand675/hs-opentelemetry
  source: hackage
  version: 1.0.0.0
- package: hs-opentelemetry-exporter-otlp
  project: mori://iand675/hs-opentelemetry
  source: hackage
  version: 1.0.0.0
- package: hs-opentelemetry-exporter-prometheus
  project: mori://iand675/hs-opentelemetry
  source: hackage
  version: 1.0.0.0
- package: hs-opentelemetry-otlp
  project: mori://iand675/hs-opentelemetry
  source: hackage
  version: 1.0.0.0
- package: hs-opentelemetry-semantic-conventions
  project: mori://iand675/hs-opentelemetry
  source: hackage
  version: 1.40.0.0
computations:
- VC-1
data:
- bytes: 729
  digest: d86c9bdfa93d3b4342666d17ce63832f6e8e36a97b66c0a0edb7aebf8c5d7065
  kind: run-spec
  mediaType: application/json
  uri: gs://kenshou-evidence-tan-nb-exp/runs/01a0fa2a-ceac-70ad-9b70-dab8679eb46b/run-spec.json
- bytes: 11429
  digest: 10b67a8a778288f6618c76157abcdf4e151a6ef9ba5487b97993d1a5841e2739
  kind: run-result
  mediaType: application/json
  uri: gs://kenshou-evidence-tan-nb-exp/runs/01a0fa2a-ceac-70ad-9b70-dab8679eb46b/run-result.json
- bytes: 3050
  digest: 0e6d5dbcef360de99e857905bebafaef47aaff3318bbeee0cbe778b15adbca0f
  kind: manifest
  mediaType: application/json
  uri: gs://kenshou-evidence-tan-nb-exp/runs/01a0fa2a-ceac-70ad-9b70-dab8679eb46b/manifest.json
- bytes: 607
  digest: 32027fc6543cf41362f8de365df7bbb1edbb70de8b0c00bf39a52ee0ad29f396
  kind: verdicts
  mediaType: application/json
  uri: gs://kenshou-evidence-tan-nb-exp/runs/01a0fa2a-ceac-70ad-9b70-dab8679eb46b/verdicts/effect-count-by-policy.json
- bytes: 618
  digest: 4ab00c53a257e721ad0b235b3495816bf7b08965084cbd757f80d0211163b918
  kind: verdicts
  mediaType: application/json
  uri: gs://kenshou-evidence-tan-nb-exp/runs/01a0fa2a-ceac-70ad-9b70-dab8679eb46b/verdicts/failed-handler-rolls-back-effect.json
- bytes: 598
  digest: 6a0d36d79ea586fa739433580fd522c6ecf03b662acd1ce87d1bba5f9e5a3c50
  kind: verdicts
  mediaType: application/json
  uri: gs://kenshou-evidence-tan-nb-exp/runs/01a0fa2a-ceac-70ad-9b70-dab8679eb46b/verdicts/failed-receipt-ceiling.json
- bytes: 616
  digest: 2e3393f24ec9326bcf6329bf1c18e126c930b49e26b52319733762685594e549
  kind: verdicts
  mediaType: application/json
  uri: gs://kenshou-evidence-tan-nb-exp/runs/01a0fa2a-ceac-70ad-9b70-dab8679eb46b/verdicts/failed-receipt-retains-envelope.json
- bytes: 606
  digest: e7493dd113e2c438f09a980b734a8ff20d60eaa9c0577feabb4a8b89de20dd3b
  kind: verdicts
  mediaType: application/json
  uri: gs://kenshou-evidence-tan-nb-exp/runs/01a0fa2a-ceac-70ad-9b70-dab8679eb46b/verdicts/failed-receipt-survives-gc.json
- bytes: 602
  digest: b9fdef2aec11f1c061013b9386702cfec0d37ab07498d147d945603614c0f648
  kind: verdicts
  mediaType: application/json
  uri: gs://kenshou-evidence-tan-nb-exp/runs/01a0fa2a-ceac-70ad-9b70-dab8679eb46b/verdicts/first-delivery-processed.json
- bytes: 620
  digest: c8bf310ae882610c684d3e41257f4ef83aacb44587ccf5b584dc21b4cc3a0559
  kind: verdicts
  mediaType: application/json
  uri: gs://kenshou-evidence-tan-nb-exp/runs/01a0fa2a-ceac-70ad-9b70-dab8679eb46b/verdicts/missing-policy-field-fails-closed.json
- bytes: 604
  digest: 9e5e61c0bafb3c3c5d1a24375ca73933d89b7ec69e97524b7ddb1088b7b52921
  kind: verdicts
  mediaType: application/json
  uri: gs://kenshou-evidence-tan-nb-exp/runs/01a0fa2a-ceac-70ad-9b70-dab8679eb46b/verdicts/one-completed-row-per-key.json
- bytes: 588
  digest: 3826bc0fd6eb530b3a903a4cd70d1537146f8e819c3dc9159accb1e0dace748d
  kind: verdicts
  mediaType: application/json
  uri: gs://kenshou-evidence-tan-nb-exp/runs/01a0fa2a-ceac-70ad-9b70-dab8679eb46b/verdicts/persistence-shape.json
- bytes: 594
  digest: 43dee3ffabacaa09fb2bd84729ed23842aeda59f10f90b47b53edd9a4c1a5caa
  kind: verdicts
  mediaType: application/json
  uri: gs://kenshou-evidence-tan-nb-exp/runs/01a0fa2a-ceac-70ad-9b70-dab8679eb46b/verdicts/redelivery-duplicate.json
- bytes: 586
  digest: a30a8bb94f320c76b60296fbdcab863e113d2b4e1a231f9e6f78da127a48bf55
  kind: verdicts
  mediaType: application/json
  uri: gs://kenshou-evidence-tan-nb-exp/runs/01a0fa2a-ceac-70ad-9b70-dab8679eb46b/verdicts/republish-policy.json
- bytes: 0
  digest: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
  kind: logs
  mediaType: application/x-ndjson
  uri: gs://kenshou-evidence-tan-nb-exp/runs/01a0fa2a-ceac-70ad-9b70-dab8679eb46b/logs/harness.jsonl
- bytes: 27755
  digest: da1ed43b7810efc0bc3e2b00f69794c19e479dbd22269ce8189956a6b4ac9676
  kind: logs
  mediaType: application/json
  uri: gs://kenshou-evidence-tan-nb-exp/runs/01a0fa2a-ceac-70ad-9b70-dab8679eb46b/logs/inbox-matrix-intake.json
- bytes: 52746
  digest: a891930b710cb0f5ea8e89c0ef8dca5cdbfd4f35923bfec8d86fe19500842727
  kind: logs
  mediaType: application/json
  uri: gs://kenshou-evidence-tan-nb-exp/runs/01a0fa2a-ceac-70ad-9b70-dab8679eb46b/logs/inbox-matrix-sql.json
- bytes: 648
  digest: a03b09b5b23889f39d44f549c4c119954db207a03d53974f26e641af59a5b6ce
  kind: logs
  mediaType: text/plain
  uri: gs://kenshou-evidence-tan-nb-exp/runs/01a0fa2a-ceac-70ad-9b70-dab8679eb46b/logs/postgres.log
dimensions:
- name: pg.durability
  value: durable
- name: pg.version
  value: '18'
- name: telemetry.metrics
  value: 'off'
- name: telemetry.tracing
  value: 'off'
environment:
  arch: aarch64
  cores: 1
  cpuModel: Apple M1 Max
  ghc: Version {versionBranch = [9,12], versionTags = []}
  memoryBytes: 68719476736
  os: darwin
  postgres: '18.6'
finishedAt: 2026-10-02T01:11:46.24125Z
harnessDirty: false
harnessRevision: af3e8a9c80093d5c1ab6987b16185983bbd6d580
kind: correctness
knobs:
- name: inbox.dedupe-policy
  value: message-id
- name: inbox.handler-effects
  value: 2
- name: inbox.idempotence
  value: inbox-table
- name: inbox.persistence
  value: dedupe-only
layer: keiro
outcome: failed
placement: local
purpose: investigation
recordKind: run
runId: 01a0fa2a-ceac-70ad-9b70-dab8679eb46b
scenario: keiro/inbox/correctness/effectively-once-matrix
seed: 4252662818734786
solverPlanHash: f76053f0c0a8216bcc67ac5396f9ab9d0501a51a8f930ab08daa2791164e6b26
startedAt: 2026-10-02T01:11:44.557245Z
subject: mori://shinzui/keiro
subjectKind: project
tier: standard
---

This run produced the recorded outcome under [VC-1](/computations/run-outcome.md). Its raw data is linked by digest in the frontmatter.
