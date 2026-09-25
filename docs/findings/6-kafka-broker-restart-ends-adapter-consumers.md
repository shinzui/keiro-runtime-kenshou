# Kafka adapter consumers exit after broker restart

Status: reproduced on the released cohort; filed as
`mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-3`.
The owner bug-report bundle passed strict OKF profile and log validation on
2026-09-25.

Two serial adapter workers and an open-loop producer used a private Redpanda
26.2.1 broker. In reduced run `01a0d624-2294-77c0-927d-a952855ed178`, the
producer received 1,000 successful delivery callbacks. After the broker was
killed and restarted, both workers exited normally before the harness sent
stop. They handled only 374 records and the group remained behind the log end
after the 30-second recovery deadline. The default run
`01a0d626-ef89-76cc-9e84-4dcedba62a6d` reproduced the two exits after a
20-second outage, with 15,000 acknowledged records and 401 original handler
facts. A reduced proxy-blackhole control
`01a0d626-2a64-713a-b162-03cc64417be8` passed with 1,000 acknowledged
and handled IDs and zero lag.

The later reduced kill run `01a0d62b-dd17-7101-819f-472923759969`
reproduced the early exits and then started replacement consumers as a
control. They reached zero lag and, together with the original workers,
handled every acknowledged ID. A prior reduced restart control reached zero
lag but still lacked nine handler facts; its separate
`outage-restart-control-no-loss` failure remains blocking and needs further
isolation. The BUG-3 known-defect scope covers only the repeated original
worker exits and their immediate no-loss and recovery failures on Hackage
adapter 0.9.0.1. It does not cover the separate restart-control failure or
unverified versions, including the newly published 0.9.1.0.

The first runs omitted the caller-installed `kafkaRebalanceHandler`. After
installing it and logging each rebalance callback, reduced kill run
`01a0d634-0897-71b4-8cfa-51b3c86e0bdb` still acknowledged all 1,000
records and both workers exited before stop. The original workers handled
380 records, and the group remained behind. This confirms the exit also
occurs with the intended callback installed. Its replacement-worker control
reached zero lag but lacked handler facts for some acknowledged IDs; that
separate result remains blocking.

Reproduce from this repository with:

```bash
cabal run kenshou -- run kafka/adapter/concurrency/broker-outage-and-reconnect --out runs
```

The sealed results and broker logs are under
`mori://shinzui/keiro-runtime-kenshou` at the run directories named above;
an artifact-level Mori URI for run directories is pending. The owner report
states the observed contract failure and leaves the exact source-level
termination path open.
