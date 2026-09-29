# Kenshou reuses an expired GCS CLI token during long cell sessions

Status: reproduced and fixed in this repository's cell client. The focused GCS checks and the full 104-example remote-client suite pass. No runtime-owner bug report is warranted.

The revision-2 PGMQ layer-ladder five-pair A/A session at `.dev/pair-aa-pgmq-layer-ladder-r2-5/round-0/session.json` verified seven cold-reset slices before `cell pair` failed while reading GCS metadata with HTTP 401. A new process could immediately read GCS using the active `gcloud` account. The original process had cached its CLI access token for 45 minutes from its first use, without knowing that token's actual remaining lifetime. This is the likely cause of the mid-session failure; a controlled mock-server test reproduces the stale-token/401 sequence without a live credential.

`cell resume` reconciled and verified all ten planned slices under a new lease, but the eighth sealed `cancelled` and has no entry exit code. The entire paired comparison is excluded from benchmark acceptance; it must be repeated under one lease after the client repair. No runtime performance conclusion follows from this interruption. The cell session journal and sealed result trees are retained as recovery and diagnostic evidence.

The client now invalidates its cached CLI token and retries an HTTP 401 once, including metadata operations, downloads, and resumable upload chunks. The focused test rotates a mock CLI token after the first 401 and checks that subsequent calls reuse the refreshed token. `cabal test -j1 kenshou-remote:test:kenshou-remote-test` passed all 104 examples on 2026-09-29. A fresh cell rerun remains required in EP-17 and EP-8.
