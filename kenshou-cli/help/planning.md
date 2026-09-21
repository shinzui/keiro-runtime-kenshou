# Planning and execution

`kenshou plan` maps named components, cohort differences, local changes, or
upstream revision ranges through the checked-in component graph. The transitive
dependent closure selects scenarios, and `--explain` shows why each one was
included. Unmapped inputs select everything rather than risk missing evidence.

Dimension policies are `default-only`, `telemetry-corners`, `pairwise`, and
`full`. Telemetry changes raise their minimum policy automatically. Benchmarks
always use durable PostgreSQL and are budgeted as complete interleaved trial
groups.

Use `--suite smoke`, `change`, `nightly`, `weekly-soak`, or `release` for the
checked-in policies. The generated run plan binds the graph digest, cohort,
seed, reasons, skips, and preassigned run IDs.

`kenshou execute --plan FILE --out DIR` runs entries sequentially and writes an
atomic plan summary. `--resume` requires the byte-identical plan, skips completed
entries, and gives interrupted entries fresh run IDs. See `docs/planning.md` for
the complete guide.
