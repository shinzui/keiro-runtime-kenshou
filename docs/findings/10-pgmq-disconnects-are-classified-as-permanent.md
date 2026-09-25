# Recoverable PGMQ disconnects are classified as permanent

Status: reproduced on the released 0.6.1.0 cohort and filed as
`mori://shinzui/pgmq-hs/okf/bug-reports/concepts/BUG-1`.

On PostgreSQL 18, immediate restart run `01a0d6d6-cb25-7609-b1d1-0eeebbba50ec`
reported an empty-SQLSTATE statement error as permanent, while 200 confirmed
keys survived and the same pool recovered in 361 ms. PostgreSQL 17 run
`01a0d6d7-cae8-72ed-ba4a-17a8cc224e53` had the same classification failure
and conservation result. PostgreSQL 18 backend-termination run
`01a0d6d7-028e-73ac-b7a5-e582b4f85c36` reported an unexpected-row-count
error as permanent; TCP-reset run `01a0d6d7-1f5e-768c-9b95-822031453720`
reported another empty-SQLSTATE statement error as permanent. Both retained
200 confirmed keys and reused the pool successfully.

Reproduce from this repository with:

```bash
cabal run kenshou -- run pgmq/effectful/concurrency/postgres-restart-recovery --out runs --dim pg.version=18
cabal run kenshou -- run pgmq/effectful/concurrency/backend-termination-recovery --out runs --dim pg.version=18
cabal run kenshou -- run pgmq/effectful/concurrency/network-partition --out runs --dim pg.version=18
```

The sealed results are under `runs/<run-id>/` in this repository. The capability
`mori://shinzui/pgmq-hs/okf/capabilities/concepts/CAP-5` promises a retry
classifier; its design note explicitly makes unrecognized statement and
row-count errors permanent, assuming they cannot be repaired by retry. These
runs show a connection fault can surface through those shapes. The owner
request is `mori://shinzui/pgmq-hs/okf/improvement-requests/concepts/IR-4`.
