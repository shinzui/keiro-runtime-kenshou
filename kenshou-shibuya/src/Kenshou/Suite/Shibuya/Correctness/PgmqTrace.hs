{-# LANGUAGE BlockArguments #-}

module Kenshou.Suite.Shibuya.Correctness.PgmqTrace (scenario) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, displayException, try)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Foldable (traverse_)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (find, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (liftIO, runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension (DimensionSupport (..), MetricsArm (..), PgDurability (..), PgVersion (..), Support (..), Supported (..), TracingArm (..))
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Suite.Shibuya.Fixture.Pgmq (PgmqFixture (..), queueHeaders, queueRows, runPgmqStack, withPgmqFixture)
import Kenshou.Telemetry (TelemetryHandles (..), telemetryKnobs, telemetrySpecFromContext, withTelemetry)
import Kenshou.Telemetry.Tracing.Probe (SpanView (..), readSpans)
import OpenTelemetry.Attributes (lookupAttribute, toAttribute)
import OpenTelemetry.Trace.Core (SpanKind (..))
import OpenTelemetry.Trace.Id (Base (..), spanIdBaseEncodedText, traceIdBaseEncodedText)
import Pgmq.Effectful (MessageBody (..), MessageHeaders (..), PgmqRuntimeError, SendMessageWithHeaders (..), runPgmq, sendMessageWithHeaders)
import Shibuya.Adapter.Pgmq (PgmqAdapterConfig (..), PollingConfig (..), defaultConfig, directDeadLetter, mkPgmqAdapterEnv, pgmqAdapter)
import Shibuya.App (QueueProcessor (..), defaultAppConfig, defaultShutdownConfig, mkProcessor, runApp, stopAppGracefully, waitApp)
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..))
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Core.Types (Envelope (..))
import Shibuya.Policy (Concurrency (..))
import Shibuya.Telemetry.Effect (runTracing)
import System.Timeout (timeout)

scenario :: Scenario
scenario =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/pgmq-adapter/correctness/trace-continuity"),
      revision = 1,
      summary = "Checks per-message W3C parents, acknowledgement spans, and DLQ trace headers.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = telemetryKnobs,
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingSdkInMemory :| [TracingOff]) TracingSdkInMemory),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| [Pg17]) Pg18)
          },
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaPgmq] [] False)},
      knownDefect = Nothing,
      run = runTraceContinuity
    }

runTraceContinuity :: RunContext -> IO ScenarioReport
runTraceContinuity context = case telemetrySpecFromContext context of
  Left problem -> pure (failedWith ["invalid-telemetry-config"] problem)
  Right telemetrySpec -> do
    outcome <- try @SomeException $
      timeout 45000000 $
        withPgmqFixture context "trace_source" 10 \source ->
          withPgmqFixture context "trace_dlq" 2 \deadLetter ->
            withTelemetry telemetrySpec \telemetry -> runArm context source deadLetter telemetry
    case outcome of
      Left err -> pure (failedWith ["trace-continuity-exception"] (Text.pack (displayException err)))
      Right Nothing -> pure (failedWith ["trace-continuity-timeout"] "PGMQ trace continuity did not finish within 45 seconds")
      Right (Just report) -> pure report

runArm :: RunContext -> PgmqFixture -> PgmqFixture -> TelemetryHandles -> IO ScenarioReport
runArm context source deadLetter telemetry = do
  let tracingOn = isJust telemetry.tracer
      entries =
        [ ("first", firstTraceparent),
          ("second", secondTraceparent),
          ("dlq", thirdTraceparent)
        ]
  traverse_ (sendTraced source) entries
  handled <- newIORef ([] :: [Text])
  let config = (defaultConfig source.queue) {polling = StandardPolling 0.05, deadLetterConfig = Just (directDeadLetter deadLetter.queue True)}
      handler Message {envelope = Envelope {payload}} = do
        let label = case payload of
              String value -> value
              _ -> "unexpected-payload"
        liftIO $ atomicModifyIORef' handled (\seen -> (label : seen, ()))
        pure $ if label == "dlq" then AckDeadLetter (PoisonPill "trace") else AckOk
      flow = do
        adapterResult <- pgmqAdapter (mkPgmqAdapterEnv source.pool) config
        adapter <- either (error . show) pure adapterResult
        started <- runApp defaultAppConfig [(ProcessorId "pgmq-trace", (mkProcessor adapter handler) {concurrency = Async 8})]
        application <- either (error . show) pure started
        completed <- liftIO $ timeout 15000000 (awaitComplete source deadLetter handled)
        drained <- stopAppGracefully defaultShutdownConfig application
        waitApp application
        pure (isJust completed, drained)
  result <- case telemetry.tracer of
    Just tracer -> runEff (runErrorNoCallStack @PgmqRuntimeError (runTracing tracer (runPgmq source.pool flow)))
    Nothing -> runPgmqStack source.pool flow
  (completed, drained) <- either (ioError . userError . show) pure result
  _ <- telemetry.flushTelemetry
  spans <- maybe (pure []) readSpans telemetry.spans
  dlqHeaders <- queueHeaders deadLetter
  seen <- reverse <$> readIORef handled
  let consumers = filter (\candidate -> candidate.kind == Consumer && candidate.name == "pgmq-trace process") spans
      expected :: [(Text, Text)]
      expected =
        [ (firstTraceparent, "ack_ok"),
          (secondTraceparent, "ack_ok"),
          (thirdTraceparent, "ack_dead_letter")
        ]
      spanMatches (parentHeader, decision) =
        case parseTraceparent parentHeader of
          Nothing -> False
          Just (traceId, parentId) ->
            case find (\candidate -> traceIdBaseEncodedText Base16 candidate.traceId == traceId) consumers of
              Nothing -> False
              Just candidate ->
                fmap (spanIdBaseEncodedText Base16) candidate.parentSpanId == Just parentId
                  && lookupAttribute candidate.attributes "messaging.system" == Just (toAttribute ("shibuya" :: Text))
                  && lookupAttribute candidate.attributes "shibuya.ack.decision" == Just (toAttribute decision)
      dlqMatches = case dlqHeaders of
        [Just (Object headers)] ->
          let upstream = KeyMap.lookup "x-shibuya-upstream-traceparent" headers
              active = KeyMap.lookup "traceparent" headers
              marker = KeyMap.lookup "kenshou-marker" headers
              expectedActive = do
                candidate <- find (\current -> traceIdBaseEncodedText Base16 current.traceId == thirdTraceId) consumers
                String header <- active
                (traceId, spanId) <- parseTraceparent header
                pure (traceId == thirdTraceId && spanId == spanIdBaseEncodedText Base16 candidate.spanId)
           in marker == Just (String "dlq")
                && if tracingOn
                  then upstream == Just (String thirdTraceparent) && expectedActive == Just True
                  else upstream == Nothing && active == Just (String thirdTraceparent)
        _ -> False
      failures =
        ["pgmq-trace-delivery" | not completed || not drained || sort seen /= ["dlq", "first", "second"]]
          <> ["pgmq-trace-span-count" | (tracingOn && length consumers /= 3) || (not tracingOn && not (null consumers))]
          <> ["pgmq-trace-parent-or-decision" | tracingOn && not (all spanMatches expected)]
          <> ["pgmq-trace-dlq-headers" | not dlqMatches]
  putSummary context Verdicts "pgmq-trace-continuity" $
    object
      [ "tracingOn" .= tracingOn,
        "handled" .= seen,
        "consumerSpans" .= length consumers,
        "parentAndDecisionMatched" .= (tracingOn && all spanMatches expected),
        "dlqHeaders" .= dlqHeaders,
        "dlqHeadersMatched" .= dlqMatches,
        "completed" .= completed,
        "drained" .= drained
      ]
  pure $ if null failures then passed else failedWith failures (Text.intercalate "; " failures)

awaitComplete :: PgmqFixture -> PgmqFixture -> IORef [Text] -> IO ()
awaitComplete source deadLetter handled = do
  sourceCount <- queueRows source
  deadLetterCount <- queueRows deadLetter
  count <- length <$> readIORef handled
  if sourceCount == 0 && deadLetterCount == 1 && count >= 3
    then pure ()
    else threadDelay 10000 >> awaitComplete source deadLetter handled

sendTraced :: PgmqFixture -> (Text, Text) -> IO ()
sendTraced source (label, traceparent) = do
  let headers = MessageHeaders (object ["traceparent" .= traceparent, "kenshou-marker" .= label])
      message = SendMessageWithHeaders source.queue (MessageBody (String label)) headers Nothing
  sent <- runPgmqStack source.pool (sendMessageWithHeaders message)
  either (ioError . userError . show) (const (pure ())) sent

parseTraceparent :: Text -> Maybe (Text, Text)
parseTraceparent value = case Text.splitOn "-" value of
  ["00", traceId, spanId, _flags] -> Just (traceId, spanId)
  _ -> Nothing

firstTraceparent, secondTraceparent, thirdTraceparent, thirdTraceId :: Text
firstTraceparent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
secondTraceparent = "00-1af7651916cd43dd8448eb211c80319d-c7ad6b7169203332-01"
thirdTraceparent = "00-2af7651916cd43dd8448eb211c80319e-d7ad6b7169203333-01"
thirdTraceId = "2af7651916cd43dd8448eb211c80319e"
