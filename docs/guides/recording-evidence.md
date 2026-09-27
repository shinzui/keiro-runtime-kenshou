# Recording verification evidence

Record a run after Kenshou has sealed its output directory and you intend to keep
its result as a historical fact. Use `purpose: baseline` for a reference run,
`release` for a release decision, `nightly` for scheduled evidence, and
`investigation` for exploratory work. A dirty harness requires `--allow-dirty`;
the recorder then forces `investigation` regardless of the requested purpose.
Record both arms before recording a comparison of them. The run and comparison
records link to raw data; they contain no measured values.

Run these commands from the repository root inside `nix develop`. The active
`gcloud` project must match `--project`. Replace the run directory, comparison
file, and IDs with the artifacts you mean to preserve.

```bash
gcloud config get-value project
cabal run -v0 kenshou -- record out/RUN-ID \
  --data-base-uri gs://kenshou-evidence-tan-nb-exp/runs \
  --project tan-nb-exp --purpose baseline
cabal run -v0 kenshou -- attest RUN-ID --project tan-nb-exp
cabal run -v0 kenshou -- history --scenario LAYER/COMPONENT/KIND/NAME --json
```

For a comparison, first record its baseline and candidate runs, then use
`record --comparison out/comparison.json` with the same durable URI prefix,
project, and an explicit purpose. `attest` accepts either a run ID or the
comparison ID. It fetches the comparison and every arm, verifies linked bytes,
recomputes the saved measurements from the arm samples, and replays the paired
comparison under the saved policy. A comparison with fewer than the policy's
required pairs can still be faithfully attested as `inconclusive`.

`record` uploads each file with a create-only precondition. An identical repeat
reports `already recorded`; conflicting content at the same record path is an
error. Use `--verify-only` to require existing objects without uploading, and
`--deep-verify` to fetch and hash them. To rehearse locally, copy
`docs/verification` outside this repository and use `--bundle COPY --store-root
DIR`; the scratch store keeps the `gs://` URI shape without touching GCS.

## Reading a record

Open a file under `docs/verification/runs/<layer>/<year>/<month>/`. `runId`,
`scenario`, `kind`, `tier`, `purpose`, `outcome`, and the timestamps identify the
event. `harnessRevision` identifies the Kenshou commit. Each entry in
`components` gives a package, its canonical Mori project URI, version, source,
and a commit when the source is Git. `cohort` and `solverPlanHash` identify the
resolved dependency set. `environment`, `knobs`, `dimensions`, and `seed`
describe how the run was executed. `computations` names the versioned definitions
under `docs/verification/computations/`. New benchmark and soak records name
VC-2 only when the run saved a `kenshou.measurements/v1` summary; a soak that
produced diagnosis alone has no latency-summary computation to replay.

Each `data` entry has a durable URI, SHA-256 digest, media type, and byte count.
For example, fetch an object's bytes and compare their digest with the entry:

```bash
gcloud storage cat gs://kenshou-evidence-tan-nb-exp/runs/RUN-ID/run-result.json | shasum -a 256
```

The `manifest` link pins the complete sealed run directory, including files
that are not listed individually in the record. The `run-result` link contains
the measurements and diagnostic details. A comparison record's `comparison`
object names its ordered baseline and candidate run concepts, while its one
data link points to `comparison.json` with the policy, metric results, and
verdict. Follow the `run` link from a file under
`docs/verification/attestations/` to find its target. An attestation has six
named checks; `confirmed` means all passed, `refuted` means linked data
contradicted a claim, and `incomplete` means at least one claim could not be
established. Only a confirmed attestation adds a machine `verified` entry to
the target record. `kenshou history --confirmed-only` reads those events and
derives compatible baselines without changing the records.

## Human sign-off

A person may review the record, raw data, and attestation, then add their own
`verified` entry to the record's frontmatter and commit it under their own Git
identity:

```yaml
verified:
- by: human:reviewer-id
  at: 2026-09-27T13:35:02Z
```

Keep any existing `verified` entries in order. This is a manual sign-off,
distinct from `kenshou attest --accept-anomaly --authority human:ID --reason
TEXT`: that interactive command records a person's acceptance of an anomaly in
a new attestation but does not change the computed verdict or grant machine
confirmation. CI and noninteractive sessions cannot use it.

## When a gate is red

Run `just verify` for the repository gate. Its evidence recipes run strict OKF
profile and log validation, regenerate and compare indexes, exercise the
rejection fixtures, and run `kenshou evidence check`. Run `kenshou evidence
check --network --deep --project tan-nb-exp` separately when GCS credentials
are available. `record` and `attest` return 0 on success or confirmation, 1
for a contradicted claim, 2 for invalid input, 3 for an incomplete conclusion,
and 4 when the command cannot run. `--json` writes one result document to
standard output; diagnostics use standard error.

Read the named rule and file in a failing gate. Regenerate stale indexes with
`okf index docs/verification --write`. Restore a missing log entry with `okf
log add` for the relevant concept. For a committed record whose claim is wrong,
do not edit its content: retain it, add a refuting attestation when the bytes
disagree, and record a corrected run. A committed record may gain only ordered
`verified` entries. The exceptional override in
`docs/verification/.immutability-exceptions` requires an ADR amendment that
explains why a recorder defect made the historical file structurally invalid.

The durable bucket uses an unlocked five-year retention period and versioning.
Upload only intended evidence. Rehearsals belong in a scratch bundle and store.
