module Kenshou.Telemetry.SelfTest (selfTestBundle) where

import Kenshou.Core.Bundle (LayerBundle (..))
import Kenshou.Core.Id (Layer (Selftest))
import Kenshou.Core.Role (WorkerRole (..), mkRoleName)
import Kenshou.Telemetry.Scrape (runScraperRole)
import Kenshou.Telemetry.SelfTest.Arms (armsScenario)
import Kenshou.Telemetry.SelfTest.Problems (slowExporterScenario, traceContinuityScenario)
import Kenshou.Telemetry.Sink (runSinkRole)

selfTestBundle :: LayerBundle
selfTestBundle = LayerBundle Selftest [armsScenario, traceContinuityScenario, slowExporterScenario] [sinkRole, scraperRole]

sinkRole :: WorkerRole
sinkRole =
  WorkerRole
    { name = either (error . show) id (mkRoleName "selftest/telemetry-otlp-sink"),
      summary = "Receives and counts OTLP payloads for telemetry scenarios.",
      run = runSinkRole
    }

scraperRole :: WorkerRole
scraperRole =
  WorkerRole
    { name = either (error . show) id (mkRoleName "selftest/telemetry-scraper"),
      summary = "Scrapes telemetry endpoints on a fixed schedule.",
      run = runScraperRole
    }
