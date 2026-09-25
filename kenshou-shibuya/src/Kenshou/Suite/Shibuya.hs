module Kenshou.Suite.Shibuya (bundle) where

import Kenshou.Core.Bundle (LayerBundle (..))
import Kenshou.Core.Id (Layer (Shibuya))
import Kenshou.Suite.Shibuya.Concurrency.CoreBatch qualified as ConcurrentCoreBatch
import Kenshou.Suite.Shibuya.Concurrency.CoreOrdering qualified as ConcurrentCoreOrdering
import Kenshou.Suite.Shibuya.Concurrency.CoreRunner qualified as ConcurrentCoreRunner
import Kenshou.Suite.Shibuya.Correctness.CoreBatch qualified as CoreBatch
import Kenshou.Suite.Shibuya.Correctness.CoreOrdering qualified as CoreOrdering
import Kenshou.Suite.Shibuya.Correctness.CoreRunner qualified as CoreRunner
import Kenshou.Suite.Shibuya.Correctness.Metrics qualified as Metrics

bundle :: LayerBundle
bundle = LayerBundle Shibuya (CoreRunner.scenarios <> ConcurrentCoreRunner.scenarios <> CoreOrdering.scenarios <> ConcurrentCoreOrdering.scenarios <> ConcurrentCoreBatch.scenarios <> CoreBatch.scenarios <> Metrics.scenarios) []
