-- Registry metadata shared with the dedicated payload. The historical cohort
-- cannot implement the new APIs; a matched payload supplies the run function.
-- mori://shinzui/kiroku/plans/81-make-consumer-group-topology-durable-and-resize-without-gaps
module Kenshou.Suite.Kiroku.Bench.Hardening (scenario) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Kenshou.Core.Dimension
import Kenshou.Core.Env
import Kenshou.Core.Id (Kind (..), parseScenarioId)
import Kenshou.Core.Knob
import Kenshou.Core.Phase qualified as CorePhase
import Kenshou.Core.Scenario
import Kenshou.Measure.Knobs (measureKnobs)

name :: Text -> KnobName
name = either (error . show) id . mkKnobName

scenario :: Scenario
scenario =
  Scenario
    { id = either (error . show) id (parseScenarioId "kiroku/append/benchmark/subscription-hardening"),
      revision = 1,
      summary = "Compares durable writes with native and acknowledgement-coupled live subscriptions.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs =
        measureKnobs Benchmark
          <> [ intKnob "mp12.width" 1 1 4,
               intKnob "mp12.append-batch" 1 1 100,
               intKnob "mp12.checkpoint-batch" 1 1 100,
               intKnob "mp12.offered" 100 0 100000,
               intKnob "mp12.max-backlog" 100000 1 1000000,
               KnobSpec (name "mp12.fresh") "Fresh streams" KnobBool (VBool False) AnyValue [],
               KnobSpec
                 (name "mp12.mode")
                 "Subscription mode"
                 KnobText
                 (VText "group-category")
                 (OneOf (VText "none" :| map VText ["all", "category", "group-all", "group-category", "adapter"]))
                 []
             ],
      dimensions =
        DimensionSupport
          (Supported (Support (TracingOff :| []) TracingOff))
          (Supported (Support (MetricsOff :| []) MetricsOff))
          (Supported (Support (PgDurable :| []) PgDurable))
          (Supported (Support (Pg18 :| [Pg17]) Pg18)),
      phases = CorePhase.PhasePlan 30 61 30,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku] [("shared_preload_libraries", "'pg_stat_statements'")] False)},
      knownDefect = Nothing,
      run = \_ -> pure (infrastructureFailureBecause "requires the dedicated matched MP-12 cell payload")
    }
  where
    intKnob key value low high = KnobSpec (name key) key KnobInt (VInt value) (IntRange low high) []
