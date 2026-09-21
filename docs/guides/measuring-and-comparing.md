# Measuring and comparing Keiro runtime behaviour

Never quote one benchmark trial. Run at least three paired trials and use five by
default. Interleave baseline and candidate arms in one environment so table
growth, checkpoint timing, and host drift affect both arms.

Use PostgreSQL durability for benchmark evidence. Prefer an open loop for
latency because intended-start timing exposes queued work, and use a closed loop
when measuring capacity. Keep the driver below saturation; a benchmark that
measures an overloaded harness is not runtime evidence.

For Kiroku, test pool sizes from 10 through 13 and compare the best stable pool
for each arm. Make the steady window span a checkpoint cycle when possible.
Retain raw benchmark samples and use `kenshou summarize --verify` before
publishing a figure. Use `kenshou compare` for the verdict; historical trends are
telemetry and do not replace a paired comparison.
