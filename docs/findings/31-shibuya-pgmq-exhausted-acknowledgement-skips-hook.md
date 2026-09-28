# Historical PGMQ acknowledgement failure skips its hook

Status: reproduced on `shibuya-pgmq-adapter` 0.16.0.0 and fixed on published 0.16.1.0. Owner report: `mori://shinzui/shibuya-pgmq-adapter/okf/bug-reports/concepts/BUG-2`.

The `shibuya/pgmq-adapter/concurrency/postgres-outage-and-the-restart-loop` scenario restarts a durable PostgreSQL postmaster while one handler is gated just before acknowledgement. The historical PostgreSQL 18 and 17 results `runs/01a0de11-51ed-7150-9859-082ef2770680/run-result.json` and `runs/01a0de13-05b9-73db-8105-0cdecfa2b820/run-result.json` reproduce `acknowledgement: ack-failure-hook-not-fired`. The application exception remains visible through `waitApp`; both queues drain and all producer IDs are conserved. The defect is the absent callback, not missing message recovery.

The isolated published 0.16.1.0 adapter passes the same scenario on PostgreSQL 18 and 17 in `runs/01a0de0e-274c-76f0-b197-fb148c673ef4/run-result.json` and `runs/01a0de0e-c680-76ca-a57b-8acd846289bf/run-result.json`. The current acknowledgement handle invokes `onAckFailure` before throwing `PgmqAcknowledgementException`, matching the 0.16.1.0 changelog. The historical `v0.16.0.0` handle omits that hook. These run paths are local to this repository.

Clean released PostgreSQL 18 run `runs/01a0e55b-52c2-75d3-aa5b-680edeff9115/run-result.json` at harness revision `9297d59` reproduced only the scoped hook label under the owner BUG-2 reference. It is nonblocking, and its run-result schema validated.
