# Two Kiroku adapter processes sharing a member repeat handler work

Status: reproduced with `mori://shinzui/kiroku/packages/shibuya-kiroku-adapter` 0.5.1.2 and 0.5.1.3 on PostgreSQL 17 and 18. This is an implementation cost of running two owners for one subscription member, not an event-loss defect.

`shibuya/kiroku-adapter/concurrency/two-processes-one-member` starts two separate worker processes with the same subscription name and member 0. Both report running before the parent appends 40 events. Each handler commits an effect row before returning `AckOk`. The parent samples `kiroku.subscriptions.last_seen`, checks every event position and ID in the SQL effect ledger, and verifies both workers exit cleanly.

The released PostgreSQL 18/17 runs are `runs/01a0de4e-a98f-7685-a754-7e2af923f04f/run-result.json` and `runs/01a0de4e-f36d-74b5-bf33-8b52ab8a9573/run-result.json`. The current-release PostgreSQL 18/17 runs are `runs/01a0de50-71be-7233-b052-0e758e894d38/run-result.json` and `runs/01a0de50-ae7c-73f4-9883-86755d8f160c/run-result.json`. All four have 40 distinct event positions, 80 effects, exactly 40 effects per process, no checkpoint regression, a final checkpoint of 40, and two successful worker exits.

The adapter constructs its subscription configuration without exposing Kiroku's `consumerGroupGuard` option. A service cannot request the store's startup ownership guard through this adapter. The recommended owner request is to expose that guard in `KirokuAdapterConfig`, so a second process can be rejected when exclusive member ownership is desired. The current suite reports the duplicate factor and keeps no-loss and checkpoint progress as blocking checks; it does not classify this documented at-least-once behavior as a bug.
