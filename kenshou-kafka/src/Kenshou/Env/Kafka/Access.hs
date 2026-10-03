-- | Typed access to the optional parts of a Kafka environment.
--
-- A private broker offers proxied lanes and process control; an external
-- broker may offer neither. Scenarios outside this layer (the assembled
-- runtime) use these helpers instead of pattern matching on 'KafkaEnv', so a
-- missing capability is reported with the suite-wide reasons
-- @lanes-unavailable@ and @broker-control-unavailable@.
module Kenshou.Env.Kafka.Access
  ( KafkaEnvUnavailable (..),
    unavailableReason,
    requestLanes,
    laneAt,
    laneProxy,
    requireControl,
    groupLag,
    topicLag,
  )
where

import Data.Foldable (toList)
import Data.Int (Int64)
import Data.Text (Text)
import Kafka.Types (TopicName)
import Kenshou.Check.Fault.Network (TcpProxy)
import Kenshou.Env.Kafka.Admin (GroupSnapshot (..), PartitionOffsets (..))
import Kenshou.Env.Kafka.Spec (BrokerBackend (..), KafkaEnvSpec (..))
import Kenshou.Env.Kafka.Types (BrokerControl, BrokerLane (..), KafkaEnv (..))

data KafkaEnvUnavailable
  = -- | The requested lane index and the number of lanes the environment has.
    LanesUnavailable Int Int
  | -- | The lane exists but has no fault proxy (an unproxied or external lane).
    LaneProxyUnavailable Int
  | BrokerControlUnavailable
  deriving stock (Eq, Show)

-- | The failure label a scenario reports for a missing capability.
unavailableReason :: KafkaEnvUnavailable -> Text
unavailableReason = \case
  LanesUnavailable _ _ -> "lanes-unavailable"
  LaneProxyUnavailable _ -> "lanes-unavailable"
  BrokerControlUnavailable -> "broker-control-unavailable"

-- | Ask a private backend for at least @n@ proxied lanes. External brokers
-- have no local proxy, so their specification is returned unchanged and the
-- scenario learns about the shortfall from 'laneAt' or 'laneProxy'.
requestLanes :: Int -> KafkaEnvSpec -> KafkaEnvSpec
requestLanes wanted spec
  | spec.backend == ExternalBrokers = spec
  | otherwise = spec {lanes = max spec.lanes (min 4 wanted)}

laneAt :: KafkaEnv -> Int -> Either KafkaEnvUnavailable BrokerLane
laneAt env index = case drop index (toList env.lanes) of
  lane : _ | index >= 0 -> Right lane
  _ -> Left (LanesUnavailable index (length env.lanes))

laneProxy :: KafkaEnv -> Int -> Either KafkaEnvUnavailable TcpProxy
laneProxy env index = laneAt env index >>= maybe (Left (LaneProxyUnavailable index)) Right . (.laneFaults)

requireControl :: KafkaEnv -> Either KafkaEnvUnavailable BrokerControl
requireControl env = maybe (Left BrokerControlUnavailable) Right env.control

-- | Total lag of a group, or 'Nothing' while any described partition has no
-- committed offset or no reported lag. An empty snapshot is 'Nothing' too:
-- an absent group has not consumed anything, which is not the same as zero
-- lag.
groupLag :: GroupSnapshot -> Maybe Int64
groupLag snapshot = sumLags snapshot.offsets

-- | 'groupLag' restricted to one topic.
topicLag :: TopicName -> GroupSnapshot -> Maybe Int64
topicLag topic snapshot = sumLags (filter ((== topic) . (.topic)) snapshot.offsets)

sumLags :: [PartitionOffsets] -> Maybe Int64
sumLags [] = Nothing
sumLags offsets = sum <$> traverse partitionLag offsets
  where
    partitionLag partition = partition.committed >> partition.lag
