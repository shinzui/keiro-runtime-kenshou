module Kenshou.Suite.Runtime.System.Broker
  ( RuntimeBroker (..),
    withRuntimeBroker,
  )
where

import Control.Exception (finally)
import Control.Monad (void)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Kafka.Consumer (ConsumerGroupId)
import Kafka.Types (TopicName)
import Kenshou.Core.Context (RunContext)
import Kenshou.Env.Kafka (KafkaEnv, TopicSpec (..), createTopics, deleteRunGroups, deleteRunTopics, groupName, kafkaEnvSpecFromRunSpec, withKafkaEnv)

data RuntimeBroker = RuntimeBroker
  { environment :: !KafkaEnv,
    shopEvents :: !TopicName,
    warehouseEvents :: !TopicName,
    shopConsumerGroup :: !ConsumerGroupId,
    warehouseConsumerGroup :: !ConsumerGroupId
  }

withRuntimeBroker :: RunContext -> Int -> (RuntimeBroker -> IO value) -> IO value
withRuntimeBroker context partitions action = do
  spec <- either (ioError . userError . Text.unpack) pure (kafkaEnvSpecFromRunSpec context)
  withKafkaEnv context spec \environment ->
    ( do
        topics <-
          createTopics
            environment
            [ TopicSpec "shop-events" partitions Map.empty,
              TopicSpec "warehouse-events" partitions Map.empty
            ]
        case topics of
          [shopEvents, warehouseEvents] ->
            action
              RuntimeBroker
                { environment,
                  shopEvents,
                  warehouseEvents,
                  shopConsumerGroup = groupName environment "shop-consumer",
                  warehouseConsumerGroup = groupName environment "warehouse-consumer"
                }
          _ -> ioError (userError "runtime broker did not create both topics")
    )
      `finally` (void (deleteRunGroups environment) >> void (deleteRunTopics environment))
