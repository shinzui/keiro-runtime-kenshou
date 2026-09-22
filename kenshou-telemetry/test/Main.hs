module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, waitCatch)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Exception (bracket)
import Control.Monad (replicateM_, void)
import Data.IORef
import Data.List (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Text qualified as Text
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), renderKnobName)
import Kenshou.Core.Scenario (Scenario (..))
import Kenshou.Telemetry.Compose
import Kenshou.Telemetry.Continuity
import Kenshou.Telemetry.Detect (Finding (..), FindingSeverity (Degraded), FindingStatus (Fired), handlerFinding, pipelineFindings, queueGrowthFinding)
import Kenshou.Telemetry.Endpoint
import Kenshou.Telemetry.Metrics
import Kenshou.Telemetry.Overhead
import Kenshou.Telemetry.Scrape
import Kenshou.Telemetry.SelfTest.Arms (armsScenario)
import Kenshou.Telemetry.SelfTest.Service
import Kenshou.Telemetry.Sink qualified as Sink
import Kenshou.Telemetry.Spec
import Kenshou.Telemetry.Tracing
import Kenshou.Telemetry.Tracing.Pipeline
import Kenshou.Telemetry.Tracing.Probe
import Network.HTTP.Types (status200, status404)
import Network.Socket (close)
import Network.Wai (Application, responseLBS)
import Network.Wai.Handler.Warp (defaultSettings, openFreePort, runSettingsSocket)
import Network.Wai.Handler.WebSockets (websocketsOr)
import Network.WebSockets qualified as WebSockets
import OpenTelemetry.Attributes (lookupAttribute)
import OpenTelemetry.Context.ThreadLocal (getContext)
import OpenTelemetry.Exporter.Span (ExportResult (..), SpanExporter (..))
import OpenTelemetry.Processor.Batch.Span qualified as Batch
import OpenTelemetry.Processor.Simple.Span qualified as Simple
import OpenTelemetry.Propagator (emptyTextMap, inject, textMapToList)
import OpenTelemetry.Trace.Core
import System.Directory (createDirectoryIfMissing)
import System.Timeout (timeout)
import Test.Hspec

main :: IO ()
main = hspec do
  describe "overhead planning" do
    it "expands the headline one-factor matrix into four arms and twelve slots" do
      let request = overheadRequest (Map.fromList [("telemetry.tracing", ["off", "noop", "sdk-otlp"]), ("telemetry.metrics", ["off", "serve-scraped"])])
      case planOverhead request armsScenario of
        Left err -> expectationFailure (show err)
        Right plan -> do
          length plan.arms `shouldBe` 4
          length plan.slots `shouldBe` 12
          map (length . unique . fmap (.arm.armId)) (blocks plan.slots) `shouldBe` [4, 4, 4]

    it "is deterministic and gives two arms ABBA order across the first two blocks" do
      let request = overheadRequest (Map.singleton "telemetry.tracing" ["off", "noop"])
      case (planOverhead request armsScenario, planOverhead request armsScenario) of
        (Right first, Right second) -> do
          first `shouldBe` second
          let order = fmap (.arm.armId) first.slots
          take 2 order `shouldBe` reverse (take 2 (drop 2 order))
        result -> expectationFailure (show result)

    it "rejects repeated arm values" do
      planOverhead (overheadRequest (Map.singleton "telemetry.tracing" ["off", "off"])) armsScenario `shouldSatisfy` isLeft

  describe "telemetry problem detectors" do
    it "detects synchronous handler stalls while a bounded async wrapper drops instead of blocking" do
      synchronousStats <- newHandlerStats
      timedHandler synchronousStats "sync" (slowHandler 6_000) ()
      synchronous <- snapshotHandlerStats "sync" synchronousStats
      (submit, snapshotAsync) <- asyncHandler 1 (slowHandler 20_000)
      replicateM_ 100 (submit ())
      queued <- snapshotAsync
      handlerFinding synchronous `shouldSatisfy` ((== Fired) . (.status))
      queued.dropped `shouldSatisfy` (> 0)

    it "marks dropped spans as degraded above the policy fraction" do
      let snapshot = PipelineSnapshot 100 100 80 0 20 20 1 (LatencySummary 1 1 1) Nothing
      pipelineFindings 0.01 (Just snapshot) [] `shouldSatisfy` any (\finding -> finding.detector == "span-drop" && finding.status == Fired && finding.severity == Degraded)

    it "fires queue growth only after more than ten consecutive samples above ninety percent" do
      queueGrowthFinding (Just 100) (replicate 10 91) `shouldSatisfy` ((/= Fired) . (.status))
      queueGrowthFinding (Just 100) (replicate 11 91) `shouldSatisfy` ((== Fired) . (.status))

  describe "telemetryKnobs" do
    it "declares each shared knob once" do
      let names = fmap (renderKnobName . (.name)) telemetryKnobs
      length names `shouldBe` length (unique names)
    it "bounds the trace-id ratio to zero through one" do
      fmap (.allowed) (find ((== "otel.sampler-arg") . renderKnobName . (.name)) telemetryKnobs)
        `shouldBe` Just (DoubleRange 0 1)

  describe "tracing arms" do
    it "does not construct a provider under off" do
      runtime <- startTracing (testSpec TracingOff)
      isNothing runtime.tracer `shouldBe` True
      isNothing runtime.provider `shouldBe` True

    it "constructs a disabled tracer under noop" do
      runtime <- startTracing (testSpec TracingNoop)
      let tracer = fromJust runtime.tracer
      tracerIsEnabled tracer `shouldBe` False
      inSpan tracer "ignored" defaultSpanArguments (pure ())
      _ <- stopTracing 1000 runtime
      pure ()

    it "retains a bounded, parented trace and installs W3C propagation" do
      runtime <- startTracing ((testSpec TracingSdkInMemory) {probeRetain = 4})
      let tracer = fromJust runtime.tracer
          provider = fromJust runtime.provider
      replicateM_ 5 (inSpan tracer "discarded" defaultSpanArguments (pure ()))
      headers <- inSpan' tracer "parent" defaultSpanArguments \parentSpan -> do
        addAttribute parentSpan "message.id" ("one" :: Text.Text)
        nested <- inSpan' tracer "child" defaultSpanArguments \childSpan -> addAttribute childSpan "message.id" ("one" :: Text.Text)
        activeContext <- getContext
        carrier <- inject (getTracerProviderPropagators provider) activeContext emptyTextMap
        pure (nested, textMapToList carrier)
      _ <- flushTracing 1000 runtime
      let probe = fromJust runtime.probe
      views <- readSpans probe
      seen <- spansSeen probe
      seen `shouldBe` 7
      length views `shouldBe` 4
      let child = fromJust (find ((== "child") . (.name)) views)
          parent = fromJust (find ((== "parent") . (.name)) views)
      child.traceId `shouldBe` parent.traceId
      child.parentSpanId `shouldBe` Just parent.spanId
      let correlation spanValue = case lookupAttribute spanValue.attributes "message.id" of Just (AttributeValue (TextAttribute value)) -> Just value; _ -> Nothing
          continuity = checkContinuity (SpanSelector (Just "parent") Nothing []) (SpanSelector (Just "child") Nothing []) correlation views
      continuity.violations `shouldBe` 0
      snd headers `shouldSatisfy` any ((== "traceparent") . fst)
      snapshot <- snapshotPipeline (fromJust runtime.pipeline)
      snapshot.spansEnded `shouldBe` 7
      snapshot.spansExportedOk `shouldBe` 7
      snapshot.spansDropped `shouldBe` 0
      _ <- stopTracing 1000 runtime
      pure ()

    it "exports plain and gzip OTLP requests to the built-in sink" do
      forCompression CompressionNone
      forCompression CompressionGzip

    it "accounts for alternating exporter failures exactly" do
      stats <- newPipelineStats
      calls <- newIORef (0 :: Int)
      let exporter =
            SpanExporter
              { spanExporterExport = \_ -> do
                  call <- atomicModifyIORef' calls (\value -> let next = value + 1 in (next, next))
                  pure (if even call then Failure Nothing else Success),
                spanExporterShutdown = pure ShutdownSuccess,
                spanExporterForceFlush = pure FlushSuccess
              }
      processor <- Simple.simpleProcessor (Simple.SimpleProcessorConfig (instrumentExporter stats exporter) 1_000_000)
      provider <- createTracerProvider [countingProcessor stats, processor] emptyTracerProviderOptions
      let tracer = makeTracer provider (instrumentationLibrary "pipeline-test" "1") tracerOptions
      replicateM_ 10 (inSpan tracer "alternating" defaultSpanArguments (pure ()))
      _ <- shutdownTracerProvider provider (Just 1_000_000)
      snapshot <- snapshotPipeline stats
      snapshot.spansEnded `shouldBe` snapshot.spansExportedOk + snapshot.spansExportFailed + snapshot.spansDropped
      snapshot.spansExportedOk `shouldBe` 5
      snapshot.spansExportFailed `shouldBe` 5

    it "drops instead of blocking when a batch queue is full" do
      stats <- newPipelineStats
      releaseExporter <- newEmptyMVar
      let exporter =
            SpanExporter
              { spanExporterExport = \_ -> readMVar releaseExporter >> pure Success,
                spanExporterShutdown = pure ShutdownSuccess,
                spanExporterForceFlush = pure FlushSuccess
              }
      processor <-
        Batch.batchProcessor
          Batch.batchTimeoutConfig
            { Batch.maxQueueSize = 8,
              Batch.scheduledDelayMillis = 10,
              Batch.maxExportBatchSize = 4,
              Batch.exportTimeoutMillis = 5_000
            }
          (instrumentExporter stats exporter)
      provider <- createTracerProvider [countingProcessor stats, processor] emptyTracerProviderOptions
      let tracer = makeTracer provider (instrumentationLibrary "backpressure-test" "1") tracerOptions
      completed <- timeout 1_000_000 (replicateM_ 10_000 (inSpan tracer "queued" defaultSpanArguments (pure ())))
      completed `shouldBe` Just ()
      beforeRelease <- snapshotPipeline stats
      beforeRelease.spansDropped `shouldSatisfy` (> 0)
      putMVar releaseExporter ()
      void (shutdownTracerProvider provider (Just 1_000_000))

  describe "metrics arms" do
    it "constructs no provider under off" do
      runtime <- startMetrics ((testSpec TracingOff) {metrics = MetricsOff})
      isNothing runtime.meter `shouldBe` True
      isNothing runtime.provider `shouldBe` True
      isNothing runtime.endpoint `shouldBe` True

    it "collects instruments without opening an endpoint" do
      runtime <- startMetrics ((testSpec TracingOff) {metrics = MetricsCollect})
      let meter = fromJust runtime.meter
      metrics <- newSyntheticMetrics meter
      void (runSyntheticOperation Nothing (Just metrics) 0 0 1)
      (snapshot, _) <- stopMetrics 1000 runtime
      runtime.endpoint `shouldBe` Nothing
      fmap (.instruments) snapshot `shouldBe` Just 2

    it "serves its Prometheus reader only for a serving arm" do
      runtime <- startMetrics ((testSpec TracingOff) {metrics = MetricsServe, otelReader = ReaderPrometheus})
      runtime.endpoint `shouldSatisfy` maybe False ((== PrometheusText) . (.kind))
      traverse_ (\endpoint -> awaitHttpReady endpoint.url 1000 >>= (`shouldBe` True)) runtime.endpoint
      void (stopMetrics 1000 runtime)

  describe "metrics scraper" do
    it "skips fixed-schedule ticks when an endpoint is slower than its interval" do
      withSlowHttpServer 75_000 \endpoint -> do
        let output = ".tmp/telemetry-test/slow-scrape"
        createDirectoryIfMissing True output
        scraper <- startScraperInProcess output 20 0
        scraper.register endpoint
        threadDelay 260_000
        summaries <- scraper.finish
        fmap (.skippedTicks) summaries `shouldSatisfy` any (> 0)

    it "detects exhausted WebSocket slots and accepts a correct server" do
      withWebSocketServer (Just 2) \leaky -> do
        result <- wsSlotLeakProbe leaky 2
        result.freshAccepted `shouldBe` False
      withWebSocketServer Nothing \correct -> do
        result <- wsSlotLeakProbe correct 2
        result.freshAccepted `shouldBe` True

testSpec :: TracingArm -> TelemetrySpec
testSpec tracing =
  TelemetrySpec
    { tracing,
      metrics = MetricsOff,
      serviceName = "kenshou.test",
      sampler = AlwaysOn,
      processor = SimpleProcessor 1000,
      exporter = HttpProtobuf,
      endpoint = BuiltinSink SinkHealthy,
      compression = CompressionNone,
      probeRetain = 16,
      shutdownMs = 1000,
      otelReader = ReaderNone,
      otelExportMs = 1000,
      scrapeMs = 1000,
      wsSubscribers = 0,
      helpers = HelperInProcess,
      workerContext = Nothing,
      outDir = ".tmp/telemetry-test",
      report = const (pure ())
    }

forCompression :: OtlpCompression -> IO ()
forCompression compression = Sink.withSink SinkHealthy \sink -> do
  let spec = (testSpec TracingSdkOtlp) {endpoint = ExternalEndpoint sink.endpoint, compression}
  runtime <- startTracing spec
  let tracer = fromJust runtime.tracer
  inSpan tracer "exported" defaultSpanArguments (pure ())
  _ <- flushTracing 2000 runtime
  _ <- stopTracing 2000 runtime
  stats <- sink.snapshot
  stats.spansReceived `shouldBe` 1

isNothing :: Maybe value -> Bool
isNothing Nothing = True
isNothing (Just _) = False

unique :: (Eq value) => [value] -> [value]
unique [] = []
unique (value : values) = value : unique (filter (/= value) values)

withSlowHttpServer :: Int -> (Endpoint -> IO value) -> IO value
withSlowHttpServer delayMicros action = withWarp application \port ->
  action (Endpoint "slow-json" JsonDocument (Text.pack ("http://127.0.0.1:" <> show port <> "/metrics")) Nothing)
  where
    application _ respond = threadDelay delayMicros >> respond (responseLBS status200 [] "delayed")

withWebSocketServer :: Maybe Int -> (Endpoint -> IO value) -> IO value
withWebSocketServer capacity action = do
  accepted <- newIORef (0 :: Int)
  withWarp (websocketsOr WebSockets.defaultConnectionOptions (server accepted) fallback) \port ->
    action (Endpoint "slot-probe" WebSocketPush (Text.pack ("ws://127.0.0.1:" <> show port <> "/ws")) Nothing)
  where
    server accepted pendingConnection = do
      count <- atomicModifyIORef' accepted (\value -> let next = value + 1 in (next, next))
      case capacity of
        Just limit | count > limit -> WebSockets.rejectRequest pendingConnection "slots exhausted"
        _ -> void (WebSockets.acceptRequest pendingConnection)
    fallback _ respond = respond (responseLBS status404 [] "not found")

withWarp :: Application -> (Int -> IO value) -> IO value
withWarp application action = bracket acquire release (\(port, _, _) -> action port)
  where
    acquire = do
      (port, socket) <- openFreePort
      server <- async (runSettingsSocket defaultSettings socket application)
      pure (port, server, socket)
    release (_, server, socket) = cancel server >> void (waitCatch server) >> close socket

traverse_ :: (a -> IO b) -> Maybe a -> IO ()
traverse_ _ Nothing = pure ()
traverse_ action (Just value) = void (action value)

overheadRequest :: Map Text.Text [Text.Text] -> OverheadRequest
overheadRequest factors =
  OverheadRequest
    { requestId = "test-overhead",
      scenarioId = armsScenario.id,
      factors,
      mode = OneFactor,
      includeControl = False,
      trials = 3,
      fixedKnobs = [],
      fixedDimensions = Map.empty,
      seed = 7,
      settleSeconds = 0,
      retries = 1
    }

blocks :: [Slot] -> [[Slot]]
blocks slots = [[slot | slot <- slots, slot.block == block] | block <- unique (fmap (.block) slots)]

isLeft :: Either left right -> Bool
isLeft (Left _) = True
isLeft (Right _) = False
