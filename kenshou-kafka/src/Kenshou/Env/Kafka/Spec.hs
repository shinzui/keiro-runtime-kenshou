module Kenshou.Env.Kafka.Spec
  ( BrokerBackend (..),
    BrokerControlHooks (..),
    KafkaEnvSpec (..),
    defaultKafkaEnvSpec,
    kafkaEnvSpecFromValue,
    kafkaEnvSpecFromRunSpec,
    validateKafkaEnvSpec,
  )
where

import Data.Aeson (FromJSON (..), Result (..), Value, fromJSON, withObject, (.!=), (.:), (.:?))
import Data.Char (isAsciiLower, isDigit)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Kafka.Types (BrokerAddress (..))
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.RunSpec (EnvironmentSpec (..))

data BrokerBackend = RedpandaContainer | ExternalBrokers
  deriving stock (Eq, Show)

data BrokerControlHooks = BrokerControlHooks
  { killCommand :: [Text],
    stopCommand :: [Text],
    startCommand :: [Text]
  }
  deriving stock (Eq, Show)

data KafkaEnvSpec = KafkaEnvSpec
  { backend :: BrokerBackend,
    brokers :: [BrokerAddress],
    controlHooks :: Maybe BrokerControlHooks,
    lanes :: Int,
    brokerProps :: Map Text Text,
    readyTimeoutSeconds :: Int,
    keepData :: Bool
  }
  deriving stock (Eq, Show)

defaultKafkaEnvSpec :: KafkaEnvSpec
defaultKafkaEnvSpec = KafkaEnvSpec RedpandaContainer [] Nothing 1 Map.empty 90 False

kafkaEnvSpecFromRunSpec :: RunContext -> Either Text KafkaEnvSpec
kafkaEnvSpecFromRunSpec context = kafkaEnvSpecFromValue context.environmentSpec.kafka

kafkaEnvSpecFromValue :: Maybe Value -> Either Text KafkaEnvSpec
kafkaEnvSpecFromValue = \case
  Nothing -> Right defaultKafkaEnvSpec
  Just value -> case fromJSON value of
    Error message -> Left (Text.pack message)
    Success spec -> validateKafkaEnvSpec spec

validateKafkaEnvSpec :: KafkaEnvSpec -> Either Text KafkaEnvSpec
validateKafkaEnvSpec spec
  | spec.lanes < 0 || spec.lanes > 4 = Left "environment.kafka.lanes must be between 0 and 4"
  | spec.readyTimeoutSeconds < 1 || spec.readyTimeoutSeconds > 600 = Left "environment.kafka.readyTimeoutSeconds must be between 1 and 600"
  | any (isSharedBroker . unBrokerAddress) spec.brokers = Left "the shared broker at loopback port 9092 is forbidden"
  | spec.backend == ExternalBrokers && null spec.brokers = Left "external Kafka requires at least one broker"
  | spec.backend == ExternalBrokers && spec.lanes /= 0 = Left "external Kafka has no local proxy lanes; set lanes to 0"
  | spec.backend /= ExternalBrokers && not (null spec.brokers) = Left "private Kafka backends choose their own broker addresses"
  | spec.backend /= ExternalBrokers && spec.controlHooks /= Nothing = Left "control hooks apply only to external brokers"
  | spec.backend == ExternalBrokers && not (Map.null spec.brokerProps) = Left "brokerProps apply only to private backends"
  | any (`Map.member` spec.brokerProps) reservedServerProperties = Left "brokerProps cannot override listeners, advertised listeners, log directories, or node identity"
  | any (not . Text.all (\character -> isAsciiLower character || isDigit character || character == '_')) (Map.keys spec.brokerProps) = Left "brokerProps keys must use lowercase Redpanda property names"
  | otherwise = Right spec
  where
    reservedServerProperties = ["listeners", "advertised.listeners", "log.dirs", "node.id", "process.roles", "controller.quorum.voters", "data_directory", "node_id", "kafka_api", "advertised_kafka_api", "rpc_server", "advertised_rpc_api", "seed_servers", "admin", "developer_mode"]

isSharedBroker :: Text -> Bool
isSharedBroker address = case Text.breakOnEnd ":" address of
  (hostWithColon, "9092") -> Text.dropEnd 1 hostWithColon `elem` ["127.0.0.1", "localhost", "[::1]"]
  _ -> False

instance FromJSON BrokerBackend where
  parseJSON = \case
    "redpanda-container" -> pure RedpandaContainer
    "external" -> pure ExternalBrokers
    value -> fail ("unknown Kafka backend: " <> show (value :: Value))

instance FromJSON BrokerControlHooks where
  parseJSON = withObject "BrokerControlHooks" \value ->
    BrokerControlHooks <$> value .: "kill" <*> value .: "stop" <*> value .: "start"

instance FromJSON KafkaEnvSpec where
  parseJSON = withObject "KafkaEnvSpec" \value -> do
    backend <- value .:? "backend" .!= RedpandaContainer
    addresses <- value .:? "brokers" .!= []
    controlHooks <- value .:? "control"
    lanes <- value .:? "lanes" .!= if backend == ExternalBrokers then 0 else 1
    brokerProps <- value .:? "brokerProps" .!= Map.empty
    readyTimeoutSeconds <- value .:? "readyTimeoutSeconds" .!= 90
    keepData <- value .:? "keepData" .!= False
    pure KafkaEnvSpec {backend, brokers = fmap BrokerAddress addresses, controlHooks, lanes, brokerProps, readyTimeoutSeconds, keepData}
