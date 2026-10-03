# Polling recovery reuses pre-fault completions after the final fault

Status: repaired and verified in revision 3; historical records remain qualified.
Owner: this repository's queue polling-fault scenario.

Revision 2 enqueues twenty jobs, waits for them to complete, then kills a
blocked polling backend, repeating five times. After the fifth kill it waits
for the same one hundred completions that were already present. It can report
processing resumed without admitting any work after the last interruption.
This weakens the recovery claim in historical passes; it does not invalidate
their observed backend kills, completed jobs or durable queue state.

Revision 3 admits a new twenty-job batch after every fault, including the last.
It seals each post-fault payload set, recovery time, lifecycle observations and
final SQL depth. Independent replay requires that every post-fault batch be
present within the recovery bound. The mutation test keeps complete final
coverage but substitutes the pre-fault warm-up set for the post-fault witness;
that capture must fail `processing-resumed`. Existing records are immutable
and retain their original scenario revision and evidence limitations.

This is a local suite defect. It neither repairs nor closes the separately
reported Keiro polling failure in finding 34 or the PGMQ classifier issue in
finding 10. Revision-3 captures report those runtime failures explicitly.

The full verification gate and six replay mutation examples pass. Independent
replay agrees with sixteen single-fault controls and three repeated-fault
controls, with 152 schema and 247 artifact integrity checks. Both supervision
strategies pass five ten-second postmaster interruptions with 120 completed
jobs each, including twenty new jobs after the fifth interruption. The default
backend-termination control stops after its first observed worker failure and
correctly fails fault-count, recovery and no-loss acceptance.
