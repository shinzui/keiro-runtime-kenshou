module Kenshou.Suite.Pgmq.Bench.Runner (runBenchmark) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, wait)
import Control.Exception (SomeException, try)
import Control.Monad (forM_, when)
import Data.Aeson (object, (.=))
import Data.Int (Int32)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Data.Word (Word64)
import Effectful qualified
import Effectful.Error.Static qualified
import Hasql.Pool qualified as Pool
import Kenshou.Core.Context (RunContext (..), SummarySection (Verdicts), putSummary, requirePostgres)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Knob (knobBool, knobInt, knobText)
import Kenshou.Core.Scenario (ScenarioReport (..), failedWith, passed)
import Kenshou.Measure.Knobs (loadModelFromKnobs)
import Kenshou.Measure.Load (ClosedConfig (..), LoadModel (..), LoadReport (..), Operation (..), runLoad)
import Kenshou.Measure.Recorder (ErrorCause (..), OpName (..), OpResult (..))
import Kenshou.Measure.Session (MeasurementReport (..), measureConfigFromKnobs, measuredOutcome, phasePlanFromCore, withMeasurement)
import Kenshou.Suite.Pgmq.Client
import Kenshou.Suite.Pgmq.Harness
import Kenshou.Suite.Pgmq.Knobs (AckMode (..), PgmqKnobs (..), ReadStrategy (..), knobName)
import Kenshou.Suite.Pgmq.Listener (awaitNotifications, withListener)
import Kenshou.Telemetry (TelemetryHandles (..))
import Pgmq.Effectful qualified as Pgmq
import Pgmq.Effectful.Effect qualified as PgmqEffect
import Pgmq.Hasql.Sessions qualified as Sessions
import Pgmq.Hasql.Statements.Types qualified as Types
import Pgmq.Types qualified as PgmqTypes

runBenchmark :: Text -> RunContext -> Maybe (IO ScenarioReport)
runBenchmark identifier context
  | identifier `elem` benchmarkIds = Just (runMeasured identifier context)
  | otherwise = Nothing

benchmarkIds :: [Text]
benchmarkIds =
  [ "pgmq/effectful/benchmark/layer-ladder",
    "pgmq/send/benchmark/send-throughput",
    "pgmq/read/benchmark/read-ack-throughput",
    "pgmq/read/benchmark/produce-consume-latency",
    "pgmq/read/benchmark/invisible-backlog-read-cost",
    "pgmq/fifo/benchmark/grouped-read-cost",
    "pgmq/notify/benchmark/notify-insert-overhead",
    "pgmq/effectful/benchmark/interpreter-tracing-overhead",
    "pgmq/queue/benchmark/metrics-poll-overhead"
  ]

runMeasured :: Text -> RunContext -> IO ScenarioReport
runMeasured identifier context = case (loadModelFromKnobs context.knobs, measureConfigFromKnobs context (phasePlanFromCore context.phases), parseLayer (knobText context.knobs (knobName "pgmq.layer"))) of
  (Left message, _, _) -> pure (failedWith ["invalid-load-config"] message)
  (_, Left message, _) -> pure (failedWith ["invalid-measure-config"] message)
  (_, _, Left message) -> pure (failedWith ["invalid-client-layer"] message)
  (Right loadModel, Right measureConfig, Right selectedLayer) ->
    withPgmqRun context \runtime ->
      case benchmarkLoadConfiguration identifier context runtime.knobs loadModel of
        Left message -> pure (failedWith ["invalid-read-ack-configuration"] message)
        Right effectiveLoadModel ->
          withScenarioQueue runtime.pool context runtime.knobs "benchmark" \queue -> do
            prepare identifier runtime queue
            let layer = if "layer-ladder" `Text.isInfixOf` identifier then selectedLayer else EffectfulLayer
                client = mkClient layer runtime.tracer runtime.pool
                operation = Operation (OpName (operationName identifier layer)) (runOperation identifier runtime client queue)
            (_, report) <- withMeasurement context measureConfig (\measurement -> runLoad measurement effectiveLoadModel operation)
            let failures = sum [load.failed | load <- report.loads]
                base = if failures == 0 then passed else failedWith ["operation-errors"] ("failed operations=" <> Text.pack (show failures))
                readAckFields =
                  if identifier == "pgmq/read/benchmark/read-ack-throughput"
                    then
                      [ "readStrategy" .= show runtime.knobs.readStrategy,
                        "ackMode" .= show runtime.knobs.ackMode,
                        "preloadedMessages" .= knobInt context.knobs (knobName "pgmq.message-count"),
                        "consumers" .= knobInt context.knobs (knobName "pgmq.consumers")
                      ]
                    else []
                groupedFields =
                  if identifier == "pgmq/fifo/benchmark/grouped-read-cost"
                    then
                      [ "preloadedMessages" .= knobInt context.knobs (knobName "pgmq.message-count"),
                        "groups" .= knobInt context.knobs (knobName "pgmq.groups"),
                        "readStrategy" .= show runtime.knobs.readStrategy,
                        "batchSize" .= runtime.knobs.batchSize,
                        "fifoIndex" .= knobBool context.knobs (knobName "pgmq.fifo-index")
                      ]
                    else []
            putSummary context Verdicts "pgmq-benchmark" (object (["identifier" .= identifier, "layer" .= show layer, "wake" .= knobText context.knobs (knobName "pgmq.wake"), "failedOperations" .= failures] <> readAckFields <> groupedFields))
            pure (base {outcome = measuredOutcome report base.outcome})

benchmarkLoadConfiguration :: Text -> RunContext -> PgmqKnobs -> LoadModel -> Either Text LoadModel
benchmarkLoadConfiguration identifier context knobs loadModel
  | identifier == "pgmq/fifo/benchmark/grouped-read-cost" =
      if knobs.readStrategy `notElem` [Grouped, GroupedRoundRobin, GroupedHead]
        then Left "grouped-read-cost requires a grouped read strategy"
        else case loadModel of
          ClosedLoop _ -> Right loadModel
          OpenLoop _ -> Left "grouped-read-cost requires load.model=closed"
  | identifier /= "pgmq/read/benchmark/read-ack-throughput" = Right loadModel
  | knobs.readStrategy `notElem` [Plain, Pop] = Left "read-ack-throughput supports only plain and pop reads"
  | knobs.readStrategy == Pop && knobs.ackMode /= AckDelete = Left "pop removes messages itself; use pgmq.ack-mode=delete"
  | otherwise = case loadModel of
      ClosedLoop config -> Right (ClosedLoop config {workers = fromIntegral (knobInt context.knobs (knobName "pgmq.consumers"))})
      OpenLoop _ -> Left "read-ack-throughput requires load.model=closed"

operationName :: Text -> Layer -> Text
operationName identifier layer
  | "layer-ladder" `Text.isInfixOf` identifier = "layer-" <> Text.toLower (Text.pack (show layer))
  | "send-throughput" `Text.isInfixOf` identifier = "send"
  | "read-ack" `Text.isInfixOf` identifier = "read-ack"
  | "produce-consume" `Text.isInfixOf` identifier = "produce-consume"
  | "backlog" `Text.isInfixOf` identifier = "backlog-read"
  | "grouped" `Text.isInfixOf` identifier = "grouped-read"
  | "notify" `Text.isInfixOf` identifier = "notify-send"
  | "metrics" `Text.isInfixOf` identifier = "queue-metrics"
  | otherwise = "effectful"

prepare :: Text -> PgmqRun -> Pgmq.QueueName -> IO ()
prepare identifier runtime queue
  | "grouped-read-cost" `Text.isInfixOf` identifier = do
      when (knobBool runtime.ctx.knobs (knobName "pgmq.fifo-index")) (effect runtime (PgmqEffect.createFifoIndex queue))
      let count = fromIntegral (knobInt runtime.ctx.knobs (knobName "pgmq.message-count"))
          groups = fromIntegral (knobInt runtime.ctx.knobs (knobName "pgmq.groups"))
      forM_ (chunksOf 1000 [1 .. count]) \chunk -> do
        let headers = [Pgmq.MessageHeaders (object ["x-pgmq-group" .= ("g" <> Text.pack (show ((index - 1) `mod` groups)))]) | index <- chunk]
        _ <- effect runtime (Pgmq.batchSendMessageWithHeaders (Types.BatchSendMessageWithHeaders queue (fmap payload chunk) headers Nothing))
        pure ()
  | "read-ack-throughput" `Text.isInfixOf` identifier = do
      let count = fromIntegral (knobInt runtime.ctx.knobs (knobName "pgmq.message-count"))
      forM_ (chunksOf 1000 [1 .. count]) \chunk -> do
        _ <- effect runtime (Pgmq.batchSendMessage (Types.BatchSendMessage queue (fmap payload chunk) Nothing))
        pure ()
  | "invisible-backlog" `Text.isInfixOf` identifier = do
      let count = fromIntegral (knobInt runtime.ctx.knobs (knobName "pgmq.invisible-backlog"))
      forM_ (chunksOf 1000 [1 .. count]) \chunk -> do
        _ <- effect runtime (Pgmq.batchSendMessage (Types.BatchSendMessage queue (fmap payload chunk) Nothing))
        pure ()
      drainInvisible count
  | "notify-insert" `Text.isInfixOf` identifier = effect runtime (Pgmq.enableNotifyInsert (Types.EnableNotifyInsert queue (Just 250)))
  | "produce-consume" `Text.isInfixOf` identifier && knobText runtime.ctx.knobs (knobName "pgmq.wake") == "notify" =
      effect runtime (Pgmq.enableNotifyInsert (Types.EnableNotifyInsert queue (Just (fromIntegral (knobInt runtime.ctx.knobs (knobName "pgmq.notify.throttle-ms"))))))
  | otherwise = pure ()
  where
    drainInvisible remaining
      | remaining <= 0 = pure ()
      | otherwise = do
          let qty = fromIntegral (min 1000 remaining)
          _ <- effect runtime (Pgmq.readMessage (Types.ReadMessage queue 3600 (Just qty) Nothing))
          drainInvisible (remaining - fromIntegral qty)

runOperation :: Text -> PgmqRun -> PgmqClient -> Pgmq.QueueName -> Int -> Word64 -> IO OpResult
runOperation identifier runtime client queue _ sequenceNumber = do
  result <- try @SomeException action
  pure $ either (OpFailed . ErrorCause . Text.pack . show) id result
  where
    action
      | "metrics-poll" `Text.isInfixOf` identifier = do
          outcome <- Pool.use runtime.pool (Sessions.queueMetrics queue)
          either (ioError . userError . show) (const (pure (OpOk 1))) outcome
      | "send-throughput" `Text.isInfixOf` identifier = sendOperation client queue sequenceNumber runtime.knobs.batchSize (knobText runtime.ctx.knobs (knobName "pgmq.op"))
      | "read-ack-throughput" `Text.isInfixOf` identifier = readAckCycle runtime client queue
      | "produce-consume" `Text.isInfixOf` identifier = wakeCycle runtime client queue sequenceNumber
      | "grouped-read" `Text.isInfixOf` identifier = groupedDrain runtime queue
      | "interpreter-tracing-overhead" `Text.isInfixOf` identifier && knobBool runtime.ctx.knobs (knobName "pgmq.trace.propagate") = propagatedCycle runtime queue sequenceNumber
      | otherwise = fullCycle client queue sequenceNumber

sendOperation :: PgmqClient -> Pgmq.QueueName -> Word64 -> Int32 -> Text -> IO OpResult
sendOperation client queue sequenceNumber batchSize operation
  | operation == "send-batch" = OpOk . length <$> client.sendBatch queue [payload (fromIntegral sequenceNumber * 1000 + index) | index <- [1 .. fromIntegral batchSize]]
  | otherwise = client.send queue (payload (fromIntegral sequenceNumber)) >> pure (OpOk 1)

fullCycle :: PgmqClient -> Pgmq.QueueName -> Word64 -> IO OpResult
fullCycle client queue sequenceNumber = do
  _ <- client.send queue (payload (fromIntegral sequenceNumber))
  messages <- readAvailable 10 (client.readBatch queue 30 1)
  case Vector.toList messages of
    [] -> pure (OpFailed (ErrorCause "empty-read-after-send"))
    message : _ -> do
      acknowledged <- client.delete queue message.messageId
      pure (if acknowledged then OpOk 3 else OpFailed (ErrorCause "delete-returned-false"))

readAckCycle :: PgmqRun -> PgmqClient -> Pgmq.QueueName -> IO OpResult
readAckCycle runtime client queue = do
  messages <- readAvailable 10 $ case runtime.knobs.readStrategy of
    Pop -> client.popBatch queue runtime.knobs.batchSize
    _ -> client.readBatch queue runtime.knobs.visibilityTimeoutSeconds runtime.knobs.batchSize
  let values = Vector.toList messages
      identifiers = fmap (.messageId) values
  if null values
    then pure (OpFailed (ErrorCause "preloaded-queue-exhausted"))
    else do
      threadDelay (fromIntegral (knobInt runtime.ctx.knobs (knobName "pgmq.handler-ms")) * length values * 1000)
      acknowledged <- case runtime.knobs.readStrategy of
        Pop -> pure True
        _ -> case runtime.knobs.ackMode of
          AckDelete -> and <$> traverse (client.delete queue) identifiers
          AckArchive -> and <$> traverse (\messageId -> effect runtime (Pgmq.archiveMessage (Types.MessageQuery queue messageId))) identifiers
          AckBatchDelete -> matching identifiers <$> effect runtime (Pgmq.batchDeleteMessages (Types.BatchMessageQuery queue identifiers))
          AckBatchArchive -> matching identifiers <$> effect runtime (Pgmq.batchArchiveMessages (Types.BatchMessageQuery queue identifiers))
      pure (if acknowledged then OpOk (length values) else OpFailed (ErrorCause "acknowledgement-incomplete"))
  where
    matching expected actual = sort expected == sort actual

readAvailable :: Int -> IO (Vector.Vector value) -> IO (Vector.Vector value)
readAvailable attempts action = do
  values <- action
  if Vector.null values && attempts > 1
    then threadDelay 1000 >> readAvailable (attempts - 1) action
    else pure values

groupedDrain :: PgmqRun -> Pgmq.QueueName -> IO OpResult
groupedDrain runtime queue = do
  let request = Types.ReadGrouped queue runtime.knobs.visibilityTimeoutSeconds runtime.knobs.batchSize
      readGrouped = case runtime.knobs.readStrategy of
        Grouped -> Pgmq.readGrouped request
        GroupedRoundRobin -> Pgmq.readGroupedRoundRobin request
        _ -> Pgmq.readGroupedHead request
  messages <- effect runtime readGrouped
  let values = Vector.toList messages
  if null values
    then pure (OpFailed (ErrorCause "preloaded-grouped-queue-exhausted"))
    else do
      acknowledged <- and <$> traverse (\message -> effect runtime (Pgmq.deleteMessage (Types.MessageQuery queue message.messageId))) values
      pure (if acknowledged then OpOk (length values) else OpFailed (ErrorCause "grouped-delete-returned-false"))

propagatedCycle :: PgmqRun -> Pgmq.QueueName -> Word64 -> IO OpResult
propagatedCycle runtime queue sequenceNumber = case runtime.telemetry.tracerProvider of
  Nothing -> pure (OpFailed (ErrorCause "trace propagation requires a tracer provider"))
  Just provider -> do
    _ <- effect runtime (Pgmq.sendMessageTraced provider queue (payload (fromIntegral sequenceNumber)) Nothing)
    messages <- effect runtime (Pgmq.readMessageWithContext provider (Types.ReadMessage queue 30 (Just 1) Nothing))
    case Vector.toList messages of
      [] -> pure (OpFailed (ErrorCause "empty-context-read-after-send"))
      (message, _) : _ -> do
        acknowledged <- effect runtime (Pgmq.deleteMessage (Types.MessageQuery queue message.messageId))
        pure (if acknowledged then OpOk 3 else OpFailed (ErrorCause "propagated-delete-returned-false"))

wakeCycle :: PgmqRun -> PgmqClient -> Pgmq.QueueName -> Word64 -> IO OpResult
wakeCycle runtime client queue sequenceNumber = case knobText runtime.ctx.knobs (knobName "pgmq.wake") of
  "poll" -> do
    _ <- client.send queue messageBody
    messages <- pollUntilAvailable (100 :: Int)
    acknowledge messages
  "long-poll" -> do
    reader <- async (effect runtime (Pgmq.readWithPoll (Types.ReadWithPollMessage queue 30 (Just 1) (max 1 runtime.knobs.pollMaxSeconds) runtime.knobs.pollIntervalMs Nothing)))
    threadDelay 1000
    _ <- client.send queue messageBody
    wait reader >>= acknowledge
  "notify" ->
    withListener (requirePostgres runtime.ctx).connectionString (PgmqTypes.notifyChannelName queue) \connection -> do
      _ <- client.send queue messageBody
      _ <- awaitNotifications connection (fromIntegral runtime.knobs.pollIntervalMs * 10)
      -- A configured throttle intentionally suppresses some per-insert signals.
      -- The consumer therefore keeps the same polling fallback required by the
      -- notification contract instead of treating a quiet interval as loss.
      effect runtime (Pgmq.readMessage (Types.ReadMessage queue 30 (Just 1) Nothing)) >>= acknowledge
  selected -> pure (OpFailed (ErrorCause ("unknown-wake-mode:" <> selected)))
  where
    messageBody = payload (fromIntegral sequenceNumber)
    pollUntilAvailable attempts = do
      messages <- effect runtime (Pgmq.readMessage (Types.ReadMessage queue 30 (Just 1) Nothing))
      if Vector.null messages && attempts > 1
        then threadDelay (fromIntegral runtime.knobs.pollIntervalMs * 1000) >> pollUntilAvailable (attempts - 1)
        else pure messages
    acknowledge messages = case Vector.toList messages of
      [] -> pure (OpFailed (ErrorCause "empty-wake-read"))
      message : _ -> do
        deleted <- effect runtime (Pgmq.deleteMessage (Types.MessageQuery queue message.messageId))
        pure (if deleted then OpOk 3 else OpFailed (ErrorCause "wake-delete-returned-false"))

payload :: Int -> Pgmq.MessageBody
payload index = Pgmq.MessageBody (object ["k" .= index])

effect :: PgmqRun -> Effectful.Eff '[Pgmq.Pgmq, Effectful.Error.Static.Error Pgmq.PgmqRuntimeError, Effectful.IOE] value -> IO value
effect runtime action = either (ioError . userError . show) pure =<< runOps runtime.tracer runtime.pool action

chunksOf :: Int -> [value] -> [[value]]
chunksOf _ [] = []
chunksOf size values = take size values : chunksOf size (drop size values)
