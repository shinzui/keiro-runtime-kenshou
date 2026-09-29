# Excess Keiro long-poll processors starve the job runtime pool

Status: reproduced on the released Keiro 0.17.0.0 cohort; owner report `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-6` is reported.

On durable PostgreSQL 18, `keiro/queue/concurrency/runtime-pool-isolation` started six long-poll processors against the shipped three-connection job runtime pool. Runs `01a0d52b-8dc4-77dc-b517-e0abb7c78218` and `01a0d52d-8a1e-7070-be94-b20e771f6650` left an available job queued with no handler effect for thirty seconds. One- and three-processor controls handled their jobs. Run `01a0d530-2239-7124-af19-f73bbbb94e31` showed that a replacement one-processor worker drained the stalled job.

Excess long polls are the leading explanation, but the exact blocked pool operation remains unisolated. The owner recommends at most three long-poll processors per worker on this pool, or ordinary polling, until the defect is repaired. A clean released-cohort alpha cell run `01a0ef06-73cc-72ba-81ce-488c5c9fbbd4` passed all four checks while affirmatively observing the saturation pattern: one processor made progress, whereas the three- and six-processor arms did not. Its [digest-linked nested run](../verification/runs/keiro/2026/09/01a0eef1-bb33-75d4-a1b7-f167d99951aa.md) is a characterization pass, not a repair. Earlier artifacts remain under local `runs/<run-id>/` directories.
