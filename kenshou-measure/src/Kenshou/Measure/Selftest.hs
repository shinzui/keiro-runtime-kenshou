module Kenshou.Measure.Selftest (bundle) where

import Kenshou.Core.Bundle (LayerBundle (..))
import Kenshou.Core.Id (Layer (Selftest))
import Kenshou.Measure.Selftest.SleepService (sleepServiceScenario)

bundle :: LayerBundle
bundle = LayerBundle Selftest [sleepServiceScenario] []
