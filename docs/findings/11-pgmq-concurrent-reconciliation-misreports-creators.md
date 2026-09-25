# Concurrent PGMQ reconciliation misreports creators

Status: reproduced on the released 0.6.1.0 cohort and filed as
`mori://shinzui/pgmq-hs/okf/bug-reports/concepts/BUG-2`.

Eight reconciler processes raced on ten queue declarations for fifty rounds.
PostgreSQL 18 run `01a0d6d6-85fe-7214-b7f3-cea91e397461` recorded eighty
creation claims for ten physical queues in round one. PostgreSQL 17 run
`01a0d6d7-9fe9-7653-bad0-83c881850ae8` also failed the unique-creator
check. Both final catalogs converged, and both recorded FIFO index `23505`
errors during some rounds. The index race is already documented as a
concurrent-startup limitation; the false action report contradicts the shipped
claim of truthful action accounting in
`mori://shinzui/pgmq-hs/okf/capabilities/concepts/CAP-9`.

Reproduce from this repository with:

```bash
cabal run kenshou -- run pgmq/config/concurrency/concurrent-reconcile --out runs --dim pg.version=18
```

The sealed results are under `runs/<run-id>/` in this repository. The owner
request is `mori://shinzui/pgmq-hs/okf/improvement-requests/concepts/IR-5`.
