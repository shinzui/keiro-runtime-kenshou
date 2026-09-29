# Keiro job worker exits after a polling backend is terminated

Status: reproduced on the released Keiro 0.17.0.0 cohort; owner report `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-3` is reported.

The durable PostgreSQL 18 scenario `keiro/queue/concurrency/workers-survive-transient-polling-error` terminates the backend serving a continuous worker after its first batch. The worker exits with `PgmqSessionError` containing `UnexpectedRowCountStatementError` for `pgmq.read`, and a later batch remains queued. Runs `01a0d1a5-1650-76e3-8cd2-4614dd07ff19` and `01a0d1a6-a1b0-7753-abc2-a5b50d1d5b76` failed the survival and no-loss checks; `01a0d1a8-a608-70aa-aca6-8f8272384b92` preserved the scoped known-defect verdict.

The adapter consults `Pgmq.Effectful.isTransient`, which classifies the observed row-count error as permanent. The owner report leaves the exact cause of that error open. Queued jobs remain durable and a restarted worker can recover them. The run artifacts are under `runs/<run-id>/` in this repository and are not yet published as immutable verification records.
