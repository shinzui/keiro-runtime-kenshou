# Comparing benchmark runs

`kenshou compare` evaluates paired baseline and candidate runs. Run both arms in
the same environment and interleave them in ABBA or BAAB order so drift affects
each arm equally. Supply one `--baseline` and one `--candidate` directory per
pair.

The declared `--vary` axes are the only compatibility fields allowed to differ.
Use `cohort`, `dim:NAME`, or `knob:NAME`. A scenario, knob, dimension, schema, or
cohort difference outside those axes is a usage error. A machine-profile change
is an infrastructure failure.

Policies combine a relative limit with an absolute floor. A metric regresses
only when the confidence interval clears both limits. Wide or crossing intervals
are inconclusive. Hard health observations produce infrastructure failure and
soft observations produce an inconclusive result. Historical series can inform
future work, but they never determine a comparison verdict.

`kenshou summarize RUN_DIR --verify` recomputes measurements from retained
samples and series and checks the section stored in `run-result.json`.
