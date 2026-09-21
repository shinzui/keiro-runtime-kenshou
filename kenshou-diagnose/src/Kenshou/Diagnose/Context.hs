module Kenshou.Diagnose.Context
  ( runDirectory,
    runIdentity,
    runSeed,
    scenarioKind,
    steadyWindow,
    publishDiagnosis,
    logWarn,
  )
where

import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Word (Word64)
import Kenshou.Core.Context qualified as Core
import Kenshou.Core.Id (Kind, ScenarioId (..), renderRunId, renderScenarioId, unSeed)
import Kenshou.Core.Log (Severity (Warning))
import Kenshou.Core.Phase (PhasePlan (..))

runDirectory :: Core.RunContext -> FilePath
runDirectory context = context.outDir

runIdentity :: Core.RunContext -> (Text, Text)
runIdentity context = (renderRunId context.runId, renderScenarioId context.scenario)

runSeed :: Core.RunContext -> Word64
runSeed context = unSeed context.seed

scenarioKind :: Core.RunContext -> Kind
scenarioKind context = context.scenario.kind

steadyWindow :: Core.RunContext -> IO (Maybe (Double, Double))
steadyWindow context =
  let start = context.phases.warmUpSeconds
      end = start + context.phases.steadySeconds
   in pure (if end > start then Just (start, end) else Nothing)

publishDiagnosis :: Core.RunContext -> Text -> Aeson.Value -> IO ()
publishDiagnosis context = Core.putSummary context Core.Diagnosis

logWarn :: Core.RunContext -> Text -> IO ()
logWarn context = Core.observe context "kenshou-diagnose" Warning
