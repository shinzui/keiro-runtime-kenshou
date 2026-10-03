# Kenshou payload relied on an ambient rpk on cells

Status: reproduced on cell `alpha` and repaired in source; the payload rebuild
and a cell rerun are pending. This is a harness packaging defect, not a Kafka
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
`redpanda-rpk-26.2.2/bin` in the wrapper. A payload rebuilt from the repair and
a rerun of the same plan on a broker-capable cell remain open.
