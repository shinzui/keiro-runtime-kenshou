# A hot ledger account serialises the shop dispatcher at 20 orders per second

Status: reproduced on cell `alpha` with the released cohort (keiro 0.17.0.0,
kiroku-store 0.8.0.1). Classified under
[ADR-14](../adr/0014-distinguish-documented-limitations-from-known-defects.md)
as a documented limitation of per-stream optimistic concurrency, not a Keiro
defect. No owner record is warranted.

The assembled runtime's reference system originally moved every order's
money through one `escrow` account, one `merchant` account and one
`loyalty-pool` account. Each is a single ledger stream, so every hold,
capture, refund and loyalty debit appends to the same three streams. Two shop
dispatcher processes over eight shards run those commands concurrently.
Under per-stream optimistic concurrency they conflict, and a command whose
conflict retries are exhausted returns `RetryExhausted`. The shard handler
then returns a retry and redelivers the event later. Without snapshots, each
attempt also replays the whole account stream, which grows by two events per
order, so the cost of every command grows with the run.

Evidence: cell session `cell-runs/ep15-runtime-3` (session
`01a103ce-04ab-72f6-b47a-25d67a40f01d`, lease
`01a103cd-fea9-776e-a64d-8bff5d71b9e7`, payload bundle
`c5b73c975dc53c51cf53b50b934a165613e6e05aff9741aa20ec7fb6feedd33f` from
Kenshou `c84540a`) ran the default load: 3,600 orders at 20 per second. In each
fault slice the fault itself took no effect, except where noted, so the load
alone explains the result. 300 seconds after the drivers finished, these
orders were still `placed`:

| Cell run | Nested run | Scenario | Orders still placed | `account-escrow` retry exhaustions |
|---|---|---|---|---|
| `01a103ce-04ab-72f7-9615-9c1e3b72aa99` | `01a10398-1258-756e-b8f0-b3f1b73b0699` | ack-retry-under-database-outage | 585 | 62 |
| `01a103ce-04ab-72f7-9b5c-cfafdf051ac3` | `01a10398-1258-756e-bcc5-30c4ecdac869` | batch-enqueue-publish-under-broker-restart | 586 | 71 |
| `01a103ce-04ab-72f7-9caa-1533487cd2f0` | `01a10398-1258-756f-80b5-55cde0b89015` | broker-restart | 572 | 61 |
| `01a103ce-04ab-72f7-a0cb-dca05145c86e` | `01a10398-1258-756f-869d-7f92522883a1` | partition-broker | 576 | 67 |
| `01a103ce-04ab-72f7-a510-290efdce0651` | `01a10398-1258-756f-8bd4-0a93944fb415` | partition-database (fault applied) | 841 | 240 |

In the first run, the stuck orders' `order.placed.v1` outbox rows were
created at 22:30:40 for orders placed at 22:25:06. The shop dispatcher was more
than five minutes behind. Only 3,019 records reached the shop topic, and the
warehouse group had committed all but two. The 600-order correctness scenarios in the same
session passed, with up to 28 such retries (`happy-path`,
`01a10398-1258-756e-ad52-4194b2c667c8`).

Documentation: keiro's command guide (`docs/user/command-cycle.md` in
`mori://shinzui/keiro`) defines `RetryExhausted` as "retries were exhausted on
a conflict". Its operations guide (`docs/user/operations.md`) tells operators
to compare `keiro.command.retries` with `keiro.command.conflicts` "to spot
retry storms on hot streams". Snapshots are opt-in (`docs/user/snapshots.md`).
No guide promises a throughput for one stream. No loss was observed: the
stuck orders' events were still pending in the shop dispatch subscription
when the 300-second deadline expired. Whether such a backlog completes is
judged by the contention scenario below, with a 900-second deadline.

Response: the reference system's default topology now splits each hot account
into `runtime.hot-account-buckets` (default 16) streams chosen by the order,
and the ledger accounts snapshot every 50 events. A local run of 3,600 orders at
20 per second then passed with no retry exhaustion (`01a1040e-0055-73b4-b703-1dcbbc99a3c2`),
on the same busy workstation where a default-rate `sigkill-role` run had
previously left 707 orders placed (`01a10318-b8c7-7570-b17c-f6a0aa8408b1`). `runtime/order-flow/correctness/hot-account-contention` keeps
the limitation visible. It sets one bucket at the default rate, judges I1–I4
after the backlog drains, and reports retry exhaustion per stream as an
implementation verdict.

Its first local run, `01a10416-0c10-7591-8108-815c777342b2` (functional
evidence on a shared workstation, snapshots on), passed. All 3,600 orders
completed, draining 64 seconds after the drivers. The implementation verdict
recorded 63 retry exhaustions on `escrow-0`, 4 on `loyalty-pool-0` and 1 on
`merchant-0`. With snapshots bounding each command's replay, a single hot
stream still contends but no longer falls behind the default rate. The
cell-scale stall needed both the unbounded replay and the contention.
