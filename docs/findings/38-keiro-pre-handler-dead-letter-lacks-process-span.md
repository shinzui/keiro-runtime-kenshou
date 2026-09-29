# Keiro pre-handler dead-lettering has no process span

Status: reproduced on the released Keiro 0.17.0.0 cohort; owner report `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-7` is reported.

The durable PostgreSQL 18 run `01a0d594-5f5a-74c9-9089-2a3a94db3eb3` of `keiro/queue/correctness/telemetry-contract` used in-memory tracing and collected metrics. A job with `maxRetries=0` reached the dead-letter queue before handler invocation: one DLQ row, zero handler calls, and zero per-message process spans. Two ordinary worker deliveries each emitted a process span. The overall scenario passed its current telemetry oracle, so this observation requires its own owner report and a stronger scenario check after repair.

The retry-ceiling path executes while polling, before the supervised runner opens its per-message span. This is an inference from the observed run and source flow; no isolated patch test has been run. Artifacts remain under the local run directory.
