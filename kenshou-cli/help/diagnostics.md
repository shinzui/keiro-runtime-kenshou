# Diagnostics

Re-evaluate the sampled series from a completed run without changing its sealed
artifacts:

    kenshou diagnose leak RUN_DIR

Render saved watchdog captures, rebuild their classification, or export the
PostgreSQL wait graph as Graphviz DOT:

    kenshou diagnose stall RUN_DIR
    kenshou diagnose stall RUN_DIR --reclassify --dot wait-graph.dot

Rerun a scenario under a bounded heap profile or GHC event log:

    kenshou diagnose profile SCENARIO --mode closure-type
    kenshou diagnose profile SCENARIO --mode info-table
    kenshou diagnose profile SCENARIO --mode eventlog --classes gu

Diagnosis uses the ordinary process exit contract: 0 means no finding, 1 means
a finding was confirmed, 2 is invalid usage, 3 means insufficient evidence, and
4 is an input, execution, or infrastructure error. See
`docs/guides/diagnosing-leaks-and-stalls.md` in the source distribution for the
full investigation workflow.
