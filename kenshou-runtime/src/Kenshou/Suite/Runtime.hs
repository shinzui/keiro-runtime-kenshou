module Kenshou.Suite.Runtime (bundle) where

import Kenshou.Core.Bundle (LayerBundle (..))
import Kenshou.Core.Id (Layer (Runtime))
import Kenshou.Suite.Runtime.Correctness.OrderFlow qualified as OrderFlow
import Kenshou.Suite.Runtime.Correctness.WireRoundtrip qualified as WireRoundtrip
import Kenshou.Suite.Runtime.Roles qualified as Roles

bundle :: LayerBundle
bundle = LayerBundle Runtime (WireRoundtrip.scenarios <> OrderFlow.scenarios) Roles.roles
