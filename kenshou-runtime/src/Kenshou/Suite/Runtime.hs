module Kenshou.Suite.Runtime (bundle) where

import Kenshou.Core.Bundle (LayerBundle (..))
import Kenshou.Core.Id (Layer (Runtime))
import Kenshou.Suite.Runtime.Concurrency.Broker qualified as Broker
import Kenshou.Suite.Runtime.Concurrency.Network qualified as Network
import Kenshou.Suite.Runtime.Concurrency.Postgres qualified as Postgres
import Kenshou.Suite.Runtime.Concurrency.Workers qualified as Workers
import Kenshou.Suite.Runtime.Correctness.Ops qualified as Ops
import Kenshou.Suite.Runtime.Correctness.OrderFlow qualified as OrderFlow
import Kenshou.Suite.Runtime.Correctness.Telemetry qualified as Telemetry
import Kenshou.Suite.Runtime.Correctness.WireRoundtrip qualified as WireRoundtrip
import Kenshou.Suite.Runtime.Roles qualified as Roles

bundle :: LayerBundle
bundle = LayerBundle Runtime (WireRoundtrip.scenarios <> OrderFlow.scenarios <> Ops.scenarios <> Telemetry.scenarios <> Workers.scenarios <> Postgres.scenarios <> Broker.scenarios <> Network.scenarios) Roles.roles
