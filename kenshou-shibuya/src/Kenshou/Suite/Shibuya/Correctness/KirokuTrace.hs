{-# LANGUAGE BlockArguments #-}

module Kenshou.Suite.Shibuya.Correctness.KirokuTrace (scenario) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, displayException, try)
import Data.Aeson (object, (.=))
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (liftIO, runEff)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension (DimensionSupport (..), MetricsArm (..), PgDurability (..), PgVersion (..), Support (..), Supported (..), TracingArm (..))
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Suite.Shibuya.Fixture.Kiroku (KirokuFixture (..), checkpointOf, eventPositions, subscriptionFor, withKirokuFixture)
import Kenshou.Telemetry (TelemetryHandles (..), telemetryKnobs, telemetrySpecFromContext, withTelemetry)
import Kenshou.Telemetry.Tracing.Probe (SpanView (..), readSpans)
import Kiroku.Store (EventData (..), EventType (..), ExpectedVersion (..), appendToStream, runStoreIO)
import OpenTelemetry.Attributes (lookupAttribute, toAttribute)
import OpenTelemetry.Trace.Core (SpanKind (..))
import OpenTelemetry.Trace.Id (Base (..), spanIdBaseEncodedText, traceIdBaseEncodedText)
import Shibuya.Adapter.Kiroku (SubscriptionName, SubscriptionTarget (..), defaultKirokuAdapterConfig, kirokuAdapter)
import Shibuya.App (QueueProcessor (..), defaultAppConfig, defaultShutdownConfig, mkProcessor, runApp, stopAppGracefully, waitApp)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Policy (Concurrency (..), OrderingPolicy (..))
import Shibuya.Telemetry.Effect (runTracing)
import System.Timeout (timeout)

scenario :: Scenario
scenario =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/kiroku-adapter/correctness/trace-continuity"),
      revision = 1,
      summary = "Checks distinct W3C event metadata parents and acknowledgement spans through a real subscription.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = telemetryKnobs,
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingSdkInMemory :| []) TracingSdkInMemory),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| [Pg17]) Pg18)
          },
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku] [] False)},
      knownDefect = Nothing,
      run = runTraceContinuity
    }

runTraceContinuity :: RunContext -> IO ScenarioReport
runTraceContinuity context = case telemetrySpecFromContext context of
  Left problem -> pure (failedWith ["invalid-telemetry-config"] problem)
  Right telemetrySpec -> do
    outcome <- try @SomeException $
      timeout 45000000 $
        withKirokuFixture context \fixture ->
          withTelemetry telemetrySpec \telemetry -> runArm context fixture telemetry
    case outcome of
      Left err -> pure (failedWith ["trace-continuity-exception"] (Text.pack (displayException err)))
      Right Nothing -> pure (failedWith ["trace-continuity-timeout"] "Kiroku trace continuity did not finish within 45 seconds")
      Right (Just report) -> pure report

runArm :: RunContext -> KirokuFixture -> TelemetryHandles -> IO ScenarioReport
runArm context fixture telemetry = do
  tracer <- maybe (ioError (userError "in-memory telemetry has no tracer")) pure telemetry.tracer
  probe <- maybe (ioError (userError "in-memory telemetry has no span probe")) pure telemetry.spans
  let headers = [firstTraceparent, secondTraceparent, thirdTraceparent]
      event number traceparent =
        EventData
          Nothing
          (EventType "KenshouTrace")
          (object ["sequence" .= number])
          (Just (object ["traceparent" .= traceparent]))
          Nothing
          Nothing
  appended <- runStoreIO fixture.store (appendToStream fixture.stream NoStream (zipWith event ([1 ..] :: [Int]) headers))
  either (ioError . userError . show) (const (pure ())) appended
  positions <- eventPositions fixture
  lastPosition <- case reverse positions of
    position : _ | length positions == 3 -> pure position
    _ -> ioError (userError "fixture did not append exactly three trace events")
  let subscription = subscriptionFor fixture "trace"
  delivered <- newIORef (0 :: Int)
  (completed, drained) <- runEff $ runTracing tracer $ do
    adapter <- kirokuAdapter fixture.store (defaultKirokuAdapterConfig subscription (Category fixture.category))
    let handler _ = do
          liftIO $ atomicModifyIORef' delivered (\count -> (count + 1, ()))
          pure AckOk
        processor = (mkProcessor adapter handler) {ordering = Unordered, concurrency = Async 8}
    started <- runApp defaultAppConfig [(ProcessorId "kiroku-trace", processor)]
    application <- either (error . show) pure started
    caughtUp <- liftIO $ timeout 15000000 (awaitCheckpoint fixture subscription lastPosition)
    drained <- stopAppGracefully defaultShutdownConfig application
    waitApp application
    pure (maybe False (const True) caughtUp, drained)
  _ <- telemetry.flushTelemetry
  spans <- readSpans probe
  count <- readIORef delivered
  checkpoint <- checkpointOf fixture subscription 0
  let consumers = filter (\candidate -> candidate.kind == Consumer && candidate.name == "kiroku-trace process") spans
      expected :: [(Text, Text)]
      expected =
        [ (firstTraceparent, "ack_ok"),
          (secondTraceparent, "ack_ok"),
          (thirdTraceparent, "ack_ok")
        ]
      spanMatches (parentHeader, decision) =
        case parseTraceparent parentHeader of
          Nothing -> False
          Just (traceId, parentId) ->
            case find (\candidate -> traceIdBaseEncodedText Base16 candidate.traceId == traceId) consumers of
              Nothing -> False
              Just candidate ->
                fmap (spanIdBaseEncodedText Base16) candidate.parentSpanId == Just parentId
                  && lookupAttribute candidate.attributes "messaging.system" == Just (toAttribute ("kiroku" :: Text))
                  && lookupAttribute candidate.attributes "shibuya.ack.decision" == Just (toAttribute decision)
      matched = all spanMatches expected
      failures =
        ["kiroku-trace-delivery" | not completed || not drained || count /= 3 || checkpoint /= Just lastPosition]
          <> ["kiroku-trace-span-count" | length consumers /= 3]
          <> ["kiroku-trace-parent-or-decision" | not matched]
  putSummary context Verdicts "kiroku-trace-continuity" $
    object
      [ "delivered" .= count,
        "consumerSpans" .= length consumers,
        "parentAndDecisionMatched" .= matched,
        "checkpoint" .= checkpoint,
        "lastPosition" .= lastPosition,
        "completed" .= completed,
        "drained" .= drained
      ]
  pure $ if null failures then passed else failedWith failures (Text.intercalate "; " failures)

awaitCheckpoint :: KirokuFixture -> SubscriptionName -> Int64 -> IO ()
awaitCheckpoint fixture subscription position = do
  checkpoint <- checkpointOf fixture subscription 0
  if checkpoint == Just position
    then pure ()
    else threadDelay 10000 >> awaitCheckpoint fixture subscription position

parseTraceparent :: Text -> Maybe (Text, Text)
parseTraceparent value = case Text.splitOn "-" value of
  ["00", traceId, spanId, _flags] -> Just (traceId, spanId)
  _ -> Nothing

firstTraceparent, secondTraceparent, thirdTraceparent :: Text
firstTraceparent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
secondTraceparent = "00-1af7651916cd43dd8448eb211c80319d-c7ad6b7169203332-01"
thirdTraceparent = "00-2af7651916cd43dd8448eb211c80319e-d7ad6b7169203333-01"
