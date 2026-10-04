# Keiro runtime verification — initial findings, 2026-10-04

**State: first round closed.** This report answers one question for the
owners of keiro, kiroku, pgmq-hs, shibuya and the Kafka adapter: what did the
first verification round of
[MasterPlan 1](../masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md)
find on the pinned released cohort? The owner closed the round on 2026-10-04
(MasterPlan Decision Log), so this report uses only evidence that was already
recorded. No run was repeated for it. It is a dated reading of that evidence,
not an edit to any immutable run record. It does not claim that an owner-marked
fix passed Kenshou verification.

This file began as the 2026-09-29 baseline checkpoint. That version's
run-by-run narrative is in this file's Git history, in the child plans and in
the [historical evidence bundle](../verification/).

## Summary

The round produced 60 numbered findings: 1–56 and 63–66. Numbers 57–62 are
deliberately unused.

| Kind | Findings | Count |
|---|---|---:|
| Runtime defect, with an owner bug report | 1, 2, 4–12, 15, 17–19, 21, 22, 24, 26–38, 63, 65 | 33 |
| Documented limitation or unpromised behavior, with an owner improvement request or no owner record | 13, 14, 16, 20, 23, 66 | 6 |
| Harness defect in this repository, repaired | 39–43, 45, 48–56, 64 | 16 |
| Unattributed or open | 3, 25, 44, 46, 47 | 5 |

The 33 runtime-defect findings map to 34 distinct owner bug records, because
findings 1 and 2 each cite both a Keiro report and the Kiroku report it
duplicates. By finding, the defects are:

- keiro: 7 (34–38, 63, 65);
- kiroku: 3 (1 and 2 through `kiroku-store` BUG-3, and 33);
- pgmq-hs: 3 (10–12);
- shibuya: 11 (17–19, 21, 22, 24, 26–30);
- shibuya-pgmq-adapter: 3 (15, 31, 32);
- shibuya-kafka-adapter: 6 (4–9).

Locally recorded owner status of those 34 records:

- 18 are reported;
- 14 are marked fixed by their owners: Kiroku BUG-3 and BUG-4, Shibuya BUG-2 to BUG-11, and Shibuya PGMQ adapter BUG-2 and BUG-3;
- 2 Keiro reports are duplicates of Kiroku BUG-3.

"Fixed" is the owner's classification. This round did not verify any fix:
both cohorts still pin the affected released versions, and post-fix
verification belongs to
[MasterPlan 2](../masterplans/2-close-the-verification-and-repair-loop-for-the-keiro-runtime-in-rounds.md).

## Priority for owner projects

| Priority | Owner record and finding | Why |
|---|---|---|
| 1 — data integrity | `mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-5`, [finding 8](../findings/8-kafka-later-retry-overwrites-earlier-barrier.md) | Two retries left offset 3 with no successful decision, yet the group committed offset 10. Reproduced on a clean local run and on alpha. |
| 1 — durable publication | `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-5`, [finding 36](../findings/36-keiro-stale-outbox-publisher-finalizes-new-claim.md) | A stale publisher marks another publisher's successful claim failed after reclaim, so the broker and the outbox disagree. Reproduced on a clean alpha run. |
| 2 — continuous consumption | `mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-3`, `mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-4`, [findings 6](../findings/6-kafka-broker-restart-ends-adapter-consumers.md) and [7](../findings/7-kafka-group-rebalance-ends-adapter-consumers.md); `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-3`, [finding 34](../findings/34-keiro-job-worker-exits-after-polling-backend-termination.md) | A broker restart, a group rebalance or a backend termination ends live workers while work remains. BUG-4 also appears in the assembled runtime with no injected fault. |
| 2 — workflow progress | `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-8`, [finding 63](../findings/63-keiro-child-completion-crash-strands-parent.md) | A child that crashes after its completion marker and before the parent wake leaves the parent suspended forever. The source is unchanged through keiro 0.19.0.0. |
| 2 — queue progress and retry budget | `mori://shinzui/shibuya-pgmq-adapter/okf/bug-reports/concepts/BUG-1`, [finding 15](../findings/15-shibuya-pgmq-long-poll-pool-starvation.md); `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-4`, `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-6`, [findings 35](../findings/35-keiro-long-poll-consumes-read-attempt-without-handler.md) and [37](../findings/37-keiro-long-poll-processors-starve-runtime-pool.md) | Long polls occupy a shared pool, stall work, or spend read attempts without delivering to the handler. No common root cause has been established. |
| 2 — failure classification | `mori://shinzui/pgmq-hs/okf/bug-reports/concepts/BUG-1`, [finding 10](../findings/10-pgmq-disconnects-are-classified-as-permanent.md) | A recoverable interruption is classified as permanent although the same pool recovers. |
| 3 — ordering, lifecycle, observability, operator surface | Kafka adapter BUG-1, BUG-2 and BUG-6; Shibuya BUG-1; Keiro BUG-7 and BUG-9; pgmq-hs BUG-3 (see the register) | Buffered retries and rebalances reorder or replay work. A forced stop finalizes after it returns. Pre-handler DLQ events have no process span. `keiro-ops` JSON renders DLQ ids with a derived `Show`. Partitioned notifications exceed their throttle. |

The table orders the work by observed impact. It does not replace the owners'
severity fields or assert that separate reports share a fix.

## Findings register

Cohort `released` means the pinned cohort described under
[Cohort and environment](#cohort-and-environment). A harness defect is in
Kenshou itself, so it has no runtime cohort.

| # | Finding | Component (owner) | Kind | Owner record | Cohort observed |
|---:|---|---|---|---|---|
| 1 | [Write-side worker heap growth](../findings/1-keiro-write-side-worker-heap-growth.md) | kiroku-store via keiro (kiroku) | Runtime defect | `mori://shinzui/kiroku/okf/bug-reports/concepts/BUG-3` (duplicate: `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-1`) | released; owner fixed in kiroku-store 0.9.0.1 |
| 2 | [Seed-backlog heap growth](../findings/2-keiro-seed-backlog-heap-growth.md) | kiroku-store via keiro (kiroku) | Runtime defect | `mori://shinzui/kiroku/okf/bug-reports/concepts/BUG-3` (duplicate: `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-2`) | released; owner fixed in kiroku-store 0.9.0.1 |
| 3 | [Harness thread growth during Keiro soaks](../findings/3-keiro-steady-restart-harness-threads.md) | Kenshou or keiro outbox restart path (open) | Unattributed/open | none | released |
| 4 | [Buffered retry leaves successors uncommitted](../findings/4-kafka-buffered-retry-leaves-successors-uncommitted.md) | shibuya-kafka-adapter | Runtime defect | `mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-1` | released (0.9.0.1) |
| 5 | [Buffered successors run before retry](../findings/5-kafka-buffered-successors-run-before-retry.md) | shibuya-kafka-adapter | Runtime defect | `mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-2` | released (0.9.0.1) |
| 6 | [Broker restart ends consumers](../findings/6-kafka-broker-restart-ends-adapter-consumers.md) | shibuya-kafka-adapter | Runtime defect | `mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-3` | released (0.9.0.1) |
| 7 | [Group rebalance ends consumers](../findings/7-kafka-group-rebalance-ends-adapter-consumers.md) | shibuya-kafka-adapter | Runtime defect | `mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-4` | released (0.9.0.1) |
| 8 | [Later retry overwrites earlier barrier](../findings/8-kafka-later-retry-overwrites-earlier-barrier.md) | shibuya-kafka-adapter | Runtime defect | `mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-5` | released (0.9.0.1) |
| 9 | [Rebalance replays committed offsets out of order](../findings/9-kafka-rebalance-replays-committed-offsets-out-of-order.md) | shibuya-kafka-adapter | Runtime defect | `mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-6` | released (0.9.0.1) |
| 10 | [Recoverable disconnects classified permanent](../findings/10-pgmq-disconnects-are-classified-as-permanent.md) | pgmq-hs | Runtime defect | `mori://shinzui/pgmq-hs/okf/bug-reports/concepts/BUG-1` (and `mori://shinzui/pgmq-hs/okf/improvement-requests/concepts/IR-4`) | released (0.6.1.0), PG 17 and 18 |
| 11 | [Concurrent reconciliation misreports creators](../findings/11-pgmq-concurrent-reconciliation-misreports-creators.md) | pgmq-hs | Runtime defect | `mori://shinzui/pgmq-hs/okf/bug-reports/concepts/BUG-2` (and `mori://shinzui/pgmq-hs/okf/improvement-requests/concepts/IR-5`) | released (0.6.1.0) |
| 12 | [Partitioned notifications bypass throttle](../findings/12-pgmq-partitioned-notifications-bypass-throttle.md) | pgmq-hs | Runtime defect | `mori://shinzui/pgmq-hs/okf/bug-reports/concepts/BUG-3` | released (0.6.1.0), PG 17 and 18 |
| 13 | [Partition recovery exceeds local bound](../findings/13-kiroku-network-partition-recovery-exceeds-local-bound.md) | kiroku-store | Documented limitation | `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-16` | released (0.8.0.1), PG 17 and 18 |
| 14 | [Retry and success counters indistinguishable](../findings/14-shibuya-retry-and-success-counters-are-indistinguishable.md) | shibuya-metrics | Documented limitation | `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-8` | released (0.9.0.3) and 0.10.0.0 |
| 15 | [Long polls starve acknowledgement](../findings/15-shibuya-pgmq-long-poll-pool-starvation.md) | shibuya-pgmq-adapter | Runtime defect | `mori://shinzui/shibuya-pgmq-adapter/okf/bug-reports/concepts/BUG-1` | released (0.16.0.0) and 0.16.1.0, PG 17 and 18 |
| 16 | [Same-member duplicate work](../findings/16-shibuya-kiroku-same-member-duplicate-work.md) | shibuya-kiroku-adapter (kiroku) | Documented limitation | `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-17` (depends on `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-15`) | released (0.5.1.2) and 0.5.1.3, PG 17 and 18 |
| 17 | [Forced stop can finalize late](../findings/17-shibuya-forced-stop-can-finalize-late.md) | shibuya-core | Runtime defect | `mori://shinzui/shibuya/okf/bug-reports/concepts/BUG-1` | released (0.9.0.3) and 0.10.0.0 |
| 18 | [Duplicate processor IDs drop a handle](../findings/18-shibuya-duplicate-processor-ids-drop-a-live-handle.md) | shibuya-core | Runtime defect | `mori://shinzui/shibuya/okf/bug-reports/concepts/BUG-2` | released (0.9.0.3); owner fixed in 0.10.0.0 |
| 19 | [Nonpositive concurrency removes bound](../findings/19-shibuya-nonpositive-concurrency-removes-handler-bound.md) | shibuya-core | Runtime defect | `mori://shinzui/shibuya/okf/bug-reports/concepts/BUG-3` | released (0.9.0.3); owner fixed in 0.10.0.0 |
| 20 | [Keyed worker failure awaits input exhaustion](../findings/20-shibuya-keyed-worker-failure-awaits-input-exhaustion.md) | shibuya-core | Documented limitation | `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-6` | released (0.9.0.3); passes on 0.10.0.0 |
| 21 | [Halt does not wake idle intake](../findings/21-shibuya-halt-does-not-wake-idle-intake.md) | shibuya-core | Runtime defect | `mori://shinzui/shibuya/okf/bug-reports/concepts/BUG-4` | released (0.9.0.3); owner fixed in 0.10.0.0 |
| 22 | [Exhausted finalizer reported as graceful halt](../findings/22-shibuya-exhausted-finalizer-is-reported-as-graceful-halt.md) | shibuya-core | Runtime defect | `mori://shinzui/shibuya/okf/bug-reports/concepts/BUG-5` | released (0.9.0.3); owner fixed in 0.10.0.0 |
| 23 | [Blocking adapter shutdown has no total deadline](../findings/23-shibuya-blocking-adapter-shutdown-has-no-total-deadline.md) | shibuya-core | Documented limitation | `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-6` | released (0.9.0.3); passes on 0.10.0.0 |
| 24 | [Throwing adapter shutdown skips siblings](../findings/24-shibuya-throwing-adapter-shutdown-skips-siblings.md) | shibuya-core | Runtime defect | `mori://shinzui/shibuya/okf/bug-reports/concepts/BUG-6` | released (0.9.0.3); owner fixed in 0.10.0.0 |
| 25 | [Startup cancellation evidence gap](../findings/25-shibuya-startup-cancellation-historical-evidence-gap.md) | shibuya-core | Unattributed/open | `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-6` (review `mori://shinzui/shibuya/okf/reviews/concepts/REV-3`) | released (0.9.0.3) |
| 26 | [Stale activity marks healthy work stuck](../findings/26-shibuya-stale-activity-marks-healthy-work-stuck.md) | shibuya-metrics | Runtime defect | `mori://shinzui/shibuya/okf/bug-reports/concepts/BUG-7` | released (0.9.0.3); owner fixed in 0.10.0.0 |
| 27 | [Health probes ignore terminal lifecycle](../findings/27-shibuya-health-probes-ignore-terminal-lifecycle.md) | shibuya-metrics | Runtime defect | `mori://shinzui/shibuya/okf/bug-reports/concepts/BUG-8` | released (0.9.0.3); owner fixed in 0.10.0.0 |
| 28 | [WebSocket disconnect leaks slots](../findings/28-shibuya-websocket-disconnect-leaks-slots.md) | shibuya-metrics | Runtime defect | `mori://shinzui/shibuya/okf/bug-reports/concepts/BUG-9` | released (0.9.0.3); owner fixed in 0.10.0.0 |
| 29 | [Disabled WebSocket still upgrades](../findings/29-shibuya-disabled-websocket-still-upgrades.md) | shibuya-metrics | Runtime defect | `mori://shinzui/shibuya/okf/bug-reports/concepts/BUG-10` | released (0.9.0.3); owner fixed in 0.10.0.0 |
| 30 | [WebSocket unsubscribe still delivers](../findings/30-shibuya-websocket-unsubscribe-still-delivers-updates.md) | shibuya-metrics | Runtime defect | `mori://shinzui/shibuya/okf/bug-reports/concepts/BUG-11` | released (0.9.0.3); owner fixed in 0.10.0.0 |
| 31 | [Exhausted acknowledgement skips hook](../findings/31-shibuya-pgmq-exhausted-acknowledgement-skips-hook.md) | shibuya-pgmq-adapter | Runtime defect | `mori://shinzui/shibuya-pgmq-adapter/okf/bug-reports/concepts/BUG-2` | released (0.16.0.0); owner fixed in 0.16.1.0 |
| 32 | [Dead-letter retry duplicates a copy](../findings/32-shibuya-pgmq-dead-letter-retry-duplicates-copy.md) | shibuya-pgmq-adapter | Runtime defect | `mori://shinzui/shibuya-pgmq-adapter/okf/bug-reports/concepts/BUG-3` | released (0.16.0.0); owner fixed in 0.16.1.0 |
| 33 | [Partial group acquisition strands members](../findings/33-shibuya-kiroku-partial-group-acquisition-leaks.md) | shibuya-kiroku-adapter (kiroku) | Runtime defect | `mori://shinzui/kiroku/okf/bug-reports/concepts/BUG-4` | released (0.5.1.2); owner fixed in 0.5.1.3 |
| 34 | [Job worker exits after backend termination](../findings/34-keiro-job-worker-exits-after-polling-backend-termination.md) | keiro job queue | Runtime defect | `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-3` | released (0.17.0.0) |
| 35 | [Long poll consumes read attempt](../findings/35-keiro-long-poll-consumes-read-attempt-without-handler.md) | keiro job queue | Runtime defect | `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-4` | released (0.17.0.0) |
| 36 | [Stale outbox publisher finalizes new claim](../findings/36-keiro-stale-outbox-publisher-finalizes-new-claim.md) | keiro outbox | Runtime defect | `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-5` | released (0.17.0.0) |
| 37 | [Long-poll processors starve runtime pool](../findings/37-keiro-long-poll-processors-starve-runtime-pool.md) | keiro job queue | Runtime defect | `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-6` | released (0.17.0.0) |
| 38 | [Pre-handler dead-letter lacks process span](../findings/38-keiro-pre-handler-dead-letter-lacks-process-span.md) | keiro telemetry | Runtime defect | `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-7` | released (0.17.0.0) |
| 39 | [GCS token cache survives expiry](../findings/39-kenshou-gcs-token-cache-survives-expiry.md) | Kenshou cell client | Harness defect repaired | none | — |
| 40 | [Kafka scenarios omitted broker requirement](../findings/40-kenshou-kafka-scenarios-omit-broker-requirement.md) | Kenshou catalog | Harness defect repaired | none | — |
| 41 | [Evidence destination checked after upload](../findings/41-kenshou-cell-evidence-base-uri-check-runs-after-uploads.md) | Kenshou recorder | Harness defect repaired | none | — |
| 42 | [Grouped-read benchmark ignored its knobs](../findings/42-kenshou-grouped-read-benchmark-ignored-its-workload-knobs.md) | Kenshou PGMQ scenario | Harness defect repaired | none | — |
| 43 | [Write-side soak used default diagnosis window](../findings/43-keiro-write-side-soak-uses-default-diagnosis-window.md) | Kenshou Keiro scenario | Harness defect repaired | none | — |
| 44 | [Write-side default soak does not quiesce](../findings/44-keiro-write-side-default-soak-does-not-quiesce.md) | keiro write side or capacity (open) | Unattributed/open | none | released |
| 45 | [Recorder rejects empty-string knob](../findings/45-verification-record-rejects-empty-string-knob.md) | Kenshou verification profile | Harness defect repaired | none | — |
| 46 | [Command writers grow heap in low-rate soak](../findings/46-keiro-command-writers-grow-heap-in-low-rate-soak.md) | Kenshou writer role or keiro/kiroku command path (open) | Unattributed/open | none | released |
| 47 | [Alpha loses its lease during outbox soak](../findings/47-alpha-cell-loses-lease-during-outbox-soak.md) | cell lease client, GCS or idle stop (open) | Unattributed/open | none | released (infrastructure) |
| 48 | [Planner drops knob pinned for another scenario](../findings/48-plan-silently-drops-knob-pinned-for-another-scenario.md) | Kenshou planner | Harness defect repaired | none | — |
| 49 | [Four-hour inbox soak times out before sealing](../findings/49-four-hour-inbox-soak-times-out-before-sealing.md) | Kenshou cell wall-clock cap | Harness defect repaired; finalization cost unattributed | none | — |
| 50 | [Verdict writers omit assertion counters](../findings/50-verdict-writers-omit-required-assertion-counters.md) | Kenshou verdict writers | Harness defect repaired | none | — |
| 51 | [Inbox handler counter counts unused sequence](../findings/51-inbox-handler-counter-counts-an-unused-sequence.md) | Kenshou inbox scenarios | Harness defect repaired | none | — |
| 52 | [Best-effort fixture propagates key failures](../findings/52-outbox-best-effort-fixture-propagates-key-failures.md) | Kenshou synthetic broker | Harness defect repaired | none | — |
| 53 | [Terminal oracle rejects single-attempt exhaustion](../findings/53-outbox-terminal-oracle-rejects-single-attempt-exhaustion.md) | Kenshou terminal oracle | Harness defect repaired | none | — |
| 54 | [Terminal replay accepts duplicate final row](../findings/54-terminal-replay-accepts-duplicate-final-row-substitution.md) | Kenshou terminal recomputer | Harness defect repaired | none | — |
| 55 | [Polling recovery reuses pre-fault completions](../findings/55-polling-recovery-reuses-pre-fault-completions.md) | Kenshou polling-fault scenario | Harness defect repaired | none | — |
| 56 | [Bounded trace probe retains evicted spans](../findings/56-bounded-trace-probe-retains-evicted-spans.md) | Kenshou tracing probe | Harness defect repaired | none | — |
| 63 | [Child completion crash strands parent](../findings/63-keiro-child-completion-crash-strands-parent.md) | keiro durable workflows | Runtime defect | `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-8` | released (0.17.0.0); source unchanged through 0.19.0.0 |
| 64 | [Payload relied on ambient rpk](../findings/64-kenshou-payload-relies-on-ambient-rpk.md) | Kenshou payload | Harness defect repaired | none | — |
| 65 | [keiro-ops DLQ id uses derived Show](../findings/65-keiro-ops-dlq-message-id-uses-derived-show.md) | keiro-ops | Runtime defect | `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-9` | released (0.17.0.0); still present at 0.19.0.0 source |
| 66 | [Hot ledger account serialises dispatcher](../findings/66-hot-ledger-account-serialises-the-shop-dispatcher.md) | keiro/kiroku per-stream concurrency | Documented limitation | none | released (cell alpha) |

Some scenarios also scope known defects that have no numbered finding:

- **Released `hw-kafka-client` native-memory growth**, scoped to
  `mori://shinzui/hw-kafka-client/commits/6caed636898a78e9f6e5a9c93eeb5562cbb2580a`.
  The 500 records/s churn soak on alpha grew native memory at about 330 MB/h
  while the post-major heap stayed stable. At 100 records/s it was stable.
- **Fenced Kafka member stays alive**, scoped to
  `mori://shinzui/keiro/masterplans/23-make-the-kafka-consumer-streaming-stack-surface-fatal-errors-and-close-deterministically`.
  On the released cohort the fenced member stays alive and idle. The head
  cohort passes.
- **Keiro drain and redrive send-before-delete windows.** These are documented
  in `mori://shinzui/keiro/okf/user-documentation/concepts/DOC-25`.
- **Trace propagation.** The released runtime carries a trace only across
  Kafka and PGMQ. It does not carry one across the event store, an outbox row
  or a workflow resume.

## Open and unattributed

Each item below carries to the next round. It closes with an owner record or a
documented non-bug disposition.

- **[Finding 3](../findings/3-keiro-steady-restart-harness-threads.md).**
  Haskell threads rise with outbox publisher restarts, and the retained
  component is unidentified. A forced-GC control suggests that collection
  timing contributes, but nothing assigns the growth to the harness or to Keiro.
- **[Finding 25](../findings/25-shibuya-startup-cancellation-historical-evidence-gap.md).**
  The startup-cancellation risk is source-confirmed by the owner. A clean
  released-cohort reproduction has not been made, so no bug report exists.
- **[Finding 44](../findings/44-keiro-write-side-default-soak-does-not-quiesce.md).**
  At the default 200 commands/s, the write side does not drain within two
  minutes, and stage counts show backlog. The extended-drain control
  (`specs/keiro-write-side-extended-drain.json`) is checked in but was not run.
  It would decide between capacity and lost work.
- **[Finding 46](../findings/46-keiro-command-writers-grow-heap-in-low-rate-soak.md).**
  Writer heaps grow at 20 commands/s. The writers-only, no-snapshot and
  generate-only controls are checked in but were not run. Kiroku BUG-3, fixed
  in kiroku-store 0.9.0.1 and pinned by neither cohort, is the leading suspect.
- **[Finding 47](../findings/47-alpha-cell-loses-lease-during-outbox-soak.md).**
  The alpha driver guest terminated and the lease was lost. The cause is not
  yet attributed to the lease client, GCS or the idle-stop path.
- **EP-11 post-rebalance slow drain.** After a partition moves by rebalance,
  drain runs at about three records per second, with and without the proxy.
  It remains unattributed until a head-cohort run separates the released
  `hw-kafka-client` from the fork.
- **EP-11 stability soak at 500 records/s.** It has no verdict: cell run
  `01a10549-a51e-7126-b5b5-fc52375f2e73` was cancelled by lease loss after the
  operator's credentials expired. The 100 records/s run was `Stable`.
- **EP-15 I5 pick redeliveries.** At 20 orders/s on alpha,
  `paused-lease-holder`, `rolling-restart`, `sigkill-role` and `sigkill-storm`
  failed only I5. Every other invariant held. The oracle allowance for
  resume-worker disturbances (`7e3820e`) has unit and negative tests, but no
  cell run confirms it. The four failed outcomes stand.
- **EP-13 process-soak residual resource flags.** After the repair in finding
  56, residual heap and thread slopes in the SDK process soaks remain
  unattributed.

## Cohort and environment

The pinned [released cohort](../../cohort/released.json) includes:

- Keiro and keiro-ops 0.17.0.0;
- Kiroku Store 0.8.0.1 and its Shibuya adapter 0.5.1.2;
- Shibuya Core and Metrics 0.9.0.3;
- the Shibuya PGMQ adapter 0.16.0.0;
- the Shibuya Kafka adapter 0.9.0.1 and `hw-kafka-client` 5.3.0;
- pgmq-hs 0.6.1.0.

Runs focus on durable PostgreSQL 18. Several substrate checks also have
PostgreSQL 17 controls. Broker scenarios use a private Redpanda broker.
Where a finding says a behavior "passes on" a newer version, that was a
focused probe of the newer package, not a whole-runtime run on a fixed cohort.

## Evidence quality

- **Clean, digest-linked evidence.** The
  [historical bundle](../verification/) holds 192 records: 186 runs and six
  comparisons, all from clean harness trees. 85 come from sealed, verified
  runs on cell alpha (PostgreSQL 18). The other 107 are clean local
  investigations. Of 96 attestations, 86 are confirmed and 10 incomplete.
  Incomplete ones include records whose business verdict cannot yet be
  replayed independently, such as the Kafka rebalance and stability records
  and the first Keiro outbox record. Incomplete attestations stay visible
  ([ADR-18](../adr/0018-keep-verification-records-immutable-and-derive-baselines.md)).
- **Cell-backed findings.** These findings have clean alpha cell evidence:
  - 8 (BUG-5 reproduced on alpha);
  - 36 (stale outbox publisher);
  - 35 and 37 (queue long-poll runs);
  - 1 and 2 (their Kiroku BUG-3 heap signature reappeared in the alpha
    write-side soak; the findings' own runs are local);
  - 3, 44, 46, 47, 49, 42, 64 and 66.

  The Kafka churn soak and the EP-15 default-rate runs are also cell evidence.
- **Local functional evidence only.** Most other runtime-defect findings were
  reproduced in sealed local runs. Those runs are ignored by Git, and the
  finding files give their IDs and commands. The 2026-09-29 audit found that
  findings 1–9, 14–16 and 34–38 cited only dirty-harness local runs at that
  time. Findings 8, 35 and 36 have since gained clean evidence. Local
  benchmark, soak and overhead numbers from the busy workstation are not
  baseline measurements. That includes EP-15's 5 orders/s runs.
- **Performance.** No performance comparison is promoted. Five-pair A/A
  controls passed for PGMQ read/ack and invisible backlog. The layer-ladder
  and queue-worker p99 results were inconclusive. The grouped-read benchmark
  is excluded (finding 42).
- **Excluded results.** These attempts are excluded and stay in the record:
  - the interrupted layer-ladder pair (finding 39);
  - the brokerless Kafka attempt (finding 40);
  - the shortened write-side soak (finding 43);
  - the dropped-knob repeat (finding 48);
  - the first four-hour inbox attempt (finding 49);
  - partial outbox samples after lease loss (finding 47).
