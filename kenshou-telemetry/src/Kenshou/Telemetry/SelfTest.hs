module Kenshou.Telemetry.SelfTest (selfTestBundle) where

import Kenshou.Core.Bundle (LayerBundle (..))
import Kenshou.Core.Id (Layer (Selftest))
import Kenshou.Core.Role (WorkerRole (..), mkRoleName)
import Kenshou.Telemetry.SelfTest.Arms (armsScenario)
import Kenshou.Telemetry.Sink (runSinkRole)

selfTestBundle :: LayerBundle
selfTestBundle = LayerBundle Selftest [armsScenario] [sinkRole]

sinkRole :: WorkerRole
sinkRole =
  WorkerRole
    { name = either (error . show) id (mkRoleName "selftest/telemetry-otlp-sink"),
      summary = "Receives and counts OTLP payloads for telemetry scenarios.",
      run = runSinkRole
    }
