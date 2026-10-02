module Kenshou.Suite.Keiro.Queue.WorkerOutcomes (workerBoundaryChecks) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM)
import Data.Aeson (Value (..), encodeFile, object, (.=))
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.Text (Text)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Keiro.PGMQ.Codec (aesonJobCodec)
import Keiro.PGMQ.Job (Job (..), JobOrdering (..), defaultRetryPolicy, enqueueWithHeaders, ensureJobQueue)
import Keiro.PGMQ.Runtime (JobRuntime (..), QueueRef (..), queueRef, runJobEff)
import Kenshou.Check.Process (awaitMark, awaitReady, killChild, roleProcess, sendCommand, spawn, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Suite.Keiro.Outbox.Workload (sourceName)
import Kenshou.Suite.Keiro.Queue.WorkerOracle (workerOutcomeCells)
import Pgmq.Types (MessageHeaders (..), MessageId (..), queueNameToText)
import System.FilePath ((</>))
import System.Timeout (timeout)

workerBoundaryChecks :: RunContext -> JobRuntime -> Value -> IO [(Text, Bool)]
workerBoundaryChecks context runtime headers = do
  Pool.use runtime.runtimePool (Session.script "CREATE TABLE IF NOT EXISTS kenshou_fx.queue_boundary_deliveries (id bigserial PRIMARY KEY, observation jsonb NOT NULL, at timestamptz NOT NULL DEFAULT clock_timestamp())") >>= either (fail . show) pure
  arms <- forM (zip [10 ..] ["retry", "default", "archive", "malformed", "future", "zero"]) \(index, label) -> do
    let logical = sourceName context ("boundary-" <> label)
        job = Job "queue-poll-probe" (queueRef logical) (aesonJobCodec @Value) Unordered defaultRetryPolicy
        payload = if label == "malformed" || label == "future" then object ["boundary" .= label] else String label
        rows table = do
          let statement = Statement.preparable ("SELECT jsonb_build_object('messageId',msg_id,'message',message,'headers',headers,'readCount',read_ct) FROM " <> table <> " ORDER BY msg_id") Encoders.noParams (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.jsonb)))
          Pool.use runtime.runtimePool (Session.statement () statement) >>= either (fail . show) pure
        sourceRows = rows ("pgmq.q_" <> queueNameToText job.jobQueue.physicalName)
        archiveRows = rows ("pgmq.a_" <> queueNameToText job.jobQueue.physicalName)
        dlqRows = rows ("pgmq.q_" <> queueNameToText job.jobQueue.dlqName)
        deliveries = do
          let statement = Statement.preparable "SELECT observation || jsonb_build_object('at',at) FROM kenshou_fx.queue_boundary_deliveries WHERE observation->>'queue'=$1 ORDER BY id" (Encoders.param (Encoders.nonNullable Encoders.text)) (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.jsonb)))
          Pool.use runtime.runtimePool (Session.statement logical statement) >>= either (fail . show) pure
        readState = do
          let statement = Statement.preparable ("SELECT jsonb_build_object('messageId',msg_id,'readCount',read_ct,'lastReadAt',last_read_at,'visibleAt',vt) FROM pgmq.q_" <> queueNameToText job.jobQueue.physicalName <> " ORDER BY msg_id") Encoders.noParams (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.jsonb)))
          Pool.use runtime.runtimePool (Session.statement () statement) >>= either (fail . show) pure
    -- Provision the empty DLQ even for the archive consumer so absence of a
    -- misplaced DLQ row can be observed directly.
    setup <- runJobEff runtime do
      ensureJobQueue job
      enqueueWithHeaders job (MessageHeaders headers) payload
    identifier <- either (fail . show) pure setup
    snapshots <- newIORef ([] :: [[Value]])
    completed <- withCheck context \check -> withSupervisor check \supervisor -> do
      child <- roleProcess check "keiro/queue-worker" index (object ["queue" .= logical, "mode" .= ("boundary-" <> label)]) >>= spawn supervisor
      awaitReady child 10000
      sendCommand child CtlStart
      awaitMark child "running" 30000
      let wait = do
            observed <- readState
            modifyIORef' snapshots \seen -> if take 1 seen == [observed] then seen else observed : seen
            remaining <- sourceRows
            archive <- archiveRows
            dead <- dlqRows
            calls <- deliveries
            let terminal
                  | label == "retry" || label == "default" = length calls >= 2
                  | label == "archive" = not (null archive)
                  | otherwise = not (null dead)
            if null remaining && terminal then pure () else threadDelay 20000 >> wait
      result <- timeout 15000000 wait
      killChild supervisor child
      pure (result == Just ())
    remaining <- sourceRows
    archived <- archiveRows
    dead <- dlqRows
    calls <- deliveries
    observedReads <- reverse <$> readIORef snapshots
    pure $ object ["case" .= label, "queue" .= logical, "messageId" .= (unMessageId identifier :: Int64), "payload" .= payload, "headers" .= headers, "completed" .= completed, "mainRows" .= remaining, "archiveRows" .= archived, "dlqRows" .= dead, "deliveries" .= calls, "readSnapshots" .= observedReads]
  let captured = object ["schema" .= ("kenshou.queue-worker-outcomes/v1" :: Text), "arms" .= arms]
  encodeFile (context.outDir </> "logs/queue-worker-outcomes.json") captured
  either (fail . show) pure (workerOutcomeCells captured)
