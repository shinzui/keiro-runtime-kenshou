module Kenshou.Suite.Shibuya (bundle) where

import Kenshou.Core.Bundle (LayerBundle (..))
import Kenshou.Core.Id (Layer (Shibuya))
import Kenshou.Suite.Shibuya.Correctness.CoreRunner qualified as CoreRunner

bundle :: LayerBundle
bundle = LayerBundle Shibuya CoreRunner.scenarios []
