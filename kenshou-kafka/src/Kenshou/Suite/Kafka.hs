module Kenshou.Suite.Kafka (bundle) where

import Kenshou.Core.Bundle (LayerBundle (..))
import Kenshou.Core.Id (Layer (Kafka))
import Kenshou.Suite.Kafka.Correctness.Ack qualified as Ack
import Kenshou.Suite.Kafka.Correctness.Halt qualified as Halt
import Kenshou.Suite.Kafka.Correctness.MultiTopic qualified as MultiTopic
import Kenshou.Suite.Kafka.Correctness.Records qualified as Records
import Kenshou.Suite.Kafka.Correctness.Retry qualified as Retry
import Kenshou.Suite.Kafka.Fixture qualified as Fixture
import Kenshou.Suite.Kafka.Producer qualified as Producer

bundle :: LayerBundle
bundle = LayerBundle Kafka (Fixture.scenarios <> Ack.scenarios <> Halt.scenarios <> MultiTopic.scenarios <> Records.scenarios <> Retry.scenarios <> Producer.scenarios) []
