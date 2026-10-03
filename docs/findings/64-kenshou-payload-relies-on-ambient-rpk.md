# Kenshou payload relied on an ambient rpk on cells

Status: reproduced on cell `alpha`, repaired in source, and verified on alpha
with a rebuilt payload. This is a harness packaging defect, not a Kafka
runtime-owner bug report.

The external-broker path runs `rpk` from `PATH`
(`Kenshou.Env.Kafka.Admin.runRpk`), but the Kenshou payload closure carried no
Redpanda client. Local runs use the development shell's `rpk` 26.2.2. On a
cell, the call reached the driver image's `rpk` 26.1.7, which rejects
`rpk group list --format json` with `unknown flag: --format`.

Evidence: released payload bundle
`d762e4e64d5bf71fe70b78cff823ec97f264d5965124e06a0c12379119374ec1`, built from
Kenshou `b9881d1`, ran the plan for
`kafka/adapter/concurrency/barrier-overwrite-loses-record` on alpha after the
plan 16 broker role was added. Cell run `01a10247-5864-74db-9978-1c73f6b232fe`
received a verified broker reset and sealed `completed` (manifest SHA-256
`ccb902b17373ae45e2607fc65d69d3463005393bcb788c542cddca3df8da77b1`). Its nested
run `01a10213-b750-723b-b7bc-b131783b7071` errored with exit code 4 before the
defect probe, so it supplies no evidence for
`mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-5`. See
[finding 40](40-kenshou-kafka-scenarios-omit-broker-requirement.md) for the
routing history of this plan.

Repair: `nix/kenshou/packages.nix` now prefixes the payload wrapper's `PATH`
with nixpkgs `redpanda-rpk` 26.2.2, allowing only that unfree package. The
`aarch64-darwin` and `x86_64-linux` payload derivations both evaluate with
`redpanda-rpk-26.2.2/bin` in the wrapper. The rebuilt payload and the rerun
are recorded below.

Verification (2026-10-03): released payload bundle
`4b12979164d319e0cba81b38600ba3166a0e4454883bc474b1f46e6fa970552a` (store path
`/nix/store/2fkzz7xpjh9hhgmk9yh2x24880d8d3kd-kenshou-released-default`) was
published from a clean worktree at Kenshou `705b9d5`. Its closure contains
`redpanda-rpk-26.2.2`, and its `bin/kenshou` wrapper prefixes `PATH` with that
package's `bin`. A fresh plan for the same scenario routed to alpha with no
refusal. Cell run `01a10261-8cbc-76a8-b9c8-24ff62aafa9a` (lease
`01a10261-86fc-7578-b570-df1f18138887`) received a verified cold broker reset,
passed all 20 health gates, and sealed `completed` with entry exit 0 and manifest
SHA-256 `9e073447bd07281422e414e7b20d4d3212101f012344761faed098feffedf2bf`.
Its nested run `01a10261-71cd-765f-a5da-23514e17523e` reached the defect probe
without an `rpk` error; see finding 40 for its BUG-5 result.
