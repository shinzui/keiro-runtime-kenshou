module Kenshou.Suite.Runtime (bundle) where

import Kenshou.Core.Bundle (LayerBundle (..))
import Kenshou.Core.Id (Layer (Runtime))
import Kenshou.Suite.Runtime.Correctness.WireRoundtrip qualified as WireRoundtrip

bundle :: LayerBundle
bundle = LayerBundle Runtime WireRoundtrip.scenarios []
