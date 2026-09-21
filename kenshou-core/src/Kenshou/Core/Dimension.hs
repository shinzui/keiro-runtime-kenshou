module Kenshou.Core.Dimension
  ( TracingArm (..),
    MetricsArm (..),
    PgDurability (..),
    PgVersion (..),
    DimensionName (..),
    Support (..),
    Supported (..),
    DimensionSupport (..),
    Dimensions (..),
    noDimensions,
    emptyDimensions,
  )
where

import Data.List.NonEmpty (NonEmpty)

data TracingArm = TracingOff | TracingNoop | TracingSdkInMemory | TracingSdkOtlp deriving stock (Eq, Ord, Show)

data MetricsArm = MetricsOff | MetricsCollect | MetricsServe | MetricsServeScraped deriving stock (Eq, Ord, Show)

data PgDurability = PgFsyncOff | PgDurable deriving stock (Eq, Ord, Show)

data PgVersion = Pg17 | Pg18 deriving stock (Eq, Ord, Show)

data DimensionName = DimTracing | DimMetrics | DimPgDurability | DimPgVersion deriving stock (Eq, Ord, Show)

data Support a = Support {values :: NonEmpty a, def :: a} deriving stock (Eq, Show)

data Supported a = NotApplicable | Supported (Support a) deriving stock (Eq, Show)

data DimensionSupport = DimensionSupport
  { tracing :: Supported TracingArm,
    metrics :: Supported MetricsArm,
    pgDurability :: Supported PgDurability,
    pgVersion :: Supported PgVersion
  }
  deriving stock (Eq, Show)

data Dimensions = Dimensions
  { tracing :: Maybe TracingArm,
    metrics :: Maybe MetricsArm,
    pgDurability :: Maybe PgDurability,
    pgVersion :: Maybe PgVersion
  }
  deriving stock (Eq, Show)

noDimensions :: DimensionSupport
noDimensions = DimensionSupport NotApplicable NotApplicable NotApplicable NotApplicable

emptyDimensions :: Dimensions
emptyDimensions = Dimensions Nothing Nothing Nothing Nothing
