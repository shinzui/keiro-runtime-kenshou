# A stale Keiro outbox publisher finalizes another publisher's claim

Status: reproduced on the released Keiro 0.17.0.0 cohort; owner report `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-5` is reported.

The durable PostgreSQL 18 `keiro/outbox/concurrency/zombie-publisher-finalization` scenario stops publisher P1 after it claims a row, lets maintenance requeue it, and lets P2 claim and publish it. Resuming P1 can change P2's live claim to `failed` (`01a0d4d0-d80e-73df-a678-185c7d8bd738`) or `dead` (`01a0d4d2-4640-7008-9a09-e46104d73de9`) after P2 has appended the broker record. The stale-success control `01a0d4d1-e880-7794-b394-58223cac3e34` also lets P1 finalize P2's claim. Later runs `01a0d4d4-4843-7266-ae9e-f6e5a1b03716`, `01a0d4d4-84c4-7680-810b-db018fce73fe`, and `01a0d4d4-c21c-76ff-a5d4-c8fc5fbe36bb` preserved this as a scoped known defect.

The owner traced finalization to an `outbox_id` and `publishing` status check without a claim generation. A successful broker append can therefore leave a row in a non-sent state after reclamation. Artifacts remain under local `runs/<run-id>/` directories.
