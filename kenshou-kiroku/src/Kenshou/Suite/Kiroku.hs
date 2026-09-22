module Kenshou.Suite.Kiroku (bundle) where

import Kenshou.Core.Bundle (LayerBundle (..))
import Kenshou.Core.Id (Layer (Kiroku))
import Kenshou.Suite.Kiroku.Correctness.Append qualified as Append

bundle :: LayerBundle
bundle = LayerBundle Kiroku Append.scenarios []
