module Kenshou.Env.Kafka.Naming
  ( runPrefix,
    topicName,
    groupName,
    namedResource,
  )
where

import Data.Char (isAsciiLower, isDigit)
import Data.Text (Text)
import Data.Text qualified as Text
import Kafka.Consumer (ConsumerGroupId (..))
import Kafka.Types (TopicName (..))
import Kenshou.Core.Id (RunId, renderRunId)
import Kenshou.Env.Kafka.Types (KafkaEnv (..))

runPrefix :: RunId -> Text
runPrefix runId = "kenshou-" <> Text.filter (/= '-') (renderRunId runId)

namedResource :: KafkaEnv -> Text -> Text
namedResource env name
  | valid name = env.prefix <> "-" <> name
  | otherwise = error ("invalid Kafka resource name: " <> Text.unpack name)
  where
    valid value = not (Text.null value) && Text.all (\char -> isAsciiLower char || isDigit char || char == '-') value

topicName :: KafkaEnv -> Text -> TopicName
topicName env = TopicName . namedResource env

groupName :: KafkaEnv -> Text -> ConsumerGroupId
groupName env = ConsumerGroupId . namedResource env
