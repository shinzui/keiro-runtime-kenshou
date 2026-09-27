module Kenshou.Suite.Shibuya (bundle) where

import Kenshou.Core.Bundle (LayerBundle (..))
import Kenshou.Core.Id (Layer (Shibuya))
import Kenshou.Suite.Shibuya.Bench.BatchSizeTimeout qualified as BatchSizeTimeout
import Kenshou.Suite.Shibuya.Bench.ConcurrencySweep qualified as ConcurrencySweep
import Kenshou.Suite.Shibuya.Bench.FrameworkTax qualified as FrameworkTax
import Kenshou.Suite.Shibuya.Bench.PgmqEndToEnd qualified as PgmqEndToEnd
import Kenshou.Suite.Shibuya.Concurrency.CoreBatch qualified as ConcurrentCoreBatch
import Kenshou.Suite.Shibuya.Concurrency.CoreOrdering qualified as ConcurrentCoreOrdering
import Kenshou.Suite.Shibuya.Concurrency.CoreRunner qualified as ConcurrentCoreRunner
import Kenshou.Suite.Shibuya.Concurrency.KeyedModel qualified as KeyedModel
import Kenshou.Suite.Shibuya.Concurrency.KirokuGroupAcquisition qualified as KirokuGroupAcquisition
import Kenshou.Suite.Shibuya.Concurrency.KirokuOutage qualified as KirokuOutage
import Kenshou.Suite.Shibuya.Concurrency.KirokuRetryRestart qualified as KirokuRetryRestart
import Kenshou.Suite.Shibuya.Concurrency.KirokuSigkillReplay qualified as KirokuSigkillReplay
import Kenshou.Suite.Shibuya.Concurrency.KirokuStaticGroup qualified as KirokuStaticGroup
import Kenshou.Suite.Shibuya.Concurrency.KirokuTwoOwners qualified as KirokuTwoOwners
import Kenshou.Suite.Shibuya.Correctness.CoreBatch qualified as CoreBatch
import Kenshou.Suite.Shibuya.Correctness.CoreOrdering qualified as CoreOrdering
import Kenshou.Suite.Shibuya.Correctness.CoreRunner qualified as CoreRunner
import Kenshou.Suite.Shibuya.Correctness.KirokuAckMapping qualified as KirokuAckMapping
import Kenshou.Suite.Shibuya.Correctness.KirokuDepth qualified as KirokuDepth
import Kenshou.Suite.Shibuya.Correctness.KirokuReplay qualified as KirokuReplay
import Kenshou.Suite.Shibuya.Correctness.KirokuTrace qualified as KirokuTrace
import Kenshou.Suite.Shibuya.Correctness.Metrics qualified as Metrics
import Kenshou.Suite.Shibuya.Correctness.PgmqAdapter qualified as PgmqAdapter
import Kenshou.Suite.Shibuya.Correctness.PgmqTrace qualified as PgmqTrace
import Kenshou.Suite.Shibuya.Roles qualified as Roles

bundle :: LayerBundle
bundle = LayerBundle Shibuya (CoreRunner.scenarios <> ConcurrentCoreRunner.scenarios <> [FrameworkTax.scenario, ConcurrencySweep.scenario, BatchSizeTimeout.scenario, PgmqEndToEnd.scenario] <> CoreOrdering.scenarios <> ConcurrentCoreOrdering.scenarios <> [KeyedModel.scenario] <> ConcurrentCoreBatch.scenarios <> CoreBatch.scenarios <> Metrics.scenarios <> PgmqAdapter.scenarios <> [PgmqTrace.scenario, KirokuAckMapping.scenario, KirokuDepth.scenario, KirokuReplay.scenario, KirokuTrace.scenario, KirokuTwoOwners.scenario, KirokuRetryRestart.scenario, KirokuStaticGroup.scenario, KirokuGroupAcquisition.scenario, KirokuOutage.scenario, KirokuSigkillReplay.scenario]) Roles.roles
