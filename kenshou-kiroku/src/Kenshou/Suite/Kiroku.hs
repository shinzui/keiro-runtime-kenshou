module Kenshou.Suite.Kiroku (bundle) where

import Kenshou.Core.Bundle (LayerBundle (..))
import Kenshou.Core.Id (Layer (Kiroku))
import Kenshou.Suite.Kiroku.Correctness.Append qualified as Append
import Kenshou.Suite.Kiroku.Correctness.ConsumerGroup qualified as ConsumerGroup
import Kenshou.Suite.Kiroku.Correctness.DeadLetter qualified as DeadLetter
import Kenshou.Suite.Kiroku.Correctness.Lifecycle qualified as Lifecycle
import Kenshou.Suite.Kiroku.Correctness.Notifier qualified as Notifier
import Kenshou.Suite.Kiroku.Correctness.Overflow qualified as Overflow
import Kenshou.Suite.Kiroku.Correctness.Read qualified as Read
import Kenshou.Suite.Kiroku.Correctness.Retention qualified as Retention
import Kenshou.Suite.Kiroku.Correctness.Subscription qualified as Subscription
import Kenshou.Suite.Kiroku.Correctness.Transaction qualified as Transaction

bundle :: LayerBundle
bundle = LayerBundle Kiroku (Append.scenarios <> Read.scenarios <> Lifecycle.scenarios <> Transaction.scenarios <> Subscription.scenarios <> Overflow.scenarios <> DeadLetter.scenarios <> Notifier.scenarios <> Retention.scenarios <> ConsumerGroup.scenarios) []
