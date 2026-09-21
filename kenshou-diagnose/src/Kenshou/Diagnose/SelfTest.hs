module Kenshou.Diagnose.SelfTest (bundle) where

import Kenshou.Core.Bundle (LayerBundle (..))
import Kenshou.Core.Id (Layer (Selftest))
import Kenshou.Diagnose.SelfTest.Leak (leakingWorkerScenario, stableWorkerScenario)
import Kenshou.Diagnose.SelfTest.Stall

bundle :: LayerBundle
bundle =
  LayerBundle
    Selftest
    [ leakingWorkerScenario,
      stableWorkerScenario,
      deadlockedWorkersScenario,
      poolStarvedScenario,
      lockWaiterScenario,
      idleSpinnerScenario,
      healthyProgressScenario
    ]
    []
