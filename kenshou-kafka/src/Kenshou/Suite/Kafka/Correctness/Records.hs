module Kenshou.Suite.Kafka.Correctness.Records (scenarios) where

import Control.Monad (forM)
import Data.Aeson (object, (.=))
import Data.ByteString qualified as ByteString
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Data.UUID qualified as UUID
import Data.Word (Word64)
import Effectful (runEff)
import Effectful.Error.Static (runError)
import Kafka.Consumer.Types (Offset (..))
import Kafka.Effectful.Consumer qualified as C
import Kafka.Effectful.Producer qualified as P
import Kafka.Types (KafkaError, PartitionId (..), Timeout (..), TopicName (..), headersFromList, headersToList)
import Keiro.Inbox.Kafka (KafkaDecodeError (..), KafkaInboundRecord (..), integrationEventFromKafka)
import Keiro.Inbox.Kafka qualified as Inbox
import Keiro.Inbox.Types (KafkaDeliveryRef (..))
import Keiro.Integration.Event (IntegrationContentType (..), IntegrationEvent (..), SchemaReference (..), TraceContext (..), headerContentType, headerDestination, headerEventType, headerMessageId, headerSchemaVersion, headerSource)
import Keiro.Outbox.Kafka (KafkaProducerRecord (..), integrationEventToKafkaRecord)
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Dimension (allTelemetryArms, noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId, unSeed)
import Kenshou.Core.Knob (knobInt, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Env.Kafka
import Kenshou.Suite.Kafka.Fixture (firstBrokers, intKnob)
import Kiroku.Store.Types (EventId (..), GlobalPosition (..))

scenarios :: [Scenario]
scenarios =
  [ Scenario
      { id = either (error . Text.unpack) id (parseScenarioId "kafka/keiro-records/correctness/roundtrip-through-broker"),
        revision = 1,
        summary = "Round-trips Keiro integration events and delivery references through Kafka headers and payloads.",
        tier = TierSmoke,
        placement = PlaceEither,
        knobs = [intKnob "kafka.messages" "Integration events" 200 2 5000],
        dimensions = allTelemetryArms noDimensions,
        phases = zeroPhases,
        requires = noEnvironment,
        knownDefect = Nothing,
        run = runRecords
      }
  ]

runRecords :: RunContext -> IO ScenarioReport
runRecords context = do
  spec <- either (ioError . userError . Text.unpack) pure (kafkaEnvSpecFromRunSpec context)
  withKafkaEnv context spec \env -> do
    let count = fromIntegral (knobInt context.knobs (either (error . Text.unpack) id (mkKnobName "kafka.messages")))
        seedValue = unSeed context.seed
    [topic] <- createTopics env [TopicSpec "keiro-records" 1 mempty]
    let events = [makeEvent topic seedValue number | number <- [0 .. count - 1]]
    offsets <- produceEvents env events
    inbound <- consumeEvents env topic count
    snapshot <- describeGroup env (groupName env "keiro-records")
    _ <- deleteRunGroups env
    _ <- deleteRunTopics env
    let decoded = fmap integrationEventFromKafka inbound
        successful = [(event, ref) | Right (event, ref) <- decoded]
        exactEvents = sortOn (.messageId) (fmap fst successful) == sortOn (.messageId) events
        expectedOffsets = Map.fromList [(event.messageId, unOffset offset) | (event, offset) <- zip events offsets]
        exactRefs =
          length successful == count
            && all (\(event, ref) -> ref == KafkaDeliveryRef (unTopicName topic) 0 (fromMaybe (-1) (Map.lookup event.messageId expectedOffsets))) successful
        sixHeaders = all (\record -> all (\name -> name `elem` fmap fst record.headers) requiredHeaders) inbound
        missingChecks = case inbound of
          first : _ ->
            [ integrationEventFromKafka (first {Inbox.headers = filter ((/= name) . fst) first.headers}) == Left (MissingHeader name)
            | name <- requiredHeaders
            ]
          [] -> []
        lagZero = length snapshot.offsets == 1 && all ((== Just 0) . (.lag)) snapshot.offsets
        good = length offsets == count && length inbound == count && exactEvents && exactRefs && sixHeaders && length missingChecks == 6 && and missingChecks && lagZero
    pure $
      if good
        then passed
        else failedWith ["keiro-record-roundtrip"] ("sent=" <> Text.pack (show (length offsets)) <> " received=" <> Text.pack (show (length inbound)) <> " decodeErrors=" <> Text.pack (show [problem | Left problem <- decoded]) <> " exactEvents=" <> Text.pack (show exactEvents) <> " exactRefs=" <> Text.pack (show exactRefs) <> " sixHeaders=" <> Text.pack (show sixHeaders) <> " missingChecks=" <> Text.pack (show missingChecks) <> " snapshot=" <> Text.pack (show snapshot))

requiredHeaders :: [Text]
requiredHeaders = [headerSource, headerDestination, headerEventType, headerSchemaVersion, headerContentType, headerMessageId]

makeEvent :: TopicName -> Word64 -> Int -> IntegrationEvent
makeEvent (TopicName topic) seedValue number =
  let present = even (number + fromIntegral (seedValue `mod` 2))
      identity = EventId (UUID.fromWords 0 0 (fromIntegral seedValue) (fromIntegral number + 1))
      bytes = ByteString.replicate (if number `mod` 20 == 0 then 65536 else 10 + number `mod` 1024) (fromIntegral (number `mod` 256))
   in IntegrationEvent
        { messageId = "message-" <> Text.pack (show number),
          source = if present then "注文/日本語" else "ordering",
          destination = topic,
          key = if present then Just ("顧客-" <> Text.pack (show number)) else Nothing,
          eventType = if present then "注文作成" else "OrderCreated",
          schemaVersion = 1 + number `mod` 3,
          contentType = ApplicationJson,
          schemaReference = if present then Just (SchemaReference (Just "registry") (Just "orders-value") (Just 2) (Just 41) (Just "sha256:sample")) else Nothing,
          sourceEventId = if present then Just identity else Nothing,
          sourceGlobalPosition = if present then Just (GlobalPosition (fromIntegral number + 1)) else Nothing,
          payloadBytes = bytes,
          occurredAt = posixSecondsToUTCTime (1700000000 + fromIntegral number),
          causationId = if present then Just identity else Nothing,
          correlationId = if present then Just identity else Nothing,
          traceContext = if present then Just (TraceContext "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" (Just "vendor=日本語")) else Nothing,
          attributes = if present then Just (object ["city" .= ("東京" :: Text), "number" .= number]) else Nothing
        }

produceEvents :: KafkaEnv -> [IntegrationEvent] -> IO [Offset]
produceEvents env events = do
  let props = P.brokersList (firstBrokers env) <> P.sendTimeout (Timeout 10000) <> P.extraProp "acks" "all"
  outcome <- runEff . runError @KafkaError $
    P.runKafkaProducer props $
      forM events \event -> do
        let neutral = integrationEventToKafkaRecord event
        P.produceMessageSync
          P.ProducerRecord
            { P.prTopic = TopicName neutral.topic,
              P.prPartition = P.UnassignedPartition,
              P.prKey = neutral.key,
              P.prValue = Just neutral.payload,
              P.prHeaders = headersFromList neutral.headers
            }
  either (ioError . userError . show) pure outcome

consumeEvents :: KafkaEnv -> TopicName -> Int -> IO [KafkaInboundRecord]
consumeEvents env topic count = do
  let props = C.brokersList (firstBrokers env) <> C.groupId (groupName env "keiro-records") <> C.noAutoOffsetStore
      subscription = C.topics [topic] <> C.offsetReset C.Earliest
  outcome <- runEff . runError @KafkaError $ C.runKafkaConsumer props subscription (loop 0 [])
  either (ioError . userError . show) pure outcome
  where
    loop (emptyPolls :: Int) collected
      | length collected >= count = pure (reverse collected)
      | emptyPolls >= 60 = pure (reverse collected)
      | otherwise = do
          candidate <- C.pollMessage (Timeout 500)
          case candidate of
            Nothing -> loop (emptyPolls + 1) collected
            Just record -> do
              C.commitOffsetMessage C.OffsetCommit record
              let inbound =
                    KafkaInboundRecord
                      { topic = unTopicName (C.crTopic record),
                        partition = fromIntegral (unPartitionId (C.crPartition record)),
                        offset = unOffset (C.crOffset record),
                        key = fmap TextEncoding.decodeUtf8 (C.crKey record),
                        payload = fromMaybe mempty (C.crValue record),
                        headers = [(TextEncoding.decodeUtf8 name, TextEncoding.decodeUtf8 value) | (name, value) <- headersToList (C.crHeaders record)],
                        receivedAt = posixSecondsToUTCTime 1700000000
                      }
              loop 0 (inbound : collected)
