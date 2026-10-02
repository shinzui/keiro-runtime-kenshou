---
id: 13
slug: cover-the-keiro-outbox-inbox-and-job-queue
title: "Cover the keiro outbox, inbox and job queue"
kind: exec-plan
created_at: 2026-09-20T17:15:35Z
intention: "intention_01m2zvy0gje40tdsdragvzr3tq"
master_plan: "docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-20T17:15:35Z
  revisions:
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T02:59:06Z
      mode: "implement"
      note: "Started outbox broker and first durable scenario"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T16:38:24Z
      mode: "implement"
      note: "Corrected synthetic broker partition offsets and added durable concurrency oracle"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T18:53:18Z
      mode: "implement"
      note: "Strengthened outbox terminal-state broker and metadata verdicts"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T19:22:49Z
      mode: "implement"
      note: "Verified disjoint outbox publisher ownership from callback intervals"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-29T17:33:27Z
      mode: "implement"
      note: "Linked five Keiro reports locally and restored baseline soak scope."
    - model: "gpt-6"
      harness: "codex"
      at: 2026-09-29T20:33:51Z
      mode: "implement"
      note: "Recorded a clean leased-cell reproduction of the stale outbox publisher defect."
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-30T01:18:06Z
      mode: "implement"
      note: "Registered the outbox soak pair and verified a functional local smoke."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-09-30T21:20:07Z
      mode: "implement"
      note: "Added continuous queue throughput workers, polling and pool controls, and a multiplicity-aware conservation oracle."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-01T16:33:42Z
      mode: "implement"
      note: "Implemented process-isolated outbox soak diagnosis and recovered the sealed four-hour inbox evidence."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-01T17:36:58Z
      mode: "implement"
      note: "Implemented native store and OpenTelemetry endpoint coverage for messaging contracts and benchmarks."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-01T19:39:23Z
      mode: "implement"
      note: "Strengthened queue lease extension acceptance with database-clock and direct read-count evidence."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-01T20:31:37Z
      mode: "implement"
      note: "Strengthened inbox persistence and effect acceptance with direct SQL observations."
---

# Cover the keiro outbox, inbox and job queue

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

keiro is the top library of the keiro runtime (a cohort of Haskell event-sourcing and messaging libraries). Three of its components form the messaging edge of every service: the outbox (a PostgreSQL table that durably holds integration events until a publisher hands them to a broker), the inbox (a PostgreSQL table that lets a consumer run its handler once per received message even though brokers redeliver), and the job queue (`keiro-pgmq`, typed background jobs on PGMQ, a message queue built from PostgreSQL tables). Each ships with example-based unit tests that run in one process against a PostgreSQL with `fsync=off`, where "crash" means a thrown exception. Nothing today proves their documented guarantees under real process death, competing processes, connection loss or hours of load, and nothing measures them with durable storage.

After this plan a maintainer can, from this repository, list and run about forty scenarios under the identifiers `keiro/outbox/…`, `keiro/inbox/…` and `keiro/queue/…`. They establish that every outbox row reaches `sent`, `rejected` or `dead` under every ordering policy and backoff schedule; that per-key publish order holds when enqueues are serialized and measurably breaks in the one situation keiro documents (concurrent inline enqueues of one key); that a publisher killed with `SIGKILL` between the broker's acknowledgement and the database mark produces bounded duplicates and no loss, and that only the maintenance pass reclaims its rows; that the inbox is effectively-once within its retention window for every dedupe policy, persistence mode and idempotence owner, and that the documented garbage-collection race really can re-run a handler; that a job is redelivered at the visibility timeout rather than the retry delay, is dead-lettered before its handler once its read count exceeds the retry ceiling, keeps strict per-group order under `FifoHeads` with competing worker processes, and that `runJobWorkers` survives a database connection being killed while it polls — the exact test keiro itself carries as `pendingWith`. Benchmarks give enqueue-to-publish latency, inbox intake throughput (table-backed versus delegated) and job throughput by ordering, batch size, visibility timeout and polling mode on a durable PostgreSQL; soaks watch `keiro_outbox`, `keiro_inbox` and the PGMQ tables grow with and without garbage collection; and every scenario can be run with OpenTelemetry tracing and metrics switched on or off so their cost is measured rather than assumed.

To see it working after implementation, run `cabal run kenshou -- list 'keiro/outbox/**'` and then `cabal run kenshou -- run keiro/outbox/concurrency/crash-between-publish-and-mark --dim pg.durability=durable --out runs/`. The command exits 0 and the run directory contains `verdicts/no-loss.json`, `verdicts/bounded-duplicates.json` and `verdicts/reclaimed-only-by-maintenance.json`, each naming how many rows were enqueued, how many broker records were observed, which process was killed when, and which rows were duplicated.


## Progress

The non-soak baseline is in place. The remaining work is to deepen specific scenario arms, finish component telemetry serving, run the planned soaks, and close the documentation and acceptance gaps. The current baseline pass includes the soaks; their outcomes remain open. These entries track deliverables rather than individual runs; detailed historical steps remain in git history and the run artifacts.

- [x] (2026-09-24) Outbox baseline: eleven correctness/concurrency/crash scenarios are registered and passed the default durable sweep, with the documented inline-order limitation and BUG-5 recorded as scoped expected failures. Publisher, enqueuer, maintenance, subscription replay, and synthetic broker roles are wired.
- [x] (2026-09-24) Inbox baseline: envelope, effectively-once matrix, poison accounting, batch intake, process race, and GC race scenarios have durable evidence. The GC race reproduces the documented retention-window failure under a realised schedule.
- [x] (2026-09-24) Queue baseline: eleven scenarios are registered and passed the default durable sweep, including the 1,600-job FIFO ordering case. The known polling, DLQ, redrive, and pool-isolation defects are scoped and linked upstream.
- [x] (2026-09-24) Measurement baseline: all seven benchmark identifiers produce durable measurement artifacts and no-loss or effect oracles; representative longer runs reached benchmark grade. One paired comparison was inconclusive under the three-pair policy, and both three-block overhead matrices completed with no failed child runs. Outbox and queue telemetry contracts passed with tracing and metrics enabled and disabled.
- [x] (2026-09-29) Reproduced owner BUG-5 on alpha with a clean released-cohort payload and durable PostgreSQL 18. Verified cell run `01a0eed0-4d26-7365-afb3-8a03d234d014` contains nested run `01a0eec4-bd55-7786-804f-bda62c6ac388`: P2 appended its broker record, then stale P1 left the row failed. Only the two scoped finalization checks failed. The [historical record](../verification/runs/keiro/2026/09/01a0eec4-bd55-7786-804f-bda62c6ac388.md) is digest-linked; its [attestation](../verification/attestations/2026/09/01a0eee9-5ccf-72b7-bcdf-54f5ec80c02a.md) remains incomplete solely because the Keiro VC-1 oracle is unavailable.
- [x] (2026-09-29) Added three clean alpha cell queue records on the released cohort. [Backend termination](../verification/runs/keiro/2026/09/01a0eef1-60b7-71f4-bcc1-c4d4eb6ef470.md) did not reproduce BUG-3 after five injected faults; the earlier local failures remain open for timing isolation. [Long-poll redelivery](../verification/runs/keiro/2026/09/01a0eef1-bb2c-73f5-b32a-1046f297db83.md) reproduced BUG-4's three scoped failures. [Pool isolation](../verification/runs/keiro/2026/09/01a0eef1-bb33-75d4-a1b7-f167d99951aa.md) passed its characterization checks while observing stalled three- and six-processor arms, consistent with BUG-6. All three cell runs verified their sealed trees and used durable PostgreSQL 18.
- [x] (2026-09-29) Revised the BUG-3 backend-termination schedule to kill a worker backend while its PGMQ read is observably blocked by a table lock, instead of killing an idle backend after a completed batch. The 37 Keiro package tests pass.
- [x] (2026-09-29) Ran that revision-2 schedule on clean alpha payload `5b52c93`. [Nested run](../verification/runs/keiro/2026/09/01a0ef2f-0b70-77e1-9c32-cd4283e1fd4d.md) passed after all five blocked-read backend terminations. BUG-3 remains reported because earlier local runs failed; this is a documented environment or error-path reproduction gap.
- [x] (2026-09-29) Completed that 11-scenario sweep as verified alpha cell run `01a0ef4f-ce12-74f3-823c-360e44b1ff93`, using clean released payload `5b52c93` and durable PostgreSQL 18. All 11 nested runs are [digest-linked](../verification/runs/keiro/2026/09/index.md). Nine scenarios passed, including FIFO ordering, atomic worker dead-lettering, lease extension, outcome semantics, telemetry, ordinary-poll crash redelivery, and runtime pool characterization. Two reproduced the deliberately scoped `mori://shinzui/keiro/okf/user-documentation/concepts/DOC-25` send-before-delete windows (`dead-letter-window-drain-path` and `redrive-window`); both are nonblocking known defects, not new owner reports. The ordinary-poll redelivery pass does not close long-poll BUG-4, which a separate clean run reproduced.
- [x] (2026-09-29) Registered the outbox table-growth full/reduced soak pair. It continuously enqueues against two publishers, periodically cancels and restarts one in-process publisher, runs maintenance and optional sent-row GC, samples the outbox relation, and checks broker coverage, bounded duplicates, retained rows, relation growth, dead tuples, and process leaks. A one-minute, low-rate local functional smoke completed seven restarts with no business-verdict failure; its short leak signal and all workstation measurements are excluded from the baseline. The planned process-isolated `SIGKILL` arm, per-process leak verdicts, and controlled reduced/full runs remain pending.
- [x] (2026-09-29) Registered the inbox dedupe-window full/reduced soak pair. It schedules early and late redeliveries for a continuous fresh stream while receipt GC runs, checks classification and effect counts, and samples inbox relation growth. A one-minute local wiring smoke processed 71 fresh messages, suppressed all 71 early deliveries, reprocessed all 71 late deliveries, and observed 142 effects without delivery or GC errors. The short local leak signal is excluded from baseline; controlled reduced/full runs remain pending.
- [x] (2026-09-29) Registered the queue/DLQ growth full/reduced soak pair. Two continuous worker loops process fresh jobs with a configurable terminal-dead share; periodic DLQ archiving, a quiesced final archive and purge, main/DLQ relation sampling, exact dead placement, and leak checks are wired. A one-minute local maintenance-on smoke handled all 71 accepted jobs once and archived all 15 dead jobs; all nine business checks held. The maintenance-off smoke likewise handled 71 jobs and retained exactly 15 active DLQ rows. The short leak verdicts were inconclusive and workstation resource measurements are excluded. Process-isolated worker leak verdicts and controlled reduced/full runs remain pending.
- [x] (2026-09-29) Ran a clean five-minute outbox table-growth control on alpha as verified cell run `01a0f014-6de1-70a5-bb0e-ee6a92a42336`, [digest-linked nested run](../verification/runs/keiro/2026/09/01a0f013-99ac-7155-aa00-bab4827de47e.md). All eight business verdicts held: 621 accepted messages reached 621 unique broker records after ten publisher restarts, with no backlog or errors; GC retained 61 rows, and sampled relation and dead-tuple bounds held. The overall run failed on a ten-thread main-harness growth signal that matches the restart count, tracked in [finding 3](../findings/3-keiro-steady-restart-harness-threads.md); its heap probe had no post-major samples. A no-restart or forced-GC control, process-isolated publisher arm, and twenty-minute reduced run remain pending.
- [x] (2026-09-30) Ran the inbox dedupe-window soak for five minutes on clean alpha: verified cell `01a0f01c-32aa-73dd-b2b6-f51199d47ddc`, [digest-linked nested run](../verification/runs/keiro/2026/09/01a0f00a-5f36-746a-b7de-4e66168494da.md). All eight business checks held. The run classified 621 fresh deliveries, suppressed 621 early redeliveries, reprocessed 621 late redeliveries, and counted 1,242 effects; no delivery or GC errors remained. Retention and sampled relation and dead-tuple growth stayed within their bounds. The overall result was inconclusive because the post-major heap interval straddled the growth threshold, although threads, file descriptors, OS threads, and connections were stable. The twenty-minute default-rate result is recorded below.
- [x] (2026-09-30) Repeated the five-minute outbox soak on clean alpha as verified cell `01a0f025-946f-73e8-bfc9-8f7d0b79d871`, [digest-linked nested run](../verification/runs/keiro/2026/09/01a0f01d-96e0-747d-838f-053d4518fb4f.md). All eight business checks held and ten restarts again matched a 142-to-152 main-thread rise. [Finding 48](../findings/48-plan-silently-drops-knob-pinned-for-another-scenario.md) shows the planner omitted the requested forced-major-GC pin because this scenario does not declare it. This repeat is excluded as a GC control; the planner now rejects such a pin. The resolved no-restart result is recorded below.
- [x] (2026-09-30) Ran the matched five-minute outbox no-restart control on clean alpha as verified cell `01a0f062-ff85-74d4-ba79-b9f287a6c58e`, [digest-linked nested run](../verification/runs/keiro/2026/09/01a0f02e-688c-7400-a8d6-c2a74ac42e44.md). All eight business checks held over 621 accepted messages and 621 unique broker records; the main Haskell thread count stayed flat at 141. Its overall verdict was inconclusive only because no eligible post-major heap points were captured. The earlier ten-thread rise is therefore restart-linked, while harness-versus-Keiro ownership remains open. The revision-2 forced-major-GC result is recorded below.
- [x] (2026-09-30) Ran the outbox revision-2 forced-major-GC diagnostic on clean alpha as verified cell `01a0f069-e617-717d-a767-e9f4fbd5b134`, [digest-linked nested run](../verification/runs/keiro/2026/09/01a0f055-c3bf-774f-9e85-993b6c0d5bb6.md). The 5,000 ms knob was resolved and produced 40 post-major heap points. All eight business checks held over 621 messages and ten restarts; main threads stayed between 142 and 144 throughout the steady window. The heap interval straddled the growth floor, so the overall result remained inconclusive. This is a collection-timing diagnostic, not a throughput comparison or a Keiro leak attribution. The twenty-minute default-rate outbox result is recorded below.
- [x] (2026-09-30) Ran the twenty-minute default-rate outbox soak on clean alpha as verified cell `01a0f070-83c2-75cb-a4f0-515241b13d94`, [digest-linked nested run](../verification/runs/keiro/2026/09/01a0f01e-9ec4-7335-94e8-280a36cf2eac.md). All eight business checks held over 24,202 accepted messages and 24,202 distinct broker records after 20 publisher restarts, with no backlog, duplicate, publisher or maintenance error; sampled relation and dead-tuple bounds held. The main Haskell thread count rose from 142 to 157 and the overall outcome failed on that diagnostic signal; native bytes, OS threads, descriptors and connections were stable, and the heap probe had no eligible post-major points. [Finding 3](../findings/3-keiro-steady-restart-harness-threads.md) remains unattributed pending a minimal supervisor control.
- [x] (2026-09-30) Ran the clean five-minute queue/DLQ soak on alpha as verified cell `01a0f02b-eed5-713b-a6b1-336c5f46b0b4`, [digest-linked nested run](../verification/runs/keiro/2026/09/01a0f021-2f7f-7272-86c4-938bd4e7663b.md). All nine business checks held: 1,551 accepted jobs were handled once, the main queue drained, and all 78 terminal jobs reached the archive, with zero worker or maintenance errors. The short heap and relation trends were inconclusive, while threads, descriptors, and connections remained stable. The twenty-minute default-rate reduced run is recorded below.
- [x] (2026-09-30) Ran the twenty-minute default-rate queue/DLQ soak on clean alpha as verified cell `01a0f032-84d0-7322-9c36-841044f755f1`, [digest-linked nested run](../verification/runs/keiro/2026/09/01a0f027-6fcb-77d8-889d-78ab23e87e4c.md). All nine business checks held over 6,051 accepted and exactly-once handled jobs; the main queue drained, 303 terminal jobs reached the archive, and worker and maintenance errors remained zero. Sampled main-table size was flat and DLQ growth stayed bounded. The overall result was inconclusive because no eligible post-major heap points were captured; native memory, thread, descriptor, and connection checks were stable. A forced-major-GC diagnostic control is needed before deciding the heap gate; this run does not establish a Keiro leak.
- [x] (2026-09-30) Ran the matched twenty-minute queue/DLQ forced-major-GC diagnostic on clean alpha as verified cell `01a0f089-f6a8-715c-8c36-460f9cc54eeb`, [digest-linked nested run](../verification/runs/keiro/2026/09/01a0f056-3861-703f-9c5d-f1a689409a8c.md). The overall outcome passed: all nine business checks held over 6,051 exactly-once handled jobs, including 303 terminal jobs archived, with no worker or maintenance errors. Forty-one post-major heap points classified the main heap stable; Haskell threads stayed at 140, and native memory, OS threads, descriptors, and connections were stable. The main queue table was flat across comparison windows and DLQ growth stayed within its bound. This resolves the reduced queue soak's heap-data gap as a forced-GC diagnostic; forced collection perturbs latency, so its throughput is not a default-rate baseline. The later four-hour inbox attempt timed out before sealing, as recorded below.
- [x] (2026-09-30) Ran the twenty-minute default-rate inbox dedupe-window soak on clean alpha as verified cell `01a0f04a-bc43-7546-b7b2-20d47c665003`, [digest-linked nested run](../verification/runs/keiro/2026/09/01a0f027-28c8-74bc-873a-f857e53473cd.md). The overall outcome passed: all eight business checks held over 2,421 fresh deliveries, 2,421 suppressed early duplicates, 2,421 late reprocessings and 4,842 effects, with no delivery or GC errors. The sampled inbox table stayed at 401,408 bytes across comparison windows. Forty eligible post-major heap points classified heap stable, and the other bounded-resource probes were stable. The reduced default-rate inbox soak gate is satisfied; its full-duration form and other inbox matrix arms remain open.
- [x] (2026-09-30) Added the optional `diagnose.major-gc-interval-ms` knob to all three messaging soak pairs, with a dedicated post-major heap series used only when the interval is positive. The default remains zero and preserves historical behavior. Forced collection perturbs latency, so its controls diagnose heap retention and are not benchmark or throughput baselines. The 37 Keiro package examples pass; controlled cell execution remains open.
- [x] (2026-09-30) Added queue throughput revision 2 with continuous-worker, polling, pool-size, and runtime batch controls. Five short durable PostgreSQL 18 arms held all three business verdicts with zero worker errors; performance remained inconclusive under the sample-count gate. The 38-example package suite includes a multiplicity-aware oracle mutation check. Controlled comparisons and the remaining provision variation stay open; functional run IDs are listed below.
- [x] (2026-09-30) Added queue throughput revision 3 native worker collection and JSON/Prometheus serving, plus `worker-metrics-contract`. All eight durable PostgreSQL 18 contract arms passed across four metrics modes and tracing off/in-memory; four throughput integration controls held every business check. The 40-example package suite passes. Native counters remain supporting telemetry, independent of business and timing oracles; controlled performance and broader queue fault coverage remain open.
- [x] (2026-09-30) Recovered full inbox cell attempt `01a0f09f-4259-700c-b501-ceb1848f8ef3` as a verified outer infrastructure failure. Its journal confirms the 14,700-second wall-clock timeout after all eight business verdict files were written, but before nested run `01a0f096-16cd-75a2-8371-d793177c4e8d` sealed a result or manifest. [Finding 49](../findings/49-four-hour-inbox-soak-times-out-before-sealing.md) preserves the evidence; partial artifacts are excluded from baseline acceptance. The client now adds ten minutes per soak to its shared five-minute margin, with 107 passing remote examples. A fresh same-seed full-duration retry is submitted, as described in the handoff below.
- [x] (2026-09-30) Completed the clean five-pair queue-worker A/A on alpha under one lease. All ten nested runs passed at benchmark grade with full raw samples, zero operation failures, 153,896 jobs handled exactly once, and 250 verified manifested files. [Saved comparison and experiment design](../reports/2026-09-30-queue-worker-comparisons.md) preserve its inconclusive p99 intervals; throughput, p50, allocation, and maximum live bytes passed. The unchanged policy has no health or compatibility rejection reason. All ten arms are digest-linked investigation records. The twenty execution-shape and polling trials completed with passing business checks; clean replay reproduced their inconclusive execution-shape and polling-latency regression results; both formal comparisons and all twenty arms are digest-linked, and both comparison attestations are confirmed. P99 repeatability and broader performance acceptance remain open.
- [x] (2026-09-30) Completed both five-pair queue configuration comparisons on clean alpha payload `9c2c9b8`: twenty benchmark-grade runs held all business checks over 307,782 exactly-once jobs, with 500 manifested files verified. Clean replay from `71f5a9e` reproduced every provisional metric and saved policy decision. Continuous workers used about 14.4% less allocation, with inconclusive p99; 100 ms long polling used about 60.2% less allocation and 36.7% less maximum live memory, with a handler-start latency regression. All twenty arms and both comparisons are digest-linked. Both comparison attestations are confirmed with all six checks passing, including independent VC-2/VC-3 recomputation. The [dated report](../reports/2026-09-30-queue-worker-comparisons.md) links every pair, clean raw comparison, and attestation. Strict evidence validation, local ledger/CLI checks, profile fixtures, and index regeneration pass; all `just verify` targets passed across foundation and evidence phases. Individual business-oracle attestation, provision variation, broader performance acceptance, and full soaks remain open.
- [x] (2026-10-01 UTC) Added queue throughput revision 4 standard/unlogged provision controls through the released API, with PostgreSQL persistence checks before and after load. Ten durable PostgreSQL 18 functional arms held all four verdicts over 7,345 exactly-once jobs, with zero worker errors, empty queues, and both consumers participating. All 30 result/spec/manifest schema checks and 264 artifact digest/size checks passed. The 41-example Keiro package suite and full `nix develop -c just verify` pass, including persistence-oracle mutations and shared integration/evidence checks. These dirty workstation runs are exploratory and do not change baseline record counts; controlled storage-performance acceptance remains open.
- [x] (2026-10-01) Added outbox/inbox native metrics serving in the telemetry contract and four benchmarks. Eight durable contract arms pass all eleven checks; five short benchmark controls hold their business checks. All 39 schema and 293 artifact integrity checks pass, with 381 successful scrapes. Controlled overhead and remaining process-role telemetry acceptance stay open.
- [x] (2026-10-01) Completed clean alpha native-metrics acceptance on payload `16ec2d6`: the telemetry contract passed all eleven checks; fifteen benchmark-grade arms conserved 230,915 messages under one lease, with 48 schema and 397 artifact integrity checks and 5,667 successful scrapes. Three metrics comparisons are digest-linked and independently confirmed for VC-2/VC-3: collect and serve-scraped pass; serve remains inconclusive on enqueue p99. The unaltered A/A report remains inconclusive on both p99 metrics and its internal control factor cannot yet be formally recorded. All sixteen underlying runs are recorded. The [dated report](../reports/2026-10-01-outbox-metrics-and-restart-controls.md) preserves the limits; p99 repeatability and broader telemetry acceptance stay open.
- [x] (2026-10-01) Completed matched clean twenty-minute outbox restart diagnostics on the same seed and payload with forced major GC every five seconds. Both held every applicable business check (eleven process, eight in-process) over 24,202 unique messages and 20 restarts, with bounded table growth. The process arm remains inconclusive because short incarnations have insufficient data, while its main process and continuous survivor have stable bounded resources. The in-process arm passed. Both are digest-linked; the [dated report](../reports/2026-10-01-outbox-metrics-and-restart-controls.md) records the resource decisions. Finding 3 remains open for historical default-GC attribution; these diagnostics do not close full-duration or independent Keiro VC-1 acceptance.
- [x] (2026-10-01) Strengthened queue lease acceptance for both execution shapes with PostgreSQL lease/read-count snapshots, intentional ignored-extension failures, and independent VC-1 replay. The local four-arm matrix meets every expected outcome; 40 schema checks and 84 artifact digests pass. The Keiro and CLI suites pass 46 and 34 examples respectively; the clean published repeat is linked below.
- [x] (2026-10-01) Strengthened inbox matrix revision 2 with exact SQL receipt persistence, independent key expectations, source-position fallback and failed-handler rollback checks. Fourteen durable arms met their expected outcomes; 202 schema and 216 artifact checks pass, with 48 package examples. Clean evidence selection and independent VC-1 replay remain separate gates.
- [x] (2026-10-02 UTC) Recorded ten clean revision-3 table-backed inbox controls with independent VC-1 attestations; all six evidence checks confirm each result, including two deliberate double-effect failures. The matrix passes 160 schema and 170 artifact integrity checks.
- [x] (2026-10-02 UTC) Sealed revision-5 delegated intake/stream observations and independently reconstructed all ten checks. Four clean policy arms are digest-linked with confirmed VC-1 attestations; all 56 schemas and 60 artifact checks pass. The full verification gate and 50 Keiro/52 CLI tests pass.
- [x] (2026-10-02 UTC) Collected and digest-linked the full queue/DLQ soak: all nine business checks hold over 72,051 exactly-once jobs and 3,603 archived dead jobs. Its heap evidence is insufficient and legacy verdict schemas are invalid under finding 50, so resource and artifact acceptance remain open.
- [ ] Finish the remaining non-soak acceptance work listed below, then rerun the affected scenarios and package tests.
- [x] (2026-10-01) Full inbox soak sealed with passing business/resource observations and was digest-linked; finding 50 qualifies its legacy verdict schema, and the first timed-out attempt remains excluded.
- [x] (2026-10-01) Implemented revision-3 process-isolated outbox soak with per-incarnation diagnosis and message-specific crash duplicate budgets.
- [x] (2026-10-02 UTC) Collected and digest-linked the repaired-payload four-hour inbox run: all eight business checks and six bounded resource probes pass, with 27 artifact checks and all 11 schemas valid. This closes inbox full-soak artifact acceptance; independent soak VC-1 remains open. The follow-on queue GC diagnostic is submitted.
- [ ] Finish queue and outbox full-soak resource acceptance, schema-valid full-soak artifacts, process isolation acceptance, remaining matrix arms, and independent evidence verification.

The five Keiro owner reports for worker exits, read-attempt accounting, stale outbox claims, pool starvation, and missing process spans now have local finding records [34](../findings/34-keiro-job-worker-exits-after-polling-backend-termination.md), [35](../findings/35-keiro-long-poll-consumes-read-attempt-without-handler.md), [36](../findings/36-keiro-stale-outbox-publisher-finalizes-new-claim.md), [37](../findings/37-keiro-long-poll-processors-starve-runtime-pool.md), and [38](../findings/38-keiro-pre-handler-dead-letter-lacks-process-span.md). Each finding has its canonical owner URI; the MasterPlan register counts those records separately from the scenarios that cite them.

The same-seed four-hour inbox retry sealed and verified on 2026-10-01 UTC:
cell `01a0f4f5-7e09-7358-ac15-b2ac2128e990`, [digest-linked nested
run](../verification/runs/keiro/2026/10/01a0f4f4-7b1a-7232-b0ab-f62d19abb0aa.md).
Clean released payload `9c2c9b8`, inbox revision 2, seed `4252662818734786`,
and the bounded 15,300-second cap are unchanged from submission. The run
passed all eight business checks: 28,821 fresh deliveries, 28,821 suppressed
early duplicates, 28,821 late reprocessings, and 57,642 effects; classification
and GC errors and pending deliveries were zero. It retained 257 rows; table
size stayed at 409,600 bytes and sampled dead tuples at 120. All six bounded
resource probes were stable, including 466 eligible post-major heap points.
The full inbox run supplies business/resource observations, but finding 50
qualifies its legacy verdict schema and leaves formal artifact acceptance open.
Its digest-pinned record is an investigation; independent inbox-soak VC-1
recomputation remains unavailable, and exploratory soak measurements establish no benchmark comparison. The
unsealed first attempt remains excluded under finding 49.

### Inbox persistence SQL acceptance

The table-backed `effectively-once-matrix` is revision 2. Its separate SQL
oracle compares every persisted envelope and identity column with the input,
including nullable schema/trace fields that the runtime decoder normalizes.
The workload supplies nonempty schema, trace, causal and correlation data.
Half the source-event deliveries use UUID identity and half exercise the
global-position fallback; expected dedupe keys no longer call the runtime's
own key function. Full-envelope and dedupe-only success receipts have distinct
exact expectations. A failed handler first inserts an effect and then throws:
the effect must roll back, its failed receipt must retain the full envelope in
both modes, its ceiling must stop another attempt, and completed-row GC must
leave it unchanged. The raw SQL receipts, effect identities, and diagnostic
expectations are sealed in `logs/inbox-matrix-sql.json` with a versioned schema.
These are inspectable observations, not independent VC-1 recomputation.

The 48-example Keiro suite passes, including missing/altered-column and
multiplicity mutations. The first durable PostgreSQL 18 matrix under
`runs/ep13-inbox-sql/matrix/` met all fourteen expected runtime outcomes:
eight table-backed and four delegated passes, and two deliberate double-effect
failures confined to `effect-count-by-policy`. Schema validation then exposed
the delegated path's older verdict writer, which lacks required assertion
counters. This scenario now uses the messaging writer for both paths;
the corrected fourteen-arm rerun passed all expected outcomes, all 202
schema checks, and all 216 manifested size/SHA-256 checks. Its summary and
validation results are under `runs/ep13-inbox-sql/final-matrix/`. These local
dirty-worktree runs are functional evidence; clean selection remains open.
The full `nix develop -c just verify` gate passes, including the new schema
fixture, shared integration checks and live self-tests.
Existing ADR-8, ADR-15 and ADR-18 govern these assertions and evidence limits;
no new architecture boundary or cohort pin is introduced.

The clean revision-2 repeat at harness `b96c37f` passed the same fourteen
expected outcomes, 202 schema checks and 216 artifact integrity checks.
Every run records `dirty=false`; the twelve positive arms and two deliberate
effect mutations are selected as digest-linked investigations. These local
correctness observations supply no performance baseline. The interrupted
`clean-final/` attempt and the earlier `clean-matrix/` repeat with a generated
untracked session journal are excluded from this clean selection. The accepted
local summary is `runs/ep13-inbox-sql/clean-final-retry/summary.json`.
Independent inbox VC-1 replay remains open.

| Arm | Recorded run | Outcome |
| --- | --- | --- |
| `inbox-table-message-id-full-envelope-1` | [01a0f942-dc98-707d-8de6-0d7d8389856a](../verification/runs/keiro/2026/10/01a0f942-dc98-707d-8de6-0d7d8389856a.md) | passed |
| `inbox-table-message-id-dedupe-only-1` | [01a0f942-e805-7151-9a4c-9dd95620fb72](../verification/runs/keiro/2026/10/01a0f942-e805-7151-9a4c-9dd95620fb72.md) | passed |
| `inbox-table-source-event-full-envelope-1` | [01a0f942-f322-7548-ba6b-1ad3f05d6059](../verification/runs/keiro/2026/10/01a0f942-f322-7548-ba6b-1ad3f05d6059.md) | passed |
| `inbox-table-source-event-dedupe-only-1` | [01a0f942-fe40-77b1-8169-46c17dcb13cd](../verification/runs/keiro/2026/10/01a0f942-fe40-77b1-8169-46c17dcb13cd.md) | passed |
| `inbox-table-kafka-delivery-full-envelope-1` | [01a0f943-0955-752f-b3f2-4ec0a65fc47a](../verification/runs/keiro/2026/10/01a0f943-0955-752f-b3f2-4ec0a65fc47a.md) | passed |
| `inbox-table-kafka-delivery-dedupe-only-1` | [01a0f943-1468-7471-a61c-60357e756018](../verification/runs/keiro/2026/10/01a0f943-1468-7471-a61c-60357e756018.md) | passed |
| `inbox-table-custom-full-envelope-1` | [01a0f943-1f76-72ea-8ef2-0c2581cf68d2](../verification/runs/keiro/2026/10/01a0f943-1f76-72ea-8ef2-0c2581cf68d2.md) | passed |
| `inbox-table-custom-dedupe-only-1` | [01a0f943-2a97-742b-a83f-78ac6dd17d3f](../verification/runs/keiro/2026/10/01a0f943-2a97-742b-a83f-78ac6dd17d3f.md) | passed |
| `inbox-table-message-id-full-envelope-2` | [01a0f943-357d-7779-ab5f-8ace4bbee25f](../verification/runs/keiro/2026/10/01a0f943-357d-7779-ab5f-8ace4bbee25f.md) | expected effect failure |
| `inbox-table-message-id-dedupe-only-2` | [01a0f943-4083-763c-abb8-77a3c3465554](../verification/runs/keiro/2026/10/01a0f943-4083-763c-abb8-77a3c3465554.md) | expected effect failure |
| `delegated-message-id-full-envelope-1` | [01a0f943-4b8a-75f6-8a12-8d612c0b67e9](../verification/runs/keiro/2026/10/01a0f943-4b8a-75f6-8a12-8d612c0b67e9.md) | passed |
| `delegated-source-event-full-envelope-1` | [01a0f943-5693-7089-a3d5-159cda5ec785](../verification/runs/keiro/2026/10/01a0f943-5693-7089-a3d5-159cda5ec785.md) | passed |
| `delegated-kafka-delivery-full-envelope-1` | [01a0f943-6182-75cb-b7f9-ac8dda0764cd](../verification/runs/keiro/2026/10/01a0f943-6182-75cb-b7f9-ac8dda0764cd.md) | passed |
| `delegated-custom-full-envelope-1` | [01a0f943-6cab-772b-9acb-4f36aa43e9c1](../verification/runs/keiro/2026/10/01a0f943-6cab-772b-9acb-4f36aa43e9c1.md) | passed |

The full four-hour outbox revision-3 soak was submitted on alpha at
2026-10-01 20:47 UTC using clean released payload `16ec2d6`, default collection,
in-process publisher restarts every 60 seconds, 20 messages/second, and durable
PostgreSQL 18. Session `01a0f938-eef5-7567-8d0b-582ee7e0b823` owns cell run
`01a0f938-eef5-7567-9383-ca0e059e5b85` and nested run
`01a0f938-67a3-7207-a457-fcccd988b600`. Its 15,300-second wall-clock cap includes
the finalization allowance; the detached lease lasts 18,000 seconds. The cell sealed and its fetched tree verified. The nested result is
`inconclusive`: all eight business checks held over 288,202 unique messages
and 240 restarts, with three permitted duplicate broker appends, no backlog,
and no publisher or maintenance errors. GC retained 605 rows; the steady
relation-growth check measured 0.114 bytes per inserted row and bounded dead
tuples. The resource gate remains open: no post-major heap samples were
eligible, and the Haskell-thread slope interval crossed the growth floor
(142 to 164 sampled threads, interval -0.889 to 4.726 threads/hour). Native
bytes, OS threads, descriptors and connections were stable. The informational
relation-size trend does not override the separate bounded steady-growth
contract check. This supplies full-duration execution evidence without
closing resource acceptance, finding 3 attribution, or independent outbox
VC-1 replay. The collection command is:

```bash
kenshou cell resume --session cell-runs/ep13-outbox-full-default
```

### Independent inbox matrix replay

Revision 3 preserves the revision-2 business checks and adds a separate
`logs/inbox-matrix-intake.json` capture of submitted envelopes, Kafka delivery
coordinates, returned result constructors, and runtime-decoded receipt
keys/statuses. The raw observation writer contains no expected outcomes.
`Kenshou.Cli.Attest.KeiroInbox` imports neither Keiro nor the scenario oracle:
it derives keys, full/dedupe-only receipt shapes, exact effect identities,
classification checks, failed-handler rollback, retry ceiling, and retained
failed rows from the two sealed observation files. It ignores the scenario's
`expectedSuccessRows` and `expectedFailedRow` diagnostics. It supports only
revisions 3 through 5 table-backed intake. Delegated revision 5 has the separate
raw-observation replay described below; older delegated runs remain incomplete
for VC-1.

All fourteen revision-3 durable PostgreSQL 18 controls reached their expected
outcomes under `runs/ep13-inbox-replay/matrix/`: twelve passes and two deliberate
double-effect failures. Independent replay agreed with the documents for all
ten table-backed arms, including both failures. All 212 schema checks and 226
artifact size/SHA-256 checks passed. Six focused replay examples exercise
every missing and changed receipt column, duplicate/empty row sets, changed
classifications and effects, incomplete inputs, and poisoned diagnostic
expectations. These dirty functional runs validate the verifier; clean
revision-3 records and confirmed attestations remain the next evidence gate.
The full `nix develop -c just verify` gate passes, including all 40 CLI
examples and live self-tests. The existing ADR-8 and ADR-18 contracts cover the change; immutable historical
records are not backfilled with observations they never captured.

The clean repeat at `af3e8a9` reached the same ten table-backed outcomes,
passed 160 schema and 170 artifact integrity checks, and independently replayed
all eleven checks per run. Every run and attester records a clean checkout.
All ten runs are now digest-linked investigations, and their VC-1 attestations
confirm all six evidence checks. The two negative controls remain failed runs;
confirmation establishes that those deliberate failures were reproduced.
All four dedupe policies and both persistence modes, including the source-position
fallback, have verifier coverage. Delegated inbox, inbox soaks, and old
revision-2 records still require different or unavailable replay observations.

| Arm | Run | Confirmed attestation |
| --- | --- | --- |
| `inbox-table-message-id-full-envelope-1` | [01a0fa2a-63cc-7643-8be1-e83b65c42aa2](../verification/runs/keiro/2026/10/01a0fa2a-63cc-7643-8be1-e83b65c42aa2.md) | [01a0fa64-7f58-700c-8e60-8cfbce7cf9db](../verification/attestations/2026/10/01a0fa64-7f58-700c-8e60-8cfbce7cf9db.md) |
| `inbox-table-message-id-dedupe-only-1` | [01a0fa2a-70dd-70e6-98f8-3a0335e85f39](../verification/runs/keiro/2026/10/01a0fa2a-70dd-70e6-98f8-3a0335e85f39.md) | [01a0fa65-5e52-73a8-8830-4ffad9f6ec04](../verification/attestations/2026/10/01a0fa65-5e52-73a8-8830-4ffad9f6ec04.md) |
| `inbox-table-source-event-full-envelope-1` | [01a0fa2a-7c44-7057-ae6b-8025ad5dffb6](../verification/runs/keiro/2026/10/01a0fa2a-7c44-7057-ae6b-8025ad5dffb6.md) | [01a0fa66-3e70-7191-a7fb-e5a456384c62](../verification/attestations/2026/10/01a0fa66-3e70-7191-a7fb-e5a456384c62.md) |
| `inbox-table-source-event-dedupe-only-1` | [01a0fa2a-87e9-76e9-9a81-bfc782dd708d](../verification/runs/keiro/2026/10/01a0fa2a-87e9-76e9-9a81-bfc782dd708d.md) | [01a0fa67-2aff-7305-9456-6a61d485f9a7](../verification/attestations/2026/10/01a0fa67-2aff-7305-9456-6a61d485f9a7.md) |
| `inbox-table-kafka-delivery-full-envelope-1` | [01a0fa2a-93be-7059-ab18-55a46bb489f1](../verification/runs/keiro/2026/10/01a0fa2a-93be-7059-ab18-55a46bb489f1.md) | [01a0fa68-104c-7483-b3f3-1dbc92de30b4](../verification/attestations/2026/10/01a0fa68-104c-7483-b3f3-1dbc92de30b4.md) |
| `inbox-table-kafka-delivery-dedupe-only-1` | [01a0fa2a-9fb6-748d-9fd3-69a0a4fe4c31](../verification/runs/keiro/2026/10/01a0fa2a-9fb6-748d-9fd3-69a0a4fe4c31.md) | [01a0fa68-f1dd-7455-b321-2e6ced1c01c6](../verification/attestations/2026/10/01a0fa68-f1dd-7455-b321-2e6ced1c01c6.md) |
| `inbox-table-custom-full-envelope-1` | [01a0fa2a-ab4e-729e-907f-cab5fa75858f](../verification/runs/keiro/2026/10/01a0fa2a-ab4e-729e-907f-cab5fa75858f.md) | [01a0fa69-d160-7199-a737-631067220ffe](../verification/attestations/2026/10/01a0fa69-d160-7199-a737-631067220ffe.md) |
| `inbox-table-custom-dedupe-only-1` | [01a0fa2a-b765-7471-99f8-014d5c34c5b6](../verification/runs/keiro/2026/10/01a0fa2a-b765-7471-99f8-014d5c34c5b6.md) | [01a0fa6b-0cd0-74c6-bef2-1519a66a5f65](../verification/attestations/2026/10/01a0fa6b-0cd0-74c6-bef2-1519a66a5f65.md) |
| `inbox-table-message-id-full-envelope-2` | [01a0fa2a-c335-76f7-8822-2c81dae1099b](../verification/runs/keiro/2026/10/01a0fa2a-c335-76f7-8822-2c81dae1099b.md) | [01a0fa6b-f514-7009-87b2-10d07d9f924c](../verification/attestations/2026/10/01a0fa6b-f514-7009-87b2-10d07d9f924c.md) |
| `inbox-table-message-id-dedupe-only-2` | [01a0fa2a-ceac-70ad-9b70-dab8679eb46b](../verification/runs/keiro/2026/10/01a0fa2a-ceac-70ad-9b70-dab8679eb46b.md) | [01a0fa6c-d797-778c-8ea4-0ded5ee1a40d](../verification/attestations/2026/10/01a0fa6c-d797-778c-8ea4-0ded5ee1a40d.md) |

### Delegated receipt identity

Revision 4 changes the delegated arm's receipt expectations to independent
`expectedKey` and `expectedDelegatedId` functions in
`kenshou-keiro/src/Kenshou/Suite/Keiro/Inbox/Oracle.hs`. The write path still uses
the runtime helpers; the expected IDs no longer do. The frozen version-one
UUIDv5 recipe is checked with a fixed UTF-8 witness, byte-length field prefixes,
and mutations to each identity field. The durable workload uses Unicode source
and target names, eight source-event IDs and eight source-position fallbacks.
All four delegated policies pass under
`runs/ep13-delegated-identity/matrix/`. The full fourteen-arm matrix preserves
twelve passes and two deliberate effect-count failures, with 212 schema and
226 artifact integrity checks. All ten table-backed outcomes independently
replay; their workload and observations are unchanged from revision 3, so the
verifier explicitly accepts both revisions. The package suites pass 50 Keiro
and 40 CLI examples; the full `nix develop -c just verify` gate also passes.
These dirty local controls strengthen coverage without
adding selected clean records or claiming delegated VC-1 replay.

Revision 5 now seals `logs/inbox-delegated-observations.json`, with the actual
delivery arguments, resolved targets, result constructors, seed versions,
stream event IDs, decoded inbox rows and post-refusal stream IDs. The CLI
verifier reconstructs all ten delegated cells from those observations and the
frozen UUIDv5 recipe without importing the runtime or the scenario oracle.
It requires the complete sixteen-message schedule and accepts only revision 5
delegated observations. Refusal checks now compare exact before/after IDs.
The schema and four captured fixtures are part of the regular validation gate.

All fourteen durable PostgreSQL 18 controls under
`runs/ep13-delegated-replay/matrix/` preserve twelve passes and the two deliberate
effect-count failures. All fourteen outcomes independently replay, including
all four delegated policies. All 216 schema and 230 artifact integrity checks
pass, and a separate Python UUIDv5 reconstruction matches all 96 delegated
receipts. These are exploratory local controls; the clean selected repeat is
recorded below.
The focused suites pass 50 Keiro and 52 CLI examples, including changed
classifications, missing or duplicated observations, reordered/substituted
receipt IDs and malformed-schedule mutations. The full
`nix develop -c just verify` gate passes, including the new observation schema.


The clean repeat at `3fe0c80bff83cc0b39b7ee4b4b2e06d10b7ce8b9` passed all four
delegated policies on durable PostgreSQL 18. All 56 schema and 60 artifact
checks pass, as does the separate 96-receipt Python UUIDv5 reconstruction.
All four runs are now digest-linked investigations with confirmed VC-1
attestations: six evidence checks pass for each, including clean run/attester
worktrees and independent reconstruction of all ten delegated cells. The
recording command needed an explicit `CLOUDSDK_CORE_PROJECT=tan-nb-exp`
because the ambient project differed; no global GCP configuration was changed.
Older delegated records and inbox soaks retain their separate replay gaps.
Strict validation of the expanded 169-concept bundle, profile rejection
fixtures, the evidence ledger and CLI checks all pass.

| Policy arm | Run | Confirmed attestation |
| --- | --- | --- |
| `delegated-message-id-full-envelope-1` | [01a0fca8-cae6-70df-9ad1-c0ef6577a2e2](../verification/runs/keiro/2026/10/01a0fca8-cae6-70df-9ad1-c0ef6577a2e2.md) | [01a0fcb3-06eb-73ca-9b92-9d974a0caf89](../verification/attestations/2026/10/01a0fcb3-06eb-73ca-9b92-9d974a0caf89.md) |
| `delegated-source-event-full-envelope-1` | [01a0fca8-d813-73af-beca-3d86c9dc0742](../verification/runs/keiro/2026/10/01a0fca8-d813-73af-beca-3d86c9dc0742.md) | [01a0fcb3-cbb5-7678-a6a6-aea5ddbf21b1](../verification/attestations/2026/10/01a0fcb3-cbb5-7678-a6a6-aea5ddbf21b1.md) |
| `delegated-kafka-delivery-full-envelope-1` | [01a0fca8-e4ac-7080-8e46-92bed3d81a9d](../verification/runs/keiro/2026/10/01a0fca8-e4ac-7080-8e46-92bed3d81a9d.md) | [01a0fcb4-90e8-72f0-b463-1e1b8a3c9e32](../verification/attestations/2026/10/01a0fcb4-90e8-72f0-b463-1e1b8a3c9e32.md) |
| `delegated-custom-full-envelope-1` | [01a0fca8-f079-7212-855b-2cc7f53c84dc](../verification/runs/keiro/2026/10/01a0fca8-f079-7212-855b-2cc7f53c84dc.md) | [01a0fcb5-5aa1-7363-ada1-20b65c33051f](../verification/attestations/2026/10/01a0fcb5-5aa1-7363-ada1-20b65c33051f.md) |

### Poison and batch rollback acceptance

Revision 2 strengthens `poison-accounting` with actual effect inserts before
pure exceptions, SQL errors and condemnation. Permanently failing delivery
must enter the handler three times and stop at its ceiling; two recovery
failures roll back every effect, the succeeding third attempt leaves exactly
one recovery effect, and redelivery adds neither an effect nor a handler call.
Returned classifications, durable failed-row retention and completed-row GC
remain checked. Revision-2 invocation/effect observations were included in
verdict parameters and did not support independent poison/batch VC-1 replay.

An initial-zero sequence guard exposed [finding 51](../findings/51-inbox-handler-counter-counts-an-unused-sequence.md).
The old `last_value` query returns one before any `nextval`. The repaired query
uses `is_called` to distinguish zero invocations. The guard also applies to
both transactional batch modes, making that scenario revision 2. Delegated
poison/batch behavior is unchanged. The seven-arm durable PostgreSQL 18
before matrix under `runs/ep13-poison-effects/before/` produces exactly the five
expected initial-zero failures and two delegated passes. All seven arms under
`runs/ep13-poison-effects/after/` pass. Each matrix passes 55 schema and 62
artifact integrity checks. These dirty local controls do not change selected
historical evidence counts.
The full `nix develop -c just verify` gate passes, including 50 Keiro and
52 CLI examples and strict validation of all 169 evidence concepts.

Revision 3 seals `logs/inbox-poison-observations.json` with the complete input
schedule, returned constructors, invocation checkpoints, effects and retained
receipt rows. `Kenshou.Cli.Attest.KeiroPoison` independently reconstructs every
poison check for table-backed exception, condemnation and SQL-error modes,
and delegated retry accounting. It rejects incomplete schedules and requires
the same failures, blocking flag, exit code and verdict summary. It imports
neither the runtime nor the scenario oracle. SQL-error classification remains
an observation; its contract is rollback without a completed effect.

All four durable PostgreSQL 18 controls under `runs/ep13-poison-replay/matrix/`
pass, with 34 schema and 38 artifact-integrity checks; offline replay agrees
with each sealed result. Eight mutation examples detect changed invocation
counts, missing or duplicate recovery effects, wrong constructors, missing
failed receipts and altered retry schedules. Targeted tests pass with 50
Keiro and 60 CLI examples. The full `nix develop -c just verify` gate passes,
including the schema fixtures, evidence checks and live self-tests.
These dirty controls are not historical records.
Earlier poison revisions remain outside independent replay coverage; batch
revision 3 is covered separately below.


The clean repeat at `e09f9fb58ba35651d11f979b922d275458e6d0f3` passes all four
poison modes on durable PostgreSQL 18, with 34 schema and 38 artifact-integrity
checks. All four are digest-linked investigation records with confirmed VC-1
attestations: all six evidence checks pass, including clean run/verifier
worktrees and independent reconstruction from raw observations. Older poison
records retain their separate coverage limits.
Strict validation of the 177-concept bundle, reproducible indexes, negative
profile fixtures, and evidence ledger/CLI checks all pass.

| Poison mode | Clean run | Confirmed attestation |
| --- | --- | --- |
| `inbox-table-pure-exception` | [01a0fd91-addb-737e-ad23-0a042e72cede](../verification/runs/keiro/2026/10/01a0fd91-addb-737e-ad23-0a042e72cede.md) | [01a0fd97-ed17-7647-9805-fc46a151ab78](../verification/attestations/2026/10/01a0fd97-ed17-7647-9805-fc46a151ab78.md) |
| `inbox-table-condemn` | [01a0fd91-bbb6-73eb-98dc-f08211a23ae7](../verification/runs/keiro/2026/10/01a0fd91-bbb6-73eb-98dc-f08211a23ae7.md) | [01a0fd98-bc9c-7380-9d30-ccf52ca6c465](../verification/attestations/2026/10/01a0fd98-bc9c-7380-9d30-ccf52ca6c465.md) |
| `inbox-table-sql-error` | [01a0fd91-c724-736c-966c-e72a6da6920b](../verification/runs/keiro/2026/10/01a0fd91-c724-736c-966c-e72a6da6920b.md) | [01a0fd99-a014-70c8-91a5-f52e88de4558](../verification/attestations/2026/10/01a0fd99-a014-70c8-91a5-f52e88de4558.md) |
| `delegated-pure-exception` | [01a0fd91-d2ca-7637-9dc6-83f1ff82d85e](../verification/runs/keiro/2026/10/01a0fd91-d2ca-7637-9dc6-83f1ff82d85e.md) | [01a0fd9a-1280-7234-984f-28677dca06d0](../verification/attestations/2026/10/01a0fd9a-1280-7234-984f-28677dca06d0.md) |

### Independent batch intake replay

Batch revision 3 now counts every table-backed handler entry using a fresh
nontransactional sequence. Both counters must start at zero, and the clean
three-delivery batch with a repeated key must enter its handler exactly twice.
This directly checks duplicate suppression alongside positional constructors,
one committed transaction, isolated poison fallback and exactly-once effects.

Both table-backed failure modes and delegated batching seal
`logs/inbox-batch-observations.json`: ordered delivery batches, returned
constructors, invocation counts/traces, SQL transaction counts, effects and
receipt rows. `Kenshou.Cli.Attest.KeiroBatch` independently reconstructs all
seven table-backed or four delegated checks, requires the complete positional
schedule, and compares failures, blocking flag, exit code and verdict summary.
Earlier batch revisions remain outside independent replay coverage.

All three durable PostgreSQL 18 controls under `runs/ep13-batch-replay/matrix/`
pass; all 30 schema and 33 artifact-integrity checks pass, and independent
offline replay agrees with each result. These dirty functional controls do not
add historical evidence records. Six mutation examples cover reordered or
missing inputs, wrong result constructors, extra committed effects, incorrect
transaction/invocation counts and missing failed receipts.
The full `nix develop -c just verify` gate passes, including all six mutation
examples in the 66-example CLI suite. The 50-example Keiro suite also passes.


The clean repeat at `39f73abfcff10d970a6e0cc4ef199579a32e0cad` passes all three
batch controls, with all 30 schema and 33 artifact-integrity checks passing.
The three digest-linked investigations have confirmed VC-1 attestations;
all six evidence checks pass for each. Table-backed controls directly verify
that the clean duplicate adds no handler invocation. Earlier batch records
are not retroactively promoted to this coverage.
Strict validation of all 184 evidence concepts, reproducible indexes, profile
rejection fixtures and evidence ledger/CLI checks pass.

| Batch mode | Clean run | Confirmed attestation |
| --- | --- | --- |
| `inbox-table-pure-exception` | [01a0fda9-ca87-7026-8e5d-aa6bf68b71b8](../verification/runs/keiro/2026/10/01a0fda9-ca87-7026-8e5d-aa6bf68b71b8.md) | [01a0fdaf-c573-7293-b7bb-08cac1d7e5b6](../verification/attestations/2026/10/01a0fdaf-c573-7293-b7bb-08cac1d7e5b6.md) |
| `inbox-table-condemn` | [01a0fda9-d66f-75e2-a87a-a52d51fec730](../verification/runs/keiro/2026/10/01a0fda9-d66f-75e2-a87a-a52d51fec730.md) | [01a0fdb1-0abe-76eb-a230-900d6ce60f21](../verification/attestations/2026/10/01a0fdb1-0abe-76eb-a230-900d6ce60f21.md) |
| `delegated-pure-exception` | [01a0fda9-e1c8-7757-85a3-f0ec3346b694](../verification/runs/keiro/2026/10/01a0fda9-e1c8-7757-85a3-f0ec3346b694.md) | [01a0fdb1-8dc7-7012-ad16-828781429ae8](../verification/attestations/2026/10/01a0fdb1-8dc7-7012-ad16-828781429ae8.md) |

### Full-soak artifacts and repaired payload

The full outbox result is [digest-linked](../verification/runs/keiro/2026/10/01a0f938-67a3-7207-a457-fcccd988b600.md)
with all 27 nested artifact sizes/hashes verified. Its spec, result and manifest
pass schema validation, but all eight legacy verdict files omit the schema's
required assertion counters. [Finding 50](../findings/50-verdict-writers-omit-required-assertion-counters.md)
tracks this local harness defect. The full business/resource observations stay
available as an investigation; they do not satisfy formal artifact acceptance.
The same qualification applies to older full inbox evidence from that writer.
The source repair and writer regression preserve verdict meanings and reject
future emissions missing required counters. Existing sealed trees stay unchanged.

The required-counter regression failed against the old shared writer and passes
after repair. The Keiro and core check suites pass 49 and 35 examples; all ten
held/violated documents from the Keiro, Kiroku, timer, shard and workflow probes
pass the verdict schema. The complete `nix develop -c just verify` gate passes,
including 40 CLI examples, strict validation of the 160-concept evidence bundle,
generated-index consistency and live fault/model self-tests.

The full four-hour queue/DLQ revision-2 soak was submitted on alpha at
2026-10-02 01:50 UTC with clean payload `16ec2d6`, five jobs/second, terminal
poison every twentieth job, DLQ maintenance on, default collection, and durable
PostgreSQL 18. Session `01a0fa4d-f1ea-74ed-94f3-929d066d3bac` owns cell run
`01a0fa4d-f1ea-74ed-9b07-a298ee957541`, nested run
`01a0fa29-a590-7007-81bb-7a26c7ba5cd4`, and a 15,300-second wall-clock cap.
It sealed at 05:58 UTC and was collected as a verified completed cell result.
The [digest-linked investigation](../verification/runs/keiro/2026/10/01a0fa29-a590-7007-81bb-7a26c7ba5cd4.md)
holds all nine business checks: 72,051 jobs handled once, an empty main queue,
3,603 dead jobs archived with none left active, zero worker/maintenance errors,
and peak main depth one. Main relation size stays at 172,032 bytes; the steady
DLQ sample grows from 90,112 to 98,304 bytes (9.1022 bytes per inserted dead row),
within its bound. Both dead-tuple checks hold.

Overall outcome is inconclusive. No eligible post-major heap points were
captured. The other five bounded resource probes are stable: native bytes,
Haskell threads (139 throughout), OS threads (nine), descriptors (31), and
connections (three). The informational relation trend does not override the
scenario's bounded table-growth check. All 28 nested artifact sizes/digests and
three top-level schemas pass; all nine legacy verdict schemas fail only the
known missing assertion counters in finding 50. The record verifies the
existing sealed cloud objects without rewriting them. Queue heap/resource
acceptance, repaired full-soak artifacts and independent queue-soak VC-1 remain
open. The fetched tree is under
`.dev/01a0fa4d-f1ea-74ed-9b07-a298ee957541/tree/`.

A clean repaired Linux payload was published from `0eda7ac` on 2026-10-02 UTC.
The descriptor is `payloads/released-verdict-counters.json`; the 60,655,972-byte
bundle has SHA-256
`479ab16385e0704b1dd1624969dd6b38bd57b13a848a31a5e541fbb133c86800`.
All 41 released-cohort package identities agree. Descriptor schema validation
and `kenshou cell payload show` pass; a fresh GCS download independently matches
the bundle SHA-256 and byte count. The workstation's configured builder
tunnel refused its connection even though the VM was running; an isolated
checkout of the same commit built and published through the documented IAP
wrapper of `mori://shinzui/load-testing-infra` (`scripts/iap-ssh.sh`,
artifact-level URI pending). The repaired payload preserves the existing soak
revisions and does not contain the later revision-4 delegated matrix change.

The full inbox rerun keeps the prior accepted run's exact seed
`4252662818734786`, two messages/second, 120-second retention, default GC,
telemetry off and durable PostgreSQL 18. Its plan is
`.dev/ep13-inbox-full-counter-repair-plan.json`, with nested run
`01a0fa97-bbd6-76a5-a7c0-03c6aa076562`; the generated run seed was explicitly
set to the prior run's seed before submission. The original local coordinator
stopped at 05:13 UTC on a TLS handshake timeout while checking queue status;
it submitted no inbox run. Manual recovery collected the sealed queue result
and submitted the prepared inbox plan at 13:04 UTC with the repaired payload
and a five-hour lease. Session `01a0fcb7-333b-77b1-ab02-fef753395c0f` owns cell
`01a0fcb7-333b-77b1-ad39-c4a38bbc4b45` and lease
`01a0fcb7-2d45-712e-90fc-637db7d731c3`. The bounded collector verified and
collected its passing result at 17:15 UTC, releasing that lease.

The [new digest-linked investigation](../verification/runs/keiro/2026/10/01a0fa97-bbd6-76a5-a7c0-03c6aa076562.md)
holds all eight business checks: 28,821 fresh deliveries, 28,821 early duplicates
suppressed, 28,821 late reprocessings and exactly 57,642 effects, with zero
classification/GC errors or pending deliveries. It retains 258 receipt rows.
The sampled comparison-window relation size decreases from 417,792 to 409,600
bytes; dead tuples decrease from 120 to 118, within both bounds.

All six bounded resource probes are stable, including 472 eligible post-major
heap points with default GC. All 27 nested artifact sizes/digests and all 11
schemas (three top-level documents and eight verdicts) pass. This closes the
inbox full-soak artifact gap from finding 50 without rewriting historical
runs. Independent inbox-soak VC-1 remains unavailable, and exploratory soak
measurements are not benchmark comparisons. Recording uses `--verify-only`
and `--deep-verify` against the existing sealed cell objects. Strict validation
of the expanded 178-concept evidence bundle, reproducible indexes, profile
rejection fixtures and evidence ledger/CLI checks all pass.

The original coordinator stop remains in `.dev/ep13-soak-sequence-stopped.json`;
the successful collector state is `.dev/ep13-inbox-full-counter-repair-watch.json`.

The follow-on queue diagnostic keeps the sealed full queue run's
exact seed `8102429385822254`, workload, duration, dimensions and knobs, except
`diagnose.major-gc-interval-ms=5000`. The generated plan seed was explicitly
set to that prior run seed before submission. The repaired payload is the same
clean `0eda7ac` bundle. This targets the missing full-duration heap evidence
and fresh schema-valid artifacts; forced collection remains a diagnostic
control, excluded from default-GC performance claims.

The plan is `.dev/ep13-queue-full-counter-repair-gc-plan.json`, nested run
`01a0fd67-a9cb-7001-9322-69251c14d682`. The bounded
`.dev/sequence-queue-full-counter-repair-gc.py` submitted it at 17:16 UTC after
the inbox collector completed and released its lease. Session
`01a0fd9d-fcda-74af-b190-c2b7d4a1f282` owns cell run
`01a0fd9d-fcda-74af-b73c-20bcb13da0f2` under a five-hour lease. Collection has
five bounded consecutive retries and a 23:15 UTC deadline. State is
`.dev/ep13-queue-full-counter-repair-gc-state.json`; no queue diagnostic outcome
is claimed. Manual collection is:

```bash
kenshou cell resume --session .dev/ep13-queue-full-counter-repair-gc
```

The matching full outbox GC diagnostic was queued at 18:41 UTC on October 2.
It waits for verified queue collection and lease release before submitting
`01a0fdea-68ff-704b-bc96-176ee5235120` on alpha. Its plan is
`.dev/ep13-outbox-full-counter-repair-gc-plan.json`; the bounded collector is
`.dev/sequence-outbox-full-counter-repair-gc.py`, with state in
`.dev/ep13-outbox-full-counter-repair-gc-state.json`. The session directory will
be `.dev/ep13-outbox-full-counter-repair-gc/` once submitted. It uses the same
clean repaired-counter payload as the inbox and queue retries, source
`0eda7ac8a63735c7198c5ff16f66b9c9ff19e1df`, payload SHA-256
`479ab16385e0704b1dd1624969dd6b38bd57b13a848a31a5e541fbb133c86800`.

The run preserves the actual preceding full outbox seed
`5023798347134724`, revision 3, four-hour duration, 20 messages/second,
32-row batches, in-process publishers, 60-second restarts, GC on and
30-second retention, durable PostgreSQL 18 and telemetry off. Among the
workload knobs, only the diagnostic major-GC interval changes from zero to
5,000 ms. The plan warning records the explicit run-seed pin. This control
addresses the heap-data gap and legacy verdict artifacts; it cannot supply
default-GC performance evidence or independently close finding 3. The launcher
stops if queue collection fails, never replaces an existing session, uses a
five-hour lease and bounds repeated collection errors. No submission or
outcome is claimed while its phase is `waiting-for-queue`.

### Queue lease SQL evidence and replay

Revision 3 uses the existing `worker` and `drain` execution shapes with
controller-gated handlers. The controller suspends intake after each delivery
mark so a process cannot prefetch its own expired job before the intended
contender. Initial and contested SQL snapshots preserve message ID, `read_ct`,
`last_read_at`, `vt`, and PostgreSQL observation time. Six seconds after the
first read, the unextended arm must have two reads and attempts zero/one;
the extended arm must retain one read and its still-live ten-second lease.
After release, two unextended effects and one extended effect must remain,
and both queues must drain. This follows ADR-12's database-clock rule.

The explicit `queue.ignore-extension=true` knob suppresses extension as a
negative oracle control and is not an automatic variant. Four durable local
PostgreSQL 18 arms passed their expected acceptance: both ordinary arms held
all five checks; both negative arms failed exactly the two extension checks.
The raw observations are separate manifested JSON documents under `logs/`,
with a versioned schema. `Kenshou.Cli.Attest.KeiroLease` independently replays
all five cells for VC-1; it rejects forged exit codes, missing effects, and
unsupported revisions. Record a passing arm with `--link-logs` to link these inputs directly;
the sealed manifest also covers them transitively. This does not close other Keiro oracles or full soaks.

The final local matrix is under `runs/ep13-lease-sql/final-matrix/`, seed
`4252662818734786`: worker pass `01a0f909-92bc-705d-903a-0a5c49e629b3`,
drain pass `01a0f909-ce22-7668-8a93-a85b66830274`, worker ignored-extension
`01a0f90a-0933-771c-9906-77223cfabff2`, and drain ignored-extension
`01a0f90a-4509-75b9-a901-7b7ea389f794`. Both negative controls exit 1 with
`extension-prevents-duplicate` and `extended-read-count-one`; other checks
hold. `validation.json` records all 40 schema checks and 84 size/digest checks.
These dirty workstation controls are functional evidence, not new historical
baseline records. ADR-12 and ADR-18 cover the clock and replay choices;
no new architecture boundary or dependency version is introduced. The full
`nix develop -c just verify` gate passes, including the new raw-observation
schema fixture; independent replay of all four final runs agrees and rejects
forged exit codes, missing effects, and unsupported revisions.


The clean repeat at commit `fed2ecabbabe130b00fa1c10693c67d9cbc0a2d2`
uses the same seed and durable PostgreSQL 18. All four saved fingerprints have
`dirty: false`; the matrix again passes 40 schema and 84 artifact integrity
checks. Independent offline replay agrees with each outcome and rejects the
same mutations. Both negative controls remain blocking failed run results;
they demonstrate oracle sensitivity and do not report an owner defect.

| Execution shape | Extension | Clean run | Outcome |
| --- | --- | --- | --- |
| worker | requested | [01a0f912-2b59-7552-8cc9-c21fb7b6923f](../verification/runs/keiro/2026/10/01a0f912-2b59-7552-8cc9-c21fb7b6923f.md) | passed |
| drain | requested | [01a0f912-65c8-7785-84df-0996b24c48c9](../verification/runs/keiro/2026/10/01a0f912-65c8-7785-84df-0996b24c48c9.md) | passed |
| worker | deliberately ignored | [01a0f912-a01f-76c3-8631-91b96114d914](../verification/runs/keiro/2026/10/01a0f912-a01f-76c3-8631-91b96114d914.md) | failed on the two extension checks |
| drain | deliberately ignored | [01a0f912-da7b-729f-b25e-8c7be8ceb46a](../verification/runs/keiro/2026/10/01a0f912-da7b-729f-b25e-8c7be8ceb46a.md) | failed on the two extension checks |

Reproduce each arm by choosing `worker` or `drain` and `false` or `true`:

```bash
nix develop -c cabal run -v0 kenshou -- run keiro/queue/concurrency/lease-extension \
  --dim pg.durability=durable --set queue.execution-shape=worker \
  --set queue.ignore-extension=false --seed 4252662818734786 --out runs/lease-replay
```

The extended cases exit 0; ignored-extension cases exit 1. The latter still
hold the unextended-expiry, cadence, and drained-queue checks. Raw inputs are
`logs/queue-lease-unextended.json` and `logs/queue-lease-extended.json` in each
sealed directory. All four are digest-linked investigation records in the
historical bundle, including both raw observation documents. All four
cloud-backed attestations are confirmed: all six checks pass,
including independent VC-1 replay and clean run/verifier worktrees. The
attester used the exact clean-run executable at `fed2eca`. Confirmation
preserves the two deliberately failed outcomes. Strict profile validation,
the evidence checker, CLI integration checks, and generated indexes pass.

| Arm | Confirmed attestation |
| --- | --- |
| `drain-extended` | [01a0f920-0b42-72d2-b3d4-6eca7317239a](../verification/attestations/2026/10/01a0f920-0b42-72d2-b3d4-6eca7317239a.md) |
| `drain-ignored` | [01a0f921-1b29-7229-9e39-b7a249cc7ad1](../verification/attestations/2026/10/01a0f921-1b29-7229-9e39-b7a249cc7ad1.md) |
| `worker-extended` | [01a0f922-276b-7722-b023-1c3d385b5e6e](../verification/attestations/2026/10/01a0f922-276b-7722-b023-1c3d385b5e6e.md) |
| `worker-ignored` | [01a0f923-39ea-712c-bb6d-4efca52d76dd](../verification/attestations/2026/10/01a0f923-39ea-712c-bb6d-4efca52d76dd.md) |


### Process-isolated outbox soak

Revision 3 adds `outbox.publisher-execution=processes` alongside the unchanged
`in-process` default. Two child publishers use the released API; one survives
the whole run while the other parks after a durable broker append and before
outbox finalization. The controller waits for its persisted `crash-window`
message IDs, sends process-group `SIGKILL`, reaps it, and starts a fresh child.
A duplicate append must belong to that exact message's recorded crash batches.
Drain shutdown acquires the restart lock before cancelling its controller,
so a parked child cannot be left between append and recorded SIGKILL.
Tracing and metrics must both be off for this process arm; other combinations
are explicitly rejected until child telemetry is implemented.

Each incarnation writes separate RTS/process series and a leak report; no
fresh process clock or heap is spliced into an old series. The ordinary
full-window leak policy is preserved: short killed incarnations can yield
`insufficient-data`, keeping the overall outcome inconclusive, while suspected
child leaks still fail. The survivor provides a continuous resource control.

A one-minute dirty-workstation smoke `01a0f845-ef94-703f-87d6-1cff0db414bf`
under `runs/ep13-outbox-process-soak/` held all eleven business verdicts:
141 accepted messages, 147 broker records, six realized kills, no backlog or
publisher/maintenance errors, and every duplicate covered by its own crash
mark. Its survivor resources were stable, but main Haskell threads grew.
A minimal weak-reference test then proved that supervisor bookkeeping retained
retired Child handles without Keiro present. EP-5 now forces the filtered child
list and stored disturbance records; the regression failed before the repair
and passed afterwards. This identifies a harness defect without attributing
all earlier in-process restart signals to it. The same-seed post-repair smoke `01a0f84f-c814-748e-83aa-0b4b60cb8c7d`
under `runs/ep13-outbox-process-soak-fixed/` held all eleven verdicts over 141
unique messages, 148 broker records and six kills, with no errors/backlog.
All six bounded main-process probes and the continuous survivor were stable;
main Haskell threads stayed at 145–146. Short killed incarnations lacked enough
samples, so the unchanged combined outcome was inconclusive. These functional
controls are dirty local evidence, not controlled baseline acceptance.
Clean controlled process soaks, queue process isolation, child telemetry, and
the full outbox/queue execution gates remain open.

The full process-soak resource gate also has a concrete duration conflict:
`soakLeakSpec` requires at least 70% of the full scenario duration for every
incarnation, while the allowed kill interval is at most 3,600 seconds. A
four-hour scenario needs 10,080 seconds of each child series; every killed
incarnation is shorter than that even at the maximum interval. Merely
lengthening the run cannot close this acceptance gate. The policy and the
per-incarnation scheduling contract need an explicit resolution before a
full process run can be interpreted as complete resource acceptance. No
threshold or verdict was weakened here, and the stable survivor remains
separate from those insufficient child series.

The 43-example Keiro package suite covers targeted mutations of crash-batch
duplicate budgets; the 34-example toolkit suite covers retired-child
reachability. All 15 run spec/result/manifest schema checks passed across the
four local process/control trees and the full inbox tree. Every one of the
216 local manifested artifacts matched its recorded size and SHA-256. ADR-10
now records eager retirement bookkeeping and separate per-incarnation series;
its descriptor type-check and strict 21-record bundle validation pass. All
`just verify` targets passed across the foundation and evidence phases; the
new evidence index required its record commit before the index-diff check.
The unsupported process/tracing combination was explicitly rejected with
`process-telemetry-unsupported` in run `01a0f856-4d2a-7025-865d-f6bc533d5611`.
The package tests were rerun after synchronizing shutdown with restart
completion and remained at 43 examples with zero failures. The final one-minute
shutdown smoke, `01a0f85b-b236-74b7-bed7-675f55873184` under
`runs/ep13-outbox-process-shutdown/`, used a five-second kill interval and held
all eleven checks over 141 unique messages, 153 broker records and twelve
recorded kills. Publisher/maintenance errors and backlog were zero; the
continuous survivor was stable. Short killed incarnations again retained
insufficient-data verdicts and the overall outcome was inconclusive.

Reproduce the functional process arm from the repository root:

```bash
nix develop -c cabal run -v0 kenshou -- run keiro/outbox/soak/table-growth-reduced --dim pg.durability=durable --set soak.duration-minutes=1 --set outbox.rate-per-second=2 --set outbox.kill-interval-seconds=10 --set outbox.publisher-execution=processes --set diagnose.major-gc-interval-ms=5000 --seed 4252662818734786 --out runs/ep13-outbox-process-soak
```

### Messaging metrics serving

Revision 2 of the outbox telemetry contract and all four outbox/inbox
benchmarks uses `Kenshou.Suite.Keiro.Messaging.Metrics`. It connects the
released Kiroku collector to the fixture store, serves the native JSON and
Prometheus endpoints in serving modes, and preserves their lifetime through
scraper finalization. The contract additionally checks Keiro's OpenTelemetry
Prometheus endpoint before and after processing against durable workload
counts; raw HTTP bodies are sealed as logs. The shared telemetry handles expose
the reader's existing endpoint, without starting a second reader or server.
The contract declares only the Prometheus reader; benchmark reader choices
remain available. Cohort versions are unchanged.

The first live traced scrape exposed a parser omission: valid exemplars follow
some counter values. Run `01a0f88a-5020-709a-80c8-351aab494e20` failed only the
new final endpoint check with correct runtime counts. The parser now separates
the exemplar suffix, with mutation checks for missing, duplicated, mislabelled
and incorrect samples. This is a local oracle correction, not an owner finding.
The corrected traced/scraped durable run
`01a0f88b-3f7c-73df-86da-b51a282e9499` passed all eleven checks. All eight
tracing-off/in-memory × metrics-off/collect/serve/serve-scraped contract arms
passed on durable PostgreSQL 18. Five integration controls (outbox drain,
enqueue-to-publish, producer replay, and table/delegated inbox intake) held
all business checks; their short measurements remain inconclusive. The
44-example Keiro and 19-example telemetry suites pass. Run identities and
resolved arguments are retained under `runs/ep13-messaging-metrics/matrix/`
and `runs/ep13-messaging-metrics/bench/`, each with `summary.json`. All 39
spec/result/manifest schema checks and 293 artifact size/SHA-256 checks passed.
The seven scraped runs completed 381 scrapes (254 native store requests),
with zero scrape failures. `runs/ep13-messaging-metrics/validation.json` retains
these totals. These dirty workstation runs do not add controlled baseline
records. Existing ADR-7 and the MasterPlan's telemetry integration contract
cover this adaptation; it introduces no new architecture boundary.
The full `nix develop -c just verify` gate passes, including formatting,
builds, shared tests, released-cohort link proof, component graph, ADR and
evidence validation, schemas, and live self-tests. A request for the contract's
unsupported `metrics.otel-reader=none` is rejected before execution with exit 2.

### Outbox terminal policy fixture repair

The clean sixteen-arm sweep at `39f73ab` exposed [local finding 52](../findings/52-outbox-best-effort-fixture-propagates-key-failures.md):
the synthetic callback propagated a poison failure to healthy same-key rows
even under `BestEffort`. Fifteen arms passed, but the exponential/seven-key arm
`01a0fdab-5460-70f7-8b21-7106d0ed8273` failed `every-row-terminal` and
`poison-attempt-ceiling`. All original artifacts remain sealed and valid.
A two-row witness reproduced the fixture mismatch without a database or
runtime publisher. Terminal-state revision 2 now selects broker failure groups
using the requested ordering policy. The healthy same-key witness succeeds;
four regressions distinguish key, source, whole-batch and independent grouping.

All sixteen repaired durable PostgreSQL 18 controls pass under
`runs/ep13-outbox-terminal-controls-after/`, with 240 schema checks and 256
artifact size/SHA-256 checks. The matrix covers all four policies, both backoff
schedules, zero/seven keys, 200 rows and batch size 17 at seed
`4252662818734786`. The nondefault batch/key combination exercises several
same-key rows together. The Keiro suite passes 54 examples and the full
`nix develop -c just verify` gate passes. These dirty local controls establish
functional coverage. Revision 3 adds independent terminal replay below, with
twenty clean digest-linked controls and confirmed attestations. Existing fixture/oracle boundaries apply; no new architecture decision
or upstream issue follows from this local repair.

### Independently replayable outbox terminal checks

Terminal-state revision 3 seals `logs/outbox-terminal-observations.json`,
validated by `schemas/kenshou.outbox-terminal-observations.v1.schema.json`.
It preserves initial and final rows, ordered callback claims and results,
callback timestamps, raw broker headers and publisher summaries. The CLI's
`Kenshou.Cli.Attest.KeiroTerminal` reconstructs the seeded poison/rejection
classification, consumed attempts and skipped successors, retry delays,
broker cardinality and all twelve business checks without importing the
scenario or runtime oracle. Missing workload inputs or incompatible revisions
are refused. Five checked-in fixtures and thirteen mutation/regression examples
cover missing/duplicate appends, terminal metadata, attempts, premature retries,
summary counts and complete input requirements.

Four compact policy controls and sixteen policy/backoff/key controls pass and
independently replay under `runs/ep13-terminal-replay-fixtures/` and
`runs/ep13-terminal-replay-matrix/`: 320 schema checks and 340 artifact checks.
Boundary testing exposed [local finding 53](../findings/53-outbox-terminal-oracle-rejects-single-attempt-exhaustion.md):
the earlier oracle treated transient failures as recoverable even when the
single allowed attempt was exhausted. Revision 3 accepts the correct dead
status and transient error in that case. Sixteen more durable controls under
`runs/ep13-terminal-attempt-boundaries/` vary all four policies, zero/three keys
and budgets one/two. All pass and replay independently, with another 256 schema
and 272 artifact checks. The one-attempt arms end dead; the two-attempt arms
end sent after retry. The preserved failing witness has valid artifacts and
is not retroactively repaired.

Full `nix develop -c just verify` passes, including 54 Keiro and 79 CLI examples.
The exploratory controls above are dirty investigations. Twenty fresh durable
controls at clean revision `06632b755f0b3eb24fd784a9c1651e96b79cb081` repeat the
sixteen policy/backoff/key arms plus four one-attempt transient-exhaustion arms.
All twelve business checks pass in each run, all 320 schema and 340 artifact
checks pass, and each digest-linked investigation has a confirmed independent
VC-1 attestation with all six evidence checks passing. Earlier terminal revisions
and other outbox scenarios retain their independent replay limitations.

| Terminal control | Clean run | Confirmed attestation |
| --- | --- | --- |
| `per-key-head-of-line-constant-keys-0` | [01a0fdd4-20b0-7485-bc27-ac793cb81d20](../verification/runs/keiro/2026/10/01a0fdd4-20b0-7485-bc27-ac793cb81d20.md) | [01a0fdfd-ac08-7385-b455-029fd877a008](../verification/attestations/2026/10/01a0fdfd-ac08-7385-b455-029fd877a008.md) |
| `per-key-head-of-line-constant-keys-7` | [01a0fdd4-2e2b-779f-a61a-969fbbe2e338](../verification/runs/keiro/2026/10/01a0fdd4-2e2b-779f-a61a-969fbbe2e338.md) | [01a0fdfe-9f1f-7320-9461-b26884a01d62](../verification/attestations/2026/10/01a0fdfe-9f1f-7320-9461-b26884a01d62.md) |
| `per-key-head-of-line-exponential-keys-0` | [01a0fdd4-3d5d-7249-a1d4-457db8f5fdc0](../verification/runs/keiro/2026/10/01a0fdd4-3d5d-7249-a1d4-457db8f5fdc0.md) | [01a0fdff-921e-73d4-8f19-b8dfd7f8fb1a](../verification/attestations/2026/10/01a0fdff-921e-73d4-8f19-b8dfd7f8fb1a.md) |
| `per-key-head-of-line-exponential-keys-7` | [01a0fdd4-4b0c-75f7-a616-a1d526579ef6](../verification/runs/keiro/2026/10/01a0fdd4-4b0c-75f7-a616-a1d526579ef6.md) | [01a0fe00-7d98-720d-b575-24556d5fd1a2](../verification/attestations/2026/10/01a0fe00-7d98-720d-b575-24556d5fd1a2.md) |
| `per-source-stream-constant-keys-0` | [01a0fdd4-5bfb-7784-9b44-1e08afdcd867](../verification/runs/keiro/2026/10/01a0fdd4-5bfb-7784-9b44-1e08afdcd867.md) | [01a0fe01-7e19-7101-839c-93c9c9ca67c9](../verification/attestations/2026/10/01a0fe01-7e19-7101-839c-93c9c9ca67c9.md) |
| `per-source-stream-constant-keys-7` | [01a0fdd4-6f8a-7586-863b-c7d3a26cdc17](../verification/runs/keiro/2026/10/01a0fdd4-6f8a-7586-863b-c7d3a26cdc17.md) | [01a0fe02-6863-74cd-995b-8da168749659](../verification/attestations/2026/10/01a0fe02-6863-74cd-995b-8da168749659.md) |
| `per-source-stream-exponential-keys-0` | [01a0fdd4-90d6-71f7-806b-ccb279bac815](../verification/runs/keiro/2026/10/01a0fdd4-90d6-71f7-806b-ccb279bac815.md) | [01a0fe03-4df1-7495-814f-d6f28c952da2](../verification/attestations/2026/10/01a0fe03-4df1-7495-814f-d6f28c952da2.md) |
| `per-source-stream-exponential-keys-7` | [01a0fdd4-ab45-7122-b939-e9a11b545919](../verification/runs/keiro/2026/10/01a0fdd4-ab45-7122-b939-e9a11b545919.md) | [01a0fe04-35a1-77d3-a7ee-a5a8cefc2b4c](../verification/attestations/2026/10/01a0fe04-35a1-77d3-a7ee-a5a8cefc2b4c.md) |
| `stop-the-line-constant-keys-0` | [01a0fdd4-bd93-76ec-b7a4-8d406c2595a3](../verification/runs/keiro/2026/10/01a0fdd4-bd93-76ec-b7a4-8d406c2595a3.md) | [01a0fe05-2a7d-722a-9ef0-c9c8ba6d37bb](../verification/attestations/2026/10/01a0fe05-2a7d-722a-9ef0-c9c8ba6d37bb.md) |
| `stop-the-line-constant-keys-7` | [01a0fdd4-cd2a-711b-9e40-4067c052994b](../verification/runs/keiro/2026/10/01a0fdd4-cd2a-711b-9e40-4067c052994b.md) | [01a0fe06-0ec2-76d6-8663-89da0e1efca0](../verification/attestations/2026/10/01a0fe06-0ec2-76d6-8663-89da0e1efca0.md) |
| `stop-the-line-exponential-keys-0` | [01a0fdd4-dd13-716c-8f01-ef03789d1ccc](../verification/runs/keiro/2026/10/01a0fdd4-dd13-716c-8f01-ef03789d1ccc.md) | [01a0fe06-f5ba-7414-a81d-85853133ad80](../verification/attestations/2026/10/01a0fe06-f5ba-7414-a81d-85853133ad80.md) |
| `stop-the-line-exponential-keys-7` | [01a0fdd4-ff90-7610-9402-2b566853a9c6](../verification/runs/keiro/2026/10/01a0fdd4-ff90-7610-9402-2b566853a9c6.md) | [01a0fe08-241d-73b7-84c2-27060cff8114](../verification/attestations/2026/10/01a0fe08-241d-73b7-84c2-27060cff8114.md) |
| `best-effort-constant-keys-0` | [01a0fdd5-1d09-77c3-85fe-1f73552416f7](../verification/runs/keiro/2026/10/01a0fdd5-1d09-77c3-85fe-1f73552416f7.md) | [01a0fe09-031b-768d-ab8e-219a422e94e6](../verification/attestations/2026/10/01a0fe09-031b-768d-ab8e-219a422e94e6.md) |
| `best-effort-constant-keys-7` | [01a0fdd5-35cf-7782-9c18-29ffc0388787](../verification/runs/keiro/2026/10/01a0fdd5-35cf-7782-9c18-29ffc0388787.md) | [01a0fe09-eab1-739a-8f18-ca235414f5fb](../verification/attestations/2026/10/01a0fe09-eab1-739a-8f18-ca235414f5fb.md) |
| `best-effort-exponential-keys-0` | [01a0fdd5-435b-757b-bfcd-eb222f33f8f1](../verification/runs/keiro/2026/10/01a0fdd5-435b-757b-bfcd-eb222f33f8f1.md) | [01a0fe0a-e399-74e2-860e-f7fa689d142d](../verification/attestations/2026/10/01a0fe0a-e399-74e2-860e-f7fa689d142d.md) |
| `best-effort-exponential-keys-7` | [01a0fdd5-50cf-772f-bdd9-e4c467b4f27d](../verification/runs/keiro/2026/10/01a0fdd5-50cf-772f-bdd9-e4c467b4f27d.md) | [01a0fe0b-dfae-75e2-b033-b190ddc87c5a](../verification/attestations/2026/10/01a0fe0b-dfae-75e2-b033-b190ddc87c5a.md) |
| `per-key-head-of-line-attempts-1-keys-3` | [01a0fdd5-6eb2-734e-a17b-1a27b1f40073](../verification/runs/keiro/2026/10/01a0fdd5-6eb2-734e-a17b-1a27b1f40073.md) | [01a0fe0c-c10e-7734-9529-1bb4aeaf961b](../verification/attestations/2026/10/01a0fe0c-c10e-7734-9529-1bb4aeaf961b.md) |
| `per-source-stream-attempts-1-keys-3` | [01a0fdd5-8c36-73f0-92db-d79d8be0adac](../verification/runs/keiro/2026/10/01a0fdd5-8c36-73f0-92db-d79d8be0adac.md) | [01a0fe0d-a58d-7658-b2fc-fac30ef0b443](../verification/attestations/2026/10/01a0fe0d-a58d-7658-b2fc-fac30ef0b443.md) |
| `stop-the-line-attempts-1-keys-3` | [01a0fdd5-98a7-77b3-8808-326830ac747a](../verification/runs/keiro/2026/10/01a0fdd5-98a7-77b3-8808-326830ac747a.md) | [01a0fe0e-8a0f-7695-81a1-3835ee92178c](../verification/attestations/2026/10/01a0fe0e-8a0f-7695-81a1-3835ee92178c.md) |
| `best-effort-attempts-1-keys-3` | [01a0fdd5-ab18-7415-aa33-951954eba2ea](../verification/runs/keiro/2026/10/01a0fdd5-ab18-7415-aa33-951954eba2ea.md) | [01a0fe0f-6b5c-74d0-a802-1dffa74dcbb7](../verification/attestations/2026/10/01a0fe0f-6b5c-74d0-a802-1dffa74dcbb7.md) |

### Remaining non-soak work

Queue throughput revision 2 now implements bounded versus continuous-worker
execution, ordinary versus long polling, actual runtime batch sizing, and
connection-pool sizing. Five local durable PostgreSQL 18 functional smokes
held all three business verdicts with zero worker errors and contributions
from both workers. Their run IDs are `01a0f431-439b-7324-a24c-e3fd7be04efe`
(bounded unordered), `01a0f432-0143-77b5-8dfd-54b808db887c` (worker unordered),
`01a0f432-9955-771c-90a0-a192b57bdd50` (long-poll unordered),
`01a0f432-e076-76a5-8c79-e87d1576064f` (long-poll FIFO), and
`01a0f433-14d2-77d1-a419-545c1faee070` (ordinary-poll FIFO with in-memory tracing
and collected metrics, default three-connection pool). Each is under
`runs/ep13-worker-throughput/`. They handled 731–732 jobs exactly once and
emptied their queue. The five-second steady windows had 500 samples per
operation, below the 1,000-sample gate: all are exploratory/inconclusive and
excluded from controlled baseline performance claims. The unsupported
bounded-drain/long-poll combination was rejected in
`01a0f433-3d85-7360-ad2b-5cbd4e3cd448`. The package suite passes 38 examples,
including doctored duplicate, missing, substituted, and empty delivery maps.
`nix develop -c just verify` passed after the component-graph reconciliation;
all six run specs, results, and manifests passed schema validation, and every
stored artifact matched its manifest size and SHA-256 digest.

Queue throughput revision 3 adds periodic native collection and private JSON
and Prometheus endpoints to the continuous-worker arm. The new
`keiro/queue/correctness/worker-metrics-contract` checks the active gauge, Done,
Retry, and Dead counters against independent handler and SQL facts. The eight
contract arms passed; the four five-second throughput controls held all three
business checks over 732–735 exactly-once jobs, with no worker errors. Collected
worker checkpoints matched the handler totals. The two scraped contract runs
completed 42 native endpoint scrapes in total, and the two-worker long-poll
benchmark completed 540; all reported zero scrape failures. Metrics-off and
bounded-drain controls produced no native collection file. Each run spec,
result, and manifest passed schema checks, every artifact matched its recorded
size and SHA-256, and periodic/checkpoint rows were checked. These dirty local
runs under `runs/ep13-worker-metrics/matrix/` establish functional wiring only;
the benchmark results remain inconclusive and do not add baseline records.
`nix develop -c just verify` passed, including the full build, shared tests,
cohort link proof, component graph, evidence bundles, schemas, and self-tests.

To reproduce the scraped contract from the repository root:

```bash
nix develop -c cabal run kenshou -- run keiro/queue/correctness/worker-metrics-contract --dim pg.durability=durable --dim telemetry.metrics=serve-scraped --dim telemetry.tracing=sdk-inmemory --set metrics.scrape-interval-ms=100 --out runs/ep13-worker-metrics
```

The command should report `passed`, five held checks, active/complete JSON and
Prometheus logs, periodic native samples, a completion checkpoint, and successful
scrape rows for both worker endpoints. Metrics-off arms keep the job checks and
explicitly mark metrics disabled in the measurements summary.

| Arm | Local functional run | Result |
| --- | --- | --- |
| `contract-off-off` | `01a0f494-b342-72b3-9925-6ed20319ef16` | passed |
| `contract-off-collect` | `01a0f494-cc19-772f-82a1-eadeea697ca4` | passed |
| `contract-off-serve` | `01a0f494-e63b-757e-8712-4ac34a49fdb8` | passed |
| `contract-off-serve-scraped` | `01a0f495-0ada-71ed-86d8-2abdd5feebd0` | passed |
| `contract-sdk-inmemory-off` | `01a0f495-2878-762f-8408-3b315e2704da` | passed |
| `contract-sdk-inmemory-collect` | `01a0f495-4235-763b-8b0b-e6bd876c0f1a` | passed |
| `contract-sdk-inmemory-serve` | `01a0f495-5d12-72cc-af96-8d4e08f559ca` | passed |
| `contract-sdk-inmemory-serve-scraped` | `01a0f495-8d89-7563-9dee-31a6cf3dbd0c` | passed |
| `throughput-workers-poll-every-off` | `01a0f495-a62f-7310-8816-bfd06a7ab8d5` | inconclusive |
| `throughput-workers-poll-every-collect` | `01a0f495-d715-767a-84d0-a6fa6958544f` | inconclusive |
| `throughput-workers-long-poll-serve-scraped` | `01a0f496-0add-7438-bc66-bad4267c0504` | inconclusive |
| `throughput-drain-poll-every-serve-scraped` | `01a0f496-539a-771d-b087-e7bd3251bdd5` | inconclusive |

Queue throughput revision 4 adds `queue.provision=standard|unlogged` through
the released provisioning API. PostgreSQL `relpersistence` is captured before
and after load, requiring the requested active main persistence and logged
main archive, DLQ, and DLQ archive. The default remains standard. Durable
server settings do not imply crash durability for the unlogged main table;
these arms inject no database crash. Partitioned provisioning remains outside
the base fixture. No cohort pin or upstream change is required.

The ten local arms below used fresh durable PostgreSQL 18 fixtures, seed
`4252662818734786`, 100 jobs/second, a five-second steady window, two consumers,
pool size eight, batch ten, and telemetry off for ordinary polling. The two
long-poll arms used tracing `sdk-inmemory` and metrics `collect`, with native
processed counters independently reconciled to handled jobs. All four
business/provision checks held in every arm, with 7,345 jobs handled exactly
once, zero errors, zero final depth, and both consumers participating. All
30 schema checks and 264 manifested artifact digest/size checks passed.
Every overall outcome is inconclusive under the short-window sample gate.
Artifacts and the matrix summary are under `runs/ep13-queue-provision/`;
these dirty workstation runs are functional evidence and are not published
as clean controlled comparisons.

| Provision / execution / ordering / polling | Run ID | Jobs |
| --- | --- | ---: |
| standard / drain / unordered / poll-every | `01a0f5ce-509b-70e4-a38e-f13a6ccfddee` | 734 |
| standard / drain / fifo-heads / poll-every | `01a0f5ce-8c00-7159-836a-8b10d715e02d` | 740 |
| standard / workers / unordered / poll-every | `01a0f5ce-c224-740e-8db7-8ec1446d343a` | 732 |
| standard / workers / fifo-heads / poll-every | `01a0f5ce-fc24-71e7-8f8a-a668abeaf2aa` | 732 |
| unlogged / drain / unordered / poll-every | `01a0f5cf-3b58-76a4-8e8c-7fa71d1d23ac` | 733 |
| unlogged / drain / fifo-heads / poll-every | `01a0f5cf-74fc-7307-be5b-d128e3fce507` | 735 |
| unlogged / workers / unordered / poll-every | `01a0f5cf-ae8f-7431-b887-a60ebc4de94b` | 734 |
| unlogged / workers / fifo-heads / poll-every | `01a0f5cf-e202-7693-a249-094f81b2e844` | 735 |
| standard / workers / unordered / long-poll | `01a0f5d0-200e-778e-8385-84a92dbecc9d` | 733 |
| unlogged / workers / unordered / long-poll | `01a0f5d0-5f9e-76a6-96f1-33f393f2b862` | 737 |

1. Complete the outbox scenario knobs, producer-path SQL oracles, and generalized role/oracle modules. Broaden the remaining concurrency fault and ordering controls beyond the passing default sweep.
2. Complete inbox effect/persistence oracles and the remaining documented correctness arms. The current table and delegated runs establish the baseline, but the planned matrix is wider.
3. Complete queue worker-path outcomes, fault modes, ordering controls, and richer DLQ/acknowledgement oracles. Native worker counter and endpoint checks are implemented; the broader fault and pre-handler paths remain open.
4. Extend the implemented outbox/inbox native metrics serving to remaining process roles and finish queue fault and pre-handler coverage. The messaging contract and all four outbox/inbox benchmarks now serve their native store and OpenTelemetry endpoints; controlled overhead acceptance remains open. The inbox `InboxInProgress` case now has a passing durable contract run; the queue pre-handler DLQ case observed zero process spans and is recorded as `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-7`.
5. Run a clean controlled standard/unlogged provision comparison and finish broader performance acceptance. Revision 4 implements provision variation and its SQL oracle; the local matrix below establishes functional coverage. Five-pair worker/polling configuration comparisons have clean saved results: execution shape remains inconclusive at p99, and long polling with a 100 ms interval trades lower allocation and live memory for a handler-start latency regression. Both comparisons are durably recorded and independently confirmed for VC-2/VC-3; individual business-oracle attestation remains open. The separate idle-poll benchmark covers polling cost.
6. Refresh `docs/layers/keiro.md`, resolve whether any local ADRs are actually required, validate the bundle, and record final non-soak outcomes. Full plan acceptance also depends on the planned soaks.

### Evidence at a glance

| Area | Representative durable evidence | Result |
| --- | --- | --- |
| Outbox correctness | `runs/01a0d4fe-*` through `runs/01a0d501-*`; 20,000-row publisher run `runs/01a0d4e0-fd0a-76aa-91a5-623739770404` | Default sweep exited zero; nine direct passes, two scoped expected failures. |
| Inbox correctness | `runs/01a0d55b-0d2e-76c5-8648-95d750c77b54`; `runs/01a0d55d-a013-702b-902b-dfe97964b4ad` | GC schedule reproduced DOC-10; two-effect mutation failed only the intended oracle. |
| Queue correctness | `runs/01a0d539-*` through `runs/01a0d53c-*`; FIFO run `runs/01a0d51b-71dc-72be-97b8-e8404c67590a` | Default sweep exited zero; eight direct passes, three scoped expected failures. |
| Benchmarks | Outbox `runs/01a0d566-56e8-7179-93f1-5bf480c9119c`; inbox `runs/01a0d58e-f76a-739d-821a-c1983474427c`; queue `runs/01a0d571-c677-739f-bd01-9b72c804d995` | Representative durable runs reached benchmark grade; all seven identifiers emit artifacts. |
| Comparison and overhead | `runs/keiro-producer-local-comparison.json`; `runs/overhead-outbox/overhead-01a0d579-3e04-740b-be98-63ee4c60addf/overhead-report.json`; `runs/overhead-queue/overhead-01a0d57b-8c4b-721b-b04d-08c1b3d43ac8/overhead-report.json` | Comparison inconclusive under sample policy; overhead reports have three valid blocks each. |
| Full inbox soak | [Schema-valid four-hour run](../verification/runs/keiro/2026/10/01a0fa97-bbd6-76a5-a7c0-03c6aa076562.md) | All eight checks held; six bounded resource probes stable; all 11 schemas and 27 artifact checks pass. Independent soak VC-1 remains open. |
| Telemetry | Inbox `runs/01a0d593-371a-772a-902b-6d5fa0c5a23f`; queue `runs/01a0d599-6794-76cf-9399-000ff650b6e1` | Enabled arms passed on durable PostgreSQL. Queue pre-handler job reached DLQ without a handler call or process span. |

## Surprises & Discoveries

- (2026-10-02 UTC) The terminal-state policy sweep exposed a local callback/oracle mismatch under best-effort ordering. [Finding 52](../findings/52-outbox-best-effort-fixture-propagates-key-failures.md) records the isolated witness and policy-aware repair; all sixteen repaired controls pass.

- (2026-10-02 UTC) Full outbox artifact validation exposed [finding 50](../findings/50-verdict-writers-omit-required-assertion-counters.md): shared verdict writers omitted required assertion counters. This is a local harness defect; intact digests and held business checks do not imply schema-valid artifacts. Producer repairs and an emission guard preserve outcomes, while existing sealed evidence retains its limitation.

- (2026-10-01) Parking only a handler did not freeze its continuous intake:
  the first worker prefetched its own expired lease before the contender could
  handle it. Exploratory run `01a0f8fd-8a4e-7600-ae15-84126fe62353` errored on
  that unrealized schedule. Suspending the process after the delivery mark
  made the competing-read control deterministic; this is harness scheduling,
  not an owner defect.
- (2026-10-01) Direct schema validation found that the messaging verdict writer
  omitted required `examined` and `violations` counters. It now records one
  examined aggregate assertion and zero/one violations per cell, retaining
  domain population counts separately. Existing sealed files are unchanged.


- The full inbox soak exhausted its cell wall-clock limit during finalization. Measurement reached done and all eight business verdict files held, but those facts cannot substitute for a sealed nested run. Finding 49 distinguishes this confirmed timeout from finding 47’s lease-loss interruption and leaves finalization cost unattributed.

- Native Shibuya worker `processed` counts include acknowledged Retry deliveries. The Done/Retry/Dead schedule therefore expects five received, four processed, and one failed, while the independent handler and SQL oracles expect three terminal Done jobs and one dead job. The first local endpoint run `01a0f48e-cadb-7446-a333-bea5274336d1` failed only the two completion checks because the harness expected three processed; both native and served counters correctly reported four. This is an oracle correction, not an owner defect. Stopped apps unregister their processors, so the harness captures completion metrics before stopping workers.

- The throughput benchmark stored handled identities in a set, which hid repeated calls for the same job, and its batch knob limited the drain count without setting `JobTuning.batchSize`. Revision 2 counts calls per identity and sets the read batch on both execution paths. The bounded API ignores `JobTuning.polling`, so a long-poll arm requires the continuous-worker path rather than silently measuring immediate reads.
- Repository verification exposed stale planned build edges for `runtime-assembly`. Its direct build edges now match the resolved `kenshou-runtime` library; transitive PGMQ, migration, and Kafka adapter coupling through the shared harness fixtures remains explicit as runtime edges under [ADR-5](../adr/0005-select-runs-from-a-checked-in-component-graph.md). Unused telemetry package edges were removed. This preserves conservative runner-change selection without claiming those packages are direct dependencies.

- The zombie publisher schedule still reproduced BUG-5 after replacing the controller's direct maintenance call with a separate worker process. The maintenance pass reported one reclaimed row, and `01a0d508-7c44-7310-a608-2deaca6b798f` retained `knownDefect.status=reproduced`, `blocking=false`, with only the two scoped finalization verdicts violated.

- The eleven-scenario default durable sweep completed with exit 0. Its two printed `failed` outcomes were the documented inline-order limitation and BUG-5 stale finalization; both run results set `knownDefect.status=reproduced` and `blocking=false`. All nine other scenarios passed, including the new producer crash replay.

- The ack-coupled subscription made the intended replay schedule observable: after kills at versions 1, 2 and 3, the final worker saw versions 1, 2, 3, 4, 5, 6, 7 and 8. In `01a0d4fc-ca80-772e-b0da-d68cb1cfde0a`, every version had one inserted producer identity, redeliveries returned `ProducerDuplicateIdentical`, and eight outbox rows yielded eight ordered broker records.

- The first per-source terminal matrix with callback timing failed `one-broker-record-per-sent-row` in `01a0d4e9-e068-70be-9cc1-2eb79a1cabbb`. The synthetic broker grouped only by `(source, key)`, so it appended a later key from the same source after an earlier key failed; Keiro then marked that later row skipped. The per-source scenario callback now stops appending later rows of the failed source while continuing independent sources. The corrected arm passed in `01a0d4ea-f034-72e9-b50d-ab348a3c8742`.

- The existing `disjoint-ownership` check could pass without comparing ownership times: one broker record and one attempt per row do not prove that callback intervals never overlap. The strengthened 2,000-row durable run recorded 63 complete intervals spanning every row, with contributions from all four publishers; the verdict held in `01a0d4dd-4973-75ed-8de1-29264806b6ad`.

- The zombie scenario confirmed the unverified claim-fencing concern. In `01a0d4d0-d80e-73df-a678-185c7d8bd738`, P1's stale failed outcome changed P2's active claim to `failed` after P2 had appended its broker record; in `01a0d4d2-4640-7008-9a09-e46104d73de9`, the stale outcome made it `dead`. The `succeeded` control also let P1 finalize P2's claim. `Keiro.Outbox.Schema` finalization statements test only `outbox_id` and `status = 'publishing'`, with no claim generation. The upstream report is `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-5`.
- A worker Dead DLQ wrapper includes `"original_headers": null` for an untraced job, while `readDlq` decodes that field as `Nothing`. The initial new `worker-dead-wrapper` verdict failed in `runs/01a0d4cb-a54c-73d9-8471-fb92ba8a728b` because it expected decoded headers to be present. A diagnostic rerun showed the raw wrapper and the corrected oracle passed in `runs/01a0d4cd-1ba2-7100-a84a-17c48e0a619d`.
- The table broker previously returned its global `record_offset` as the Kafka partition offset, unlike the in-process broker's per-partition offset. A transactional `(topic, partition)` counter now assigns stable offsets on append, and `multi-process-publishers` checks that every partition has `0..n-1` even with four competing processes.
- The initial 32-row and 2,000-row multi-process reruns passed, but one publisher did all the work in each run. Passing four worker PIDs alone did not exercise concurrent claiming. A later 2,000-row rerun deliberately failed `publisher-participation`: three workers saw no claimable head while the fourth owned all twenty keys, then exited. The worker now retries idle passes for one second, with a brief pause between productive batches. The strengthened durable rerun passed in `01a0d44b-c4d9-705d-b4b7-0f2d5600f632`; two publishers appended 1,939 and 61 records, and all contract verdicts held.
- A harness-held advisory lock made the inline ordering inversion deterministic in `01a0d450-8f91-7488-a358-a1ff743257ca`. The first transaction's `created_at` was 16:47:25.693036 UTC, the second's was 16:47:25.708822 UTC, and the broker observed `second`, then `first`. `schedule-realised` and `no-loss` held; `per-key-order` was violated with `knownDefect.status=reproduced` for `mori://shinzui/keiro/okf/user-documentation/concepts/DOC-16`.
- A repeat of the inline ordering arm produced the same three verdict statuses in `01a0d452-908a-774e-87a0-18983be910b4`. This confirms that the advisory-lock schedule is repeatable on the local durable PostgreSQL fixture.
- The shared outbox knob decoder passed its default and invalid-configuration unit checks (33 `kenshou-keiro-test` examples total). After wiring it into two correctness scenarios, `terminal-state-matrix` passed a 200-row default-knob durable run in `01a0d457-9c65-71df-8b8e-216208690afa` and an exponential, best-effort, no-key arm in `01a0d458-9ca1-70f9-8f0d-910f23fa551a`. `per-key-order-serialized` passed a 200-row per-source arm in `01a0d459-84d6-70c8-9169-ccae83772aca`.
- The broker unit suite now checks that fault decisions are independent of callback order and that hooks observe zero records before append and one after append. Together with the durable per-partition offset verdict, this closes the Broker implementation item (35 `kenshou-keiro-test` examples pass).
- The publisher role's before-append hook can now park after the claim but before any broker write. In `01a0d45d-ecee-769a-a09f-8694399bbdfb`, killing it left 32 publishing rows and zero broker records; maintenance reclaimed them, and recovery sent 32 rows with no duplicates. The after-append one-kill regression arm passed in `01a0d45e-3d29-7211-abf0-5c52d4965629`.
- The direct producer-path control arm of `concurrent-inline-enqueue-order` passed in `01a0d462-2dce-7589-86c1-04c8bda467f4`: two serialized `enqueueProducerEventTx` calls generated distinct stable message IDs, and their broker order matched the source-event order. This is not yet a subscription restart or concurrency test.
- The inline arm still reproduced its scoped ordering failure after the producer-path knob was added, in `01a0d462-7423-745d-b423-c2f9ea7713de`.
- In the after-claim exhaustion run `01a0d465-ccf9-757b-b16c-75d80ab20333`, two `SIGKILL`s consumed the attempt ceiling for the first batch without any broker refusal. Maintenance left 32 dead rows; 32 later rows of the same key were published, and `attempts-exhausted-by-crashes`, `no-loss`, and all other verdicts held.
- The ordinary after-append arm passed again after the exhaustion oracle was added, in `01a0d466-47b8-745b-8a85-230cd778b7df`.
- A table lock held the outbox finalization statement after the broker append; the controller terminated that blocked PostgreSQL backend. The first attempt then tried an additional process-group kill, which failed with `Operation not permitted` because the worker had already exited on the connection error. Removing the redundant signal yielded a passing `backend-kill-during-mark` arm in `01a0d46b-2fd8-70e0-b433-bb3f1f392d64`: 32 rows remained in `publishing`, maintenance reclaimed them, and broker replay produced exactly 32 bounded duplicates. The worker control log reports a connection error and a normal process exit.
- The project shell does not expose `ghc` directly to a plain `cabal` invocation. `nix develop -c cabal build kenshou-keiro kenshou-check kenshou-measure kenshou-diagnose kenshou-telemetry` passed; use `nix develop -c` for the subsequent commands. The completed write-side fixture exports the modules named in Interfaces and Dependencies.
- The first outbox scenario passed with durable PostgreSQL: `keiro/outbox/correctness/failure-skips-successors` wrote its verdicts under `runs/01a0d15a-0b81-771e-9bea-a08921d97bf2` and the CLI reported `passed`. This establishes the scenario registration and fixture integration, not the other ten outbox scenarios.
- The implemented `kenshou list` accepts positional scenario selectors and has no `--component` option. The old plan command exited 2 with `Invalid option '--component'`; the plan now uses selectors such as `list 'keiro/outbox/**'`.
- In the first `publisher-misbehaviour` run, the throw and missing-outcome checks failed when both rows shared one key: the outbox marked the later row as skipped without consuming its attempt after the first failure. The rejection checks passed. The test now uses distinct keys for the throw, missing and unknown-outcome arms, and keeps one key for the rejection arm, which is meant to prove a rejected head does not block its successor.
- The first `producer-identity` run passed seven of eight checks. For a changed message-ID namespace, `ProducerIdentityConflict` carries the attempted identity: its outbox UUID remains the original UUID while its message ID carries the new namespace. The scenario initially compared that returned identity with the original message ID; the check now compares it with `deriveProducerIdentity` for the changed producer and still demands exactly `IdentityField`.
- The corrected `publisher-misbehaviour` and `producer-identity` scenarios passed on durable PostgreSQL in runs `01a0d167-23fd-75f0-a9dd-716c6287b9b7` and `01a0d16c-1722-73c2-9e19-ad577f97a48b`.
- The 5,000-row `per-key-order-serialized` default passed on durable PostgreSQL in run `01a0d16c-bb1b-756e-a4d3-26c6e56a1a6a`.
- The first table-broker run failed at table creation because `offset` is a PostgreSQL keyword. Renaming the column to `record_offset` fixed it; `failure-skips-successors` then passed in run `01a0d174-2602-7004-b1bf-8173e1e7cae1`.
- The role registry requires `layer/name` identifiers, so the outbox publisher is registered as `keiro/outbox-publisher`. The first process-death run passed on durable PostgreSQL in `01a0d177-db24-754e-9fd6-30bf28bbd987`: the controller observed all 32 broker records, killed the publisher, saw 32 `publishing` rows, confirmed an ordinary publisher pass reclaimed none, then maintenance requeued them and replay produced exactly two records per message.
- The inbox envelope round trip passed in run `01a0d17b-6554-720a-a28b-d9ddb32744bd`. The first poison accounting arm passed in `01a0d17c-a11c-76c9-b4e6-1ca06d73f2f4`.
- The first effectively-once matrix run failed only its persistence-shape check: the shared outbox workload generated empty payloads, so full-envelope and dedupe-only were indistinguishable. Giving each probe a nonempty message-ID payload made the check meaningful. Full-envelope and dedupe-only then passed in `01a0d17e-6446-724d-925d-11f61af93d59` and `01a0d17f-3e26-7551-be30-a1eca5575c8b`. The CLI uses `--set` for a knob override, not `--knob`.
- The PGMQ migration is available under `SchemaPgmq` in the environment. The first queue validation run passed in `01a0d182-5dea-740f-9266-42f966963458`; the stronger SQL read-count check initially hit a decoder mismatch because `read_ct` is narrower than `bigint`, and an explicit SQL cast fixed it. The full scenario passed in `01a0d184-2021-7578-bab7-766c6e1a7b12`.
- The queue retry ceiling scenario passed in `01a0d186-b8df-704a-bfd1-51c82cee2701`. Its DLQ query checks `dead_letter_reason=max_retries_exceeded` and wrapper read counts of four and one for the three-attempt and zero-attempt policies respectively.
- The inbox batch scenario passed in `01a0d188-bf5b-7211-9fd4-0504b828a6d8`: clean deliveries shared one PostgreSQL transaction, a repeated key stayed positional, and a throwing delivery triggered per-message fallback without double effects. The matrix still passed after adding a transaction ID to the shared effect table in `01a0d189-681c-7193-9195-552fb32500ec`.
- The crash scenario's first implementation used the command fixture's generic verdict writer, which gave files a `keiro-fixture-` prefix and omitted crash evidence. A messaging verdict writer now emits the plan's exact verdict filenames with enqueue, broker, kill, duplicate counts and the killed PID. The durable rerun passed in `01a0d18b-be3c-7219-a804-c2fae6acf6fa`.
- The repeated after-append crash arm passed at 32 rows and three kills in `01a0d18e-abf1-7387-b6a9-14177f45550f`, then at its 2,000-row default with 20 keys and three kills in `01a0d18f-117a-7149-9aa8-3c6a5da4939d`. The first kill held maintenance for three stale-row timeouts; later kills reclaimed their 32-row batches after each timeout. The final oracle checked all 2,000 sent rows, bounded duplicate records, and first-record per-key order.
- The four-process publisher arm passed at 2,000 rows in `01a0d191-2bab-7250-b036-0929cfc66bf6` and at its 20,000-row default in `01a0d191-8636-75b7-a79d-eb8c1e3a0a43`. Each row had one broker record and one attempt; per-key order held. The scenario records each publisher's broker count, but does not yet read callback start/end facts to independently establish non-overlapping ownership intervals.
- `docs/layers/keiro.md` now has Outbox, Inbox and Job queue sections describing the implemented probes, durable checks, and current CLI selectors. The sections require another pass when the remaining planned scenarios and telemetry arms are implemented.
- Initial `job-outcome-semantics` arms passed in `01a0d194-e4c1-71b0-bf34-d6459848537e`. Direct queue and DLQ reads confirmed Done deletes the row, explicit Retry delays redelivery and increments the handler's attempt, delayed enqueue waits before first delivery, and Dead moves the row to a DLQ with a `poison_pill` reason.
- The first inbox process race passed in `01a0d197-aabb-745f-80ef-6a332bcbb12a`. Four consumers started against one key with a one-second transactional handler; exactly one reported `processed`, three reported `duplicate`, and SQL contained one completed inbox row and one effect.
- The first winner-kill attempt timed out because `SIGKILL` closed the worker process but PostgreSQL continued its sleeping backend until the query ended. The controller now polls `pg_stat_activity` for the parked `pg_sleep(30)` query and explicitly terminates that backend after killing the process. The kill arm passed in `01a0d19c-2d9e-7275-91df-88dc05d18e2d`; a no-kill rerun passed in `01a0d19c-b9d6-773d-8e32-11889b92545e`.
- The continuous queue worker stopped after its first polling backend termination, leaving the next batch queued. The first attempt was interrupted while waiting through later batches; the controller now stops when the role exits. Durable runs `01a0d1a5-1650-76e3-8cd2-4614dd07ff19` and `01a0d1a6-a1b0-7753-abc2-a5b50d1d5b76` failed the survival and no-loss checks. The role log reports `PgmqSessionError` with `UnexpectedRowCountStatementError` for `pgmq.read`. The adapter's `retryingTransient` path consults `Pgmq.Effectful.isTransient`, which classes statement row-count errors as permanent. Reported at `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-3`.
- With `KnownDefect` attached, run `01a0d1a8-a608-70aa-aca6-8f8272384b92` still reports `outcome=failed` and the three failed contract cells, with `knownDefect.status=reproduced`; the CLI exits zero for this expected failure. Unit tests remain green (15 examples).
- Expanded `job-outcome-semantics` passed in `01a0d1aa-a16b-7187-b8eb-35f3eb169a81`, adding the default retry delay, archive path, batch IDs and rows, and the `x-pgmq-group` header.
- The drain-handler exception arm passed in `01a0d1ab-f709-7594-b68c-ad4c861ba02b`: the failed handler counted zero settled jobs, left its row hidden, and the row redelivered after the one-second visibility timeout.
- The payload-decode arms passed in `01a0d1ad-d304-715a-bcfa-633b6381a68e`: a corrupted body moved to the DLQ with `invalid_payload`, while a future-version body remained queued, was hidden during its retry delay, and its `read_ct` rose from one to two on the next delivery.
- `crash-redelivery-cadence` passed with `PollEvery 1` in `01a0d1b0-e9e6-7507-88a0-4dbb61bf2fc1` and `01a0d1b6-4762-7781-8f97-8a52245b0bb4`: three killed handlers gave attempts 0, 1, 2, delivery gaps of about three seconds, and a DLQ wrapper with `read_count=4`, despite a 60-second retry policy delay. Its long-poll arm instead skipped an attempt or inflated the DLQ read count in `01a0d1b2-0605-71c5-a5c2-5d064a97b35d`, `01a0d1b3-8a6c-7624-aa6f-7fff066f8787`, and `01a0d1b4-5232-707b-abed-404ce0d0db3e`. Reported at `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-4`; the verdict-preserving rerun `01a0d1b5-b342-7584-8a62-771055f84aad` records `knownDefect.status=reproduced`.
- The worker-path `lease-extension` probe initially stopped before the second six-second unextended handler finished. With a longer observation window, `01a0d1b9-f099-700e-8593-b6eaece98606` passed: the unextended job wrote two effects and the extended job wrote one. Revision 3 now supplies the controlled drain arm and direct SQL read-count oracle, described in Progress.
- The worker Done/context arm passed in `01a0d1bc-a179-7337-8461-76fd02b42ac3`: a supervised worker emitted attempt zero and `headers=Nothing`, inserted one effect, and deleted its source row.
- The first per-source and stop-the-line failure-skip pass mixed in earlier failed rows from the same database, so its pass-summary totals were larger than the arm's own ten rows. A 60-second backoff keeps prior failed rows ineligible during subsequent arms. The durable rerun passed all three policy arms in `01a0d1bf-aa69-705c-8820-404149d0736a`.
- The added per-source and stop-the-line rejection arms passed in `01a0d1c1-0d0e-71d9-ac18-a1cc8b650a70`: both published the rejected row's successor, and stop-the-line left `haltedOn` empty.
- The ADR-42 frozen outbox UUID and message ID vector passed in `01a0d1c2-d768-703a-89cd-d213dde7400b`, alongside the identity replay and conflict checks.
- All eight `terminal-state-matrix` policy/backoff combinations passed at 200 rows on durable PostgreSQL; the exponential runs were `01a0d1c3-afdd-74be-9388-31027efdd784`, `01a0d1c3-e98e-7565-841f-c0548647cd24`, `01a0d1c4-22d7-7425-a7fc-3541de801a11`, and `01a0d1c4-5b42-7464-9856-467a5efffc32`.
- The first per-source serialized-order run failed multiple oracles because the synthetic broker callback kept appending later keys after an earlier row of the same source failed, while Keiro marked those later rows skipped. The per-source arm now dispatches one source row at a time and stops on the failure, so its broker log and Keiro's source-level skipped rows agree. It passed at 200 rows in `01a0d1c6-a2ab-700c-978b-72354c820d41` and at 5,000 rows in `01a0d1c7-2777-7548-80a7-bfe54acdccf8`. Stop-the-line passed at 200 and 5,000 rows in `01a0d1c6-ed12-73e1-8395-3e5236071a76` and `01a0d1c7-e11d-76bb-813a-559ae2ee9a7e`.


## Decision Log

- Decision: Collect native worker metrics through the public Shibuya master API and serve each master through the released metrics server. Keep server cleanup outside the telemetry scope so endpoint scraping finishes before servers stop; checkpoint counters before app shutdown. Bump queue throughput to revision 3 and register a separate worker metrics correctness contract. The component graph selects this contract for changes to `mori://shinzui/shibuya/packages/shibuya-metrics`, through its existing core runner dependency.
  Rationale: Existing released APIs provide the required counters and HTTP responses without upstream changes. Independent handler/SQL checks and the measurement recorder remain authoritative for business correctness and timing, following [ADR-7](../adr/0007-record-measurements-independently-of-the-feature-under-test.md). Bounded drainers have no worker master, so they retain generic telemetry without native worker claims. This follows existing telemetry and layer ownership decisions; no new ADR is required.
  Date: 2026-09-30

- Decision: Keep the default bounded execution shape and three-connection runtime pool, expose explicit worker/polling/pool controls, and bump only the throughput scenario to revision 2. Cancelled continuous-worker tasks call `stopApp` before releasing their runtime pool.
  Rationale: The controls make the intended workload observable while preserving the default execution shape; changed batch and conservation semantics require a new scenario revision. Existing measurement and fixture ADRs apply, so no new architecture decision is needed for this extension.
  Date: 2026-09-30

- Decision: The producer crash role parks after the outbox transaction commits and before filling the subscription acknowledgement variable; the controller kills the parked process and restarts with the same subscription name.
  Rationale: This pins the real replay window without relying on timing and proves that Kiroku's checkpoint has not advanced while Keiro's producer identity has already been stored.
  Date: 2026-09-24

- Decision: In the per-source terminal matrix, invoke the synthetic broker one source row at a time and stop dispatching a source after its first failure in the callback; continue other sources.
  Rationale: Keiro's per-source outcome grouping marks later rows of a failed source skipped, so the harness callback must not append those rows to the broker before Keiro can apply that rule.
  Date: 2026-09-24

- Decision: Scope the zombie publisher's `KnownDefect` to `stale-finalization-no-effect` and `terminal-consistent-with-success`; keep `schedule-realised` a blocking contract verdict.
  Rationale: The upstream finding covers late finalization only. A run that misses maintenance reclamation or P2's claim cannot count as a reproduction.
  Date: 2026-09-24

- Decision: For an untraced worker job, the DLQ oracle checks that the raw wrapper contains `original_headers` with JSON null and that Keiro's decoded `originalHeaders` is `Nothing`.
  Rationale: The adapter preserves a header field even when the producer supplied none; requiring a non-null decoded value would reject a valid wrapper.
  Date: 2026-09-24

- Decision: Outbox and inbox scenarios publish to and consume from a synthetic broker owned by this plan (an in-process log for single-process scenarios and benchmarks, a harness-owned PostgreSQL table for multi-process scenarios), never the Kafka fixture of `docs/plans/11-…`.
  Rationale: Integration Point 1 of the MasterPlan forbids layer packages from importing one another, and a red keiro layer must be attributable to keiro. keiro's publisher takes a caller-supplied publish function, so a synthetic broker exercises the whole shipped code path; the real broker is exercised by `docs/plans/11-…` and `docs/plans/15-…`.
  Date: 2026-09-20

- Decision: A documented limitation (concurrent inline enqueue order, the inbox GC-versus-insert race, the two-statement dead-letter and redrive windows) is encoded as a scenario whose oracle is the ideal property, preceded by a `schedule-realised` guard verdict, and carrying a `KnownDefect` reference to the upstream document that states the limitation. If the guard is false the outcome is `inconclusive`, never `passed`.
  Rationale: Asserting the ideal property makes the scenario flip to green if upstream ever removes the limitation, while the guard prevents a vacuous green when the adversarial interleaving did not actually occur. The reference makes the expected failure non-blocking, as Integration Point 3 specifies.
  Date: 2026-09-20

- Decision: Crash windows are hit with harness-owned hooks first (the publish callback, the job handler and the inbox handler's SQL are harness code and can block on the control channel, on an advisory lock or on `pg_sleep`), with a row-lock holder second, and with the TCP proxy only where the runtime offers no hook at all (between the two statements of `tryInsertCompletedTx`, and inside `redriveDlq`).
  Rationale: Hooks and locks are deterministic and work over the Unix socket that `ephemeral-pg` uses; the proxy needs a TCP listener and widens a window rather than pinning it.
  Date: 2026-09-20

- Decision: Each component exports `scenarios :: [Scenario]` and `roles :: [WorkerRole]` from its namespace root (`Kenshou.Suite.Keiro.Outbox`, `.Inbox`, `.Queue`), and this plan edits the bundle module created by `docs/plans/12-…` only to import and concatenate them.
  Rationale: The MasterPlan gives this plan three namespaces inside a package whose single `bundle` value belongs to another plan. Concatenation of exported lists is the smallest edit that keeps ownership clear and merges cleanly with `docs/plans/14-…`.
  Date: 2026-09-20

- Decision: Inbox handler effects are SQL writes into a harness-owned table without a uniqueness constraint, and handler invocations are counted with a PostgreSQL sequence.
  Rationale: An inbox handler is a `Hasql.Transaction.Transaction` and cannot perform IO, so a process-local ledger cannot see it. A table without a unique key makes a double application countable instead of impossible, and `nextval` is not rolled back, so invocations that ended in rollback are still counted.
  Date: 2026-09-20

- Decision: Runtime validators that are pure functions (`mkOutboxPublishOptions`, `mkRetryPolicy`, `mkJobTuning`, `queueRef`) are not re-tested here; `JobConsumptionConfigError` is, through `jobProcessorWithContext` and `runJobOnceWithContext`.
  Rationale: The MasterPlan excludes unit tests that belong inside a runtime package. The consumption check is different: `validateJobConsumptionConfig` is not exported, and the behaviour that matters (no PGMQ read is issued on rejection) is only observable against a database.
  Date: 2026-09-20

- Decision: Every soak is registered twice from one implementation: `<id>` with tier `soak` and placement `cell`, and `<id>-reduced` with tier `extended` and placement `either`.
  Rationale: Integration Point 3 gives a scenario exactly one tier, while every coverage plan must offer its soak locally at reduced duration. Two identifiers keep the compatibility key of a twenty-minute run distinct from that of a four-hour run. Collapse to one identifier if the kernel turns out to derive the tier from a duration knob.
  Date: 2026-09-20

- Decision: All scenarios in this plan support `pg.version=18` only.
  Rationale: keiro requires PostgreSQL 18 (kiroku's schema under keiro uses `uuidv7()`); running the keiro layer on 17 would fail in migration, not in the component under test.
  Date: 2026-09-20

- Decision: `keiro/outbox/concurrency/zombie-publisher-finalization` is included as an exploratory contract check without a `KnownDefect` reference.
  Rationale: Reading `Keiro.Outbox.Schema` shows that finalization statements are conditional on `status = 'publishing'` but carry no claim token, so a publisher that outlives `publishingTimeout` may finalize a row that another publisher has re-claimed. This is unverified. If the scenario fails, the finding is filed upstream and the reference added then.
  Date: 2026-09-20

- Decision: The publisher-misbehaviour scenario gives each row a distinct key when checking callback-wide errors, and uses one shared key only for the rejection subcase.
  Rationale: Ordered publisher policies skip later same-key rows after a failure, so sharing a key would conflate callback normalization with the intentional skip rule and make the attempt-count assertion wrong.
  Date: 2026-09-24

- Decision: The multi-process publisher role waits through a one-second idle window and yields briefly after productive batches, and its scenario requires at least two publishers to append records.
  Rationale: With twenty keys, one publisher can temporarily own every claimable head. Other workers previously exited on their first empty claim, so four live PIDs did not create a competition test. The idle window lets them claim newly released heads, while the participation verdict prevents a vacuous pass.
  Date: 2026-09-24

- Decision: Messaging verdicts accept a per-cell invariant class, so the documented inline ordering limitation is recorded as an implementation verdict while schedule and no-loss remain contract verdicts.
  Rationale: The known-defect reference covers only `per-key-order`. A failed schedule or no-loss check must still block, and the ordering limitation must be visible as a violated ideal property.
  Date: 2026-09-24


## Outcomes & Retrospective

The durable baseline now exercises the outbox, inbox, and queue through correctness, process-failure, concurrency, telemetry, and benchmark scenarios. All seven planned benchmark identifiers are registered. The package suite passes 54 examples. Queue throughput now supports continuous workers, both polling modes, standard/unlogged provision variation, and native metrics collection and serving, with oracles that detect duplicate calls and incorrect physical persistence. The eight-arm worker metrics contract passes; its new short local smokes are functional evidence only. Known defects remain visible as scoped expected failures rather than silent passes; the local finding records above retain their canonical owner references. The documented inline ordering, inbox GC, and DLQ/redrive windows also remain scoped expected failures.

The plan is still in progress. The concrete non-soak gaps are listed in Progress. The repaired-payload full inbox run has a digest-linked record with eight held business checks, six stable resource probes and all eleven schemas valid. This closes inbox full-soak artifact acceptance; independent soak VC-1 remains open. Full acceptance still requires queue/outbox resource acceptance and schema-valid full-soak verdicts, controlled process-isolation evidence, remaining matrix coverage and independent Keiro verdict verification. The earlier producer comparison remains inconclusive under its three-pair policy. New clean five-pair queue comparisons preserve execution-shape p99 uncertainty and measure a latency/memory tradeoff for 100 ms long polling; both are durably recorded and independently confirmed for VC-2/VC-3, with individual business-oracle attestation still open. The earlier overhead reports remain local evidence. The new clean outbox metrics investigation has sixteen digest-linked runs and three independently confirmed VC-2/VC-3 comparisons, while serving and A/A tail latency remain inconclusive. The matched reduced process/in-process diagnostics are also recorded; short killed incarnations and historical default-GC attribution remain open. No configuration experiment measures an upstream release change.


## Context and Orientation

This repository, `keiro-runtime-kenshou`, is a verification suite. Its MasterPlan is `docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md`; this plan is child 13. The suite is one cabal project whose packages match `kenshou-*/*.cabal`. A scenario is a Haskell value with the four-segment identifier `<layer>/<component>/<kind>/<name>` (kind is `correctness`, `concurrency`, `soak` or `benchmark`), a cost tier (`smoke` under one minute, `standard` under ten, `extended` under an hour, `soak` hours), a placement (`local`, `cell`, `either`; a cell is a leased set of Google Cloud machines), typed knobs with defaults and allowed values, the dimension values it supports, and optionally a `KnownDefect` reference (a `mori://` URI) that turns an expected failure into a reported, non-blocking outcome. Scenarios are not test-suite tests; they are run with the `kenshou` executable, which writes a run directory (`run-spec.json`, `run-result.json`, `manifest.json`, `samples/`, `series/`, `verdicts/`, `diagnosis/`, `logs/`) and exits 0 for passed, 1 for failed, 2 for a usage error, 3 for inconclusive, 4 for errored or infrastructure-failure. Four dimensions cut across all scenarios: `telemetry.tracing` (`off`, `noop`, `sdk-inmemory`, `sdk-otlp`), `telemetry.metrics` (`off`, `collect`, `serve`, `serve-scraped`), `pg.durability` (`fsync-off`, `durable`; `durable` is mandatory for benchmarks and crash scenarios) and `pg.version` (`17`, `18`).

This plan extends the package `kenshou-keiro`, layer `keiro`, which `docs/plans/12-cover-the-keiro-command-processor-process-managers-and-routers.md` creates. It owns the namespaces `Kenshou.Suite.Keiro.Outbox.*`, `Kenshou.Suite.Keiro.Inbox.*` and `Kenshou.Suite.Keiro.Queue.*` and the components `outbox`, `inbox` and `queue`. It hard-depends on that plan and, transitively, on the kernel (`docs/plans/2-build-the-harness-kernel-for-scenarios-dimensions-run-specs-and-results.md`), the measurement toolkit (`docs/plans/4-…`), the correctness toolkit (`docs/plans/5-…`), the diagnostics toolkit (`docs/plans/6-…`) and the telemetry toolkit (`docs/plans/7-…`). Layer packages never import one another; `kenshou-keiro` may depend on the kernel, the toolkits and the runtime libraries only. At the time of writing none of those plans is implemented and the repository contains no Haskell code, so Interfaces and Dependencies states what this plan expects from each, and the first step of Concrete Steps checks it.

The code under test lives in `mori://shinzui/keiro`, on disk at `/Users/shinzui/Keikaku/bokuno/keiro` (read-only for this work). The released cohort pins keiro, keiro-core and keiro-pgmq at 0.17.0.0; the messaging sources at the repository head (`d0e0dfbd` when this plan was written) are identical to the tags `keiro-0.17.0.0` and `keiro-pgmq-0.17.0.0`. Every name below was checked against that source. Records in keiro use `generic-lens` labels (`opts ^. #batchSize`); `keiro-pgmq` uses `OverloadedRecordDot` (`tuning.batchSize`). keiro's effects are `effectful` effects: `Store :> es` is kiroku's database effect, interpreted for IO with `Kiroku.Store.Effect.runStoreIO :: KirokuStore -> Eff '[Store, Error StoreError, IOE] a -> IO (Either StoreError a)`, and `Kiroku.Store.Transaction.runTransaction :: Store :> es => Tx.Transaction a -> Eff es a` runs a `hasql-transaction` body at `READ COMMITTED` on the store's pool (default `poolSize = 10`).

Terms used throughout. An integration event is a public message one service publishes for others, as opposed to a private domain event in its own event store; in keiro it is `Keiro.Integration.Event.IntegrationEvent` with fields `messageId`, `source`, `destination` (the topic), `key` (the partition key, optional), `eventType`, `schemaVersion`, `contentType`, `payloadBytes`, `occurredAt`, optional `sourceEventId`, `sourceGlobalPosition`, `causationId`, `correlationId`, `traceContext` and `attributes`. At-least-once delivery means a message may be delivered more than once but is never lost; effectively-once means the effect of handling it is applied once although delivery is at-least-once. `FOR UPDATE SKIP LOCKED` is the PostgreSQL row-locking clause that lets competing workers claim disjoint rows without waiting on one another. Head-of-line blocking means an unfinished earlier item prevents later items of the same group from being taken. A visibility timeout is the period after a queue read during which the message is hidden from other readers; when it expires without an acknowledgement the message becomes readable again. A dead-letter queue (DLQ) holds messages that will not be retried; redrive moves them back. `SIGKILL` is the Unix signal that ends a process immediately without running any cleanup, which is what this suite means by a crash; terminating a backend means ending one PostgreSQL server process with `pg_terminate_backend`, which the client sees as a lost connection. An advisory lock is a PostgreSQL lock on an application-chosen number; `pg_advisory_xact_lock` holds it until the transaction ends. A ledger is the correctness toolkit's bounded, per-process, append-only file of facts ("produced X", "observed X"), merged at verification time; a verdict is one JSON document (`kenshou.verdict/v1`) per invariant checker with counts, counter-examples and a class. The class is `contract` when the runtime documents the property as a guarantee (only these block a release) and `implementation` when the property is merely true of, or hoped of, the current code. Open-loop load issues requests on a schedule regardless of completions and measures latency from the intended start, which corrects coordinated omission (the error of a closed loop that stops sending while the system is slow and so never records the slow period); latencies are kept in HDR-style log-linear histograms. A leak verdict is the diagnostics toolkit's judgement over sampled series (live bytes after major garbage collections, threads, file descriptors, connections, relation sizes). W3C trace context is the `traceparent`/`tracestate` header pair that links spans across processes. OKF is the house format for documentation bundles (Markdown with YAML frontmatter) validated by the `okf` tool; `mori` is the house registry that resolves `mori://` URIs to projects and documents.

The outbox is `Keiro.Outbox` with `Keiro.Outbox.Types`, `.Schema`, `.Identity` and `.Kafka` (all exposed; `Keiro.Outbox.Rejection` is hidden and re-exported through `.Types`), files under `/Users/shinzui/Keikaku/bokuno/keiro/keiro/src/Keiro/Outbox*`. Rows live in `keiro.keiro_outbox`: primary key `outbox_id`, `UNIQUE (source, message_id)`, `status` one of `pending`, `publishing`, `sent`, `rejected`, `failed`, `dead`, plus `attempt_count`, `next_attempt_at`, `last_error`, `published_at`, `rejected_at`, `rejection_code`, `rejection_detail`, and `created_at`/`updated_at` defaulting to `now()`, which in PostgreSQL is the transaction start time. There are two ways in. The inline path is `enqueueIntegrationEventTx :: OutboxId -> IntegrationEvent -> Tx.Transaction ()` (insert, `ON CONFLICT (source, message_id) DO NOTHING`), meant to be called inside the transaction of a command. The canonical producer path is `enqueueProducerEventTx :: IntegrationProducer e -> RecordedEvent -> Word32 -> IntegrationEventDraft -> Tx.Transaction ProducerEnqueueOutcome`, called from a subscription over the service's private events; it derives both identifiers purely from `(source, producer name, source event id, emission index)` (`deriveProducerIdentity`: an `OutboxId` that is a UUIDv8 made from a SHA-256 digest and a `messageId` of the form `<namespace>_v1_<sha256 hex>`) and returns `ProducerInserted`, `ProducerDuplicateIdentical`, or `ProducerIdentityConflict` with the differing `ConflictField` classes (`IdentityField`, `RoutingField`, `SchemaField`, `PayloadField`, `OccurredAtField`, `CausalField`, `TraceField`, `AttributesField`, `ProvenanceField`) without touching the retained row. If `garbageCollectSent` deletes the conflicting row between the insert and the comparison read, the function retries the insert. Publication is `publishClaimedOutbox :: (IOE :> es, Store :> es) => ([OutboxRow] -> Eff es [(OutboxId, PublishOutcome)]) -> OutboxPublishOptions -> Maybe KeiroMetrics -> Eff es OutboxPublishSummary`. It is one pass, not a loop: it reads the wall clock, claims one batch with `claimOutboxBatch policy batchSize now` (rows `pending` or `failed` whose `next_attempt_at` has passed, ordered by `(created_at, outbox_id)`, locked with `FOR UPDATE SKIP LOCKED`, filtered by the ordering policy, moved to `publishing` with `attempt_count + 1`), calls the publish function once with the whole batch (once per row under `StopTheLine`), and finalizes all rows in one transaction in which every update is conditional on the row still being `publishing`. `PublishOutcome` is `PublishSucceeded`, `PublishFailed Text` or `PublishRejected PublishRejection` (built with `mkPublishRejection code detail`; codes match `[a-z][a-z0-9._-]*`, at most 64 characters). A missing outcome counts as `PublishFailed "publisher returned no outcome"`; a thrown publisher fails every row of that call with the exception text. In an ordered group, the first failure marks that row `failed` (or `dead` when `attempt_count >= maxAttempts`) with `next_attempt_at = now + nextDelay backoff attemptCount`, and returns every later row of the group to `failed` with its attempt given back, `next_attempt_at = now` and `last_error = "skipped: earlier record for the same key failed"`; these count in `OutboxPublishSummary.retried`. Groups are per `(source, key)` under `PerKeyHeadOfLine` (rows with no key are their own group), per `source` under `PerSourceStream`, the whole batch under `StopTheLine` (which also sets `haltedOn`), and per row under `BestEffort`. A rejection is terminal and releases its successors under every policy, including `StopTheLine` (`mori://shinzui/keiro/okf/adrs/concepts/ADR-37`). A `dead` row also stops blocking its key, so consumers can see a gap. Defaults (`defaultPublishOptions`): `batchSize = 32`, `maxAttempts = 10`, `backoff = ConstantBackoff 2`, `orderingPolicy = PerKeyHeadOfLine`, `publishingTimeout = 300`, `tracer = Nothing`; `ExponentialBackoff (ExponentialBackoffOptions initial maxDelay multiplier)` gives `min maxDelay (initial * multiplier ^ (attempt - 1))`. Rows left in `publishing` by a dead publisher are reclaimed only by `outboxMaintenancePass :: OutboxMaintenanceOptions -> Maybe KeiroMetrics -> Eff es OutboxMaintenanceSummary`: rows whose `updated_at` is older than `publishingTimeout` become `dead` with `last_error` `reclaimed: publisher crashed mid-publish` when `attempt_count >= maxAttempts`, otherwise `failed` and immediately claimable. `garbageCollectSent :: NominalDiffTime -> UTCTime -> Eff es Int` deletes only `sent` rows older than the retention; after that a producer replay reinserts and republishes the same `messageId`. The documented ordering caveat: because ordering uses `created_at`, two concurrent transactions that enqueue the same key inline can commit in the opposite order of their `created_at`, and a publisher can publish the later one first; the producer path is safe because a subscription serializes. keiro's own suite has no adversarial test for this.

The inbox is `Keiro.Inbox` with `.Types`, `.Schema`, `.Delegated` and `.Kafka`. Rows live in `keiro.keiro_inbox`, primary key `(source, dedupe_key)`, `status` one of `processing` (legacy, never written today), `completed`, `failed`, with `attempt_count`, `last_error`, `completed_at`. `runInboxTransaction :: Maybe KeiroMetrics -> InboxDedupePolicy -> IntegrationEvent -> Maybe KafkaDeliveryRef -> (IntegrationEvent -> Tx.Transaction a) -> Eff es (Either InboxError (InboxResult a))` computes the key with `dedupeKeyFor` and, in one transaction, inserts the row already `completed` with `ON CONFLICT DO NOTHING`; if the insert took effect it runs the handler, otherwise it reads the existing row and returns `InboxDuplicate`, `InboxInProgress` or `InboxPreviouslyFailed`. A handler exception rolls back the row too. The policies are `PreferIntegrationMessageId` (default), `PreferSourceEventIdentity` (source event id, else global position), `KafkaDeliveryIdentity` (`topic:partition:offset`; does not collapse a republish) and `CustomDedupeKey Text`; an envelope lacking the needed field yields `Left (DedupePolicyUnsatisfied policy)`. `runInboxTransactionWith` adds `InboxPersistence` (`PersistFullEnvelope` or `PersistDedupeOnly`, which stores an empty payload and no schema, trace or attributes on success; failed rows always keep the full envelope). `runInboxTransactionWithRetries mMetrics attemptCeiling …` records a failed attempt in a second transaction when the handler throws (`InboxHandlerFailed message attempts`), retries a failed row while `attempt_count < ceiling`, and otherwise returns `InboxPreviouslyFailed` without running the handler; `Tx.condemn` is deliberately not treated as a failure. `runInboxTransactionBatch mMetrics attemptCeiling policy persistence deliveries handler` runs a whole batch in one transaction, classifies repeated keys inside the batch as duplicates, and falls back to the per-message retrying runner if anything throws or if a re-read shows the batch was condemned. The delegated family (`runInboxDelegated`, `runInboxDelegatedWithRetries` with `mkDelegatedRetryContext ceiling attempt`, `runInboxDelegatedBatch`) reads and writes no inbox row: the handler receives the dedupe key and must return `DelegatedFresh a` or `DelegatedDuplicate`; `Keiro.Inbox.Delegated.delegatedEventId consumer source dedupe target operation` derives a UUIDv5 receipt and `delegatedCommand` protects one aggregate command with it, failing with `DelegatedCommandWithoutReceipt` when the command appends nothing (`mori://shinzui/keiro/okf/adrs/concepts/ADR-43`). The type `InboxIdempotence` (`IdempotenceInboxTable | IdempotenceDelegated`) is descriptive only; no runtime function takes it, so choosing an idempotence owner means choosing a runner family. `garbageCollectCompleted :: NominalDiffTime -> UTCTime -> Eff es Int` deletes completed rows older than the retention, which therefore is the deduplication window. The module header documents a race: a concurrent GC can delete the conflicting completed row between the insert attempt and the lookup; the handler then commits without any deduplication row and a later redelivery runs it again. keiro has no test that reproduces it. One drift to be aware of: the user guide `docs/user/inbox.md` still describes an insert as `processing` followed by an update, while the source inserts `completed` directly.

The job queue is the package `keiro-pgmq` (`mori://shinzui/keiro/packages/keiro-pgmq`), modules `Keiro.PGMQ` (umbrella), `.Runtime`, `.Job`, `.Dlq`, `.Metrics`, `.Codec`. It is the only keiro component that uses shibuya's supervised runner (`Shibuya.App.runApp`) through `mori://shinzui/shibuya-pgmq-adapter`, on top of `mori://shinzui/pgmq-hs`. A queue named `q` is the table `pgmq.q_q` with columns `msg_id`, `read_ct`, `enqueued_at`, `last_read_at`, `vt`, `message`, `headers`, and an archive `pgmq.a_q`. `queueRef :: Text -> QueueRef` derives a legal physical name and a `<physical>_dlq` name. `withJobRuntime :: Text -> Maybe Tracer -> (JobRuntime -> IO a) -> IO a` builds its own `hasql-pool` pool with library defaults — three connections and a ten-second acquisition timeout — separate from the kiroku store pool, and offers no way to size it; `runJobEff :: JobRuntime -> Eff '[Reader PgmqAdapterEnv, Pgmq, Tracing, Error PgmqRuntimeError, IOE] a -> IO (Either PgmqRuntimeError a)` selects `runTracingNoop` with `runPgmq` for `Nothing` and `runTracing` with `runPgmqTraced` for `Just tracer`. A `Job p` has `jobName`, `jobQueue`, `jobCodec`, `jobOrdering` and `jobPolicy`; a handler returns `Done`, `Retry RetryDelay`, `RetryDefault` or `Dead Text`. `defaultRetryPolicy` is `maxRetries = 5`, `defaultRetryDelay = RetryDelay 60`, `useDeadLetter = True`; `defaultJobTuning` is `visibilityTimeout = 30` (whole seconds, `Int32`), `batchSize = 1`, `polling = PollEvery 1` (alternative `LongPoll maxSeconds intervalMs`, which holds a pool connection for the whole poll), `ordering = Unordered`. There are two execution shapes. `runJobWorkers :: SupervisionStrategy -> Int -> [Eff es (ProcessorId, QueueProcessor es)] -> Eff es (Either AppError (AppHandle es))` runs processors built by `jobProcessor` or `jobProcessorWithContext` under shibuya supervision (`IgnoreFailures` or `StopAllOnFailure`; shibuya never restarts a failed processor); the adapter retries transient poll and acknowledgement errors five times with backoff from 0.1 s doubling to at most 5 s, moves a message to the DLQ and deletes the source in one transaction, turns a thrown handler into a retry, and dead-letters a message whose `read_ct` exceeds `maxRetries` before the handler runs. `runJobOnceWithContext :: JobTuning -> Int -> Job p -> (JobContext es -> p -> Eff es JobOutcome) -> Eff es Int` (and `runJobOnce :: Int -> Job p -> (p -> Eff es JobOutcome) -> Eff es ()`) reads PGMQ directly; there, a thrown handler issues no finalizer at all, and dead-lettering is two separate statements — send to the DLQ, then delete from the main queue — so a crash between them leaves the message in both places. `Keiro.PGMQ.Dlq.redriveDlq :: Job p -> Int -> Eff es Int` has the mirror window (send to main, then delete from the DLQ), and every DLQ read hides the row for thirty seconds. Crash redelivery happens when the visibility timeout expires, not after `defaultRetryDelay`, and every expiry consumes one `read_ct`. `JobOrdering` is `Unordered`, `FifoThroughput`, `FifoRoundRobin` or `FifoHeads`; groups are named by the `x-pgmq-group` header (`enqueueToGroup`), `FifoHeads` leases at most one absolute head per group so a failed head blocks only its group, and both entry points throw `JobConsumptionConfigError` (`InvalidJobTuning`, `JobOrderingMismatch`, `UnsafeLegacyFifoBatch`) before any read when the tuning is invalid, disagrees with the job's declared ordering, or combines a legacy FIFO mode with `batchSize > 1` (`mori://shinzui/keiro/okf/adrs/concepts/ADR-44`). `JobContext` gives `extendLease`, the zero-based `attempt`, and `headers` (drain path only). keiro's own suite marks one test pending at `keiro-pgmq/test/Main.hs:660`: "runJobWorkers survives a transient database error during polling — needs a deterministic … fault injector". keiro's plan to add real crash tests, `mori://shinzui/keiro/plans/132-add-real-crash-window-tests-on-a-durability-enabled-fixture` under `mori://shinzui/keiro/masterplans/22-make-the-test-infrastructure-exercise-real-crash-and-production-semantics` (neither URI resolves through the released Mori yet), was never started; this plan delivers the outbox, inbox and queue parts of it from outside.

Observability seams. Tracing is switched per call site with `Maybe Tracer`: `OutboxPublishOptions.tracer` opens one Producer-kind span named `send <destination>` per publish call with the attribute `keiro.outbox.batch.size`; `Keiro.Telemetry.withConsumerSpan :: Maybe Tracer -> Maybe Text -> KafkaInboundRecord -> Maybe IntegrationEvent -> (Maybe Span -> m a) -> m a` opens a Consumer-kind span `process <topic>` parented from the record's W3C headers; `withJobRuntime connStr (Just tracer)` gives one Consumer-kind span `<jobName> process` per delivery on both execution shapes with `messaging.*` attributes and `shibuya.ack.decision` (`mori://shinzui/keiro/okf/adrs/concepts/ADR-1`), plus lower-level PGMQ operation spans. Metrics are OpenTelemetry instruments built once with `Keiro.Telemetry.newKeiroMetrics :: Meter -> m KeiroMetrics` and passed as `Maybe KeiroMetrics`: `keiro.outbox.backlog`, `.published`, `.rejected`, `.retried`, `.deadlettered`, `.reclaimed`, `.identity.conflict` (recorded only when the caller invokes `recordProducerEnqueueOutcome`), and `keiro.inbox.processed`, `.duplicates`, `.failed`, `.poisoned`, `.backlog` (via `sampleInboxBacklog`). keiro exposes no HTTP endpoint; `keiro-pgmq` has no instruments, only SQL-backed `jobQueueMetrics`, `jobDlqMetrics` and `queueDepth`.

There is no local ADR corpus yet: `docs/adr/` does not exist until `docs/plans/1-bootstrap-the-kenshou-repository-and-pin-the-runtime-cohort.md` creates it as a profile-governed OKF bundle. The cross-repository decisions this plan relies on are: `mori://shinzui/keiro/okf/adrs/concepts/ADR-37` (outbox rejection is terminal, releases ordered successors, and finalization is conditional and counted only when committed); `mori://shinzui/keiro/okf/adrs/concepts/ADR-42` (producer outbox identity is a frozen, versioned function of source-event coordinates; differing retained content is refused, never overwritten), which with `mori://shinzui/keiro/okf/adrs/concepts/ADR-24` gives the checkers exact expected identifiers; `mori://shinzui/keiro/okf/adrs/concepts/ADR-43` (delegated inbox intake needs one downstream event receipt covering the whole atomic operation); `mori://shinzui/keiro/okf/adrs/concepts/ADR-44` (every job declares its ordering; only group heads batch safely); `mori://shinzui/keiro/okf/adrs/concepts/ADR-45` (PGMQ provisioning preserves upstream SQL; partitioned queues need `pg_partman`, which the suite's extension-free PGMQ install does not provide, so partitioned queues are out of scope here); `mori://shinzui/keiro/okf/adrs/concepts/ADR-25` (worker loops survive per-pass and per-item failures), which the transient-polling-error scenario tests; and `mori://shinzui/keiro/okf/adrs/concepts/ADR-1` (one process span per delivery on both job paths). The documented limitations are referenced as `mori://shinzui/keiro/okf/user-documentation/concepts/DOC-16` (Durable Outbox), `mori://shinzui/keiro/okf/user-documentation/concepts/DOC-10` (Idempotent Inbox) and `mori://shinzui/keiro/okf/user-documentation/concepts/DOC-25` (Work Queues). `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-38` (guarded recovery of dead outbox deliveries) is context for what `dead` means operationally. Two decisions of this plan deserve new local ADRs once `docs/adr/` exists: "keiro messaging scenarios use a synthetic broker; the Kafka fixture is reserved for the kafka and runtime layers", and "a documented limitation is verified by asserting the ideal property behind a realised-schedule guard with a KnownDefect reference" (check first whether `docs/plans/5-…`, `9-…` or `12-…` already recorded the second; amend rather than duplicate). Allocate handles with `okf id next docs/adr --profile docs/adr/profile.dhall ADR` and validate with `okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce`.


## Plan of Work

All new library modules go under `kenshou-keiro/src/Kenshou/Suite/Keiro/`, unit tests under `kenshou-keiro/test/Kenshou/Suite/Keiro/`, and both are listed in `kenshou-keiro/kenshou-keiro.cabal`. The bundle registration already exists. This plan also owns the messaging guide, raw observation schemas and fixtures, and scenario-specific independent replay modules under `kenshou-cli/src/Kenshou/Cli/Attest/`. Those replay modules consume sealed observations without importing the runtime or scenario oracles.

Conventions for every scenario below unless it says otherwise: `pg.version` supports `18` only; correctness scenarios support `pg.durability` `fsync-off` and `durable`, all other kinds support `durable` only; correctness and concurrency scenarios support `telemetry.tracing` in `off`, `noop`, `sdk-inmemory` and `telemetry.metrics` in `off`, `collect`; benchmarks and soaks support every value; the environment requirement is a migrated database with the components kiroku and keiro (queue scenarios add PGMQ), one database per run. Every scenario namespaces its data by run: outbox and inbox `source` values are `kenshou-<first 8 hex digits of the run id>-<n>`, queue logical names are `kenshou.<run8>.<name>` (short enough to stay under `queueRef`'s 43-character hashing threshold). Every random choice derives from the run seed. Worker processes set `application_name` in their connection string to the value the correctness toolkit's backend-termination injector expects, for both the kiroku store and the job runtime pool.

### Milestone 1 — Outbox scenarios

Scope: the shared messaging support (synthetic broker, fault plan, workload, worker roles, oracles) and eleven outbox scenarios. At the end, `kenshou list 'keiro/outbox/**'` shows them and each runs to an outcome locally. Acceptance is the behaviour listed per scenario plus unit tests that prove each oracle fails on doctored data.

The synthetic broker is `Kenshou.Suite.Keiro.Outbox.Broker`. It stores what a Kafka topic would: records with a topic, a partition (hash of the key modulo `broker.partitions`, default 4), a monotonically increasing offset, key, payload and headers, produced from `Keiro.Outbox.Kafka.outboxRowToKafkaRecord` so the wire mapping under test is keiro's own. The in-process backend is a `TVar` log for single-process scenarios and benchmarks; the table backend writes to `kenshou_fx.broker_log` (created with `CREATE SCHEMA IF NOT EXISTS kenshou_fx` and `CREATE TABLE IF NOT EXISTS` at scenario set-up, outside the pg-migrate ledger and outside the `keiro` schema) over a harness-owned connection that is not part of the kiroku pool. A broker model adds service time (`broker.invocation-micros` per call, default 1000; `broker.per-record-micros`, default 10), following the model keiro's own benchmark uses. A fault plan decides, as a pure function of the seed, the row's `messageId` and its `attemptCount`, whether the callback reports success, failure, rejection, throws, or drops the row's outcome, so multi-process runs are reproducible whatever the interleaving. The callback honours the contract keiro places on publishers: once a row of a `(source, key)` group has failed in a call, no later row of that group is appended in that call. Two hooks run inside the callback, one before the broker append and one between the append and the return of outcomes; crash scenarios use them to announce "batch claimed" or "batch appended" on the control channel and block until told to continue or killed.

```haskell
module Kenshou.Suite.Keiro.Outbox.Broker where

data BrokerRecord = BrokerRecord
  { topic :: !Text, partition :: !Int64, offset :: !Int64
  , key :: !(Maybe ByteString), payload :: !ByteString, headers :: ![(ByteString, ByteString)]
  , appendedAt :: !UTCTime, publisher :: !Text, attempt :: !Int }

data Broker = InProcessBroker !(TVar (Seq BrokerRecord)) | TableBroker !Hasql.Pool.Pool
data BrokerModel = BrokerModel { invocationMicros :: !Int, perRecordMicros :: !Int }

data FaultPlan = FaultPlan
  { seed :: !Word64, failRatio, rejectRatio, poisonRatio, throwRatio, dropOutcomeRatio :: !Double }
data FaultDecision = Succeed | FailOnce Text | RejectWith PublishRejection | AlwaysFail | ThrowInCall | DropOutcome
decide :: FaultPlan -> OutboxRow -> FaultDecision

data PublishHook = PublishHook { beforeBrokerAppend, afterBrokerAppend :: [OutboxRow] -> IO () }

publishCallback :: (IOE :> es) => Broker -> BrokerModel -> FaultPlan -> PublishHook
                -> [OutboxRow] -> Eff es [(OutboxId, PublishOutcome)]
readBroker :: Broker -> IO [BrokerRecord]                       -- offset order
toInboundRecord :: UTCTime -> BrokerRecord -> KafkaInboundRecord -- consumed by the inbox milestone
```

`Kenshou.Suite.Keiro.Outbox.Knobs` declares the knobs once and decodes them to `OutboxPublishOptions` through `mkOutboxPublishOptions` (a knob combination keiro rejects is a usage error, exit code 2). The knobs are `outbox.ordering-policy` (enum `per-key-head-of-line` default, `per-source-stream`, `stop-the-line`, `best-effort`), `outbox.batch-size` (int, default 32), `outbox.max-attempts` (int, default 10), `outbox.backoff` (enum `constant` default, `exponential`), `outbox.backoff-seconds` (decimal, default 2), `outbox.backoff-max-seconds` (decimal, default 60), `outbox.backoff-multiplier` (decimal, default 2.0), `outbox.publishing-timeout-seconds` (decimal, default 300), `outbox.publishers` and `outbox.enqueuers` (process counts, default 1), `outbox.enqueue-path` (enum `producer` default, `inline`), `outbox.rows` (int), `outbox.key-cardinality` (int; 0 means no key), `outbox.sources` (int, default 1), `outbox.payload-bytes` (int, default 1024), `outbox.maintenance-interval-ms` (int, default 500), `outbox.gc` (enum `off` default, `on`), `outbox.retention-seconds` (decimal), and the `broker.*` knobs above. Scenarios that must finish in minutes override three defaults and say so in their `KnobSpec`: `outbox.backoff-seconds=0.05`, `outbox.max-attempts=4`, `outbox.publishing-timeout-seconds=2`.

`Kenshou.Suite.Keiro.Outbox.Workload` generates integration events from the seed, each carrying a per-key sequence number in `attributes` so order can be judged from broker records alone. The inline path calls `enqueueIntegrationEventTx` with a UUIDv7 from `freshOutboxId`. The producer path appends account events through the fixture aggregate of `docs/plans/12-…` and runs a producer built with `mkIntegrationProducer` over a kiroku subscription, calling `enqueueProducerEventTx producer recorded 0 draft` and then `recordProducerEnqueueOutcome`. `Kenshou.Suite.Keiro.Outbox.Roles` registers four worker roles: `keiro.outbox.enqueuer`, `keiro.outbox.producer`, `keiro.outbox.publisher` (loops `publishClaimedOutbox` with a short idle sleep; under `StopTheLine` it records a `halted` fact when `haltedOn` is set and resumes after the backoff) and `keiro.outbox.maintenance` (loops `outboxMaintenancePass`, and `garbageCollectSent` when `outbox.gc=on`). Each publisher writes ledger facts for callback start, broker append and callback end with the row ids. `Kenshou.Suite.Keiro.Outbox.Oracle` holds the SQL oracles over `keiro.keiro_outbox` and the broker log.

`keiro/outbox/correctness/terminal-state-matrix` (tier `standard`, placement `either`) proves that every row reaches a terminal state under each of the four ordering policies and both backoff schedules. Knobs: the policy, backoff and batch knobs, `outbox.rows=2000`, `outbox.key-cardinality=50`, `broker.fail-ratio=0.1`, `broker.reject-ratio=0.02`, `broker.poison-ratio=0.01`. One process enqueues, then loops publisher passes until `countOutboxBacklog` is zero and no row is `publishing`, within a deadline derived from `maxAttempts` and the backoff. Oracle, class `contract`: every enqueued `outbox_id` is `sent`, `rejected` or `dead`; a row is `sent` exactly when the broker holds at least one record with its `messageId`; rejected rows carry the rejection code the fault plan chose and never appear in the broker; `dead` rows have `attempt_count = maxAttempts` and were chosen as poison, or failed transiently when `maxAttempts=1`; their error text must identify the matching failure; for every row `attempt_count` equals the number of callback invocations that contained it and were not skipped; after a failed (not skipped) attempt k of a row, its next callback starts no earlier than `nextDelay backoff k` after the failed callback ended. The sums of `published`, `rejected`, `retried` and `dead` over all pass summaries equal the corresponding SQL counts.

`keiro/outbox/correctness/per-key-order-serialized` (tier `standard`) proves the ordering guarantee where keiro gives it: one enqueuer (or the producer path), failures injected. Knobs: `outbox.ordering-policy` restricted to the three ordered policies, `outbox.enqueue-path`, `outbox.publishers` (default 1, allowed up to 4 processes), `outbox.rows=5000`, `outbox.key-cardinality=20`. Oracle, class `contract`: for each `(source, key)`, ordering rows by the broker offset of their first record gives strictly increasing per-key sequence numbers once `rejected` and `dead` rows are removed; no record of sequence n+1 is appended before the first record of sequence n unless n ended `rejected` or `dead`; under `per-source-stream` the same holds across all keys of a source.

`keiro/outbox/correctness/failure-skips-successors` (tier `smoke`) is a scripted check of attempt accounting. Five rows of one key and five of another are claimed in one batch and the callback fails the second row of the first key. Oracle, class `contract`: the first row is `sent`; the second is `failed` with `attempt_count = 1`; rows three to five are `failed` with `attempt_count = 0`, `last_error` equal to `skipped: earlier record for the same key failed` and `next_attempt_at` not later than the failed row's; the other key's five rows are all `sent`; the pass summary reports `published = 6` and `retried = 4`. Repeated under `per-source-stream` with two sources (a failure in one source skips nothing in the other) and under `stop-the-line` (everything after the pivot is skipped and `haltedOn` names the pivot).

`keiro/outbox/correctness/publisher-misbehaviour` (tier `smoke`) covers what the publisher may do wrong and the terminal rejection. Sub-cases, each against a fresh set of rows: the callback throws (every row of the call `failed` with the exception text and one attempt consumed); the callback omits outcomes (`last_error = publisher returned no outcome`); the callback returns outcomes for unknown ids (ignored); the callback rejects the first row of a key (class `contract`, ADR-37: the row is `rejected` with `rejected_at`, code and detail, its successors are published in the same or the next pass under all three ordered policies, `stop-the-line` does not halt, the rejected row is absent from `countOutboxBacklog`, untouched by `outboxMaintenancePass` and by `garbageCollectSent` with zero retention, and a producer replay of the same source event returns `ProducerDuplicateIdentical` without reviving it).

`keiro/outbox/correctness/producer-identity` (tier `smoke`) checks ADR-42 with hedgehog properties over generated drafts. Oracle, class `contract`: the stored `outbox_id` and `message_id` equal `deriveProducerIdentity`; an identical re-enqueue returns `ProducerDuplicateIdentical` and leaves `created_at`, `status`, `attempt_count` and `updated_at` unchanged; a re-enqueue differing in exactly one field class returns `ProducerIdentityConflict` naming exactly that class (one case each for routing, schema, payload, occurred-at, causal, trace, attributes and provenance, and the identity class by changing `messageIdPrefix`) and still leaves the row unchanged; sub-microsecond differences in `occurredAt` and reordered keys in `attributes` do not conflict. The frozen test vector recorded in ADR-42 is asserted literally so an accidental change of the derivation across cohorts is caught.

`keiro/outbox/concurrency/concurrent-inline-enqueue-order` (tier `smoke`, `KnownDefect` `mori://shinzui/keiro/okf/user-documentation/concepts/DOC-16`) reproduces the documented ordering limitation. The controller takes advisory lock L on its own session. Transaction A begins, enqueues sequence 1 of key k inline, then executes `SELECT pg_advisory_xact_lock(L)` and blocks. Transaction B begins later, enqueues sequence 2 of k and commits. A publisher pass runs and publishes what it can see. The controller releases L, A commits, a second pass runs. Verdicts: `schedule-realised` is true when `created_at` of row 1 is earlier than that of row 2 and the broker offset of row 2 is lower than that of row 1; if false the outcome is `inconclusive`. `per-key-order` (class `implementation`, the verdict the known defect covers) asserts the ideal property and is expected to fail. `no-loss` (class `contract`) must pass: both rows end `sent`. A control arm with `outbox.enqueue-path=producer` runs the same two events through the producer subscription and must pass all three verdicts; it is the evidence that the canonical path is safe.

`keiro/outbox/concurrency/crash-between-publish-and-mark` (tier `standard`) kills a publisher process with `SIGKILL` at a chosen point. Knobs: `outbox.crash-point` (enum `after-broker-append` default, `after-claim`, `backend-kill-during-mark`), `outbox.kills` (int, default 3), `outbox.publishers=2`, `outbox.rows=2000`, `outbox.key-cardinality=20`, `outbox.publishing-timeout-seconds=2`. The publisher's hook (before or after the broker append, according to the crash point) announces the batch and blocks; the controller kills it (for `backend-kill-during-mark` it lets the callback return and terminates the publisher's backends by `application_name` while a lock holder delays the finalization transaction). For the first kill the maintenance role is held back for three publishing timeouts to show that nothing else reclaims the rows; then it runs. Oracles, class `contract`: `no-loss` (every row terminal and every `sent` row in the broker); `bounded-duplicates` (a `messageId` appears more than once in the broker only if the row was in a batch that was in flight at a recorded kill instant, at most once extra per such kill, and in total at most `batchSize × kills` extra records); `reclaimed-only-by-maintenance` (while maintenance is held back the killed batch stays `publishing` and later rows of its keys are not published; after it runs the rows are `failed` or, if their claim consumed the last attempt, `dead` with `last_error` `reclaimed: publisher crashed mid-publish`, within one publishing timeout plus one maintenance interval); `per-key-order` holds on first records. With `outbox.kills` below `outbox.max-attempts` no row may end `dead`. A second arm aims `outbox.kills` equal to `outbox.max-attempts` at the batches of one key and expects that key's head to end `dead` although the broker never refused it, which documents that reclamation does not give an attempt back and crashes alone can exhaust the budget.

`keiro/outbox/concurrency/multi-process-publishers` (tier `standard`) runs `outbox.publishers=4` processes over one backlog with `outbox.rows=20000`, `outbox.key-cardinality=200`, and a publishing timeout far longer than the run. Oracles, class `contract`: `disjoint-ownership` (no row is inside two callbacks at overlapping times, judged from the start and end facts), `per-key-order`, `no-loss`, and zero duplicates because nothing is killed. Rows per second per publisher count is recorded as information, not judged.

`keiro/outbox/concurrency/zombie-publisher-finalization` (tier `standard`, `KnownDefect` `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-5`) stops publisher P1 with `SIGSTOP` inside its callback for longer than `publishingTimeout`, lets maintenance requeue its row and publisher P2 re-claim it, holds P2 inside its callback, resumes P1 with `SIGCONT` so that it finalizes, and then lets P2 finish. Knob `outbox.zombie-outcome` (enum `failed` default, `succeeded`, `dead`) chooses what P1 reports; the `dead` arm uses `maxAttempts=2`, so that P2's re-claim has already raised `attempt_count` to the ceiling when P1's late failure mark reads it. The blocking `schedule-realised` verdict requires maintenance to requeue and P2 to claim the row. The ideal `terminal-consistent-with-success` and `stale-finalization-no-effect` verdicts are scoped to BUG-5. All three arms reproduced late finalization on durable PostgreSQL; the failed and dead arms left a successful P2 broker append in a non-sent database state.

`keiro/outbox/concurrency/producer-identity-race-with-gc` (tier `standard`) has N processes (`outbox.enqueuers=4`) enqueue the same source events through `enqueueProducerEventTx` while a publisher drains and `garbageCollectSent` runs with zero retention. Oracle, class `contract`: every call returns `ProducerInserted` or `ProducerDuplicateIdentical` and returns within a bound (the GC retry loop terminates); at any instant there is at most one row per identity; all broker records for one source event carry one `messageId`. The number of republications after GC is reported, because keiro documents that suppression lasts only as long as the row.

`keiro/outbox/concurrency/producer-subscription-crash-replay` (tier `standard`) kills the `keiro.outbox.producer` role repeatedly while the fixture workload appends account events. Oracle, class `contract`: after quiescence there is exactly one outbox row per source event and emission index, per-key order equals the order of events in each account stream, and no enqueue ever reported a conflict.

### Milestone 2 — Inbox scenarios

Scope: effect recording, the delivery generator, consumer roles and six scenarios. At the end `kenshou list 'keiro/inbox/**'` shows them. Acceptance is per scenario below.

`Kenshou.Suite.Keiro.Inbox.Effects` creates `kenshou_fx.inbox_effects (source text, dedupe_key text, message_id text, consumer text, txid bigint, applied_at timestamptz)` with no unique constraint, and the sequence `kenshou_fx.handler_calls`. The standard handler is a `Tx.Transaction` that calls `nextval` on the sequence and inserts one effect row with `txid_current()`; variants fail with a pure exception (`pure $! error "…"`, the technique keiro's own tests use), with a SQL error (division by zero), by calling `Tx.condemn`, or sleep with `pg_sleep`. For delegated intake the effect is one `Deposited`-style event on a fixture account stream, appended through `Keiro.Inbox.Delegated.delegatedCommand` with the marker from `delegatedEventId "kenshou-consumer" source dedupe target "deposit"`. `Kenshou.Suite.Keiro.Inbox.Delivery` turns broker records into deliveries with `toInboundRecord` and `Keiro.Inbox.Kafka.integrationEventFromKafka`, and generates redeliveries (same record again) and republishes (same logical message at a new offset, optionally with a new `messageId`) from the seed. Knobs: `inbox.dedupe-policy` (enum `message-id` default, `source-event`, `kafka-delivery`, `custom`), `inbox.persistence` (enum `full-envelope` default, `dedupe-only`), `inbox.idempotence` (enum `inbox-table` default, `delegated`; selects the runner family; `delegated` with `dedupe-only` is rejected as a usage error), `inbox.batch-size` (int, default 0 meaning the per-message runner), `inbox.attempt-ceiling` (int, default 3), `inbox.consumers` (int, default 1), `inbox.deliveries`, `inbox.redelivery-ratio`, `inbox.republish-ratio`, `inbox.payload-bytes`, `inbox.gc` (enum `off` default, `on`), `inbox.retention-seconds`, `inbox.gc-interval-ms`, `inbox.failure-mode` (enum `pure-exception` default, `sql-error`, `condemn`), `inbox.race-mode` (enum `staged` default, `statistical`). Roles: `keiro.inbox.consumer` and `keiro.inbox.gc`.

`keiro/inbox/correctness/effectively-once-matrix` (tier `standard`) runs one combination of policy, persistence and idempotence per run; the knob variants declare the full matrix so the planner can expand it. Knobs as above with `inbox.deliveries=2000`, `inbox.redelivery-ratio=0.3`, `inbox.republish-ratio=0.1`. Oracle, class `contract`: the number of effects per `(source, dedupe_key)` is exactly one; the first delivery of a key returns `InboxProcessed` and every later one `InboxDuplicate`; under `source-event` a republish with a new `messageId` collapses to one effect, under `custom` the consumer builds `CustomDedupeKey` per delivery from a business identifier in the payload and the same holds, and under `kafka-delivery` it does not (the expected count is the number of distinct offsets, as documented); an envelope lacking the field a policy needs returns `DedupePolicyUnsatisfied` and leaves no row and no effect. Persistence: `dedupe-only` rows have an empty payload and null attributes, trace and schema columns, while failed rows always keep the full envelope. Delegated: `keiro.keiro_inbox` stays empty, each target stream holds exactly one event per dedupe key and its event id equals `delegatedEventId …`, a command that appends nothing yields `DelegatedCommandWithoutReceipt`, and a rejected command yields `DelegatedCommandFailed`.

`keiro/inbox/correctness/batch-fast-path-and-fallback` (tier `smoke`) drives `runInboxTransactionBatch` and `runInboxDelegatedBatch`. Oracle, class `contract`: results align positionally with deliveries; a key repeated inside the batch is `InboxDuplicate` without a handler call; a clean batch commits once (class `implementation`: all its effect rows share one `txid`); with one throwing delivery the whole batch rolls back and the per-message fallback yields `InboxHandlerFailed _ 1` for the poison and exactly one effect for every other key; with one condemning delivery the re-read detects the rollback and the fallback runs; the delegated batch remembers successes only within the call.

`keiro/inbox/correctness/poison-accounting` (tier `smoke`) drives `runInboxTransactionWithRetries` with `inbox.attempt-ceiling=3`. Oracle, class `contract`: a permanently failing message returns `InboxHandlerFailed _ 1`, `_ 2`, `_ 3` and then `InboxPreviouslyFailed` with no further handler call (the sequence does not advance); a message that fails twice and then succeeds ends `completed` with one effect; failed rows survive `garbageCollectCompleted` with zero retention; with the delegated runner an attempt above the ceiling returns `InboxPreviouslyFailed Nothing` without a handler call. For `inbox.failure-mode=condemn` the documented behaviour is asserted: the call returns `InboxProcessed`, nothing is committed, and the next delivery runs the handler again. For `sql-error` only the at-least-once contract is asserted (no effect and no completed row after the failure); the classification keiro returns is recorded in the run result as an observation.

`keiro/inbox/correctness/envelope-round-trip` (tier `smoke`) is the fidelity check for the synthetic broker: for generated events, `outboxRowToKafkaRecord`, the broker, `toInboundRecord` and `integrationEventFromKafka` return the original event (class `contract`), and removing any of the six required headers (`keiro-message-id`, `keiro-source`, `keiro-destination`, `keiro-event-type`, `keiro-schema-version`, `content-type`) yields `MissingHeader`.

`keiro/inbox/concurrency/race-one-key` (tier `standard`) has `inbox.consumers=4` processes deliver the same message at a barrier, with a handler that sleeps. Knob `inbox.kill-winner` (enum `none` default, `sigkill`, `backend-kill`). Oracle, class `contract`: exactly one effect per key; with `none`, one process reports `InboxProcessed` and the others `InboxDuplicate`; when the winner is killed mid-handler its transaction leaves no row and no effect, exactly one of the waiting consumers then runs the handler, and a redelivery to the restarted process is a duplicate. Class `implementation`: no consumer ever reports `InboxInProgress`. With `inbox.idempotence=delegated` the same holds with one `DelegatedFresh` and one marker event.

`keiro/inbox/concurrency/gc-vs-insert-race` (tier `standard`, `KnownDefect` `mori://shinzui/keiro/okf/user-documentation/concepts/DOC-10`) reproduces the documented race. In `staged` mode the consumer connects through the correctness toolkit's TCP proxy. A completed row R for key k exists and is older than the retention. The proxy pauses the consumer's lookup request after its conflicting insert, then the controller runs `garbageCollectCompleted` and releases the lookup. Verdicts: `schedule-realised` (the consumer reported `InboxProcessed` for a key that had a completed row when the delivery began, and no inbox row for k exists afterwards); `gc-reprocess-observed` (two effects after GC); `effectively-once` (class `implementation`, covered by the known defect, expected to fail with two effects for k); `at-least-once` (class `contract`): at least one effect. The scenario reports `inconclusive` if the exact lookup barrier is never reached.

### Milestone 3 — Job queue scenarios

Scope: a scripted fixture job, a job runtime helper, roles and eleven scenarios. At the end `kenshou list 'keiro/queue/**'` shows them. The environment must include the PGMQ migration component.

`Kenshou.Suite.Keiro.Queue.Jobs` defines the payload and the handler. The handler looks up the step for the delivery's zero-based `attempt` in the payload's script, so behaviour is a function of the message and the delivery count alone, whichever process handles it. `StepAwaitController` writes a fact and blocks on the control channel, which is how crash windows are pinned.

```haskell
module Kenshou.Suite.Keiro.Queue.Jobs where

data Step = StepDone | StepRetry !Double | StepRetryDefault | StepDead !Text | StepThrow
          | StepSleep !Double | StepExtendLease !Double | StepAwaitController !Text
data FixtureJob = FixtureJob
  { jobId :: !UUID, groupKey :: !(Maybe Text), seqInGroup :: !Int, script :: ![Step], pad :: !Text }

fixtureJob :: Text -> JobOrdering -> RetryPolicy -> Job FixtureJob        -- aesonJobCodec, queueRef "kenshou.<run8>.<name>"
fixtureHandler :: (IOE :> es) => HandlerEnv -> JobContext es -> FixtureJob -> Eff es JobOutcome
withFixtureRuntime :: QueueKnobs -> Text -> Maybe Tracer -> (JobRuntime -> IO a) -> IO a
```

`withFixtureRuntime` calls `withJobRuntime` unchanged when `queue.pool-size` is 3 and otherwise builds a `hasql-pool` pool of the requested size and the record `JobRuntime {runtimePool, runtimeTracer}` directly (its constructor is exported). Knobs: `queue.ordering` (enum `unordered` default, `fifo-heads`, `fifo-throughput`, `fifo-round-robin`), `queue.visibility-timeout-seconds` (int, default 30), `queue.batch-size` (int, default 1), `queue.polling` (enum `poll-every` default, `long-poll`), `queue.poll-interval-ms` (int, default 1000), `queue.long-poll-max-seconds` (int, default 5), `queue.long-poll-interval-ms` (int, default 100), `queue.max-retries` (int, default 5), `queue.default-retry-delay-seconds` (int, default 60), `queue.use-dead-letter` (bool, default true), `queue.execution-shape` (enum `workers` default, `drain`), `queue.workers` (processes, default 1), `queue.processors-per-worker` (int, default 1), `queue.inbox-size` (int, default 16), `queue.supervision` (enum `stop-all-on-failure` default, `ignore-failures`), `queue.pool-size` (int, default 3), `queue.provision` (enum `standard` default, `unlogged`), `queue.jobs`, `queue.groups`, `queue.payload-bytes`, `queue.handler-millis`. Roles: `keiro.queue.producer`, `keiro.queue.worker` (runs `runJobWorkers`, waits on the handle with `waitApp`, and restarts the app in a loop, recording every exit, because shibuya never restarts a processor), `keiro.queue.drainer` (loops `runJobOnceWithContext`) and `keiro.queue.dlq-operator` (`redriveDlq`). `Kenshou.Suite.Keiro.Queue.Oracle` reads `pgmq.q_<physical>`, `pgmq.a_<physical>` and `pgmq.q_<dlq>` directly.

`keiro/queue/correctness/job-outcome-semantics` (tier `standard`, run for both execution shapes) checks, class `contract`: `Done` removes the message; `Retry d` redelivers no earlier than `d` rounded up to whole seconds with `read_ct` one higher and `attempt` equal to `read_ct − 1`; `RetryDefault` uses the policy delay; `Dead r` leaves one DLQ row whose wrapper has `original_message`, a `dead_letter_reason` beginning `poison_pill`, `read_count` and `original_headers`, or one archive row when `queue.use-dead-letter=false`; a malformed payload is dead-lettered as `invalid_payload` without a handler call; a payload from a future codec version is retried, consuming attempts (this sub-case uses a job whose codec is built with `mkJobCodec` so that a flagged payload decodes to `JobPayloadFromFuture`); a thrown handler on the drain path leaves the message invisible until the visibility timeout and is not counted in the returned total, while on the worker path it is retried promptly; `headers` is `Just` on the drain path and `Nothing` on the worker path; `enqueueWithDelay` delivers no earlier than the delay, `enqueueBatch` returns ids in order, and `enqueueToGroup` sets `x-pgmq-group`.

`keiro/queue/correctness/max-retries-before-handler` (tier `standard`) uses `queue.max-retries=3` and a script that always retries immediately. Oracle, class `contract`: the handler runs exactly three times and the message then sits in the DLQ with reason `max_retries_exceeded` and `read_count = 4`; with the raw constructor `RetryPolicy 0 …` every message is dead-lettered with zero handler calls.

`keiro/queue/correctness/consumption-config-rejections` (tier `smoke`) exercises ADR-44 through `jobProcessorWithContext` and `runJobOnceWithContext`. Oracle, class `contract`: non-positive visibility timeout, batch size or poll interval throws `InvalidJobTuning`; a tuning whose ordering differs from `jobOrdering` throws `JobOrderingMismatch` with both values; `fifo-throughput` or `fifo-round-robin` with a batch above one throws `UnsafeLegacyFifoBatch`; invalid tuning wins over mismatch, which wins over the unsafe batch; and in every case the waiting message still has `read_ct = 0`, proving no read was issued.

`keiro/queue/concurrency/crash-redelivery-cadence` (tier `standard`) sets `queue.visibility-timeout-seconds=3`, `queue.default-retry-delay-seconds=60`, `queue.max-retries=3`, `queue.workers=2` so that a live worker is always polling, and kills the worker process that holds the message inside the handler (`StepAwaitController`). Oracle, class `contract`: the next delivery starts between 3 s and 3 s plus one poll interval plus one second after the killed read; its `attempt` equals the number of kills; after three kills the message is dead-lettered with `max_retries_exceeded` and the handler is not called a fourth time — crashes alone exhaust the budget. Run for both polling modes.

`keiro/queue/concurrency/dead-letter-window-drain-path` (tier `smoke`, `KnownDefect` `mori://shinzui/keiro/okf/user-documentation/concepts/DOC-25`) pins the two-statement window. The drainer's handler announces the message id and waits; the controller opens a transaction and locks that row of `pgmq.q_<physical>` with `SELECT … FOR UPDATE`; the handler returns `Dead`; the drainer sends the DLQ row and its delete blocks on the lock; the controller sees the DLQ row, kills the drainer (`queue.crash-mode`: `sigkill` default, or `backend-kill`), terminates the drainer's backends so the blocked delete cannot complete, and rolls back. Verdicts: `schedule-realised` (the DLQ row existed while the main row was locked); `exactly-one-place` (class `implementation`, covered by the known defect, expected to fail: the message is in both tables); `never-nowhere` (class `contract`). `keiro/queue/concurrency/dead-letter-atomic-worker-path` runs the same schedule against `runJobWorkers`, where the adapter moves the message in one transaction, and must pass `exactly-one-place` as class `contract`: after the backend is terminated the message is only in the main queue, and it reaches the DLQ exactly once afterwards, through the adapter's acknowledgement retry or a later delivery.

`keiro/queue/concurrency/redrive-window` (tier `standard`, `KnownDefect` `mori://shinzui/keiro/okf/user-documentation/concepts/DOC-25`) does the same for `redriveDlq`, which has no hook: the operator role connects through the proxy with 250 ms latency each way, the controller polls the main queue directly and kills the operator as soon as the redriven row appears, before the delete can arrive. Verdicts as above with `exactly-one-place` expected to fail; additionally, class `contract`, a second redrive after the thirty-second inspection hide moves the DLQ row again, so handlers see the payload twice and nothing is lost.

`keiro/queue/concurrency/fifo-heads-strict-order` (tier `standard`) runs `queue.workers=4` processes, `queue.groups=32`, fifty jobs per group, `queue.batch-size=8`, scripts that retry and one worker killed mid-run. Oracle for `queue.ordering=fifo-heads`, class `contract`: within a group, jobs finish in send order and no job starts while an earlier job of its group is unfinished; while one group's head is blocked, other groups keep completing; nothing is lost. For the other three orderings (legacy modes forced to batch one) the same order check is emitted as class `implementation` and does not decide the outcome; the `unordered` arm is expected to show reordering and thereby shows the checker is not vacuous. In every arm no message id is inside two handlers at once unless its visibility timeout had expired.

`keiro/queue/concurrency/workers-survive-transient-polling-error` (tier `standard`) is the test keiro marks pending. A worker process runs `runJobWorkers` under steady load. Knobs: `queue.fault` (enum `backend-kill` default, `postmaster-restart`, `proxy-reset`), `queue.outage-seconds` (decimal, default 0), `queue.fault-count` (int, default 5), `queue.polling`, `queue.supervision`. Oracle, class `contract`: for a fault shorter than the adapter's retry budget (five attempts, 0.1 s doubling to 5 s) the app handle is still running afterwards, no processor is reported failed, processing resumes within five seconds, every job completes and duplicates are limited to jobs in flight at a fault; for an outage longer than the budget (`postmaster-restart` with `queue.outage-seconds=10`) the failure is visible — `waitApp` returns or the processor is reported failed — never a silently idle worker, and after the role restarts the app every job still completes.

`keiro/queue/concurrency/runtime-pool-isolation` (tier `standard`) examines the separate three-connection pool. Part one occupies all ten kiroku store connections with transactions running `pg_sleep` (an idle transaction would be ended by kiroku's thirty-second `idleInTransactionTimeout`) and shows that job processing continues (class `contract`: the pools are independent). Part two runs `queue.processors-per-worker` of 1, 3 and 6 with `queue.polling=long-poll` on the shipped pool and records acknowledgement latency, `PgmqAcquisitionTimeout` occurrences and the job runtime's connection count by `application_name`. Class `implementation`: that count never exceeds three; class `contract`: no job is lost. The diagnostics toolkit's stall watchdog runs during part two; a `pool-starvation` classification is reported as a finding, and if confirmed is filed against `mori://shinzui/keiro` because the pool cannot be sized through `withJobRuntime`.

`keiro/queue/concurrency/lease-extension` (tier `standard`) uses a six-second handler with `queue.visibility-timeout-seconds=2` and two workers. Without `StepExtendLease` the job is handled more than once and `read_ct` rises (recorded as the documented consequence); with `StepExtendLease 10` first, class `contract`: it is handled exactly once and finishes with `read_ct = 1`, on both execution shapes.

### Milestone 4 — Messaging benchmarks, soak and telemetry arms

Scope: adaptation of the two telemetry dimensions, two telemetry-contract scenarios, seven benchmarks, three soaks and two overhead reports. Benchmarks take their load generators, recorder, samplers and summaries from the measurement toolkit, support `pg.durability=durable` only, are tier `standard` with placement `either` (authoritative only on a cell), and embed the milestone's no-loss checker so a fast but wrong run fails.

Telemetry adaptation lives in `Kenshou.Suite.Keiro.Outbox.Telemetry`, `.Inbox.Telemetry` and `.Queue.Telemetry`, reusing the helper of `docs/plans/12-…` for `newKeiroMetrics` if it exists. From `Kenshou.Telemetry.withTelemetry` a role takes `Maybe Tracer` and `Maybe Meter`; the tracer goes to `OutboxPublishOptions.tracer`, to `withConsumerSpan` around each inbox delivery and to `withJobRuntime`; the meter becomes `Maybe KeiroMetrics`. Producers use `enqueueTraced` when tracing is on. For `telemetry.metrics` `serve` and `serve-scraped`, outbox and inbox roles start the kiroku-metrics server on their store and queue workers start the shibuya-metrics server on the app's master (`getAppMaster`), both on a free port announced through the telemetry toolkit's endpoint registrar. `keiro/outbox/correctness/telemetry-contract` (tier `smoke`, requires `sdk-inmemory` and `collect`) asserts one Producer span `send <destination>` per publish call with `keiro.outbox.batch.size`, error status when a row failed, a consumer span that is a child of the context persisted in the outbox row's `traceparent`, counter totals equal to the summed pass summaries and to SQL truth, `keiro.outbox.backlog` equal to `countOutboxBacklog`, and inbox counters equal to the result classification with nothing recorded for `InboxInProgress`. `keiro/queue/correctness/telemetry-contract` asserts ADR-1: one Consumer span `<jobName> process` per delivery on both shapes, continuing the trace of `enqueueTraced`, with the `messaging.*` attributes, `shibuya.partition` for grouped jobs, `shibuya.ack.decision` with the documented status mapping, no acknowledgement attribute for a thrown handler on the drain path, and `shibuya.inflight.*` on the worker path only. Whether a delivery that is dead-lettered before the handler on the worker path gets a span is recorded as an observation and filed upstream if it does not.

Benchmarks. `keiro/outbox/benchmark/enqueue-to-publish` drives open-loop enqueues at `outbox.rate` per second (default 500) and records `outbox.enqueue` (corrected for coordinated omission) and `outbox.enqueue-to-publish` (callback entry minus the `occurredAt` the enqueuer stamped; both on one host), by `outbox.batch-size` (1, 8, 32, 128), `outbox.ordering-policy`, `outbox.publishers` (1, 2, 4), `outbox.key-cardinality` (1, 200, 0) and the broker model. `keiro/outbox/benchmark/drain-throughput` preloads rows and measures rows per second of closed-loop passes, the shape of keiro's own benchmark so numbers can be related. `keiro/outbox/benchmark/producer-identity-replay` compares a fresh `enqueueProducerEventTx` with an identical replay. `keiro/inbox/benchmark/intake-throughput` measures deliveries per second and latency by `inbox.idempotence`, `inbox.persistence`, `inbox.batch-size` (0, 10, 100), `inbox.redelivery-ratio` (0, 0.5, 1.0), `inbox.consumers` and `inbox.payload-bytes`. `keiro/queue/benchmark/job-throughput` measures jobs per second and enqueue-to-handler-start latency by `queue.ordering`, `queue.batch-size` (1, 10, 50), `queue.visibility-timeout-seconds`, `queue.polling`, `queue.execution-shape`, `queue.workers`, `queue.pool-size`, `queue.groups` and `queue.provision`. `keiro/queue/benchmark/enqueue` measures `enqueue`, `enqueueBatch` (10, 100) and `enqueueTraced`. `keiro/queue/benchmark/idle-poll-cost` measures database statements per second of idle workers under `poll-every` and `long-poll`, from `pg_stat_statements`.

Soaks, each judged by the leak verdict per process, the milestone's ledger checkers and growth verdicts over sampled relation sizes and dead tuples; full form tier `soak`, placement `cell`, `soak.duration-minutes=240`; `-reduced` form tier `extended`, placement `either`, 20 minutes. `keiro/outbox/soak/table-growth` runs enqueuers, two publishers and maintenance at a steady rate with occasional publisher kills; with `outbox.gc=on` the size of `keiro.keiro_outbox` and its indexes must have no significant positive slope after warm-up, with `off` the growth per row is reported; backlog stays bounded. `keiro/inbox/soak/dedupe-window` runs consumers with GC on and `inbox.retention-seconds=120`, redelivering each message at a lag drawn from the seed; class `contract`: a redelivery at a lag below the retention minus one GC interval is always `InboxDuplicate`; redeliveries beyond the retention plus one interval are processed again and counted as the documented window; table size is bounded. `keiro/queue/soak/queue-and-dlq-growth` runs producers and workers with a small share of `Dead` scripts; main-queue depth stays bounded, the DLQ (or the archive when `queue.use-dead-letter=false`) grows by exactly the dead count, and with knob `queue.dlq-maintenance=on` a periodic `archiveDlq` then `purgeDlq` keeps the active DLQ bounded.

Finally run `kenshou overhead keiro/outbox/benchmark/enqueue-to-publish` and `kenshou overhead keiro/queue/benchmark/job-throughput` with the arms `tracing=off,noop,sdk-otlp` and `metrics=off,collect,serve-scraped`; the queue is expected to show the largest tracing cost because the traced interpreter adds a span per PGMQ operation. Add the three sections to `docs/layers/keiro.md`.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro-runtime-kenshou`, inside the Nix development shell (`nix develop`, or direnv). The exact filter flags of `kenshou list` are defined by `docs/plans/2-…`; adjust if they differ.

Step 1, check the state this plan expects.

```bash
test -f kenshou-keiro/kenshou-keiro.cabal && echo "kenshou-keiro exists"
ls kenshou-keiro/src/Kenshou/Suite/Keiro/Fixture/
cabal build kenshou-keiro kenshou-check kenshou-measure kenshou-diagnose kenshou-telemetry
cabal run kenshou -- list --layer keiro | head
cabal run kenshou -- run selftest/kernel/correctness/postgres-roundtrip --out runs/
cabal run kenshou -- run selftest/check/concurrency/postgres-backend-kill --out runs/
cabal run kenshou -- run selftest/check/concurrency/proxy-partition --out runs/
```

Every command must succeed; the three runs must exit 0. If the fixture modules are named differently from Interfaces and Dependencies, note the real names in Surprises & Discoveries and adapt. Locate the sources with `mori registry show shinzui/keiro --full` and confirm the released code you are coding against by reading the tags in that checkout, for example `git -C /Users/shinzui/Keikaku/bokuno/keiro show keiro-0.17.0.0:keiro/src/Keiro/Outbox.hs` and `git -C /Users/shinzui/Keikaku/bokuno/keiro show keiro-pgmq-0.17.0.0:keiro-pgmq/src/Keiro/PGMQ/Job.hs`.

Step 2, per milestone: add modules, register them in the cabal file, build and unit-test.

```bash
cabal build kenshou-keiro
cabal test kenshou-keiro-test --test-options='--match "/Outbox/"'
```

```text
Kenshou.Suite.Keiro.Outbox.Broker
  decide is a pure function of seed, message id and attempt [✔]
  never appends a later row of a key after an earlier row of that key failed in the same call [✔]
Kenshou.Suite.Keiro.Outbox.Oracle
  per-key-order fails on a doctored broker log [✔]
  bounded-duplicates fails when a duplicate lies outside every crash window [✔]
```

Step 3, splice the lists into the bundle module that `docs/plans/12-…` created (use its real path and field names; the expected shape is shown).

```diff
+import Kenshou.Suite.Keiro.Outbox qualified as Outbox
+import Kenshou.Suite.Keiro.Inbox qualified as Inbox
+import Kenshou.Suite.Keiro.Queue qualified as Queue
@@
-    , scenarios = writeSideScenarios
-    , roles = writeSideRoles
+    , scenarios = writeSideScenarios <> Outbox.scenarios <> Inbox.scenarios <> Queue.scenarios
+    , roles = writeSideRoles <> Outbox.roles <> Inbox.roles <> Queue.roles
```

Step 4, run scenarios. The transcript is illustrative; identifiers and counts will differ.

```bash
cabal run kenshou -- list 'keiro/outbox/**'
cabal run kenshou -- run keiro/outbox/concurrency/crash-between-publish-and-mark \
  --dim pg.durability=durable --set outbox.kills=3 --out runs/
echo "exit=$?"
```

```text
keiro/outbox/concurrency/crash-between-publish-and-mark  run 0199f3c2-…  seed 8841
  killed publisher-1 at +4.2s (after-broker-append, 32 rows in flight)
  maintenance held back 6.0s: 32 rows still publishing, 0 successors published
  verdict no-loss                         passed  enqueued=2000 terminal=2000 sent=2000
  verdict bounded-duplicates              passed  duplicates=96 budget=96 outside-window=0
  verdict reclaimed-only-by-maintenance   passed
  verdict per-key-order                   passed  keys=20
outcome: passed
exit=0
```

A scenario carrying a `KnownDefect` reports its expected failure without blocking; the exact rendering and exit code are the kernel's.

```bash
cabal run kenshou -- run keiro/inbox/concurrency/gc-vs-insert-race --dim pg.durability=durable --out runs/
```

```text
  verdict schedule-realised   passed
  verdict at-least-once       passed  effects(k)=2
  verdict effectively-once    failed  effects(k)=2 expected=1   [known defect mori://shinzui/keiro/okf/user-documentation/concepts/DOC-10]
outcome: failed (known defect, non-blocking)
```

Step 5, benchmarks, comparison, overhead and a short soak.

```bash
cabal run kenshou -- run keiro/queue/benchmark/job-throughput --dim pg.durability=durable \
  --set queue.ordering=fifo-heads --set queue.batch-size=10 --out runs/
cabal run kenshou -- run keiro/queue/benchmark/job-throughput --dim pg.durability=durable \
  --set queue.execution-shape=workers --set queue.polling=long-poll \
  --set queue.workers=4 --set queue.pool-size=8 --set queue.batch-size=10 --out runs/
cabal run kenshou -- summarize runs/<run-id>
cabal run kenshou -- overhead keiro/outbox/benchmark/enqueue-to-publish \
  --arms tracing=off,noop,sdk-otlp --arms metrics=off,collect,serve-scraped --out runs/overhead-outbox
cabal run kenshou -- run keiro/outbox/soak/table-growth-reduced --dim pg.durability=durable --set outbox.gc=on --out runs/
```

Step 6, commit after each milestone with a Conventional Commits subject and the three trailers.

```text
feat(keiro): cover the keiro outbox with correctness and crash scenarios

MasterPlan: docs/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime.md
ExecPlan: docs/plans/13-cover-the-keiro-outbox-inbox-and-job-queue.md
Intention: intention_01m2zvy0gje40tdsdragvzr3tq
```


## Validation and Acceptance

Milestone 1 is accepted when the eleven outbox scenarios are listed; the correctness scenarios and the multi-process, crash, identity-race and producer-crash scenarios exit 0 with `pg.durability=durable`; `concurrent-inline-enqueue-order` reports `schedule-realised` passed, `no-loss` passed and the per-key-order verdict failed under its known-defect reference, while its producer-path control arm passes all three; and `zombie-publisher-finalization` has produced an outcome that is either passed or recorded as an upstream finding with its URI attached. Deliberately breaking the system must turn scenarios red: run `crash-between-publish-and-mark` with the maintenance role disabled for the whole run and observe `no-loss` fail on rows stuck in `publishing`; run `per-key-order-serialized` with a test-only broker flag that appends same-key successors after a failure and observe the order verdict fail.

Milestone 2 is accepted when the six inbox scenarios are listed; the matrix passes for every declared combination of policy, persistence and idempotence (run the expansion with `kenshou plan` once `docs/plans/3-…` is implemented, or a shell loop over the knob values); `race-one-key` passes for all three values of `inbox.kill-winner`; and `gc-vs-insert-race` in `staged` mode reports `schedule-realised` passed and two effects for the raced key. Replacing the standard handler with one that inserts two effect rows must make `effectively-once-matrix` fail.

Milestone 3 is accepted when the eleven queue scenarios are listed and pass, with the two window scenarios failing only on `exactly-one-place` under their known-defect reference while `dead-letter-atomic-worker-path` passes; `crash-redelivery-cadence` shows redelivery at about three seconds with a sixty-second retry delay configured; and `workers-survive-transient-polling-error` passes for five backend kills and shows a visible failure followed by recovery for a ten-second outage. Setting the scripted handler to ignore `StepExtendLease` must make `lease-extension` fail.

Milestone 4 is accepted when both telemetry-contract scenarios pass with `--dim telemetry.tracing=sdk-inmemory --dim telemetry.metrics=collect`; every benchmark produces `samples/*.hist`, `series/*.csv` and a summary, and refuses `pg.durability=fsync-off` with a usage error; two runs of one benchmark with identical knobs compare as `pass` or `inconclusive`, never `regression`, under `kenshou compare`; each `-reduced` soak produces a leak verdict per worker process and growth verdicts for its tables; and two overhead reports exist. The whole plan is accepted when `cabal test kenshou-keiro-test` passes, `kenshou list --layer keiro` shows the scenarios of all three components beside those of `docs/plans/12-…`, and `docs/layers/keiro.md` describes every scenario, its knobs and what it proves.


## Idempotence and Recovery

Every run gets a fresh database from the kernel and its own run directory, so re-running any scenario is safe and leaves earlier evidence untouched. Harness-owned objects (`kenshou_fx` schema, tables, sequence) are created with `IF NOT EXISTS` and live only in the run's database. Queue names, outbox and inbox sources carry the run prefix, so a run against an external server (a cell) cannot collide with another; note that `garbageCollectSent`, `garbageCollectCompleted` and outbox claims are global to a database, which is why one database per run is assumed, and on a cell the lease's deterministic reset provides it. Worker processes are children of the correctness toolkit's supervisor and are reaped by process group even when the scenario throws; lock-holder sessions, held advisory locks and proxies are released in `finally` blocks, and a scenario that finds a stale lock holder at start terminates it by `application_name`. If a scenario is interrupted with Ctrl-C, check for leftovers with `pgrep -fl "kenshou worker"` and end them with `pkill -KILL -f "kenshou worker"`; ephemeral PostgreSQL clusters orphaned by a `SIGKILL` of the harness itself are swept as `docs/plans/2-…` describes. Editing the cabal file, the bundle module and `docs/layers/keiro.md` is additive; if `docs/plans/14-…` edited the same lines first, rebase and keep both sets of imports and list terms. If a scenario reveals an upstream defect, do not change the oracle to make it pass: file the report in the owning repository, put its `mori://` URI in the scenario's `KnownDefect`, and record the finding in Surprises & Discoveries.


## Interfaces and Dependencies

Runtime libraries, at the versions of the released cohort pinned by `docs/plans/1-…`: `keiro`, `keiro-core` and `keiro-pgmq` 0.17.0.0; `kiroku-store` 0.8.0.1; `shibuya-core` 0.9.0.3 and `shibuya-metrics`; `shibuya-pgmq-adapter` 0.16.0.0; `pgmq-core`, `pgmq-effectful`, `pgmq-hasql` and `pgmq-migration` 0.6.1.0 (installs PGMQ without the extension; `FifoHeads` needs PGMQ 1.12 or later, which it provides); `hasql` 1.10, `hasql-pool` 1.4, `hasql-transaction` 1.2; `effectful` 2.6; `hs-opentelemetry-api` 1.0; plus `aeson`, `uuid`, `stm`, `containers`, `hedgehog` and `hspec`. This plan adds to `kenshou-keiro.cabal` whichever of these `docs/plans/12-…` did not already list. Sibling checkouts such as `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya` are at unreleased heads; read the tag that matches the cohort (for example `git show v0.9.0.3:shibuya-core/src/Shibuya/App.hs`) before relying on a signature.

Expected from the kernel (`docs/plans/2-…`), module `Kenshou.Core.*`: `Scenario` with identifier, summary, knobs, dimension support, tier, placement, environment requirements, optional `KnownDefect` and `run :: RunContext -> IO ScenarioReport`; `KnobSpec` with name, type, default and allowed values; `LayerBundle`; `WorkerRole` and the hidden `kenshou worker` dispatch; `RunContext` giving resolved knobs and dimensions, a `PostgresEnv` with a connection string, the seed, the output directory, a logger, phase markers and a place to register verdicts and summaries. Two needs to check: that a scenario with a `KnownDefect` can say which verdicts the defect covers, so that a failing `contract` side-check in a known-defect scenario still counts as a real failure (if it cannot, move the side-checks into the sibling scenario and say so in the Decision Log); and that `PostgresEnv` can expose a TCP host and port, which the proxy-based scenarios need because `ephemeral-pg` connects over a Unix socket by default.

Expected from the correctness toolkit (`docs/plans/5-…`), package `kenshou-check`: the bounded ledger; checkers for no-loss, duplicates bounded by declared crash windows, per-key order, exactly-N effects per key, eventual quiescence and disjoint ownership, each emitting `kenshou.verdict/v1` with a class; `Kenshou.Check.Process` to spawn roles, exchange control messages, send `SIGKILL`, `SIGSTOP` and `SIGCONT`, and record kill instants; fault injectors that terminate backends by `application_name`, stop and start the postmaster of a durable fixture, hold a row lock for a duration, and proxy TCP with added latency or resets; hedgehog support with replayable seeds. Expected from the measurement toolkit (`docs/plans/4-…`): the recorder, open-loop and closed-loop generators, samplers for the GHC runtime, the process, and PostgreSQL relation sizes, dead tuples, connections by `application_name` and `pg_stat_statements` deltas for named tables (`keiro.keiro_outbox`, `keiro.keiro_inbox`, `pgmq.q_*`, `pgmq.a_*`, `kenshou_fx.*`), summaries and `kenshou compare`. Expected from the diagnostics toolkit (`docs/plans/6-…`): the leak verdict over those series and the stall watchdog with its `pool-starvation` classification. Expected from the telemetry toolkit (`docs/plans/7-…`): `Kenshou.Telemetry.withTelemetry` yielding `Maybe Tracer`, `Maybe Meter`, in-memory exporter handles and an endpoint registrar, and `kenshou overhead`.

Expected from the fixture domain of `docs/plans/12-…`, namespace `Kenshou.Suite.Keiro.Fixture.*`. The names are this plan's assumption; the shapes are what it needs. If that plan delivers less, build the missing piece inside this plan's namespaces and record it. The completed plan `docs/plans/12-cover-the-keiro-command-processor-process-managers-and-routers.md` delivers the fixture as the modules `Kenshou.Suite.Keiro.Fixture.Domain`, `.Account`, `.Transfer`, `.Bonus`, `.Projection`, `.Model`, `.Workload`, `.Oracle`, `.Runtime`, `.Roles` and `.Bridge` (account-ledger aggregate, transfer saga process manager, bonus router, projections, pure model, seeded workload, SQL oracles including `money-is-conserved`, and `submitAccountCommand`); read its Milestone 1 and its Interfaces and Dependencies section first and reconcile the names assumed here against the real exports before writing anything else.

```haskell
-- a store for the run, with application_name set, and an IO runner for Store effects
withFixtureStore :: RunContext -> Text -> (KirokuStore -> IO a) -> IO a
-- the account aggregate: identifiers, commands, events, validated event stream, stream naming
accountStreamName :: AccountId -> StreamName
runAccountCommand :: (Store :> es, IOE :> es) => RunCommandOptions -> AccountId -> AccountCommand
                  -> Eff es (Either CommandError (CommandResult AccountEventStream))
decodeAccountEvent :: RecordedEvent -> Either Text AccountEvent
-- a seeded workload and a SQL oracle over account streams
accountWorkload :: Word64 -> WorkloadShape -> [(AccountId, AccountCommand)]
depositsApplied :: KirokuStore -> AccountId -> IO [EventId]
-- an ack-coupled subscription over the account category, from Kiroku.Store.Subscription.Stream.subscriptionAckStream
runAccountSubscription :: KirokuStore -> Text -> (RecordedEvent -> AccountEvent -> IO ()) -> IO ()
```

This plan uses them in three places: the producer path of the outbox (account events are the private events an `IntegrationProducer AccountEvent` maps to drafts), the delegated inbox (a deposit command on an account stream is the downstream receipt), and the benchmarks that enqueue inline inside `runCommandWithSqlEvents`.

At the end of Milestone 1 these exist: `Kenshou.Suite.Keiro.Outbox` exporting `scenarios :: [Scenario]` and `roles :: [WorkerRole]`; `Kenshou.Suite.Keiro.Outbox.Broker` as shown in Plan of Work; `Kenshou.Suite.Keiro.Outbox.Knobs` with `outboxKnobs :: [KnobSpec]` and `decodePublishOptions :: ResolvedKnobs -> Maybe Tracer -> Either OutboxPublishConfigError OutboxPublishOptions`; `.Workload`, `.Roles`, `.Oracle`; one module per scenario under `.Correctness` and `.Concurrency`. At the end of Milestone 2: `Kenshou.Suite.Keiro.Inbox` with the same two exports, `.Effects` (`ensureEffectSchema :: Pool -> IO ()`, `effectHandler :: Text -> HandlerMode -> IntegrationEvent -> Tx.Transaction ()`, `effectCounts :: Pool -> IO (Map (Text, Text) Int)`), `.Delivery`, `.Knobs`, `.Roles`, `.Oracle` and the scenario modules. At the end of Milestone 3: `Kenshou.Suite.Keiro.Queue` with the two exports, `.Jobs` as shown, `.Knobs` (`decodeTuning :: ResolvedKnobs -> JobTuning`, deliberately unvalidated so rejection scenarios can build invalid tunings, and `decodePolicy :: ResolvedKnobs -> RetryPolicy`), `.Roles`, `.Oracle` (`queueRows`, `archiveRows`, `dlqRows :: Pool -> QueueRef -> IO [QueueRowView]`) and the scenario modules. At the end of Milestone 4: the three `.Telemetry` modules, `.Bench.*` and `.Soak.*` modules per component, and the three sections of `docs/layers/keiro.md`.

Consumers of this plan: `docs/plans/15-verify-the-assembled-runtime-end-to-end-and-under-soak.md` may depend on `kenshou-keiro` and can reuse the fault plan, the inbox effect table and the scripted job for its own roles, and uses this plan's scenarios to localise an end-to-end failure to the outbox, the inbox or the queue; `docs/plans/3-plan-and-select-runs-from-what-changed.md` selects `keiro/outbox/**` and `keiro/inbox/**` when keiro's outbox or inbox modules change and `keiro/queue/**` when `keiro-pgmq`, `shibuya-pgmq-adapter`, `shibuya-core` or the pgmq packages change; `docs/plans/18-…` records the resulting runs.


## Revision note — 2026-09-24

The four-publisher outbox oracle now reads every callback start and end mark from each worker's retained control log, checks that each row belongs to exactly one complete interval, and checks intervals for the same row do not overlap. The 2,000-row durable run passed with 63 intervals and four participating publishers; the package's 36 unit examples also passed. This replaces the earlier count-only interpretation of `disjoint-ownership`.

The same strengthened oracle passed at the scenario's planned 20,000-row default in `runs/01a0d4e0-fd0a-76aa-91a5-623739770404`. Its 625 complete intervals covered every row, and all four publisher processes contributed broker records.

The terminal matrix now logs callback starts and ends with claimed rows and returned outcomes. It checks each row's SQL attempt count against effective callback attempts, each failed callback's delay before a retry, and the retried-summary total against attempts and skipped claims. The per-source callback was corrected after the first new run exposed an invalid broker append after an earlier source failure. All eight policy/backoff combinations then passed at 200 rows, the default 2,000-row arm passed, and the final retried-summary check passed for all four policies at 200 rows. The package test suite still has 36 passing examples.

The producer subscription crash replay now uses a dedicated worker over the fixture account category. The worker maps each recorded event to an integration draft, commits `enqueueProducerEventTx`, then parks before replying to Kiroku. Three `SIGKILL`s force replay at successive versions. A durable run passed with one stable row per event, no conflicts, no loss, and ordered broker records; all eight source events reached `sent`.

The separate enqueuer worker preloaded the four-publisher scenario at both 2,000 and 20,000 rows without changing its ownership, broker, or ordering verdicts. A bounded maintenance worker now performs reclamation and optional GC; its one-pass reclaim was exercised by the zombie publisher scenario and preserved the known-defect classification.

An eleven-scenario outbox sweep at default settings on durable PostgreSQL completed with CLI exit 0. Nine scenarios passed. The two expected failures reproduced the documented inline enqueue order limitation and stale publisher finalization defect with nonblocking known-defect status. This satisfies the local default-run item, while the remaining role generalization and producer-path oracles keep Milestone 1 open.

The delegated inbox matrix now passes all four dedupe policies on durable
PostgreSQL. It uses deterministic account-stream event IDs as receipts,
checks first delivery, redelivery and republish effects, and verifies that
zero-event and rejected commands return typed failures without changing the
stream. The default delegated arm passed again after those refusal checks in
run `01a0d4a0-4b53-7042-8b4b-6dcd78dcbdb5`.
The delegated poison-accounting arm passed on durable PostgreSQL in run
`01a0d4a3-57ee-72ee-bf9c-04ed15875f53`: an attempt above the caller-owned
ceiling did not invoke the handler, while the ceiling attempt did; no inbox
row was written.
The delegated batch arm passed in durable run
`01a0d4a5-6f98-714a-8e19-24a2076ee761`: a successful duplicate was
suppressed within one call, a failed key was retried within that call, and a
second call invoked the handler again for the same key.
All four delegated policy arms passed again after adding the missing-field
negative oracle, in durable runs `01a0d4a7-8111-7499-b0b3-6e76aa529f2a`,
`01a0d4a7-8d14-7524-84e8-08233e86e82e`,
`01a0d4a7-99c5-7506-ae08-2bd18f43325a`, and
`01a0d4a7-a53c-74f9-ac8e-3cc70de8d5d3`.
The table-backed matrix now compares exact effect IDs and dedupe keys, so a
missing republish cannot be offset by an extra effect for another key. All
eight policy/persistence combinations passed on durable PostgreSQL in the
`01a0d4aa-*` runs.
The staged inbox GC race is registered but has not met its exact guard. Runs
`01a0d4ad-d3a3-7456-b442-41d65e0f797f`,
`01a0d4ae-e9aa-72ee-8392-3bf4f72e28c6`,
`01a0d4b7-2232-729f-963e-54be0124532c`, and
`01a0d4ba-69a0-7210-89a6-44bbe89658b5` deleted the old completed row and
observed a second effect, but a new completed row for the same key remained.
The `effectively-once` implementation verdict is violated in those runs,
while `schedule-realised` is false and the scenario outcome is inconclusive.
The earlier query observer found no matching backend before the proxy
consumer started. The exact insert-then-lookup gap still needs isolation.

The inbox race now includes backend-only termination with a visible connection error, one peer winner, and a fresh redelivery classified duplicate. Durable run `01a0d498-893d-75dc-8e4c-62666a139fd5` passed; the SIGKILL arm passed again in `01a0d498-b9a1-75b0-a5ad-cf8188565639`.

The synthetic PostgreSQL broker now assigns Kafka-style offsets per topic and partition. The multi-process publisher scenario checks those offsets and requires actual participation from at least two workers. This exposed an idle-worker early exit in the scenario fixture; a bounded idle polling window resolved it. A new inline enqueue ordering arm uses an advisory lock to reproduce the documented inversion, with separate contract and implementation verdicts; its direct producer-path control passes. An ack-coupled Kiroku account subscription control also passes through the planned `outbox.enqueue-path=producer` arm in run `01a0d478-5fc6-7397-8565-058ec8596346`; the direct control remains available as `producer-direct` and passed again in `01a0d478-a1fa-7055-ac78-cac2b0776b8f`. The broker's fault decisions and hooks now have focused unit coverage. The crash scenario covers after-append, after-claim, attempt exhaustion, and backend termination during a locked finalization transaction; the latter passed on durable PostgreSQL in run `01a0d46b-2fd8-70e0-b433-bb3f1f392d64`. A new GC identity race scenario passed in run `01a0d471-e45e-754c-be39-6bd75ae53f1b`, with 192 sent rows deleted and 106 republications retaining stable wire IDs. `publisher-misbehaviour` now includes a producer replay of a rejected row after maintenance and GC, passed in durable run `01a0d494-f1ab-7343-b7b6-387d735f9af6`. The queue lease extension scenario now covers bounded drains in `01a0d47d-c676-74dc-b38d-782616c700b5` as well as continuous workers in `01a0d47f-5bff-77a0-920d-f29debefd45a`. Inbox poison accounting now covers condemned transactions in durable run `01a0d48a-1110-7420-a5ed-bb403cb51fdc` and SQL errors in durable run `01a0d48a-3cbe-7341-a256-b33a758db94c`; the latter returned `UnexpectedServerError "22012" "division by zero"` without a completed effect. The default exception arm passed again in durable run `01a0d48a-610d-7196-b189-236185308036`. The inbox batch scenario's condemn and exception arms passed in durable runs `01a0d48d-5d35-763a-a6ad-fc453f28ee51` and `01a0d48d-75b4-711f-9b99-7b625246afb8`. All eight table-backed inbox dedupe and persistence combinations passed in the `01a0d491-*` durable runs. The outbox knob declarations and publisher option decoder drive two correctness scenarios; remaining scenario wiring and the other Milestone 1 scenario and oracle work are still tracked above.

The terminal-state matrix now verifies that sent rows each yield exactly one broker record, rejected rows retain their rejection timestamp and code, and poisoned dead rows reach the configured attempt ceiling with the expected error. A durable 200-row run passed with all three new verdicts held in `runs/01a0d4c4-2801-751b-8a8a-0efb45f77b89`. This closes a gap where the earlier status and summary checks could miss duplicate appends or incomplete terminal metadata.

The queue job-outcome scenario now drives `runJobWorkers` through Retry and Dead as well as Done. A durable run passed in `runs/01a0d4c7-5a07-727e-ab17-0fb6e2b56695`: Retry produced two handler effects before deletion, while Dead produced one effect and a poison-pill DLQ row. This adds worker-path evidence without changing the drain-path assertions.

A further durable queue run, `runs/01a0d4c9-5084-72ed-803f-591d45cb094c`, passed the worker thrown-handler arm. The first delivery wrote an effect and threw; after the one-second visibility timeout, a second delivery completed and removed the source row. The scenario now tests Done, Retry, Dead, and a thrown handler through continuous workers.

The worker Dead DLQ oracle now decodes the wrapper with Keiro's `readDlq` and checks the original payload, source message ID, read count and raw headers field. The initial expectation of non-null decoded headers was wrong for an untraced send: the wrapper stores JSON null, which decodes to `Nothing`. The corrected durable run passed in `runs/01a0d4cd-1ba2-7100-a84a-17c48e0a619d`.

The zombie-publisher scenario is now registered. Its controlled `SIGSTOP` and maintenance schedule reproduced late finalization in all three outcomes on durable PostgreSQL. A stale failure left a successful second publisher's row `failed`; the attempt-ceiling arm left it `dead`; a stale success also changed the second publisher's claim. The upstream report is `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-5`. The scenario now scopes that known defect to the two ideal finalization verdicts, while `schedule-realised` remains blocking. The known-defect reruns `01a0d4d4-4843-7266-ae9e-f6e5a1b03716`, `01a0d4d4-84c4-7680-810b-db018fce73fe`, and `01a0d4d4-c21c-76ff-a5d4-c8fc5fbe36bb` each exited zero with the defect reproduced. The strengthened terminal matrix also passed at 2,000 rows in `01a0d4ce-902f-7255-a0e5-c38985c6e946`.


Revision note (2026-09-30): Queue throughput revision 2 adds the planned continuous-worker and polling shapes, explicit runtime pool sizing, actual read-batch tuning, and delivery multiplicity checks. Five durable local functional arms held all business verdicts; their short measurement windows remain exploratory. Controlled comparisons, provision variation, component metrics serving, and the other acceptance gaps stay open.

Revision note (2026-09-30): Queue throughput revision 3 collects and serves native worker metrics through existing released APIs. The new eight-arm correctness matrix passed with independent outcome checks; four throughput integration controls held the business invariants and remain exploratory. Broader fault/pre-handler coverage, outbox and inbox serving, controlled comparisons, and full-duration acceptance stay open.

Revision note (2026-10-01 UTC): Queue throughput revision 4 adds standard/unlogged provision variation with an independent SQL metadata oracle before and after load. Ten durable local arms held all four checks over 7,345 exactly-once jobs; all 30 schema checks and 264 artifact hashes/sizes passed. The 41-example package suite and full `nix develop -c just verify` pass. Controlled storage-performance comparison and the other acceptance gaps remain open.

Revision note (2026-10-01 UTC): Published clean messaging metrics and matched restart diagnostics with unchanged uncertainty limits. The historical bundle now has 95 run/comparison records; the three new comparison attestations confirm measurement and policy recomputation, not individual Keiro business oracles.
