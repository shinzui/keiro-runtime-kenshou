# Keiro job worker exits after a polling backend is terminated

Status: reproduced on the released Keiro 0.17.0.0 cohort; owner report `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-3` is reported.

The durable PostgreSQL 18 scenario `keiro/queue/concurrency/workers-survive-transient-polling-error` terminates the backend serving a continuous worker after its first batch. The worker exits with `PgmqSessionError` containing `UnexpectedRowCountStatementError` for `pgmq.read`, and a later batch remains queued. Runs `01a0d1a5-1650-76e3-8cd2-4614dd07ff19` and `01a0d1a6-a1b0-7753-abc2-a5b50d1d5b76` failed the survival and no-loss checks; `01a0d1a8-a608-70aa-aca6-8f8272384b92` preserved the scoped known-defect verdict.

The adapter consults `Pgmq.Effectful.isTransient`, which classifies the observed row-count error as permanent. The owner report leaves the exact cause of that error open. Queued jobs remain durable and a restarted worker can recover them. The earlier run artifacts remain under `runs/<run-id>/`.

A clean released-cohort cell control, verified cell run `01a0ef02-3208-72ed-be06-92f4f114149d` and [digest-linked nested run](../verification/runs/keiro/2026/09/01a0eef1-60b7-71f4-bcc1-c4d4eb6ef470.md), terminated five polling backends but **did not reproduce** the worker exit: all four checks held and `knownDefect.status=not-reproduced`. This is a reproducibility gap across environments and schedules, not proof of an owner fix. The scenario kills the polling backend after each batch has drained, so the timing of the next read is a variable to isolate.
