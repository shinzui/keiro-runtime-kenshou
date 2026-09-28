# Historical PGMQ dead-letter retry can duplicate a copy

Status: reproduced on `shibuya-pgmq-adapter` 0.16.0.0 and fixed on published 0.16.1.0. Owner report: `mori://shinzui/shibuya-pgmq-adapter/okf/bug-reports/concepts/BUG-3`.

The `shibuya/pgmq-adapter/concurrency/dead-letter-move-is-atomic` scenario sends uniquely identified messages to a direct DLQ while backend termination and lost-commit-response faults disturb acknowledgement. Pinned historical 0.16.0.0 runs `runs/01a0ddb7-bdd1-7204-bd0f-756e7c698b12/run-result.json` and `runs/01a0ddbe-0d8f-74c9-b010-9478ea1edc9f/run-result.json` produced respectively two duplicate copies among 1,000 originals and nine among 10,000. No original ID was lost and the lost-commit-response arm passed. Another historical fault schedule did not reproduce duplicates, so fault timing matters.

The historical `v0.16.0.0` source sends a DLQ copy before deleting the source row in a transaction. Its retry can send a second copy after the first move committed. The 0.16.1.0 source deletes the source row first and sends only when that deletion claims it. Current PostgreSQL 18 and 17 runs `runs/01a0ddd5-f6cd-74fa-8a0c-e9412f4b6ba3/run-result.json` and `runs/01a0ddd6-4b62-779d-b81c-cf3f50bfcef5/run-result.json` passed with no duplicates. These run paths are local to this repository.
