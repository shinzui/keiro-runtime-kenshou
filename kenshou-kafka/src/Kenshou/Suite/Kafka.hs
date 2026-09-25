module Kenshou.Suite.Kafka (bundle) where

import Kenshou.Core.Bundle (LayerBundle (..))
import Kenshou.Core.Id (Layer (Kafka))
import Kenshou.Suite.Kafka.Concurrency.AutoOffsetStore qualified as AutoOffsetStore
import Kenshou.Suite.Kafka.Concurrency.Fencing qualified as Fencing
import Kenshou.Suite.Kafka.Concurrency.NonSerial qualified as NonSerial
import Kenshou.Suite.Kafka.Concurrency.Sigkill qualified as Sigkill
import Kenshou.Suite.Kafka.Concurrency.StaticMembership qualified as StaticMembership
import Kenshou.Suite.Kafka.Correctness.Ack qualified as Ack
import Kenshou.Suite.Kafka.Correctness.Buffered qualified as Buffered
import Kenshou.Suite.Kafka.Correctness.DeadLetter qualified as DeadLetter
import Kenshou.Suite.Kafka.Correctness.Halt qualified as Halt
import Kenshou.Suite.Kafka.Correctness.MultiTopic qualified as MultiTopic
import Kenshou.Suite.Kafka.Correctness.Records qualified as Records
import Kenshou.Suite.Kafka.Correctness.Retry qualified as Retry
import Kenshou.Suite.Kafka.Fixture qualified as Fixture
import Kenshou.Suite.Kafka.Producer qualified as Producer
import Kenshou.Suite.Kafka.Producer.BatchFailure qualified as BatchFailure
import Kenshou.Suite.Kafka.Producer.Transactions qualified as Transactions
import Kenshou.Suite.Kafka.Roles qualified as Roles

bundle :: LayerBundle
bundle = LayerBundle Kafka (Fixture.scenarios <> Ack.scenarios <> Buffered.scenarios <> DeadLetter.scenarios <> Halt.scenarios <> MultiTopic.scenarios <> Records.scenarios <> Retry.scenarios <> NonSerial.scenarios <> Sigkill.scenarios <> AutoOffsetStore.scenarios <> StaticMembership.scenarios <> Fencing.scenarios <> Producer.scenarios <> BatchFailure.scenarios <> Transactions.scenarios) Roles.roles
