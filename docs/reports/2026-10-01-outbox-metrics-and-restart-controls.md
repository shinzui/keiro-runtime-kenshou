# Controlled outbox metrics and restart diagnostics

All runs use clean released-cohort Linux payload `16ec2d667894996149149fd235fb7f6791818cf0`
on leased alpha with durable PostgreSQL 18.6. The payload bundle SHA-256 is
`040b32f2fa2fb3396894715f7d07b57725325ac695451141746b7a929418b41f`;
the cohort plan SHA-256 is `3cd821029b55222b1236939f5f2586b4bf1ce57e0d4f81164bef7fdd00fe81c9`.
These are configuration investigations within one released cohort.

## Metrics serving and overhead

The [revision-2 telemetry contract](../verification/runs/keiro/2026/10/01a0f899-f196-7031-aa56-2d49cf00e6b6.md)
passed all eleven checks with in-memory tracing and scraped metrics. It checks
queued and completed native Kiroku JSON/Prometheus and Keiro OpenTelemetry
responses against the fixture's durable state. All six endpoint scrapes succeeded.

The enqueue-to-publish benchmark then ran three blocks of five arms: metrics
off, collect, serve, serve-scraped, and an identical off control. Tracing stayed
off. Each arm used a 60-second steady window, offered load 250 messages/s,
two publishers and batch size 32; scraping ran every 100 ms where enabled.
All fifteen cold-reset slices used one lease with consecutive sequences 1–15.
All passed at benchmark grade, conserved 230,915 messages across all phases,
and drained their outboxes. Across the contract and benchmark runs, 48 schema
checks and 397 artifact size/digest checks passed. All 5,667 scrapes succeeded,
including 3,778 native-store scrapes.

The three valid paired blocks use the unchanged saved comparison policy,
95% intervals and 10,000 bootstrap iterations with the Student-t envelope.
All three enabled-metrics comparisons have confirmed VC-2/VC-3 attestations;
these confirm their recorded decisions, including inconclusive decisions.
They do not provide the still-missing independent Keiro VC-1 business oracle.

| Metrics arm versus off | Allocated bytes/op change (95% interval) | Overall policy | Evidence / attestation |
| --- | --- | --- | --- |
| collect | +7.06% (+4.03% to +10.18%) | pass | [comparison](../verification/runs/keiro/2026/10/01a0f8be-8005-7455-a352-f2165da567f6.md), [confirmed](../verification/attestations/2026/10/01a0f8d7-0ca5-7664-b00d-a73b15baa21f.md) |
| serve | +6.67% (+2.46% to +11.05%) | inconclusive | [comparison](../verification/runs/keiro/2026/10/01a0f8be-8179-75d7-9d7a-0b089f042fa8.md), [confirmed](../verification/attestations/2026/10/01a0f8de-28b2-7071-be08-5e9d97b1e35e.md) |
| serve-scraped | +9.53% (+6.41% to +12.75%) | pass | [comparison](../verification/runs/keiro/2026/10/01a0f8be-8279-7667-ad13-3757c626211f.md), [confirmed](../verification/attestations/2026/10/01a0f8e6-0b3d-7186-9141-0392dcefe7ab.md) |

The overall overhead report is inconclusive. Serve's enqueue p99 interval
crosses its policy limit, and the A/A control is inconclusive on both p99
metrics. Thus p99 repeatability and broad telemetry-overhead acceptance remain
open. Throughput near 250 messages/s shows that the arms met this offered load;
it does not estimate peak capacity. No observations or policy limits were removed.

The [unaltered A/A comparison](data/2026-10-01-outbox-metrics-control.json) has SHA-256
`e02590d3c57ef942e5d13f74be3a9673b3d43e33c52d06d00c65a34fbefddd97`. Its internal `control`
factor is unsupported by the evidence recorder; a same-cohort replay also rejects
identical arm values. The raw report and all underlying run records are preserved
without inventing a differing factor. Formal A/A recording and attestation remain open.

| Cell sequence | Metrics | Sealed run |
| --- | --- | --- |
| 1 | serve | [01a0f8a2-690d-70ad-8c16-1d46e7397a5e](../verification/runs/keiro/2026/10/01a0f8a2-690d-70ad-8c16-1d46e7397a5e.md) |
| 2 | serve-scraped | [01a0f8a4-3c36-746e-a2ec-0c47a79ae357](../verification/runs/keiro/2026/10/01a0f8a4-3c36-746e-a2ec-0c47a79ae357.md) |
| 3 | off | [01a0f8a6-304f-7726-bcf1-ba6343c2bb1e](../verification/runs/keiro/2026/10/01a0f8a6-304f-7726-bcf1-ba6343c2bb1e.md) |
| 4 | collect | [01a0f8a8-0fbe-7737-b239-d7be7f258756](../verification/runs/keiro/2026/10/01a0f8a8-0fbe-7737-b239-d7be7f258756.md) |
| 5 | off | [01a0f8a9-de59-7509-95a1-ec880428ba12](../verification/runs/keiro/2026/10/01a0f8a9-de59-7509-95a1-ec880428ba12.md) |
| 6 | off | [01a0f8ab-bf34-760b-8a29-8b514d545050](../verification/runs/keiro/2026/10/01a0f8ab-bf34-760b-8a29-8b514d545050.md) |
| 7 | collect | [01a0f8ad-87e1-739d-9544-6bf01e555fe7](../verification/runs/keiro/2026/10/01a0f8ad-87e1-739d-9544-6bf01e555fe7.md) |
| 8 | off | [01a0f8af-7dbe-7050-910d-9b3eca09b9a4](../verification/runs/keiro/2026/10/01a0f8af-7dbe-7050-910d-9b3eca09b9a4.md) |
| 9 | serve-scraped | [01a0f8b1-63ca-704b-8fea-fed0339b50f6](../verification/runs/keiro/2026/10/01a0f8b1-63ca-704b-8fea-fed0339b50f6.md) |
| 10 | serve | [01a0f8b3-46c6-774a-8de5-c0daa19a1c05](../verification/runs/keiro/2026/10/01a0f8b3-46c6-774a-8de5-c0daa19a1c05.md) |
| 11 | serve-scraped | [01a0f8b5-3434-77e6-a3e9-ced441da2fa7](../verification/runs/keiro/2026/10/01a0f8b5-3434-77e6-a3e9-ced441da2fa7.md) |
| 12 | off | [01a0f8b7-233c-7471-96e8-29cb50b1f908](../verification/runs/keiro/2026/10/01a0f8b7-233c-7471-96e8-29cb50b1f908.md) |
| 13 | collect | [01a0f8b8-eed2-7406-b54b-55be68231d95](../verification/runs/keiro/2026/10/01a0f8b8-eed2-7406-b54b-55be68231d95.md) |
| 14 | off | [01a0f8ba-af98-7607-af3e-1ce8271ed91a](../verification/runs/keiro/2026/10/01a0f8ba-af98-7607-af3e-1ce8271ed91a.md) |
| 15 | serve | [01a0f8bc-9f3d-76ce-bdde-662078433ce4](../verification/runs/keiro/2026/10/01a0f8bc-9f3d-76ce-bdde-662078433ce4.md) |

## Matched restart diagnostics

Two twenty-minute revision-3 outbox soaks use the same resolved seed
`8066040983596989`, 20 messages/s, two publishers, one restart per minute,
30-second sent-row retention, and forced major GC every 5 seconds. Only
`outbox.publisher-execution` differs. Each received a cold reset.
Forced collection perturbs runtime behavior, so these are diagnostics and are
excluded from throughput comparisons and default-GC leak clearance.

The [process run](../verification/runs/keiro/2026/10/01a0f8c1-747d-7434-befb-a01931028005.md), cell `01a0f8c1-8e02-7501-b45a-73180dc60106`,
is **inconclusive**. All 11 business checks held over 24,202 unique
messages, 24,222 broker records and 20 restarts, with zero backlog
or publisher/maintenance errors. Retention, relation-size and dead-tuple bounds
held. Main Haskell thread window medians started at 144 and ended at
145; the heap had 41 eligible post-major points.
All six bounded main-process probes classified stable.
The continuous surviving publisher also had stable bounded resources. Twenty-one
short killed/final replacement incarnations retained insufficient-data verdicts;
no incarnation series was spliced or policy weakened to obtain a pass.

The [in-process run](../verification/runs/keiro/2026/10/01a0f8c5-2ae0-768c-a4d1-14c63e1cb802.md), cell `01a0f8d5-613c-713c-86ff-d4bc329383ca`,
**passed**. All 8 business checks held over 24,202 unique
messages, 24,202 broker records and 20 restarts, with zero backlog
or publisher/maintenance errors. Retention, relation-size and dead-tuple bounds
held. Main Haskell thread window medians started at 143 and ended at
143; the heap had 40 eligible post-major points.
All six bounded main-process probes classified stable.

All six spec/result/manifest schema checks and 171 manifested-file
size/digest checks passed for these two soaks. Their records are digest-linked
investigations, without independent Keiro VC-1 attestations.

The clean process result supports the earlier supervisor bookkeeping repair.
[Finding 3](../findings/3-keiro-steady-restart-harness-threads.md) remains open for
the historical default-collection in-process signal. A local GHC 9.12.4 [probe](data/2026-10-01-listthreads.hs)
also showed that `listThreads` includes finished threads before collection:
twenty completed forks raised the observed count from four to twenty-four,
and explicit major GC returned it to four ([observed output](data/2026-10-01-listthreads.txt)). This is a sampler-semantics observation,
not attribution of the earlier workload. The four-hour outbox and queue soaks,
remaining scenario matrices and independent Keiro business-verdict replay remain open.

The sampler probe can be repeated with the pinned toolchain:

```bash
nix develop -c ghc -threaded docs/reports/data/2026-10-01-listthreads.hs -outputdir /tmp/ep13-listthreads-build -o /tmp/ep13-listthreads
/tmp/ep13-listthreads +RTS -N2 -RTS
```

Strict OKF profile/log validation passes for all 117 concepts. The evidence
ledger check, CLI record/replay/refusal/tamper fixtures, formatting, and all 28
local report links pass. The implementation commit also passed the full
`nix develop -c just verify` gate, including 44 Keiro and 19 telemetry examples.
