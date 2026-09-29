# Keiro long polling consumes a read attempt without handler delivery

Status: reproduced on the released Keiro 0.17.0.0 cohort; owner report `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-4` is reported.

The durable PostgreSQL 18 `keiro/queue/concurrency/crash-redelivery-cadence` scenario kills handler processes during delivery. With long polling, run `01a0d1b3-8a6c-7624-aa6f-7fff066f8787` recorded three handler calls but a dead-letter wrapper with `read_count=5`; run `01a0d1b4-5232-707b-abed-404ce0d0db3e` skipped handler attempt one. The verdict-preserving run is `01a0d1b5-b342-7584-8a62-771055f84aad`.

The ordinary polling controls `01a0d1b0-e9e6-7507-88a0-4dbb61bf2fc1` and `01a0d1b6-4762-7781-8f97-8a52245b0bb4` delivered three attempts followed by `read_count=4`. Concurrent long-poll prefetch is a possible cause, but the owner has not isolated it. Artifacts remain under local `runs/<run-id>/` directories.
