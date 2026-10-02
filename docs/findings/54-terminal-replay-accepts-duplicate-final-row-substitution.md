# Terminal replay accepts a duplicated final-row substitution

Status: fixed and verified by mutation tests and captured-run replay.
Owner: this repository's independent outbox terminal recomputer.

At `06632b7`, replacing one exhausted final row with another exhausted row
still replayed all twelve terminal checks as passing. Both rows had four
attempts, so the replacement preserved row count, status totals, retry totals
and callback-count comparisons. The recomputer verified each observed identity
against an input, but did not require the final identity set to cover every
input exactly once.

The deterministic witness uses
`kenshou-cli/test/fixtures/outbox-terminal-best-effort.json`, seed
`4252662818734786`. `.dev/probe-terminal-final-duplicates.hs` preserves the
altered observation under `.dev/terminal-final-row-substitution.json`. On the
old implementation both the original and substituted fixture returned
`Right []`, meaning no failed checks. This is a mutation of captured data,
not a newly observed Keiro runtime failure or a sealed baseline run.

The repair requires the final-row identity set to equal the complete input
identity set, in addition to the existing exact row count and terminal status
checks. Four policy-specific regressions replace one exhausted row with another
and require `every-row-terminal` to fail. Valid captures retain their existing
scenario revision and artifact schema. Historical attestations preserve the
recomputer revision that actually produced them.

All eighteen terminal-focused CLI examples pass. The original witness now
returns `Right ["every-row-terminal"]`, while its unmodified fixture still
returns `Right []`. The corrected recomputer agrees with all 52 saved controls:
sixteen policy/backoff/key investigations, sixteen retry-budget investigations,
and twenty clean terminal runs. An additional identity audit finds no missing
or duplicate identifiers among the clean runs' 3,280 final rows. Those captures
need no correction; no Keiro runtime or upstream owner defect is claimed.
