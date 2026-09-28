# Historical Kiroku group acquisition can strand members

Status: reproduced on `shibuya-kiroku-adapter` 0.5.1.2 and fixed on published 0.5.1.3. Owner report: `mori://shinzui/kiroku/okf/bug-reports/concepts/BUG-4`.

The `shibuya/kiroku-adapter/concurrency/group-acquisition-failure-strands-nothing` scenario probes 200 cancellation boundaries and a later factory error with a throwing cleanup, then tests real eight-member groups on PostgreSQL 17 and 18. Historical revision-two runs `runs/01a0df01-114c-73b4-9432-80f8615690e8/run-result.json` and `runs/01a0e426-4b9d-7703-9826-083204494700/run-result.json` reproduce `REV-13-F1`: only one release runs, the primary construction exception is replaced, and subscription threads remain above baseline. Seven group SQL reads per arm stayed flat over 35 seconds, but a leaked worker may remain blocked on the seeded event; the thread, release and exception checks establish the defect.

The published 0.5.1.3 adapter passes the same revision on PostgreSQL 18 and 17 in `runs/01a0defd-fd74-740c-a48b-06a18c690658/run-result.json` and `runs/01a0e42a-5b2e-76c0-aa59-8cc80dd6ae40/run-result.json`. Its masked ownership ledger records each acquired member before another interruptible step, attempts every release, and preserves the primary error. These run paths are local to this repository.

Clean released PostgreSQL 18 run `runs/01a0e55d-02ea-77e4-909c-f9163be0cdb5/run-result.json` at harness revision `9297d59` reproduced only the scoped cleanup labels under owner BUG-4. It is nonblocking, and its run-result schema validated.
