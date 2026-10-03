module Kenshou.Env.Kafka.Types
  ( BrokerLane (..),
    BrokerControl (..),
    KafkaEnv (..),
  )
where

import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Kafka.Types (BrokerAddress)
import Kenshou.Check.Fault.Network (TcpProxy)
import Kenshou.Env.Kafka.Spec (BrokerBackend)

data BrokerLane = BrokerLane
  { laneBrokers :: [BrokerAddress],
    laneFaults :: Maybe TcpProxy
  }

data BrokerControl = BrokerControl
  { kill :: IO (),
    stop :: IO (),
    start :: IO (),
    isRunning :: IO Bool,
    generation :: IO Text
  }

data KafkaEnv = KafkaEnv
  { backend :: BrokerBackend,
    lanes :: NonEmpty BrokerLane,
    prefix :: Text,
    control :: Maybe BrokerControl,
    brokerVersion :: Text,
    workDir :: FilePath,
    -- | Unproxied addresses used by the fixture's own administration (topic,
    -- group and offset requests). Lane faults never apply to them, so an
    -- oracle can still sample offsets while a client lane is partitioned.
    adminBrokers :: [BrokerAddress]
  }
