{-# LANGUAGE BangPatterns #-}

module Kenshou.Suite.Keiro.Outbox.SoakPublisher
  ( role,
    PublisherReport (..),
    withProcessPublishers,
    publisherLeakSpec,
    duplicatesWithinCrashBatches,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (cancel, link, withAsync)
import Control.Concurrent.MVar (modifyMVar_, newMVar, readMVar, withMVar)
import Control.Exception (mask_)
import Control.Monad (forM, forever, unless, when)
import Data.Aeson (encode, object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx
import Keiro.Integration.Event (IntegrationEvent (..))
import Keiro.Outbox (OutboxPublishOptions (..), OutboxPublishSummary (..), OutboxRow (..), defaultPublishOptions, publishClaimedOutbox)
import Kenshou.Check.Process (awaitMark, awaitReady, childPid, killChild, readChildMessages, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (ArtifactDir (..), RunContext (..), artifactPath, declareMediaType)
import Kenshou.Core.Id (unSeed)
import Kenshou.Core.Knob (knobInt, mkKnobName)
import Kenshou.Core.Role (ControlMessage (..), PostgresConnInfo (..), RoleContext (..), WorkerInit (..), WorkerMessage (..), WorkerRole (..), mkRoleName)
import Kenshou.Diagnose.Leak (LeakReport (..), LeakSpec, ProbeReport (..), analyseSeriesDirectory)
import Kenshou.Suite.Keiro.Fixture.Runtime (FixtureEnv (..), KeiroRunner (..), KeiroTelemetry (..))
import Kenshou.Suite.Keiro.Messaging.Metrics (probeMessagingMetricsAt, withMessagingTelemetryAt)
import Kenshou.Suite.Keiro.Messaging.SoakDiagnosis (processLeakSpec, soakLeakSpec, withRoleSamples)
import Kenshou.Suite.Keiro.Outbox.Broker qualified as Broker
import Kenshou.Telemetry (TelemetryHandles (..), telemetrySpecFromWorker)
import Kiroku.Store.Transaction (runTransaction)
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))

data PublisherReport = PublisherReport
  { kills :: !Int,
    errors :: !Int,
    stopped :: !Bool,
    crashedBatches :: ![[Text]],
    childLeaks :: ![LeakReport]
  }

role :: WorkerRole
role = WorkerRole (either (error . Text.unpack) id (mkRoleName roleName)) "Continuously publishes outbox rows with per-incarnation resource samples and an armed post-append crash boundary." runPublisher

roleName :: Text
roleName = "keiro/outbox-soak-publisher"

-- Each incarnation owns separate files: a fresh process's clock and heap must
-- never be joined to its predecessor's resource series.
withProcessPublishers :: RunContext -> Int -> (IO () -> IO value) -> IO (value, PublisherReport)
withProcessPublishers context killInterval action = withCheck context \check -> withSupervisor check \supervisor -> do
  history <- newIORef []
  killCount <- newIORef (0 :: Int)
  crashed <- newIORef []
  errorCount <- newIORef (0 :: Int)
  let start index = do
        spec <- roleProcess check roleName index (object [])
        child <- spawn supervisor spec
        atomicModifyIORef' history (\indices -> (index : indices, ()))
        awaitReady child 10000
        sendCommand child CtlStart
        awaitMark child "started" 10000
        pure child
      collectErrors child = do
        messages <- readChildMessages child
        atomicModifyIORef' errorCount (\count -> (count + length [() | WrkError _ <- messages], ()))
        pure messages
  first <- start 0
  second <- start 1
  current <- newMVar first
  let restartLoop index = do
        threadDelay (killInterval * 1000000)
        mask_ $ modifyMVar_ current \old -> do
          sendCommand old (CtlCustom "arm-crash" (object []))
          awaitMark old "crash-window" 10000
          killChild supervisor old
          messages <- collectErrors old
          case [identifiers | WrkCustom "crash-window" payload <- messages, Just identifiers <- [parseMaybe (withObject "crash window" (.: "messageIds")) payload]] of
            [identifiers] | not (null identifiers) -> atomicModifyIORef' crashed (\batches -> (identifiers : batches, ()))
            _ -> fail "outbox publisher did not retain its armed crash batch"
          atomicModifyIORef' killCount (\count -> (count + 1, ()))
          replacement <- start index
          pure replacement
        restartLoop (index + 1)
  value <- withAsync (if killInterval == 0 then pure () else restartLoop 2) \killer -> do
    link killer
    -- Quiesce between complete restarts. Cancelling while a child is parked
    -- but before its SIGKILL is recorded would create an unbudgeted duplicate.
    action (withMVar current (const (cancel killer)))
  active <- readMVar current
  let grace = 30000 + 2 * fromIntegral (integer "metrics.scrape-interval-ms") + 4 * fromIntegral (integer "otel.shutdown-timeout-ms")
  exits <- traverse (\child -> stopGracefully supervisor child grace) [active, second]
  mapM_ collectErrors [active, second]
  indices <- reverse <$> readIORef history
  errors <- readIORef errorCount
  count <- readIORef killCount
  batches <- reverse <$> readIORef crashed
  let duration = fromIntegral (integer "soak.duration-minutes") * 60
  leaks <- forM indices \index -> do
    let label = "keiro-outbox-soak-publisher-" <> show index
        spec = publisherLeakSpec ("children" </> label) (soakLeakSpec context duration)
    report <- analyseSeriesDirectory context.outDir spec (unSeed context.seed)
    let LeakReport verdict window seed policy probes = report
        named = LeakReport verdict window seed policy [probe {process = Text.pack label} | probe <- probes]
        file = "leak-" <> label <> ".json"
    path <- artifactPath context DiagnosisDir file
    LazyByteString.writeFile path (encode named)
    declareMediaType context ("diagnosis" </> file) "application/json"
    pure named
  pure (value, PublisherReport count errors (all (== ExitSuccess) exits && childPid first /= childPid second) batches leaks)
  where
    integer key = knobInt context.knobs (either (error . show) id (mkKnobName key))

publisherLeakSpec :: FilePath -> LeakSpec -> LeakSpec
publisherLeakSpec = processLeakSpec

-- A repeated broker append needs a recorded crash of that exact message,
-- rather than borrowing the unused duplicate allowance of an unrelated batch.
duplicatesWithinCrashBatches :: [[Text]] -> [Text] -> Bool
duplicatesWithinCrashBatches crashed received =
  all (\(message, count) -> count <= 1 + Map.findWithDefault 0 message budget) (Map.toList counts)
  where
    counts = Map.fromListWith (+) [(message, 1 :: Int) | message <- received]
    budget = Map.fromListWith (+) [(message, 1 :: Int) | batch <- crashed, message <- Map.keys (Map.fromList [(identity, ()) | identity <- batch])]

runPublisher :: RoleContext -> IO ()
runPublisher context = case context.init.postgres of
  Nothing -> context.send (WrkError "outbox soak publisher requires PostgreSQL")
  Just postgres -> do
    context.send WrkReady
    context.receive >>= \case
      Just CtlStart -> do
        let label = Text.replace "/" "-" context.init.instanceName
            directory = context.init.outDir </> "children" </> Text.unpack label
            report value = do
              createDirectoryIfMissing True (directory </> "logs")
              LazyByteString.writeFile (directory </> "logs" </> "messaging-store-metrics.json") (encode value)
        spec <- either (fail . Text.unpack) pure (telemetrySpecFromWorker context directory)
        withMessagingTelemetryAt postgres.connectionString report spec \fixture telemetry endpoints ->
          Broker.withTableBroker postgres.connectionString \broker -> withRoleSamples context do
            stopped <- newIORef False
            armed <- newIORef False
            let KeiroRunner runFixture = fixture.runner
                batch = fromIntegral (integer "outbox.batch-size")
                options = defaultPublishOptions {batchSize = batch, publishingTimeout = 10, tracer = fixture.telemetry.keiroTracer}
                receive =
                  context.receive >>= \case
                    Just (CtlStop _) -> writeIORef stopped True
                    Nothing -> writeIORef stopped True
                    Just (CtlCustom "arm-crash" _) -> writeIORef armed True >> receive
                    Just _ -> receive
                hooks = Broker.PublishHook (const (pure ())) \rows -> do
                  park <- readIORef armed
                  when park do
                    context.send (WrkCustom "crash-window" (object ["rows" .= length rows, "messageIds" .= map ((.messageId) . (.event)) rows]))
                    forever (threadDelay 1000000)
                publish = Broker.publishScripted broker (Broker.BrokerModel 0 0 4) (const Broker.Succeed) hooks context.init.instanceName
                loop !published = do
                  stop <- readIORef stopped
                  if stop
                    then pure published
                    else do
                      result <- runFixture (publishClaimedOutbox publish options fixture.telemetry.keiroMetrics)
                      case result of
                        Left err -> context.send (WrkError (Text.pack (show err))) >> threadDelay 100000 >> loop published
                        Right summary -> do
                          when (summary.claimed == 0) (threadDelay 20000)
                          loop (published + summary.published)
            published <- withAsync receive \receiver -> do
              link receiver
              context.send (WrkCustom "started" (object []))
              loop 0
            let count = Statement.preparable "SELECT count(*) FROM kenshou_fx.broker_log WHERE publisher=$1" (Encoders.param (Encoders.nonNullable Encoders.text)) (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))
            appended <- runFixture (runTransaction (Tx.statement context.init.instanceName count)) >>= either (fail . show) pure
            _ <- telemetry.flushTelemetry
            sums <- telemetry.readMetricSums
            let matched = fromIntegral published == appended && (not telemetry.metricsLive || sum [value | (key, value) <- sums, key == "keiro.outbox.published"] == fromIntegral appended)
            served <- probeMessagingMetricsAt directory telemetry endpoints "complete" [("keiro_outbox_published{job=\"kenshou\"}", fromIntegral appended)]
            unless (matched && served) (context.send (WrkError "outbox publisher telemetry disagrees with its SQL broker records"))
            context.send (WrkCustom "telemetry-checked" (object ["published" .= published, "brokerRecords" .= appended, "matched" .= (matched && served)]))
        context.send (WrkDone Nothing)
      _ -> pure ()
  where
    integer key = knobInt context.init.knobs (either (error . show) id (mkKnobName key))
