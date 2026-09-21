module Kenshou.Core.Context
  ( RunContext (..),
    InfrastructureError (..),
  )
where

import Control.Exception (Exception)
import Data.Text (Text)
import Kenshou.Core.Dimension (Dimensions)
import Kenshou.Core.Id (RunId, ScenarioId, Seed)
import Kenshou.Core.Knob (ResolvedKnobs)
import Kenshou.Core.Phase (PhasePlan)

data RunContext = RunContext
  { runId :: RunId,
    scenario :: ScenarioId,
    knobs :: ResolvedKnobs,
    dimensions :: Dimensions,
    seed :: Seed,
    phases :: PhasePlan,
    outDir :: FilePath
  }

newtype InfrastructureError = InfrastructureError Text
  deriving stock (Eq, Show)

instance Exception InfrastructureError
