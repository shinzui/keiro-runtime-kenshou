module Kenshou.Measure.Load.Types
  ( Operation (..),
    Arrival (..),
    ClosedConfig (..),
    OverloadConfig (..),
    OpenConfig (..),
    LoadModel (..),
    OverloadEvidence (..),
    LoadReport (..),
    emptyLoadReport,
  )
where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.Word (Word64)
import Kenshou.Measure.Recorder (OpName, OpResult)

data Operation = Operation
  { name :: OpName,
    run :: Int -> Word64 -> IO OpResult
  }

data Arrival = ConstantRate !Double | PoissonRate !Double
  deriving stock (Eq, Show)

data ClosedConfig = ClosedConfig
  { workers :: !Int,
    thinkTimeNs :: !Word64,
    staggerNs :: !Word64
  }
  deriving stock (Eq, Show)

data OverloadConfig = OverloadConfig
  { maxLagNs :: !Word64,
    sustainedIntervals :: !Int,
    abortLagNs :: !Word64
  }
  deriving stock (Eq, Show)

data OpenConfig = OpenConfig
  { arrival :: !Arrival,
    executors :: !Int,
    rampFrom :: !Double,
    overload :: !OverloadConfig
  }
  deriving stock (Eq, Show)

data LoadModel = ClosedLoop !ClosedConfig | OpenLoop !OpenConfig
  deriving stock (Eq, Show)

data OverloadEvidence = OverloadEvidence
  { thresholdNs :: !Word64,
    observedLagNs :: !Word64
  }
  deriving stock (Eq, Show)

data LoadReport = LoadReport
  { model :: !LoadModel,
    offered :: !Word64,
    started :: !Word64,
    completed :: !Word64,
    failed :: !Word64,
    maxLagNs :: !Word64,
    overloaded :: !(Maybe OverloadEvidence),
    abortedEarly :: !Bool
  }
  deriving stock (Eq, Show)

emptyLoadReport :: LoadModel -> LoadReport
emptyLoadReport model = LoadReport model 0 0 0 0 0 Nothing False

instance ToJSON OverloadEvidence where
  toJSON value = object ["thresholdNs" .= value.thresholdNs, "observedLagNs" .= value.observedLagNs]

instance ToJSON LoadReport where
  toJSON report =
    object
      [ "model" .= modelName report.model,
        "offered" .= report.offered,
        "started" .= report.started,
        "completed" .= report.completed,
        "failed" .= report.failed,
        "maxLagNs" .= report.maxLagNs,
        "overloaded" .= report.overloaded,
        "abortedEarly" .= report.abortedEarly
      ]
    where
      modelName (ClosedLoop _) = "closed" :: String
      modelName (OpenLoop config) = case config.arrival of ConstantRate _ -> "open-constant"; PoissonRate _ -> "open-poisson"
