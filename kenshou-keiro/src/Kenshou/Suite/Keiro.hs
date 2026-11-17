module Kenshou.Suite.Keiro (bundle) where

import Kenshou.Check.Oracle (OracleQuery (..))
import Kenshou.Check.Oracle.Keiro qualified as Oracle
import Kenshou.Core.Bundle (LayerBundle (..), mkBundle)
import Kenshou.Core.Contribution (OracleSpec (..), PoolMethodology (..))
import Kenshou.Core.Id (mkLayerId)
import Kenshou.Suite.Keiro.Command.Bench qualified as Bench
import Kenshou.Suite.Keiro.Command.Concurrency qualified as Concurrency
import Kenshou.Suite.Keiro.Command.Correctness qualified as Correctness
import Kenshou.Suite.Keiro.Command.Projection qualified as Projection
import Kenshou.Suite.Keiro.Command.Soak qualified as Soak
import Kenshou.Suite.Keiro.Command.SteadyState qualified as SteadyState
import Kenshou.Suite.Keiro.Fixture.Roles qualified as Roles
import Kenshou.Suite.Keiro.Inbox qualified as Inbox
import Kenshou.Suite.Keiro.Outbox qualified as Outbox
import Kenshou.Suite.Keiro.ProcessManager.Bench qualified as PMBench
import Kenshou.Suite.Keiro.ProcessManager.Concurrency qualified as PMConcurrency
import Kenshou.Suite.Keiro.ProcessManager.Correctness qualified as PMCorrectness
import Kenshou.Suite.Keiro.Queue qualified as Queue
import Kenshou.Suite.Keiro.Router.Bench qualified as RouterBench
import Kenshou.Suite.Keiro.Router.Concurrency qualified as RouterConcurrency
import Kenshou.Suite.Keiro.Router.Correctness qualified as RouterCorrectness
import Kenshou.Suite.Keiro.Shard qualified as Shard
import Kenshou.Suite.Keiro.Telemetry qualified as KeiroTelemetry
import Kenshou.Suite.Keiro.Timer qualified as Timer
import Kenshou.Suite.Keiro.Workflow qualified as Workflow

bundle :: LayerBundle
bundle = (mkBundle (either (error . show) id (mkLayerId "keiro")) (Correctness.scenarios <> Concurrency.scenarios <> Bench.scenarios <> Soak.scenarios <> SteadyState.scenarios <> Projection.scenarios <> PMCorrectness.scenarios <> PMConcurrency.scenarios <> PMBench.scenarios <> RouterCorrectness.scenarios <> RouterConcurrency.scenarios <> RouterBench.scenarios <> KeiroTelemetry.scenarios <> Outbox.scenarios <> Inbox.scenarios <> Queue.scenarios <> Workflow.scenarios <> Timer.scenarios <> Shard.scenarios) (Roles.roles <> Outbox.roles <> Inbox.roles <> Queue.roles <> Workflow.roles <> Timer.roles <> Shard.roles)) {oracles = oracleSpecs, evidenceSubject = Just "mori://shinzui/keiro"}

oracleSpecs :: [OracleSpec]
oracleSpecs = OracleSpec Oracle.outboxNonTerminal.name Oracle.outboxNonTerminal.sql : [OracleSpec query.name query.sql | query <- [Oracle.inboxByStatus, Oracle.timersByStatus, Oracle.workflowLeases, Oracle.shardOwners, Oracle.deadLetters]]
