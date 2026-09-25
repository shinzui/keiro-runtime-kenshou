module Main (main) where

import Data.Aeson (object, (.=))
import Data.Map.Strict qualified as Map
import Kafka.Types (BrokerAddress (..))
import Kenshou.Env.Kafka.Spec
import Kenshou.Suite.Kafka.Model.Simulator (Decision (..), Event (..), Schedule (..), Trace (..), propFirstSuccessInOrder, propNoCommitPastUnacked, propTerminates)
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
  describe "Kafka reference acknowledgement model" do
    it "satisfies no-loss, first-success order, and finite completion for two retries" do
      mapM_ checkReference [1 .. 7]

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
