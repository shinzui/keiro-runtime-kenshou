module Kenshou.Suite.Keiro (bundle) where

import Kenshou.Core.Bundle (LayerBundle (..))
import Kenshou.Core.Id (Layer (Keiro))
import Kenshou.Suite.Keiro.Command.Correctness qualified as Correctness

bundle :: LayerBundle
bundle = LayerBundle Keiro Correctness.scenarios []
