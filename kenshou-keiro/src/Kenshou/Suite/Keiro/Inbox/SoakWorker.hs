module Kenshou.Suite.Keiro.Inbox.SoakWorker (role, ProcessReport (..), withProcessConsumers, deliverInbox) where

import Control.Concurrent.STM (atomically, check)
import Control.Monad (forM)
import Data.Aeson (Value, encode, object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.ByteString.Lazy qualified as LBS
import Data.Functor.Contravariant (contramap)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx
import Keiro.Inbox (InboxDedupePolicy (..), InboxPersistence (..), InboxResult (..), runInboxTransactionWith)
import Keiro.Integration.Event (IntegrationEvent (..))
import Keiro.Telemetry (withConsumerSpan)
import Kenshou.Check.Process (ProgressSnapshot (..), awaitMark, awaitReady, childPid, progress, readChildMessages, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (ArtifactDir (..), RunContext (..), artifactPath, declareMediaType)
import Kenshou.Core.Id (unSeed)
import Kenshou.Core.Knob (knobInt, mkKnobName)
import Kenshou.Core.Role (ControlMessage (..), PostgresConnInfo (..), RoleContext (..), WorkerInit (..), WorkerMessage (..), WorkerRole (..), mkRoleName)
import Kenshou.Diagnose.Leak (LeakReport (..), ProbeReport (..), analyseSeriesDirectory)
import Kenshou.Suite.Keiro.Fixture.Runtime (FixtureEnv (..), KeiroRunner (..), KeiroTelemetry (..))
import Kenshou.Suite.Keiro.Inbox.Correctness (effectInsertStatement)
import Kenshou.Suite.Keiro.Messaging.Metrics (probeMessagingMetricsAt, withMessagingTelemetryAt)
import Kenshou.Suite.Keiro.Messaging.SoakDiagnosis (processLeakSpec, soakLeakSpec, withRoleSamples)
import Kenshou.Suite.Keiro.Outbox.Broker (BrokerRecord (..), toInboundRecord)
import Kenshou.Suite.Keiro.Outbox.Workload (inlineEvent)
import Kenshou.Telemetry (TelemetryHandles (..), telemetrySpecFromWorker)
import Kiroku.Store.Transaction (runTransaction)
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Timeout (timeout)
import Text.Read (readMaybe)

data ProcessReport = ProcessReport
  { stopped :: !Bool,
    errors :: !Int,
    workers :: ![Value],
    childLeaks :: ![LeakReport]
  }

roleName :: Text
roleName = "keiro/inbox-soak-consumer"

role :: WorkerRole
role = WorkerRole (either (error . Text.unpack) id (mkRoleName roleName)) "Consumes fresh or redelivered soak envelopes with process-local telemetry and resource samples." runConsumer

-- One caller owns each channel: the load generator sends fresh deliveries,
-- while the scheduled redelivery loop uses the other process. A single mark
-- is replaced for every response, keeping supervisor state bounded.
withProcessConsumers :: RunContext -> Text -> ((Text -> IntegrationEvent -> IO Text) -> IO value) -> IO (value, ProcessReport)
withProcessConsumers context source action = withCheck context \checkEnv -> withSupervisor checkEnv \supervisor -> do
  children <- forM [0, 1 :: Int] \index -> do
    spec <- roleProcess checkEnv roleName index (object ["source" .= source])
    child <- spawn supervisor spec
    awaitReady child 10000
    sendCommand child CtlStart
    awaitMark child "started" 10000
    pure child
  let deliver stage event = do
        let child = children !! (if stage == "fresh" then 0 else 1)
            request = object ["stage" .= stage, "messageId" .= event.messageId, "occurredAt" .= event.occurredAt]
        sendCommand child (CtlCustom "deliver" request)
        response <- timeout 10000000 $ atomically do
          snapshot <- progress child
          let decoded = Map.lookup "delivery" snapshot.marks >>= parseMaybe (withObject "delivery" \fields -> (,,) <$> fields .: "stage" <*> fields .: "messageId" <*> fields .: "classification")
          case decoded of
            Just (replyStage, identity, classification) -> check (replyStage == stage && identity == event.messageId) >> pure classification
            Nothing -> check False >> pure "unexpected"
        maybe (fail "inbox soak consumer did not answer within ten seconds") pure response
  value <- action deliver
  let knob key = fromIntegral (knobInt context.knobs (either (error . show) id (mkKnobName key)))
      grace = 30000 + 2 * knob "metrics.scrape-interval-ms" + 4 * knob "otel.shutdown-timeout-ms"
  exits <- traverse (\child -> stopGracefully supervisor child grace) children
  messages <- concat <$> traverse readChildMessages children
  let reports = [payload | WrkCustom "finished" payload <- messages]
      reportHeld payload = parseMaybe (withObject "consumer report" \fields -> (&&) <$> ((> (0 :: Int)) <$> fields .: "deliveries") <*> fields .: "metricsMatched") payload == Just True
      healthy = length reports == 2 && all reportHeld reports
      distinct = childPid (head children) /= childPid (children !! 1)
      duration = fromIntegral (knobInt context.knobs (either (error . show) id (mkKnobName "soak.duration-minutes"))) * 60
  leaks <- forM [0, 1 :: Int] \index -> do
    let label = "keiro-inbox-soak-consumer-" <> show index
    report <- analyseSeriesDirectory context.outDir (processLeakSpec ("children" </> label) (soakLeakSpec context duration)) (unSeed context.seed)
    let named = report {probes = [probe {process = Text.pack label} | probe <- report.probes]}
        file = "leak-" <> label <> ".json"
    path <- artifactPath context DiagnosisDir file
    LBS.writeFile path (encode named)
    declareMediaType context ("diagnosis" </> file) "application/json"
    pure named
  pure (value, ProcessReport (distinct && healthy && all (== ExitSuccess) exits) (length [() | WrkError _ <- messages]) reports leaks)

-- The soak uses synthetic envelopes, not a live Kafka broker. The consumer
-- span wraps the same transactional inbox call used by both isolation arms.
deliverInbox :: FixtureEnv -> TelemetryHandles -> IntegrationEvent -> IO Text
deliverInbox fixture telemetry event = do
  now <- getCurrentTime
  let record = BrokerRecord event.destination 0 0 Nothing event.payloadBytes [] event.occurredAt "inbox-soak" 1
      KeiroRunner runFixture = fixture.runner
  result <- withConsumerSpan telemetry.tracer (Just "kenshou-inbox-soak") (toInboundRecord now record) (Just event) \_ ->
    runFixture (runInboxTransactionWith fixture.telemetry.keiroMetrics PersistDedupeOnly PreferIntegrationMessageId event Nothing (\item -> Tx.statement item.messageId effectInsertStatement))
  pure case result of
    Right (Right (InboxProcessed ())) -> "processed"
    Right (Right InboxDuplicate) -> "duplicate"
    _ -> "unexpected"

runConsumer :: RoleContext -> IO ()
runConsumer context = case (context.init.postgres, parseMaybe (withObject "soak consumer" (.: "source")) context.init.args) of
  (Just postgres, Just source) -> do
    context.send WrkReady
    context.receive >>= \case
      Just CtlStart -> do
        let label = Text.replace "/" "-" context.init.instanceName
            directory = context.init.outDir </> "children" </> Text.unpack label
            report value = do
              createDirectoryIfMissing True (directory </> "logs")
              LBS.writeFile (directory </> "logs" </> "messaging-store-metrics.json") (encode value)
        spec <- either (fail . Text.unpack) pure (telemetrySpecFromWorker context directory)
        withRoleSamples context $ withMessagingTelemetryAt postgres.connectionString report spec \fixture telemetry endpoints -> do
          let KeiroRunner runFixture = fixture.runner
              insert = Statement.preparable "INSERT INTO kenshou_fx.inbox_soak_deliveries (worker, stage, message_id, classification) VALUES ($1,$2,$3,$4)" (contramap (\(a, _, _, _) -> a) textParam <> contramap (\(_, b, _, _) -> b) textParam <> contramap (\(_, _, c, _) -> c) textParam <> contramap (\(_, _, _, d) -> d) textParam) Decoders.noResult
              counts = Statement.preparable "SELECT classification, count(*)::integer FROM kenshou_fx.inbox_soak_deliveries WHERE worker=$1 GROUP BY classification" textParam (Decoders.rowList ((,) <$> Decoders.column (Decoders.nonNullable Decoders.text) <*> Decoders.column (Decoders.nonNullable Decoders.int4)))
              loop =
                context.receive >>= \case
                  Just (CtlCustom "deliver" args) -> do
                    (stage, identity, at) <- maybe (fail "invalid inbox soak delivery") pure (parseMaybe (withObject "delivery args" \fields -> (,,) <$> fields .: "stage" <*> fields .: "messageId" <*> fields .: "occurredAt") args)
                    sequenceNumber <- maybe (fail "invalid inbox soak message ID") pure (readMaybe (Text.unpack identity))
                    classification <- deliverInbox fixture telemetry (inlineEvent source identity Nothing sequenceNumber at)
                    runFixture (runTransaction (Tx.statement (label, stage, identity, classification) insert)) >>= either (fail . show) pure
                    context.send (WrkCustom "delivery" (object ["stage" .= stage, "messageId" .= identity, "classification" .= classification]))
                    loop
                  Just (CtlStop _) -> pure ()
                  Nothing -> fail "inbox soak controller disconnected"
                  _ -> loop
          context.send (WrkCustom "started" (object []))
          loop
          classifications <- runFixture (runTransaction (Tx.statement label counts)) >>= either (fail . show) pure
          _ <- telemetry.flushTelemetry
          sums <- telemetry.readMetricSums
          let total category = sum [fromIntegral count :: Double | (name, count) <- classifications, name == category]
              metric name = sum [value | (key, value) <- sums, key == name]
              matched = not telemetry.metricsLive || (metric "keiro.inbox.processed" == total "processed" && metric "keiro.inbox.duplicates" == total "duplicate" && metric "keiro.inbox.failed" == 0)
              expected = [("keiro_inbox_" <> category <> "{job=\"kenshou\"}", total classification) | (category, classification) <- [("processed", "processed"), ("duplicates", "duplicate")], total classification > 0]
          served <- probeMessagingMetricsAt directory telemetry endpoints "complete" expected
          context.send (WrkCustom "finished" (object ["worker" .= label, "deliveries" .= sum (map snd classifications), "processed" .= total "processed", "duplicates" .= total "duplicate", "metricsMatched" .= (matched && served && total "unexpected" == 0)]))
        context.send (WrkDone Nothing)
      _ -> fail "inbox soak consumer requires start"
  _ -> fail "inbox soak consumer requires PostgreSQL and a source"
  where
    textParam = Encoders.param (Encoders.nonNullable Encoders.text)
