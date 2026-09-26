# Verification evidence

`kenshou record RUN-DIR --data-base-uri gs://BUCKET/PREFIX --purpose release --project PROJECT` publishes a finished run's files and adds one record to the OKF verification bundle. The record names the run, cohort, outcome, and SHA-256-pinned object links. It contains no measurements; those remain in the linked run files.

The default bundle is `docs/verification`. `--bundle DIR` selects another bundle. A real GCS upload requires `--project PROJECT`, and the command checks that the active gcloud project matches it. `--verify-only` checks that all objects already exist; `--deep-verify` downloads them and checks their bytes. Failed or inconclusive runs link logs automatically; `--link-logs` also links logs for a passing run.

`--config PATH` reads ordered YAML configuration. The supported keys are `evidence.bundle-root`, `gcp.project`, and `evidence.data-base-uri`; the corresponding environment variables are `KENSHOU_EVIDENCE_BUNDLE`, `KENSHOU_GCP_PROJECT`, and `KENSHOU_EVIDENCE_DATA_BASE_URI`. Named flags take precedence over the environment and files. `kenshou evidence check` uses the same bundle default and configuration sources. Unknown keys are rejected.

A dirty harness requires `--allow-dirty` and is recorded with `purpose: investigation` regardless of the requested purpose. Use `--subject MORI-URI` with `--subject-kind project|package` when the default layer project is too broad. Repeat `--produced MORI-URI` for reports caused by this run.

For a local rehearsal, copy the verification bundle outside the repository and pass `--bundle COPY --store-root DIR`. The record still contains `gs://` URIs, while the bytes are stored under the scratch directory. The command refuses `--store-root` with a bundle inside this repository.

`--json` prints one `kenshou.record-result/v1` document and sends errors to standard error. A repeat with the same record content succeeds and reports `already recorded`; different content at the same record path is a conflict.

`kenshou evidence check` checks record paths, IDs, digest and revision shapes, textual fields, event-only keys, timestamps, required data links, and changes to committed records. `--base REF` limits the Git history span. The command exits 0 when clean, 1 for findings, and 4 when it cannot check. `--json` prints one `kenshou.evidence-check/v1` document.
