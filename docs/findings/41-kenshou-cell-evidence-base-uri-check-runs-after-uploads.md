# The cell evidence recorder validated its destination after publishing files

Status: reproduced and repaired in this repository's evidence publisher. This is a local harness defect; no runtime-owner report is warranted.

While recording clean Keiro outbox cell run `01a0eec4-bd55-7786-804f-bda62c6ac388`, the generic `gs://kenshou-evidence-tan-nb-exp/runs` base passed the ordinary URI check. The recorder uploaded the nested run files there, then rejected the base as `InvalidBaseUri` when it reached the cell manifest link. A cell run must instead use its existing sealed prefix `gs://tan-nb-exp-cells-results/runs/01a0eed0-4d26-7365-afb3-8a03d234d014/output`, with verify-only publication. No OKF record was created by the rejected attempt. The duplicate uploads under the generic evidence bucket prefix are unreferenced by the historical bundle.

The cell-specific suffix check now runs before the first object-store write. A focused memory-store test supplies a valid generic GCS URI for a cell source and verifies both `InvalidBaseUri` and the absence of any nested upload. The [evidence recording guide](../guides/recording-evidence.md) now shows the cell prefix and `--verify-only` command separately from ordinary local-run publication.
