# Partitioned PGMQ notifications bypass throttle and channel

Status: reproduced on the released 0.6.1.0 cohort and filed as
`mori://shinzui/pgmq-hs/okf/bug-reports/concepts/BUG-3`.

With notifications enabled at the default 250 ms throttle, PostgreSQL 18 run
`01a0d6d6-268b-73bc-b9fe-40b6045586bd` and PostgreSQL 17 run
`01a0d6d7-5dab-76ea-8315-00fcc28919d3` each produced 1,000
leaf-partition notifications in about five seconds, versus an allowance of 21.
None used the queue channel returned by `notifyChannelName`. Disabling
notifications yielded zero on the same listener. This contradicts the shipped
throttle and channel claim in
`mori://shinzui/pgmq-hs/okf/capabilities/concepts/CAP-4`.

Reproduce from this repository with pg_partman available:

```bash
cabal run kenshou -- run pgmq/notify/concurrency/partitioned-notify-storm --out runs --dim pg.version=18
```

The sealed results are under `runs/<run-id>/` in this repository. The owner
fix is planned at
`mori://shinzui/pgmq-hs/plans/23-gate-the-notification-fail-open-on-a-real-queue-row-and-state-the-partitioned-queue-contract`.
