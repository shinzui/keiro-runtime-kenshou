# Keiro long polling consumes a read attempt without handler delivery

Status: reproduced on the released Keiro 0.17.0.0 cohort; owner report `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-4` is reported.

The durable PostgreSQL 18 `keiro/queue/concurrency/crash-redelivery-cadence` scenario kills handler processes during delivery. With long polling, run `01a0d1b3-8a6c-7624-aa6f-7fff066f8787` recorded three handler calls but a dead-letter wrapper with `read_count=5`; run `01a0d1b4-5232-707b-abed-404ce0d0db3e` skipped handler attempt one. The verdict-preserving run is `01a0d1b5-b342-7584-8a62-771055f84aad`.

The ordinary polling controls `01a0d1b0-e9e6-7507-88a0-4dbb61bf2fc1` and `01a0d1b6-4762-7781-8f97-8a52245b0bb4` delivered three attempts followed by `read_count=4`. Concurrent long-poll prefetch is a possible cause, but the owner has not isolated it. A clean released-cohort alpha cell run `01a0ef05-232e-74cc-ba42-fd7713371f19` independently reproduced the three scoped failures; its [digest-linked nested run](../verification/runs/keiro/2026/09/01a0eef1-bb2c-73f5-b32a-1046f297db83.md) recorded handler attempts `[0,2]`, a third delivery timeout, and DLQ `read_count=4`. These observations support the same missing-delivery problem while showing that the exact read count varies by schedule. Earlier artifacts remain under local `runs/<run-id>/` directories.

A later clean alpha queue sweep, verified cell run `01a0ef4f-ce12-74f3-823c-360e44b1ff93`, ran the same crash-redelivery scenario with `queue.polling=poll-every` as a control. Nested run `01a0ef4d-d6ae-76a1-9e4e-73634d34e454` passed all checks and marked BUG-4 `not-reproduced` for that polling mode. The long-poll failure remains the owner-facing defect.
