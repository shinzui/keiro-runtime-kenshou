module Main (main) where

import Data.Aeson (object, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Kafka.Consumer (ConsumerGroupId (..), PartitionId (..))
import Kafka.Types (BrokerAddress (..), TopicName (..))
import Kenshou.Core.Bundle (LayerBundle (..))
import Kenshou.Core.Env (EnvRequirements (..))
import Kenshou.Core.Scenario (Scenario (..))
import Kenshou.Env.Kafka (BrokerLane (..), GroupSnapshot (..), KafkaEnv (..), KafkaEnvUnavailable (..), PartitionOffsets (..), adminAddresses, groupLag, laneAt, laneProxy, requestLanes, requireControl, topicLag, unavailableReason)
import Kenshou.Env.Kafka.Spec
import Kenshou.Suite.Kafka qualified as Kafka
import Kenshou.Suite.Kafka.Model qualified as Model
import Kenshou.Suite.Kafka.Model.Simulator (Decision (..), Event (..), Schedule (..), Trace (..), propFirstSuccessInOrder, propNoCommitPastUnacked, propTerminates)
import Test.Hspec

main :: IO ()
main = hspec do
  describe "Kafka scenario requirements" do
    it "requires a broker for every broker-backed scenario" do
      let modelIds = fmap (.id) Model.scenarios
          brokerBacked = filter (\scenario -> scenario.id `notElem` modelIds) Kafka.bundle.scenarios
      map (.id) brokerBacked `shouldSatisfy` (not . null)
      map (\scenario -> scenario.requires.kafka) brokerBacked `shouldSatisfy` and
      map (\scenario -> scenario.requires.kafka) Model.scenarios `shouldSatisfy` (all not)
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
  describe "Kafka environment access" do
    it "requests proxied lanes only from private backends" do
      (requestLanes 2 defaultKafkaEnvSpec).lanes `shouldBe` 2
      (requestLanes 9 defaultKafkaEnvSpec).lanes `shouldBe` 4
      (requestLanes 0 defaultKafkaEnvSpec).lanes `shouldBe` 1
      let external = defaultKafkaEnvSpec {backend = ExternalBrokers, brokers = [BrokerAddress "10.0.0.1:9092"], lanes = 0}
      requestLanes 2 external `shouldBe` external
    it "reports missing lanes, proxies and control with the suite-wide labels" do
      let env = directEnv []
      fmap (.laneBrokers) (laneAt env 0) `shouldBe` Right [BrokerAddress "127.0.0.1:40001"]
      either Just (const Nothing) (laneAt env 1) `shouldBe` Just (LanesUnavailable 1 1)
      either Just (const Nothing) (laneAt env (-1)) `shouldBe` Just (LanesUnavailable (-1) 1)
      either Just (const Nothing) (laneProxy env 0) `shouldBe` Just (LaneProxyUnavailable 0)
      either (Just . unavailableReason) (const Nothing) (requireControl env) `shouldBe` Just "broker-control-unavailable"
      fmap unavailableReason [LanesUnavailable 1 1, LaneProxyUnavailable 0] `shouldBe` ["lanes-unavailable", "lanes-unavailable"]
    it "administers through the control listener when one exists" do
      adminAddresses (directEnv []) `shouldBe` [BrokerAddress "127.0.0.1:40001"]
      adminAddresses (directEnv [BrokerAddress "127.0.0.1:40009"]) `shouldBe` [BrokerAddress "127.0.0.1:40009"]
    it "sums group lag only when every partition has committed" do
      let offsets committed lag partition topic = PartitionOffsets (TopicName topic) (PartitionId partition) committed 10 lag
          snapshot = GroupSnapshot (ConsumerGroupId "g") "Stable" []
      groupLag (snapshot []) `shouldBe` Nothing
      groupLag (snapshot [offsets (Just 10) (Just 0) 0 "a", offsets (Just 7) (Just 3) 1 "a"]) `shouldBe` Just 3
      groupLag (snapshot [offsets (Just 10) (Just 0) 0 "a", offsets Nothing (Just 10) 1 "a"]) `shouldBe` Nothing
      topicLag (TopicName "b") (snapshot [offsets Nothing Nothing 0 "a", offsets (Just 4) (Just 6) 0 "b"]) `shouldBe` Just 6
      topicLag (TopicName "c") (snapshot [offsets (Just 4) (Just 6) 0 "b"]) `shouldBe` Nothing
  describe "Kafka reference acknowledgement model" do
    it "satisfies no-loss, first-success order, and finite completion for two retries" do
      mapM_ checkReference [1 .. 7]

directEnv :: [BrokerAddress] -> KafkaEnv
directEnv admin = KafkaEnv RedpandaContainer (BrokerLane [BrokerAddress "127.0.0.1:40001"] Nothing :| []) "kenshou-test" Nothing "test" "/nonexistent" admin

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _ = False

isRight :: Either a b -> Bool
isRight (Right _) = True
isRight _ = False

checkReference :: Int -> IO ()
checkReference retryAt = do
  let schedule = Schedule 1 1 10 (Map.fromList [(retryAt, [DecideRetry, DecideOk]), (retryAt + 1, [DecideRetry, DecideOk])])
      trace = referenceSchedule schedule
  propNoCommitPastUnacked trace `shouldBe` True
  propFirstSuccessInOrder trace `shouldBe` True
  propTerminates trace `shouldBe` True

-- A deliberately small independent handler: one record in flight and the
-- earliest pending seek wins when another retry is registered.
referenceSchedule :: Schedule -> Trace
referenceSchedule schedule = go 0 0 Map.empty (Map.empty :: Map.Map Int Int) [] [] 0
  where
    go position stored attempts barriers events successes steps
      | position >= schedule.maxOffsets = Trace events successes stored schedule.maxOffsets True steps
      | steps >= 4 * schedule.maxOffsets + 10 = Trace events successes stored schedule.maxOffsets False steps
      | otherwise =
          let attempted = Map.findWithDefault 0 position attempts
              script = Map.findWithDefault [] position schedule.script
              decision = case drop attempted script of next : _ -> next; [] -> DecideOk
              attempts' = Map.insert position (attempted + 1) attempts
              decided = events <> [Decided position decision]
           in case decision of
                DecideRetry ->
                  let barriers' = Map.insertWith min 0 position barriers
                      sought = Map.findWithDefault position 0 barriers'
                   in go sought stored attempts' barriers' (decided <> [Sought sought]) successes (steps + 1)
                DecideOk ->
                  let allowed = maybe True (position <=) (Map.lookup 0 barriers)
                      barriers' = if allowed then Map.delete 0 barriers else barriers
                      stored' = if allowed then position + 1 else stored
                      events' = if allowed then decided <> [Stored stored'] else decided
                      successes' = if position `elem` successes then successes else successes <> [position]
                   in go (position + 1) stored' attempts' barriers' events' successes' (steps + 1)
