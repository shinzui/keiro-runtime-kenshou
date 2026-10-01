# Four-hour inbox soak ends without a sealed nested result

Status: confirmed cell runner wall-clock timeout during finalization; finalization cost remains unattributed. No Keiro owner defect is inferred.

The clean released-cohort four-hour inbox soak on alpha was submitted as cell run `01a0f09f-4259-700c-b501-ceb1848f8ef3`, planned nested run `01a0f096-16cd-75a2-8371-d793177c4e8d`, using clean payload harness revision `c1f99a0e81749ff3123bbb249d997ab1a30c3c25`. Collection verified the sealed outer tree, whose effective outcome is `infrastructure-failure` with reason `runner-failed` and no entry exit code or signal.

The payload stderr reached measurement `done`; all eight business verdict files were written with `held` status at 2026-09-30T08:46:38.893000251Z. The tree contains samples, series, diagnosis, and the run specification, but no nested `run-result.json` or manifest. Those partial artifacts do not constitute a completed Kenshou run or baseline evidence. Cell health passed its host, storage, reset, and version gates over 04:43:01Z–08:48:21Z.

The submission allowed 14,700 seconds (four hours plus five minutes). The agent journal confirms `Finished with result: timeout`, termination by `15/TERM`, and `Service runtime: 4h 5min 27ms` at 08:48:21Z. The runner exhausted this budget after the business verdicts and before nested finalization completed. The runner source in `mori://shinzui/load-testing-infra`, project-relative path `nixos/pkgs/cell-agent/src/src/runner.rs` (artifact-level URI pending), sets `RuntimeMaxSec` from that budget and rejects a unit that stops without its entry-exit record. The journal also confirms `payload unit stopped without an entry exit record (exit status: 1)`. Memory peaked at 413.8 MiB and CPU consumption was 4m 6.3s across the unit lifetime; there is no recorded out-of-memory indication. This differs from finding 47's lease-loss interruption. Increase the bounded finalization allowance or reduce final diagnosis cost before repeating the full soak; do not count the partial verdicts as acceptance.

The fetched `diagnosis/leak.json` is zero bytes. The scenario writes its eight
business verdicts immediately before `judgeLeaksWithWindow`; that diagnosis
function opens the output file while encoding a lazy statistical report.
This narrows the unfinished stage to leak-report generation or its surrounding
finalization, without proving which computation consumed the remaining time.

An offline replay of the original sampled series with the same seed
`4252662818734786` and effective leak policy completed on the workstation in
300.06 seconds (273.50 seconds of user CPU, 3.82 seconds of system CPU).
The diagnosis and statistics sources are unchanged between the interrupted
payload and the replay. This shows the diagnosis is finite and can itself
cost minutes; it supports investigating finalization allowance and statistical
cost rather than claiming a runtime hang. Host and execution mode differ, so
this duration is not a Linux-cell performance estimate or proof of the exact
interrupted call. The [saved replay](../reports/data/2026-09-30-inbox-finalization-replay.txt)
classified all six bounded probes as Stable; its
[timing](../reports/data/2026-09-30-inbox-finalization-replay-timing.json)
is preserved separately. The replay writes outside the fetched tree and
supplies no replacement nested result or full-soak acceptance.

The journal excerpt is:

```text
2026-09-30 08:48:21 UTC: Finished with result: timeout
Main processes terminated with: code=killed, status=15/TERM
Service runtime: 4h 5min 27ms
payload unit stopped without an entry exit record (exit status: 1)
```

The outer manifest is preserved at `gs://tan-nb-exp-cells-results/runs/01a0f09f-4259-700c-b501-ceb1848f8ef3/manifest.json`, SHA-256 `5e935ff4f19e61a6599f449ae88c7044edbcd1ede907f9ba9b96f79d09a891c7` (11,134 bytes). The local verified tree is `.dev/01a0f09f-4259-700c-b501-ceb1848f8ef3/tree`. The original attempt remains excluded; the successful fresh retry is recorded below.

The read-only replay uses the public diagnosis API directly because the CLI
requires a sealed `run-result.json`. No result is fabricated for that check:

```haskell
import Kenshou.Diagnose.Leak

main :: IO ()
main = do
  let policy = defaultLeakSpec {warmupCutSeconds = 0, minDurationSeconds = 10080, minPoints = 10, envelopeWindowSeconds = 30}
  report <- analyseSeriesDirectory ".dev/01a0f09f-4259-700c-b501-ceb1848f8ef3/tree/output/01a0f096-16cd-75a2-8371-d793177c4e8d" policy 4252662818734786
  print report
```

Save that script outside the fetched tree, then run
`nix develop -c cabal exec -- runghc -package=kenshou-diagnose SCRIPT.hs`.
The supplied policy matches `soakLeakSpec` for 14,400 seconds with forced GC off.

The client now adds ten minutes per soak to the existing shared five-minute
slice margin. One four-hour soak receives 15,300 seconds; two grouped four-hour
soaks receive 30,300 seconds. Non-soak limits and scenario business deadlines
are unchanged. The 107-example remote suite includes full-duration, grouped,
benchmark, and overflow checks. This is a bounded budget mitigation; a fresh
full-duration cell run must still seal and verify before acceptance.


On 2026-10-01 UTC the fresh same-seed retry sealed and verified as cell
`01a0f4f5-7e09-7358-ac15-b2ac2128e990`, [digest-linked nested
run](../verification/runs/keiro/2026/10/01a0f4f4-7b1a-7232-b0ab-f62d19abb0aa.md).
It used clean released payload `9c2c9b8`, unchanged inbox revision 2 business
settings, seed `4252662818734786`, and the bounded 15,300-second cap. All eight
business checks held over 28,821 fresh deliveries and 57,642 effects; all six
bounded resource probes were stable. The full inbox execution gate is now
satisfied. This validates the bounded budget mitigation without retroactively
accepting the first attempt or attributing its exact finalization cost.
Independent Keiro VC-1 verification remains unavailable.
