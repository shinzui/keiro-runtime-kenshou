# Excess Keiro long-poll processors starve the job runtime pool

Status: reproduced on the released Keiro 0.17.0.0 cohort; owner report `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-6` is reported.

On durable PostgreSQL 18, `keiro/queue/concurrency/runtime-pool-isolation` started six long-poll processors against the shipped three-connection job runtime pool. Runs `01a0d52b-8dc4-77dc-b517-e0abb7c78218` and `01a0d52d-8a1e-7070-be94-b20e771f6650` left an available job queued with no handler effect for thirty seconds. One- and three-processor controls handled their jobs. Run `01a0d530-2239-7124-af19-f73bbbb94e31` showed that a replacement one-processor worker drained the stalled job.

Excess long polls are the leading explanation, but the exact blocked pool operation remains unisolated. The owner recommends at most three long-poll processors per worker on this pool, or ordinary polling, until the defect is repaired. Artifacts remain under local `runs/<run-id>/` directories.
