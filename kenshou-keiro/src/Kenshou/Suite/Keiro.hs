module Kenshou.Suite.Keiro (bundle) where

import Kenshou.Core.Bundle (LayerBundle (..))
import Kenshou.Core.Id (Layer (Keiro))
import Kenshou.Suite.Keiro.Command.Bench qualified as Bench
import Kenshou.Suite.Keiro.Command.Concurrency qualified as Concurrency
import Kenshou.Suite.Keiro.Command.Correctness qualified as Correctness
import Kenshou.Suite.Keiro.Command.Projection qualified as Projection
import Kenshou.Suite.Keiro.Fixture.Roles qualified as Roles
import Kenshou.Suite.Keiro.ProcessManager.Bench qualified as PMBench
import Kenshou.Suite.Keiro.ProcessManager.Concurrency qualified as PMConcurrency
import Kenshou.Suite.Keiro.ProcessManager.Correctness qualified as PMCorrectness
import Kenshou.Suite.Keiro.Router.Bench qualified as RouterBench
import Kenshou.Suite.Keiro.Router.Concurrency qualified as RouterConcurrency
import Kenshou.Suite.Keiro.Router.Correctness qualified as RouterCorrectness

bundle :: LayerBundle
bundle = LayerBundle Keiro (Correctness.scenarios <> Concurrency.scenarios <> Bench.scenarios <> Projection.scenarios <> PMCorrectness.scenarios <> PMConcurrency.scenarios <> PMBench.scenarios <> RouterCorrectness.scenarios <> RouterConcurrency.scenarios <> RouterBench.scenarios) Roles.roles
