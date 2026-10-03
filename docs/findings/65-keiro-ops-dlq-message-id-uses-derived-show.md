# keiro-ops renders DLQ message ids with a derived Show

Status: reproduced on the released cohort (keiro-ops 0.17.0.0, pgmq-core
0.6.1.0) and still present in the keiro source at `82988ae6` (keiro-ops
0.19.0.0). Classified as an implementation-class observation about the
operator console's JSON surface. No owner record has been filed yet.

`keiro-ops --json pgmq dlq read --queue <q>` is part of the automation
surface that keiro's operations guide (`docs/user/operations.md` in
`mori://shinzui/keiro`) documents as stable. Its JSON gives each entry's
identifier as `"dlq_message_id": "MessageId {unMessageId = 1}"`. The value is
produced by `showText entry.dlqMessageId` in `keiro-ops/src/Keiro/Ops/Pgmq.hs`,
and pgmq-core's `MessageId` is a record newtype with a derived stock `Show`
(`pgmq-core/src/Pgmq/Types.hs` in `mori://shinzui/pgmq-hs`). Other identifiers
in the same entry, such as `original_message_id`, are plain JSON numbers. To use
the identifier, for example as the `--entry` argument of `pgmq dlq archive`,
an automation client must know the Haskell rendering of a type it never sees.

Evidence: `runtime/ops/correctness/keiro-ops-cross-check` keeps every console
output under `diagnosis/`. Clean local runs
`01a102da-b8e3-75b6-ad77-27cfd68f3acb` and
`01a102dc-cee5-7044-8331-978248c9f14f` (functional evidence on a shared
workstation) recorded the rendering in
`diagnosis/keiro-ops-12-warehouse-pgmq-dlq-read.json`. Their
`ops-json-machine-shaped` verdict is `violated`. That verdict is
implementation-class, so it does not change the outcome. I8 accepts the
rendering by parsing it, and it still compares the identifier set with
`pgmq.q_pick_dlq` exactly.

Disposition needed: an improvement request or bug report in the keiro corpus
that asks for `dlq_message_id` to be rendered as a number, or a documented
decision that the rendering is intended. The cross-check's parser accepts both
forms, so the scenario keeps working after a fix. Only the
implementation verdict changes, to `held`.
