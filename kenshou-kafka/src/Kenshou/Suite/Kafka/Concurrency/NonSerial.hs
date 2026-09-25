module Kenshou.Suite.Kafka.Concurrency.NonSerial (scenarios) where

import Control.Concurrent (threadDelay)
import Data.ByteString.Char8 qualified as ByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (liftIO, runEff)
import Effectful.Error.Static (runError)
import Kafka.Consumer.Types (Offset (..))
import Kafka.Effectful.Consumer qualified as C
import Kafka.Types (KafkaError, PartitionId (..), Timeout (..), TopicName)
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Dimension (allTelemetryArms, noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobInt, knobText, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (CohortScope (..), KnownDefect (..), Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Env.Kafka
import Kenshou.Suite.Kafka.Fixture (firstBrokers, produceValues)
import Shibuya.Adapter.Kafka (defaultConfig, kafkaAdapter)
import Shibuya.App (ProcessorId (..), QueueProcessor (..), defaultAppConfig, mkProcessor, runApp, stopApp, waitApp)
import Shibuya.Core.Ack (AckDecision (..), HaltReason (..))
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Types (Envelope (..))
import Shibuya.Policy (Concurrency (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios =
  [ Scenario
      { id = either (error . Text.unpack) id (parseScenarioId "kafka/adapter/concurrency/non-serial-finalization-commits-past-halt"),
        revision = 1,
        summary = "Checks whether concurrent finalization commits beyond a halted offset.",
        tier = TierStandard,
        placement = PlaceEither,
        knobs =
          [ KnobSpec (key "shibuya.concurrency") "Shibuya concurrency mode" KnobText (VText "async") (OneOf (VText "ahead" :| [VText "async"])) [],
            KnobSpec (key "shibuya.concurrency-n") "Concurrent handler count" KnobInt (VInt 4) (IntRange 2 32) []
          ],
        dimensions = allTelemetryArms noDimensions,
        phases = zeroPhases,
        requires = noEnvironment,
        knownDefect =
          Just
            KnownDefect
              { reference = "mori://shinzui/shibuya-kafka-adapter/okf/capabilities/concepts/CAP-1",
                summary = "Kafka adapter acknowledgements require serial finalization.",
                expectedFailures = ["non-serial-committed-past-halt"],
                appliesTo = AllCohorts
              },
        run = runNonSerial
      }
  ]

key :: Text -> KnobName
key = either (error . Text.unpack) id . mkKnobName

runNonSerial :: RunContext -> IO ScenarioReport
runNonSerial context = do
  spec <- either (ioError . userError . Text.unpack) pure (kafkaEnvSpecFromRunSpec context)
  withKafkaEnv context spec \env -> do
    [topic] <- createTopics env [TopicSpec "nonserial" 1 mempty]
    _ <- produceValues env topic [0 .. 79]
    facts <- newIORef []
    let mode = knobText context.knobs (key "shibuya.concurrency")
        capacity = fromIntegral (knobInt context.knobs (key "shibuya.concurrency-n"))
        concurrency = if mode == "ahead" then Ahead capacity else Async capacity
    result <- timeout 20000000 (consumeUntilHalt env topic concurrency facts)
    seen <- reverse <$> readIORef facts
    snapshot <- describeGroup env (groupName env "nonserial")
    resumed <- timeout 20000000 (firstOnResume env topic)
    _ <- deleteRunGroups env
    _ <- deleteRunTopics env
    let boundary = [offset | item <- snapshot.offsets, item.partition == PartitionId 0, Just offset <- [item.committed]]
        crossed = any (> 30) boundary && maybe False (> 30) (joinMaybe resumed)
        note = "mode=" <> mode <> " seen=" <> Text.pack (show seen) <> " committed=" <> Text.pack (show boundary) <> " resumed=" <> Text.pack (show resumed)
    pure $
      if result /= Just () || 30 `notElem` seen || null boundary || resumed == Nothing
        then failedWith ["non-serial-run-completed"] note
        else
          if crossed
            then failedWith ["non-serial-committed-past-halt"] note
            else
              if boundary == [30] && resumed == Just (Just 30)
                then passed
                else failedWith ["non-serial-halt-boundary"] note

consumeUntilHalt :: KafkaEnv -> TopicName -> Concurrency -> IORef [Int] -> IO ()
consumeUntilHalt env topic concurrency facts = do
  let props = C.brokersList (firstBrokers env) <> C.groupId (groupName env "nonserial") <> C.noAutoOffsetStore <> C.extraProp "auto.commit.interval.ms" "1000"
      subscription = C.topics [topic] <> C.offsetReset C.Earliest
  outcome <- runEff . runError @KafkaError . runTracingNoop $
    C.runKafkaConsumer props subscription $ do
      adapter <- kafkaAdapter (defaultConfig [topic])
      let handler Message {envelope = Envelope {payload}} = do
            case payload >>= readInt of
              Nothing -> pure AckOk
              Just offset -> do
                liftIO $ modifyIORef' facts (offset :)
                if offset == 30
                  then do
                    liftIO $ threadDelay 2000000
                    pure (AckHalt (HaltFatal "kenshou"))
                  else pure AckOk
      appResult <- runApp defaultAppConfig [(ProcessorId "nonserial", (mkProcessor adapter handler) {concurrency})]
      case appResult of
        Left problem -> liftIO $ ioError (userError (show problem))
        Right handle -> do
          waitApp handle
          liftIO $ threadDelay 2500000
          stopApp handle
  either (ioError . userError . show) pure outcome

firstOnResume :: KafkaEnv -> TopicName -> IO (Maybe Int)
firstOnResume env topic = do
  let props = C.brokersList (firstBrokers env) <> C.groupId (groupName env "nonserial") <> C.noAutoOffsetStore
      subscription = C.topics [topic] <> C.offsetReset C.Earliest
  outcome <- runEff . runError @KafkaError $ C.runKafkaConsumer props subscription (poll 0)
  either (ioError . userError . show) pure outcome
  where
    poll (attempts :: Int)
      | attempts >= 15 = pure Nothing
      | otherwise = do
          candidate <- C.pollMessage (Timeout 1000)
          case candidate of
            Nothing -> poll (attempts + 1)
            Just record -> pure (Just (fromIntegral (unOffset (C.crOffset record))))

readInt :: ByteString.ByteString -> Maybe Int
readInt bytes = case reads (ByteString.unpack bytes) of [(value, "")] -> Just value; _ -> Nothing

joinMaybe :: Maybe (Maybe a) -> Maybe a
joinMaybe = (>>= id)
