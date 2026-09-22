module Kenshou.Suite.Kiroku (bundle) where

import Kenshou.Core.Bundle (LayerBundle (..))
import Kenshou.Core.Id (Layer (Kiroku))
import Kenshou.Suite.Kiroku.Correctness.Append qualified as Append
import Kenshou.Suite.Kiroku.Correctness.Lifecycle qualified as Lifecycle
import Kenshou.Suite.Kiroku.Correctness.Read qualified as Read
import Kenshou.Suite.Kiroku.Correctness.Transaction qualified as Transaction

bundle :: LayerBundle
bundle = LayerBundle Kiroku (Append.scenarios <> Read.scenarios <> Lifecycle.scenarios <> Transaction.scenarios) []
