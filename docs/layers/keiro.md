# Keiro write-side verification

The `keiro` layer runs against a harness-provisioned PostgreSQL 18 database
with the kiroku and keiro schemas migrated together. It uses a bank-ledger
fixture: account commands emit account events, and a pure model plus direct
SQL queries check what persisted. The fixture is owned by
`kenshou-keiro/src/Kenshou/Suite/Keiro/Fixture/`.

Run the first scenario from the repository root inside `nix develop`:

```bash
cabal run kenshou -- run keiro/command/correctness/fixture-roundtrip --out runs
```

The scenario opens ten accounts, submits seeded deposits and withdrawals
through `runCommandWithProjections`, and reads the event log and inline
balance table using a separate Hasql connection. It emits four contract
verdicts: `log-is-well-formed`, `model-equals-log`,
`inline-read-model-equals-log`, and `money-is-conserved`. The
`workload.operations` knob defaults to 500.

The fixture also defines a bonus event stream and a transfer process manager
with deterministic target commands. Their scenario coverage is being added
under `docs/plans/12-cover-the-keiro-command-processor-process-managers-and-routers.md`.

The registered command scenarios also cover duplicate event identifiers,
optimistic retry and exhaustion, controlled SQL rollback, and hydration over
stream lengths and page sizes. `keiro/snapshot/correctness/policy-matrix`
checks the persisted snapshot version and register values for all five
policies. Two concurrency scenarios check simultaneous submission of one
identifier and sustained writes to one hot stream. The scenario IDs and
their knobs are available through `cabal run kenshou -- list --layer keiro`.

The process manager scenarios check stable manager and target identities under
redelivery, timer persistence, and both orders of transfer inputs. The reactive
manager scenario checks insert-only timeout scheduling, reminder rearming,
cancellation, and duplicate delivery. The `reaction-no-advance-receipt` run
reproduces the documented missing durable receipt for a `NoAdvance` input;
the harness reports it as a nonblocking known defect tied to
`mori://shinzui/keiro/okf/adrs/concepts/ADR-41`. The process-manager
`policy-matrix` run checks all nine poison and rejected-command policy
combinations, including acknowledgement decisions and durable dead letters.
The `sigkill-crash-windows` scenario runs a separate process-manager worker,
parks it at one of four append or acknowledgement boundaries, kills it, and
checks the durable saga and target effects after a fresh worker resumes the
same subscription. Select a boundary with `--set pm.kill-window=between-targets`.
The router
scenarios check fanout under redelivery and selection drift, independent
target commits with a durable dead letter, and the declarative selection
policy matrix. The asynchronous projection scenario checks deduplication,
rebuild fencing, and the documented effect of pruning deduplication rows.
