---
type: Architecture Decision Record
title: Keep Kafka brokers private to a run
description: Local Kafka verification uses a disposable run-owned Redpanda container; cells use their provisioned brokers, and the machine-global broker is never mutated.
timestamp: 2026-09-24T23:25:26Z
generated:
  by: process:codex
  at: "2026-09-24T23:25:26Z"
docId: ADR-17
status: Accepted
date: 2026-09-24
originatingPlan: docs/plans/11-cover-the-kafka-transport-edge-with-a-disposable-broker.md
---

# Keep Kafka brokers private to a run

## Context

The machine-global Kafka broker at `127.0.0.1:9092` is shared by several
projects. A broker outage, topic purge, or configuration change there would
affect unrelated work. Kafka transport scenarios need to kill and restart a
broker, inject network faults, and inspect owned topics and groups.

## Decision

Local runs start a private Redpanda container named for the run. The harness
allocates free host ports, publishes only its own listeners, and exposes
run-owned proxy lanes. It can kill and restart that same container and data.
The harness saves broker logs and removes the container and temporary work
directory when the run ends, except when the run explicitly keeps data for
investigation. A later run sweeps only abandoned containers bearing the
harness's name and dead-process marker.

On a provisioned cell the harness uses the broker address supplied in the
run specification. All topic and group names have a run prefix, and cleanup
removes only names with that prefix. The run specification rejects the shared
loopback broker address, with no override. Every `rpk` invocation uses an
explicit broker address and a private configuration file.

## Consequences

- Broker crash and restart evidence can be gathered without interrupting
  other projects.
- A local run needs Apple Container on macOS or Docker on Linux and the
  pinned Redpanda image.
- A retained private container needs explicit cleanup after investigation.
