module Kenshou.Suite.Kafka.Telemetry.Context (scenarios) where

import Control.Monad (forM_, when)
import Data.Aeson (object, (.=))
import Data.ByteString.Char8 qualified as ByteString
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (liftIO, runEff)
import Effectful.Error.Static (runError)
import Kafka.Effectful.Consumer qualified as C
import Kafka.Effectful.OpenTelemetry.Consumer.Interpreter (runKafkaConsumerTraced)
import Kafka.Effectful.OpenTelemetry.Producer.Interpreter (runKafkaProducerTraced)
import Kafka.Effectful.Producer qualified as P
import Kafka.Types (BatchSize (..), KafkaError, Timeout (..), TopicName)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension (DimensionSupport (..), MetricsArm (..), Support (..), Supported (..), TracingArm (..))
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobText, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Env.Kafka
import Kenshou.Suite.Kafka.Fixture (firstBrokers)
import Kenshou.Telemetry (TelemetryHandles (..), telemetryKnobs, telemetrySpecFromContext, withTelemetry)
import Kenshou.Telemetry.Continuity (ContinuityResult (..), IsolationResult (..), SpanSelector (..), checkIsolation)
import Kenshou.Telemetry.Continuity qualified as Continuity
import Kenshou.Telemetry.Tracing.Probe (SpanView (..), readSpans)
import OpenTelemetry.Attributes (lookupAttribute, toAttribute)
import OpenTelemetry.Context qualified as OtelContext
import OpenTelemetry.Context.ThreadLocal (getContext)
import OpenTelemetry.Trace.Core (SpanKind (..), defaultSpanArguments)
import OpenTelemetry.Trace.Id (Base (..), spanIdBaseEncodedText, traceIdBaseEncodedText)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Kafka (defaultConfig, kafkaAdapter)
import Shibuya.App (ProcessorId (..), defaultAppConfig, mkProcessor, runApp, stopApp, waitApp)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Types (Envelope (..))
import Shibuya.Telemetry.Effect (runTracing, withSpan')
import Streamly.Data.Stream qualified as Stream

scenarios :: [Scenario]
scenarios =
  [ Scenario
      { id = either (error . Text.unpack) id (parseScenarioId "kafka/telemetry/correctness/context-leak-regression"),
        revision = 1,
        summary = "Checks traced, headerless, and independently traced records in one batch without ambient context leakage.",
        tier = TierSmoke,
        placement = PlaceEither,
        knobs = telemetryKnobs,
        dimensions =
          DimensionSupport
            { tracing = Supported (Support (TracingSdkInMemory :| []) TracingSdkInMemory),
              metrics = Supported (Support (MetricsOff :| []) MetricsOff),
              pgDurability = NotApplicable,
              pgVersion = NotApplicable
            },
        phases = zeroPhases,
        requires = noEnvironment,
        knownDefect = Nothing,
        run = runIsolation
      },
    Scenario
      { id = either (error . Text.unpack) id (parseScenarioId "kafka/telemetry/correctness/w3c-context-continuity"),
        revision = 1,
        summary = "Checks traced producer headers, Shibuya processing spans, and the traced consumer against one broker record.",
        tier = TierSmoke,
        placement = PlaceEither,
        knobs = telemetryKnobs <> [KnobSpec (either (error . Text.unpack) id (mkKnobName "kafka.consumer-tracing")) "Consumer tracing interpreter" KnobText (VText "shibuya") (OneOf (VText "shibuya" :| [VText "kafka-effectful", VText "both"])) []],
        dimensions =
          DimensionSupport
            { tracing = Supported (Support (TracingSdkInMemory :| []) TracingSdkInMemory),
              metrics = Supported (Support (MetricsOff :| []) MetricsOff),
              pgDurability = NotApplicable,
              pgVersion = NotApplicable
            },
        phases = zeroPhases,
        requires = noEnvironment,
        knownDefect = Nothing,
        run = runContinuity
      }
  ]

runIsolation :: RunContext -> IO ScenarioReport
runIsolation context = do
  telemetrySpec <- either (ioError . userError . Text.unpack) pure (telemetrySpecFromContext context)
  kafkaSpec <- either (ioError . userError . Text.unpack) pure (kafkaEnvSpecFromRunSpec context)
  withKafkaEnv context kafkaSpec \env -> withTelemetry telemetrySpec \handles -> do
    tracer <- maybe (ioError (userError "in-memory telemetry has no tracer")) pure handles.tracer
    probe <- maybe (ioError (userError "in-memory telemetry has no span probe")) pure handles.spans
    [topic] <- createTopics env [TopicSpec "context-isolation" 1 mempty]
    let records =
          [ makeRecord topic 0 (Just firstTraceparent),
            makeRecord topic 1 Nothing,
            makeRecord topic 2 (Just secondTraceparent)
          ]
    produced <- runEff . runError @KafkaError $ P.runKafkaProducer (P.brokersList (firstBrokers env) <> P.extraProp "acks" "all") $ forM_ records P.produceMessageSync
    either (ioError . userError . show) pure produced
    before <- getContext
    let props = C.brokersList (firstBrokers env) <> C.groupId (groupName env "context-isolation") <> C.noAutoOffsetStore
        subscription = C.topics [topic] <> C.offsetReset C.Earliest
    result <- runEff . runError @KafkaError $ runKafkaConsumerTraced tracer props subscription $ do
      let firstBatch (0 :: Int) = pure []
          firstBatch attempts = do
            candidate <- C.pollMessageBatch (Timeout 500) (BatchSize 3)
            if any isRecord candidate then pure candidate else firstBatch (attempts - 1)
          isRecord (Right _) = True
          isRecord _ = False
      rows <- firstBatch 20
      forM_ rows \case Right row -> C.commitOffsetMessage C.OffsetCommit row; Left _ -> pure ()
      pure [row | Right row <- rows]
    rows <- either (ioError . userError . show) pure result
    after <- getContext
    _ <- handles.flushTelemetry
    spans <- filter ((== Consumer) . (.kind)) <$> readSpans probe
    _ <- deleteRunGroups env
    _ <- deleteRunTopics env
    let traceIds = fmap (traceIdBaseEncodedText Base16 . (.traceId)) spans
        isolation = case spans of
          _ : middle : _ -> checkIsolation (SpanSelector Nothing (Just Consumer) []) (\candidate -> candidate.traceId == middle.traceId) spans
          _ -> checkIsolation (SpanSelector Nothing (Just Consumer) []) (const False) spans
        beforeHasSpan = maybe False (const True) (OtelContext.lookupSpan before)
        afterHasSpan = maybe False (const True) (OtelContext.lookupSpan after)
        expectedTraces = [firstTraceId, secondTraceId]
        failures =
          ["context-isolation-one-batch" | length rows /= 3]
            <> ["context-isolation-span-count" | length spans /= 3]
            <> ["context-isolation-traced-neighbors" | case traceIds of [first, _, third] -> [first, third] /= expectedTraces; _ -> True]
            <> ["context-isolation-headerless-root" | isolation.checked /= 1 || isolation.violations /= 0 || case traceIds of [first, middle, third] -> middle `elem` [first, third]; _ -> True]
            <> ["context-isolation-ambient" | beforeHasSpan /= afterHasSpan]
    putSummary context Verdicts "contextIsolation" (object ["records" .= length rows, "consumerSpans" .= length spans, "traceIds" .= traceIds, "rootCheck" .= isolation, "ambientBeforeHasSpan" .= beforeHasSpan, "ambientAfterHasSpan" .= afterHasSpan])
    pure $ if null failures then passed else failedWith failures ("traceIds=" <> Text.pack (show traceIds) <> " spans=" <> Text.pack (show (length spans)))

makeRecord :: TopicName -> Int -> Maybe ByteString.ByteString -> P.ProducerRecord
makeRecord topic number traceparent =
  P.ProducerRecord
    { P.prTopic = topic,
      P.prPartition = P.SpecifiedPartition 0,
      P.prKey = Just (ByteString.pack (show number)),
      P.prValue = Just (ByteString.pack (show number)),
      P.prHeaders = P.headersFromList (maybe [] (\value -> [("traceparent", value)]) traceparent)
    }

firstTraceId, secondTraceId :: Text
firstTraceId = "0af7651916cd43dd8448eb211c80319c"
secondTraceId = "1af7651916cd43dd8448eb211c80319d"

firstTraceparent, secondTraceparent :: ByteString.ByteString
firstTraceparent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
secondTraceparent = "00-1af7651916cd43dd8448eb211c80319d-c7ad6b7169203332-01"

runContinuity :: RunContext -> IO ScenarioReport
runContinuity context = do
  telemetrySpec <- either (ioError . userError . Text.unpack) pure (telemetrySpecFromContext context)
  kafkaSpec <- either (ioError . userError . Text.unpack) pure (kafkaEnvSpecFromRunSpec context)
  withKafkaEnv context kafkaSpec \env -> withTelemetry telemetrySpec \handles -> do
    tracer <- maybe (ioError (userError "in-memory telemetry has no tracer")) pure handles.tracer
    probe <- maybe (ioError (userError "in-memory telemetry has no span probe")) pure handles.spans
    [topic] <- createTopics env [TopicSpec "w3c-continuity" 1 mempty]
    let mode = knobText context.knobs (either (error . Text.unpack) id (mkKnobName "kafka.consumer-tracing"))
        producerProps = P.brokersList (firstBrokers env) <> P.extraProp "acks" "all"
        consumerProps suffix = C.brokersList (firstBrokers env) <> C.groupId (groupName env suffix) <> C.noAutoOffsetStore
        subscription = C.topics [topic] <> C.offsetReset C.Earliest
        record = makeRecord topic 0 Nothing
    sent <- runEff . runError @KafkaError . runTracing tracer $
      withSpan' "kenshou.parent" defaultSpanArguments $ \_ ->
        runKafkaProducerTraced tracer producerProps (P.produceMessageSync record)
    _ <- either (ioError . userError . show) pure sent
    wire <- runEff . runError @KafkaError $ C.runKafkaConsumer (consumerProps "w3c-wire") subscription $ do
      let next (0 :: Int) = pure Nothing
          next attempts = C.pollMessage (Timeout 500) >>= maybe (next (attempts - 1)) (pure . Just)
      candidate <- next 20
      forM_ candidate (C.commitOffsetMessage C.OffsetCommit)
      pure (candidate >>= (lookup "traceparent" . P.headersToList . C.crHeaders))
    header <- either (ioError . userError . show) pure wire
    shibuyaHandled <- newIORef False
    when (mode /= "kafka-effectful") do
      outcome <- runEff . runError @KafkaError . runTracing tracer $ C.runKafkaConsumer (consumerProps "w3c-shibuya") subscription $ do
        adapter <- kafkaAdapter (defaultConfig [topic])
        let finite = adapter {source = Stream.take 1 adapter.source}
            handler Message {envelope = Envelope {payload}} = do
              liftIO $ writeIORef shibuyaHandled (payload == Just "0")
              pure AckOk
        app <- runApp defaultAppConfig [(ProcessorId "continuity", mkProcessor finite handler)]
        case app of
          Left problem -> liftIO $ ioError (userError (show problem))
          Right running -> waitApp running >> stopApp running
      either (ioError . userError . show) pure outcome
    tracedReceived <- newIORef False
    when (mode /= "shibuya") do
      outcome <- runEff . runError @KafkaError $ runKafkaConsumerTraced tracer (consumerProps "w3c-traced") subscription $ do
        let next (0 :: Int) = pure Nothing
            next attempts = C.pollMessage (Timeout 500) >>= maybe (next (attempts - 1)) (pure . Just)
        candidate <- next 20
        forM_ candidate (C.commitOffsetMessage C.OffsetCommit)
        pure (isJust candidate)
      either (ioError . userError . show) (writeIORef tracedReceived) outcome
    _ <- handles.flushTelemetry
    spans <- readSpans probe
    handled <- readIORef shibuyaHandled
    traced <- readIORef tracedReceived
    _ <- deleteRunGroups env
    _ <- deleteRunTopics env
    let parentSpan = find ((== "kenshou.parent") . (.name)) spans
        producerSpans = filter ((== Producer) . (.kind)) spans
        consumers = filter ((== Consumer) . (.kind)) spans
        producerSpan = case producerSpans of [single] -> Just single; _ -> Nothing
        wireIds = do
          value <- header
          case ByteString.split '-' value of
            [_version, traceId, spanId, _flags] -> Just (Text.pack (ByteString.unpack traceId), Text.pack (ByteString.unpack spanId))
            _ -> Nothing
        headerMatches = case (wireIds, producerSpan) of
          (Just (traceId, spanId), Just producer) -> traceId == traceIdBaseEncodedText Base16 producer.traceId && spanId == spanIdBaseEncodedText Base16 producer.spanId
          _ -> False
        parentMatches = case (parentSpan, producerSpan) of
          (Just parent, Just producer) -> producer.parentSpanId == Just parent.spanId && producer.traceId == parent.traceId
          _ -> False
        continuity = Continuity.checkContinuity (SpanSelector Nothing (Just Producer) []) (SpanSelector Nothing (Just Consumer) [("messaging.system", toAttribute ("kafka" :: Text))]) (const (Just "one")) spans
        shibuyaSpan = find ((== "continuity process") . (.name)) consumers
        attrsPresent = case shibuyaSpan of
          Nothing -> False
          Just candidate -> all (isJust . lookupAttribute candidate.attributes) ["messaging.system", "messaging.kafka.destination.partition", "messaging.kafka.message.offset"]
        expectedConsumers = if mode == "both" then 2 else 1
        failures =
          ["w3c-wire-header" | not headerMatches]
            <> ["w3c-producer-parent" | not parentMatches]
            <> ["w3c-consumer-continuity" | continuity.consumers /= expectedConsumers || continuity.matched /= expectedConsumers || continuity.violations /= 0]
            <> ["w3c-shibuya-handler" | mode /= "kafka-effectful" && not handled]
            <> ["w3c-shibuya-attributes" | mode /= "kafka-effectful" && not attrsPresent]
            <> ["w3c-traced-consumer" | mode /= "shibuya" && not traced]
    putSummary context Verdicts "w3cContinuity" (object ["mode" .= mode, "header" .= fmap ByteString.unpack header, "producerSpans" .= length producerSpans, "consumerSpans" .= length consumers, "parentMatches" .= parentMatches, "headerMatches" .= headerMatches, "continuity" .= continuity, "shibuyaAttributesPresent" .= attrsPresent, "shibuyaHandled" .= handled, "tracedReceived" .= traced])
    pure $ if null failures then passed else failedWith failures ("header=" <> Text.pack (show header) <> " consumers=" <> Text.pack (show (length consumers)) <> " continuity=" <> Text.pack (show continuity))
