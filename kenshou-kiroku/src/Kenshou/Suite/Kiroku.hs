module Kenshou.Suite.Kiroku (bundle) where

import Kenshou.Core.Bundle (LayerBundle (..))
import Kenshou.Core.Id (Layer (Kiroku))
import Kenshou.Suite.Kiroku.Bench.Append qualified as BenchAppend
import Kenshou.Suite.Kiroku.Bench.Ladder qualified as BenchLadder
import Kenshou.Suite.Kiroku.Bench.Read qualified as BenchRead
import Kenshou.Suite.Kiroku.Bench.Subscription qualified as BenchSubscription
import Kenshou.Suite.Kiroku.Bench.Transaction qualified as BenchTransaction
import Kenshou.Suite.Kiroku.Concurrency.Append qualified as ConcurrencyAppend
import Kenshou.Suite.Kiroku.Concurrency.ConsumerGroup qualified as ConcurrencyConsumerGroup
import Kenshou.Suite.Kiroku.Concurrency.Fault qualified as ConcurrencyFault
import Kenshou.Suite.Kiroku.Concurrency.KnownDefects qualified as KnownDefects
import Kenshou.Suite.Kiroku.Concurrency.Subscription qualified as ConcurrencySubscription
import Kenshou.Suite.Kiroku.Correctness.Append qualified as Append
import Kenshou.Suite.Kiroku.Correctness.ConsumerGroup qualified as ConsumerGroup
import Kenshou.Suite.Kiroku.Correctness.DeadLetter qualified as DeadLetter
import Kenshou.Suite.Kiroku.Correctness.Lifecycle qualified as Lifecycle
import Kenshou.Suite.Kiroku.Correctness.Metrics qualified as Metrics
import Kenshou.Suite.Kiroku.Correctness.Notifier qualified as Notifier
import Kenshou.Suite.Kiroku.Correctness.Otel qualified as Otel
import Kenshou.Suite.Kiroku.Correctness.Overflow qualified as Overflow
import Kenshou.Suite.Kiroku.Correctness.Read qualified as Read
import Kenshou.Suite.Kiroku.Correctness.Retention qualified as Retention
import Kenshou.Suite.Kiroku.Correctness.Subscription qualified as Subscription
import Kenshou.Suite.Kiroku.Correctness.Transaction qualified as Transaction
import Kenshou.Suite.Kiroku.Roles qualified as Roles

bundle :: LayerBundle
bundle = LayerBundle Kiroku (Append.scenarios <> Read.scenarios <> Lifecycle.scenarios <> Transaction.scenarios <> Subscription.scenarios <> Overflow.scenarios <> DeadLetter.scenarios <> Notifier.scenarios <> Retention.scenarios <> ConsumerGroup.scenarios <> Metrics.scenarios <> Otel.scenarios <> ConcurrencyAppend.scenarios <> ConcurrencyConsumerGroup.scenarios <> ConcurrencyFault.scenarios <> ConcurrencySubscription.scenarios <> KnownDefects.scenarios <> BenchAppend.scenarios <> BenchLadder.scenarios <> BenchRead.scenarios <> BenchSubscription.scenarios <> BenchTransaction.scenarios) Roles.roles
