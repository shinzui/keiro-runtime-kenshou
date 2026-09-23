module Kenshou.Suite.Keiro (bundle) where

import Kenshou.Core.Bundle (LayerBundle (..))
import Kenshou.Core.Id (Layer (Keiro))
import Kenshou.Suite.Keiro.Command.Concurrency qualified as Concurrency
import Kenshou.Suite.Keiro.Command.Correctness qualified as Correctness
import Kenshou.Suite.Keiro.ProcessManager.Correctness qualified as PMCorrectness

bundle :: LayerBundle
bundle = LayerBundle Keiro (Correctness.scenarios <> Concurrency.scenarios <> PMCorrectness.scenarios) []
