module Main (main) where

import Data.Aeson (object, (.=))
import Data.Map.Strict qualified as Map
import Kafka.Types (BrokerAddress (..))
import Kenshou.Env.Kafka.Spec
import Test.Hspec

main :: IO ()
main = hspec do
  describe "Kafka broker specification" do
    it "rejects every spelling of the shared broker" do
      mapM_
        (\address -> validateKafkaEnvSpec (defaultKafkaEnvSpec {backend = ExternalBrokers, brokers = [BrokerAddress address], lanes = 0}) `shouldSatisfy` isLeft)
        ["127.0.0.1:9092", "localhost:9092", "[::1]:9092"]
    it "rejects shared addresses from the run specification" do
      mapM_
        (\address -> kafkaEnvSpecFromValue (Just (object ["backend" .= ("external" :: String), "brokers" .= [address :: String]])) `shouldSatisfy` isLeft)
        ["127.0.0.1:9092", "localhost:9092", "[::1]:9092"]
    it "accepts a distinct external broker" do
      validateKafkaEnvSpec (defaultKafkaEnvSpec {backend = ExternalBrokers, brokers = [BrokerAddress "10.0.0.1:9092"], lanes = 0}) `shouldSatisfy` isRight
    it "rejects listener overrides" do
      validateKafkaEnvSpec (defaultKafkaEnvSpec {brokerProps = Map.singleton "advertised.listeners" "127.0.0.1:9092"}) `shouldSatisfy` isLeft

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _ = False

isRight :: Either a b -> Bool
isRight (Right _) = True
isRight _ = False
