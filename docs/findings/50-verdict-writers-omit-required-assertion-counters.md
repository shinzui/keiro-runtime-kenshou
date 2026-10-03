# Verdict writers omit required assertion counters

Status: fixed in source; historical sealed artifacts remain schema-invalid.
Owner: this repository's verdict producers and emission boundary. This is not
an upstream runtime defect and does not add an owner bug report.

The completed four-hour outbox run
`01a0f938-67a3-7207-a457-fcccd988b600`, cell
`01a0f938-eef5-7567-9383-ca0e059e5b85`, sealed on clean released payload
`16ec2d667894996149149fd235fb7f6791818cf0`. Its spec, result and manifest pass
schema validation and all 27 nested artifact hashes/sizes match. All eight
business verdicts report held, but every verdict's `counts` contains only
`events: 1`. The version-one [verdict schema](../../schemas/kenshou.verdict.v1.schema.json)
also requires `examined` and `violations`, so these eight documents fail schema
validation. Digest verification and a sealed cell tree do not establish this
separate protocol requirement.

The source was `recordCells` in
[Kenshou.Suite.Keiro.Command.Correctness](../../kenshou-keiro/src/Kenshou/Suite/Keiro/Command/Correctness.hs).
All three messaging soak families and many command checks use it. A direct,
database-free invocation with one held and one violated assertion reproduces
the omission in both outputs. A producer audit found the same omission in the
Kiroku shared cell writer and OCC counterexample, the Keiro shard/timer/workflow
writers, and the core property-model verdict's missing `examined` count.

Reproduce the sealed outbox failure from the repository root after collecting
the session with `kenshou cell resume --session cell-runs/ep13-outbox-full-default`:

```bash
nix develop -c check-jsonschema \
  --schemafile schemas/kenshou.verdict.v1.schema.json \
  cell-runs/01a0f938-eef5-7567-9383-ca0e059e5b85/tree/output/01a0f938-67a3-7207-a457-fcccd988b600/verdicts/keiro-fixture-no-loss.json
```

The repair supplies one examined assertion and zero/one violations for Boolean
cells, preserves their existing domain counters, and uses executed-case counts
for model verdicts. `writeVerdict` now rejects a document before writing if
either required counter is absent. Regression tests cover held/violated shared
checks and both missing-field cases, including absence of partial output.
The minimal shared-writer probe covers Keiro, Kiroku, timer, shard and workflow
writers independently of database behavior.

The change preserves outcomes, failure labels and statistical policies. It
does not backfill immutable raw files or make old runs schema-valid. The
[digest-linked full outbox investigation](../verification/runs/keiro/2026/10/01a0f938-67a3-7207-a457-fcccd988b600.md)
remains available with its inconclusive resource outcome and this artifact
qualification. Earlier inbox soaks using the writer have the same limitation.
The queue/DLQ full soak submitted as cell
`01a0fa4d-f1ea-74ed-9b07-a298ee957541` sealed and is now
[digest-linked](../verification/runs/keiro/2026/10/01a0fa29-a590-7007-81bb-7a26c7ba5cd4.md).
All 28 nested artifact checks and three top-level schemas pass, but all nine
held verdicts fail the same missing-counter requirement. Its inconclusive
heap/resource outcome and this artifact qualification remain explicit.
The repaired-payload [full inbox rerun](../verification/runs/keiro/2026/10/01a0fa97-bbd6-76a5-a7c0-03c6aa076562.md)
passes all 11 schemas, including eight verdict documents with required
assertion counters, and all 27 artifact checks. Inbox full-soak artifact
acceptance is closed. The repaired [full queue GC diagnostic](../verification/runs/keiro/2026/10/01a0fd67-a9cb-7001-9322-69251c14d682.md)
also passes all twelve schemas and 29 artifact checks, closing the queue
artifact gap. The repaired [four-hour outbox GC diagnostic](../verification/runs/keiro/2026/10/01a0fdea-68ff-704b-bc96-176ee5235120.md)
passes all eleven schemas and 28 artifact checks, closing the last repaired
full-soak artifact gap. Historical sealed artifacts retain their qualification.

Validation: the Keiro regression failed before the production change and passed
afterward. All 49 Keiro and 35 core check examples pass. All ten held/violated
shared-writer probe documents pass the verdict schema with exact assertion
counts. The full `nix develop -c just verify` gate passes, including the model
counterexample self-test, all 40 CLI examples, and strict validation of the
160-concept evidence bundle. Existing sealed artifacts were not rewritten.
