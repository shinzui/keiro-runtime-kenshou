# Harness thread growth during Keiro soaks

Status: investigating. The durable recovery checks passed; the leak signal is
in the harness process and its retained component is not yet identified.

The reduced `keiro/command/soak/write-side-steady-state-reduced` run
`01a0d116-079f-73e6-96e2-93ff0487d22b` used four accounts, one bonus
recipient, twenty target commands per second, a one-minute steady window,
and `soak.kill-interval-seconds=10`. It rotated SIGKILL and restart across the
process-manager, router, and projection workers six times while both writers
continued. The ignored run data is in
`runs/01a0d116-079f-73e6-96e2-93ff0487d22b/`.

All ten scenario checks passed over 1,593 account events: the source and target
logs, inline balances, async activity, no dead letters, snapshot row bounds,
and writer completion remained correct after recovery. The overall outcome was
`failed` because the main harness process's Haskell thread probe rose from 18
to 24 and was judged `leak-suspected`. Native bytes, OS threads, file
descriptors, and PostgreSQL connections were stable. The heap probe lacked
enough post-major samples, and first and last command latency p99 values of
7.50 and 11.19 ms gave an inconclusive drift verdict.

An earlier run showed the same six-thread rise. The supervisor was changed to
retire children after exit, but the rerun still grew by six threads. The count
therefore needs a more focused harness investigation before it can be
attributed to a specific retained object or upstream runtime component. The
worker leak reports also lacked sufficient duration to judge this one-minute
restart arm.

A separate one-minute `seed-verification-backlog-reduced` run with in-memory
tracing, collected metrics, and three offered commands per second completed
211 commands and passed four durable checks without child worker restarts.
Its main-process Haskell thread probe grew by 13 and was judged
`leak-suspected`; native bytes, OS threads, file descriptors, and PostgreSQL
connections were stable, while the heap probe lacked enough post-major
samples. An otherwise matching earlier run grew by eight counted threads but
was `insufficient-data` under the statistical policy. These observations show
that the main-process signal is not confined to the restart arm. They do not
establish that the two runs retain the same objects. The ignored run data is
under `runs/01a0d130-aab3-70c7-ad94-0a21d40d45fa/` and
`runs/01a0d12e-fbc4-7367-b1d0-536a84fcacea/`.

Reproduce with:

```bash
cabal run kenshou -- run keiro/command/soak/write-side-steady-state-reduced \
  --set soak.duration-minutes=1 --set command.accounts=4 \
  --set command.rate-per-second=20 --set router.fanout=1 \
  --set soak.kill-interval-seconds=10 \
  --set projection.prune-interval-seconds=0 \
  --dim pg.durability=durable --out runs
```

Next, run a minimal supervisor loop without the Keiro workers and inspect
live thread references after each child exit. Compare its thread series with
the same soak with restarts disabled and with a longer steady window.
