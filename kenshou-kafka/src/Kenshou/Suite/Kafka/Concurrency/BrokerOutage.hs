module Kenshou.Suite.Kafka.Concurrency.BrokerOutage (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, wait)
import Control.Monad (forM_)
import Data.Aeson (FromJSON (..), object, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Char8 qualified as ByteString
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Effectful (liftIO, runEff)
import Effectful.Error.Static (runError)
import Kafka.Consumer.Types (ConsumerGroupId (..))
import Kafka.Effectful.Consumer qualified as C
import Kafka.Effectful.Producer qualified as P
import Kafka.Types (BrokerAddress (..), KafkaError, Timeout (..), TopicName (..))
import Kenshou.Check.Fault.Network (ProxyMode (..), resetConnections, setProxyMode)
import Kenshou.Check.Process (Child, Supervisor, awaitReady, readChildMessages, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension (allTelemetryArms, noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobInt, knobText, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..), WorkerMessage (..))
import Kenshou.Core.Scenario (CohortScope (..), KnownDefect (..), PackageCondition (..), Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Env.Kafka
import Kenshou.Suite.Kafka.Fixture (firstBrokers, intKnob)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios =
  [ Scenario
      { id = either (error . Text.unpack) id (parseScenarioId "kafka/adapter/concurrency/broker-outage-and-reconnect"),
        revision = 1,
        summary = "Keeps two adapter consumers and an acknowledged producer alive through a broker outage.",
        tier = TierStandard,
        placement = PlaceEither,
        knobs =
          [ intKnob "kafka.outage-seconds" "Broker outage duration" 20 1 60,
            intKnob "kafka.recovery-deadline-seconds" "Drain deadline after recovery" 60 10 180,
            intKnob "kafka.messages" "Open-loop producer records" 15000 1000 30000,
            KnobSpec (key "kafka.outage-mode") "Outage injection" KnobText (VText "kill") (OneOf (VText "kill" :| [VText "blackhole"])) []
          ],
        dimensions = allTelemetryArms noDimensions,
        phases = zeroPhases,
        requires = noEnvironment,
        knownDefect =
          Just
            KnownDefect
              { reference = "mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-3",
                summary = "Released adapter consumers exit after a broker restart before acknowledged backlog drains.",
                expectedFailures = ["outage-acked-no-loss", "outage-consumers-resumed", "outage-adapter-exit"],
                appliesTo = OnlyWhen (ResolvedFromHackage "shibuya-kafka-adapter" :| [VersionBelow "shibuya-kafka-adapter" "0.9.0.2"])
              },
        run = runBrokerOutage
      }
  ]

data OkFact = OkFact {value :: Int, partition :: Int, offset :: Int, at :: UTCTime} deriving stock (Eq, Show)

instance FromJSON OkFact where
  parseJSON = withObject "outage ok fact" \v -> OkFact <$> v .: "value" <*> v .: "partition" <*> v .: "offset" <*> v .: "at"

runBrokerOutage :: RunContext -> IO ScenarioReport
runBrokerOutage context = do
  spec <- either (ioError . userError . Text.unpack) pure (kafkaEnvSpecFromRunSpec context)
  withKafkaEnv context spec \env -> do
    let outageSeconds = fromIntegral (knobInt context.knobs (key "kafka.outage-seconds"))
        recoverySeconds = fromIntegral (knobInt context.knobs (key "kafka.recovery-deadline-seconds"))
        messages = fromIntegral (knobInt context.knobs (key "kafka.messages"))
        outageMode = knobText context.knobs (key "kafka.outage-mode")
        group = groupName env "broker-outage"
    [topic] <- createTopics env [TopicSpec "broker-outage" 4 mempty]
    (acked, deliveryFailures, facts, recoveryFacts, brokerValues, workerErrors, outageStart, outageEnd, reachedEnd, recoveredAfterRestart) <- withCheck context \check -> withSupervisor check \supervisor -> do
      let args = object ["brokers" .= fmap unBrokerAddress (firstBrokers env), "topic" .= unTopicName topic, "group" .= unConsumerGroupId group, "autoCommitMillis" .= (1000 :: Int), "serviceMillis" .= (1 :: Int)]
      firstSpec <- roleProcess check "kafka/crash-consumer" 0 args
      secondSpec <- roleProcess check "kafka/crash-consumer" 1 args
      first <- spawn supervisor firstSpec
      second <- spawn supervisor secondSpec
      awaitReady first 10000
      awaitReady second 10000
      sendCommand first CtlStart
      sendCommand second CtlStart
      reports <- newIORef []
      producer <- async (produceOpenLoop env topic messages reports)
      threadDelay 1000000
      outageStart <- getCurrentTime
      injectOutage env outageMode
      threadDelay (outageSeconds * 1000000)
      healOutage env outageMode
      outageEnd <- getCurrentTime
      produced <- timeout ((recoverySeconds + 60) * 1000000) (wait producer)
      case produced of
        Nothing -> cancel producer >> ioError (userError "outage producer did not flush after recovery")
        Just () -> pure ()
      delivered <- reverse <$> readIORef reports
      let acknowledged = [value | P.DeliverySuccess sent _ <- delivered, Just value <- [P.prValue sent >>= readInt]]
          failedReports = length [() | P.DeliveryFailure _ _ <- delivered]
      firstBefore <- readChildMessages first
      secondBefore <- readChildMessages second
      groupResult <-
        if any ended firstBefore && any ended secondBefore
          then Left <$> describeGroup env group
          else awaitGroup env group recoverySeconds (\snapshot -> length snapshot.offsets == 4 && all ((== Just 0) . (.lag)) snapshot.offsets)
      stopIfAlive supervisor first
      stopIfAlive supervisor second
      firstMessages <- readChildMessages first
      secondMessages <- readChildMessages second
      brokerValues <- readBackBroker env topic messages
      let handled = okFacts (firstMessages <> secondMessages)
          errors = [message | WrkError message <- firstMessages <> secondMessages]
          reached = either (const False) (const True) groupResult
      (controlFacts, recovered) <-
        if reached || null errors
          then pure ([], False)
          else do
            recoveryFirstSpec <- roleProcess check "kafka/crash-consumer" 2 args
            recoverySecondSpec <- roleProcess check "kafka/crash-consumer" 3 args
            recoveryFirst <- spawn supervisor recoveryFirstSpec
            recoverySecond <- spawn supervisor recoverySecondSpec
            awaitReady recoveryFirst 10000
            awaitReady recoverySecond 10000
            sendCommand recoveryFirst CtlStart
            sendCommand recoverySecond CtlStart
            controlResult <- awaitGroup env group recoverySeconds (\snapshot -> length snapshot.offsets == 4 && all ((== Just 0) . (.lag)) snapshot.offsets)
            stopIfAlive supervisor recoveryFirst
            stopIfAlive supervisor recoverySecond
            firstControl <- readChildMessages recoveryFirst
            secondControl <- readChildMessages recoverySecond
            pure (okFacts (firstControl <> secondControl), either (const False) (const True) controlResult)
      pure (acknowledged, failedReports, handled, controlFacts, brokerValues, errors, outageStart, outageEnd, reached, recovered)
    _ <- deleteRunGroups env
    _ <- deleteRunTopics env
    let acknowledged = Set.fromList acked
        handled = Set.fromList (fmap (.value) facts)
        missing = Set.toAscList (Set.difference acknowledged handled)
        handledAfterRestart = Set.union handled (Set.fromList (fmap (.value) recoveryFacts))
        missingAfterRestart = Set.toAscList (Set.difference acknowledged handledAfterRestart)
        missingOnBroker = Set.toAscList (Set.difference acknowledged brokerValues)
        byId = Map.fromListWith (<>) [(fact.value, [fact]) | fact <- facts]
        afterWindow = addUTCTime 1 outageEnd
        lateDuplicates =
          [ (value, fact.at)
          | (value, occurrences) <- Map.toList byId,
            length occurrences > 1,
            fact <- drop 1 (sortByTime occurrences),
            fact.at < outageStart || fact.at > afterWindow
          ]
        failures =
          ["outage-acknowledged-traffic" | length acked < 1000]
            <> ["outage-callback-duplicate" | Set.size acknowledged /= length acked]
            <> ["outage-acked-no-loss" | not (null missing)]
            <> ["outage-broker-ack-loss" | not (null missingOnBroker)]
            <> ["outage-consumers-resumed" | not reachedEnd]
            <> ["outage-duplicate-window" | not (null lateDuplicates)]
            <> ["outage-adapter-exit" | not (null workerErrors)]
            <> ["outage-restart-control-no-loss" | not (null recoveryFacts) && (not recoveredAfterRestart || not (null (filter (`Set.member` brokerValues) missingAfterRestart)))]
    putSummary context Verdicts "brokerOutage" (object ["mode" .= outageMode, "acknowledged" .= length acked, "uniqueAcknowledged" .= Set.size acknowledged, "deliveryFailures" .= deliveryFailures, "handled" .= length facts, "missing" .= take 20 missing, "brokerAvailable" .= Set.size brokerValues, "missingOnBroker" .= take 20 missingOnBroker, "recoveryControlHandled" .= length recoveryFacts, "missingAfterRestart" .= take 20 missingAfterRestart, "recoveredAfterRestart" .= recoveredAfterRestart, "lateDuplicates" .= take 20 lateDuplicates, "consumerErrors" .= workerErrors, "zeroLag" .= reachedEnd])
    pure $
      if null failures
        then passed
        else failedWith failures ("acked=" <> Text.pack (show (length acked)) <> " handled=" <> Text.pack (show (length facts)) <> " missing=" <> Text.pack (show (take 20 missing)) <> " lateDuplicates=" <> Text.pack (show (take 20 lateDuplicates)) <> " workerErrors=" <> Text.pack (show workerErrors) <> " zeroLag=" <> Text.pack (show reachedEnd))

produceOpenLoop :: KafkaEnv -> TopicName -> Int -> IORef [P.DeliveryReport] -> IO ()
produceOpenLoop env topic count reports = do
  let props = P.brokersList (firstBrokers env) <> P.extraProp "acks" "all" <> P.extraProp "message.timeout.ms" "90000"
  result <- runEff . runError @KafkaError $
    P.runKafkaProducer props $ do
      forM_ [0 .. count - 1] \value -> do
        let record = P.ProducerRecord {P.prTopic = topic, P.prPartition = P.UnassignedPartition, P.prKey = Just (ByteString.pack (show value)), P.prValue = Just (ByteString.pack (show value)), P.prHeaders = mempty}
        _ <- P.produceMessage' record (\report -> atomicModifyIORef' reports (\old -> (report : old, ())))
        liftIO $ threadDelay 2000
      P.flushProducer
  either (ioError . userError . show) pure result

readBackBroker :: KafkaEnv -> TopicName -> Int -> IO (Set.Set Int)
readBackBroker env topic expected = do
  let props = C.brokersList (firstBrokers env) <> C.groupId (groupName env "outage-audit") <> C.noAutoOffsetStore
      subscription = C.topics [topic] <> C.offsetReset C.Earliest
      loop idle values
        | Set.size values >= expected || idle >= 10 = pure values
        | otherwise = do
            candidate <- C.pollMessage (Timeout 500)
            case candidate >>= (\row -> C.crValue row >>= readInt) of
              Nothing -> loop (idle + 1) values
              Just value -> loop 0 (Set.insert value values)
  result <- runEff . runError @KafkaError $ C.runKafkaConsumer props subscription (loop (0 :: Int) Set.empty)
  either (ioError . userError . show) pure result

injectOutage :: KafkaEnv -> Text -> IO ()
injectOutage env "kill" = maybe (ioError (userError "broker-control-unavailable")) (.kill) env.control
injectOutage env "blackhole" = case env.lanes of lane :| _ -> maybe (ioError (userError "lanes-unavailable")) (\proxy -> setProxyMode proxy Blackhole) lane.laneFaults
injectOutage _ _ = ioError (userError "invalid outage mode")

healOutage :: KafkaEnv -> Text -> IO ()
healOutage env "kill" = maybe (ioError (userError "broker-control-unavailable")) (.start) env.control
healOutage env "blackhole" = case env.lanes of lane :| _ -> maybe (ioError (userError "lanes-unavailable")) (\proxy -> setProxyMode proxy Forward >> resetConnections proxy >> pure ()) lane.laneFaults
healOutage _ _ = ioError (userError "invalid outage mode")

okFacts :: [WorkerMessage] -> [OkFact]
okFacts = mapMaybe \case
  WrkCustom "ok" value -> case Aeson.fromJSON value of Aeson.Success fact -> Just fact; _ -> Nothing
  _ -> Nothing

sortByTime :: [OkFact] -> [OkFact]
sortByTime = sortOn (.at)

readInt :: ByteString.ByteString -> Maybe Int
readInt bytes = case reads (ByteString.unpack bytes) of [(value, "")] -> Just value; _ -> Nothing

key :: Text -> KnobName
key = either (error . Text.unpack) id . mkKnobName

stopIfAlive :: Supervisor -> Child -> IO ()
stopIfAlive supervisor child = do
  messages <- readChildMessages child
  if any ended messages
    then pure ()
    else do
      _ <- stopGracefully supervisor child 5000
      pure ()

ended :: WorkerMessage -> Bool
ended (WrkDone _) = True
ended (WrkError _) = True
ended _ = False
