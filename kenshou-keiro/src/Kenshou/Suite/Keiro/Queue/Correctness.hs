module Kenshou.Suite.Keiro.Queue.Correctness (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically)
import Control.Exception (try)
import Control.Monad (forM)
import Data.Aeson (Value (..), encodeFile, object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.List (nub)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (liftIO)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Keiro.PGMQ.Codec (JobCodec (..), JobDecodeError (..), aesonJobCodec)
import Keiro.PGMQ.Dlq (DlqEntry (..), readDlq)
import Keiro.PGMQ.Job (Job (..), JobConsumptionConfigError (..), JobContext (..), JobOrdering (..), JobOutcome (..), JobPolling (..), JobTuning (..), JobTuningConfigError (..), RetryDelay (..), RetryPolicy (..), defaultJobTuning, defaultRetryPolicy, enqueue, enqueueBatch, enqueueToGroup, enqueueWithDelay, enqueueWithHeaders, ensureJobQueue, jobProcessorWithContext, runJobOnceWithContext, withOrdering)
import Keiro.PGMQ.Runtime (JobRuntime (..), QueueRef (..), queueRef, runJobEff, withJobRuntime)
import Kenshou.Check.Process (ProgressSnapshot (..), awaitMark, awaitReady, killChild, progress, roleProcess, sendCommand, spawn, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Command.Correctness (recordCells)
import Kenshou.Suite.Keiro.Outbox.Workload (sourceName)
import Kenshou.Suite.Keiro.Queue.Oracle qualified as Oracle
import Kenshou.Suite.Keiro.Queue.WorkerOutcomes (workerBoundaryChecks)
import Pgmq.Types (MessageHeaders (..), MessageId (..), queueNameToText)
import System.FilePath ((</>))
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [consumptionConfigRejections, maxRetriesBeforeHandler, jobOutcomeSemantics]

jobOutcomeSemantics :: Scenario
jobOutcomeSemantics =
  consumptionConfigRejections
    { id = either (error . show) id (parseScenarioId "keiro/queue/correctness/job-outcome-semantics"),
      revision = 3,
      summary = "Checks job outcomes, batch identity/order, preserved headers and pre-handler refusal.",
      tier = TierStandard,
      run = runJobOutcomeSemantics
    }

runJobOutcomeSemantics :: RunContext -> IO ScenarioReport
runJobOutcomeSemantics context =
  withJobRuntime (requirePostgres context).connectionString Nothing \runtime -> do
    attempts <- newIORef ([] :: [Maybe Word])
    defaultAttempts <- newIORef ([] :: [Maybe Word])
    deadHeaders <- newIORef ([] :: [Maybe Value])
    malformedCalls <- newIORef (0 :: Int)
    futureCalls <- newIORef (0 :: Int)
    let makeJob name = Job name (queueRef (sourceName context name)) (aesonJobCodec @Text) Unordered defaultRetryPolicy
        doneJob = makeJob "done"
        retryJob = makeJob "retry"
        deadJob = makeJob "dead"
        delayJob = makeJob "delay"
        defaultJob = (makeJob "default-retry") {jobPolicy = defaultRetryPolicy {defaultRetryDelay = RetryDelay 1}}
        archiveJob = (makeJob "archive") {jobPolicy = defaultRetryPolicy {useDeadLetter = False}}
        batchJob = makeJob "batch"
        groupJob = (makeJob "group") {jobOrdering = FifoHeads}
        thrownJob = makeJob "thrown"
        malformedJob = makeJob "malformed"
        futureJob = Job "future" (queueRef (sourceName context "future")) (JobCodec (const (object ["future" .= True])) (const (Left (JobPayloadFromFuture 2 1)))) Unordered defaultRetryPolicy {defaultRetryDelay = RetryDelay 1}
        workerJob = Job "queue-poll-probe" (queueRef (sourceName context "worker-done")) (aesonJobCodec @Text) Unordered defaultRetryPolicy
        workerRetryJob = workerJob {jobQueue = queueRef (sourceName context "worker-retry")}
        workerDeadJob = workerJob {jobQueue = queueRef (sourceName context "worker-dead")}
        workerThrowJob = workerJob {jobQueue = queueRef (sourceName context "worker-throw")}
        preservedHeaders = object ["probe" .= ("preserved" :: Text), "nested" .= object ["value" .= (1 :: Int)]]
        doneHandler _ _ = pure Done
        countedHandler calls _ _ = liftIO (atomicModifyIORef' calls (\count -> (count + 1, ()))) >> pure Done
        retryHandler jobContext _ = do
          liftIO $ atomicModifyIORef' attempts (\seen -> (seen <> [jobContext.attempt], ()))
          pure $ if jobContext.attempt == Just 0 then Retry (RetryDelay 1) else Done
        deadHandler jobContext _ = do
          liftIO $ atomicModifyIORef' deadHeaders (\seen -> (seen <> [jobContext.headers], ()))
          pure (Dead "bad-work")
        defaultHandler jobContext _ = do
          liftIO $ atomicModifyIORef' defaultAttempts (\seen -> (seen <> [jobContext.attempt], ()))
          pure $ if jobContext.attempt == Just 0 then RetryDefault else Done
        throwingHandler _ _ = liftIO (fail "fixture handler failure")
        runOne target handler = runJobEff runtime (runJobOnceWithContext defaultJobTuning 1 target handler) >>= either (fail . show) pure
        runThrown handler = runJobEff runtime (runJobOnceWithContext defaultJobTuning {visibilityTimeout = 1} 1 thrownJob handler) >>= either (fail . show) pure
        queueCount target = do
          let table = "pgmq.q_" <> queueNameToText target.jobQueue.physicalName
              statement = Statement.preparable ("SELECT count(*) FROM " <> table) Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))
          Pool.use runtime.runtimePool (Session.statement () statement) >>= either (fail . show) pure
        deadLetter target = do
          let table = "pgmq.q_" <> queueNameToText target.jobQueue.dlqName
              statement = Statement.preparable ("SELECT count(*), coalesce(max(message->>'dead_letter_reason'),'')::text FROM " <> table) Encoders.noParams (Decoders.singleRow ((,) <$> Decoders.column (Decoders.nonNullable Decoders.int8) <*> Decoders.column (Decoders.nonNullable Decoders.text)))
          Pool.use runtime.runtimePool (Session.statement () statement) >>= either (fail . show) pure
        archiveCount target = do
          let table = "pgmq.a_" <> queueNameToText target.jobQueue.physicalName
              statement = Statement.preparable ("SELECT count(*) FROM " <> table) Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))
          Pool.use runtime.runtimePool (Session.statement () statement) >>= either (fail . show) pure
        physicalRows archived target = do
          let table = (if archived then "pgmq.a_" else "pgmq.q_") <> queueNameToText target.jobQueue.physicalName
              statement =
                Statement.preparable
                  ("SELECT msg_id, message, headers, read_ct::bigint FROM " <> table <> " ORDER BY msg_id")
                  Encoders.noParams
                  (Decoders.rowList ((,,,) <$> Decoders.column (Decoders.nonNullable Decoders.int8) <*> Decoders.column (Decoders.nonNullable Decoders.jsonb) <*> Decoders.column (Decoders.nullable Decoders.jsonb) <*> Decoders.column (Decoders.nonNullable Decoders.int8)))
          Pool.use runtime.runtimePool (Session.statement () statement) >>= either (fail . show) pure
        queueReadCount target = do
          let table = "pgmq.q_" <> queueNameToText target.jobQueue.physicalName
              statement = Statement.preparable ("SELECT coalesce(max(read_ct),0)::bigint FROM " <> table) Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))
          Pool.use runtime.runtimePool (Session.statement () statement) >>= either (fail . show) pure
        groupHeaderCount = do
          let table = "pgmq.q_" <> queueNameToText groupJob.jobQueue.physicalName
              statement = Statement.preparable ("SELECT count(*) FROM " <> table <> " WHERE headers->>'x-pgmq-group' = 'alpha'") Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))
          Pool.use runtime.runtimePool (Session.statement () statement) >>= either (fail . show) pure
        effectCount payload = do
          let statement = Statement.preparable "SELECT count(*) FROM kenshou_fx.queue_effects WHERE payload = $1" (Encoders.param (Encoders.nonNullable Encoders.text)) (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))
          Pool.use runtime.runtimePool (Session.statement payload statement) >>= either (fail . show) pure
        corruptMessage = do
          let table = "pgmq.q_" <> queueNameToText malformedJob.jobQueue.physicalName
          Pool.use runtime.runtimePool (Session.script ("UPDATE " <> table <> " SET message = '{\"unexpected\":true}'::jsonb")) >>= either (fail . show) pure
    setup <- runJobEff runtime do
      ensureJobQueue doneJob
      ensureJobQueue retryJob
      ensureJobQueue deadJob
      ensureJobQueue delayJob
      ensureJobQueue defaultJob
      ensureJobQueue archiveJob
      ensureJobQueue batchJob
      ensureJobQueue groupJob
      ensureJobQueue thrownJob
      ensureJobQueue malformedJob
      ensureJobQueue futureJob
      ensureJobQueue workerJob
      ensureJobQueue workerRetryJob
      ensureJobQueue workerDeadJob
      ensureJobQueue workerThrowJob
      _ <- enqueue doneJob ("done" :: Text)
      _ <- enqueue retryJob ("retry" :: Text)
      deadId <- enqueueWithHeaders deadJob (MessageHeaders preservedHeaders) ("dead" :: Text)
      _ <- enqueueWithDelay delayJob 1 ("delayed" :: Text)
      _ <- enqueue defaultJob ("default" :: Text)
      archiveId <- enqueueWithHeaders archiveJob (MessageHeaders preservedHeaders) ("archive" :: Text)
      batchIds <- enqueueBatch batchJob (["one", "two", "three"] :: [Text])
      _ <- enqueueToGroup groupJob "alpha" ("grouped" :: Text)
      _ <- enqueue thrownJob ("throw" :: Text)
      _ <- enqueue malformedJob ("malformed" :: Text)
      _ <- enqueue futureJob ("future" :: Text)
      pure (batchIds, deadId, archiveId)
    (batchIds, deadId, archiveId) <- either (fail . show) pure setup
    corruptMessage
    done <- runOne doneJob doneHandler
    doneDepth <- queueCount doneJob
    retried <- runOne retryJob retryHandler
    beforeRetry <- runOne retryJob retryHandler
    beforeDelay <- runOne delayJob doneHandler
    threadDelay 1200000
    afterRetry <- runOne retryJob retryHandler
    afterDelay <- runOne delayJob doneHandler
    observedAttempts <- readIORef attempts
    dead <- runOne deadJob deadHandler
    deadDepth <- queueCount deadJob
    deadLettered <- deadLetter deadJob
    drainDeadHeaders <- readIORef deadHeaders
    drainDlq <- runJobEff runtime (readDlq deadJob 1) >>= either (fail . show) pure
    defaultFirst <- runOne defaultJob defaultHandler
    defaultEarly <- runOne defaultJob defaultHandler
    archiveHandled <- runOne archiveJob deadHandler
    archiveDepth <- queueCount archiveJob
    archived <- archiveCount archiveJob
    archivedRows <- physicalRows True archiveJob
    groupedHeaders <- groupHeaderCount
    batchDepth <- queueCount batchJob
    batchRows <- physicalRows False batchJob
    thrownResult <- runThrown throwingHandler
    thrownEarly <- runThrown doneHandler
    thrownDepth <- queueCount thrownJob
    malformedHandled <- runOne malformedJob (countedHandler malformedCalls)
    malformedDepth <- queueCount malformedJob
    malformedDead <- deadLetter malformedJob
    futureHandled <- runOne futureJob (countedHandler futureCalls)
    futureEarly <- runOne futureJob (countedHandler futureCalls)
    futureDepth <- queueCount futureJob
    futureFirstReadCount <- queueReadCount futureJob
    threadDelay 1200000
    defaultSecond <- runOne defaultJob defaultHandler
    thrownRedelivery <- runThrown doneHandler
    futureSecond <- runOne futureJob (countedHandler futureCalls)
    futureSecondReadCount <- queueReadCount futureJob
    observedDefaultAttempts <- readIORef defaultAttempts
    malformedHandlerCalls <- readIORef malformedCalls
    futureHandlerCalls <- readIORef futureCalls
    workerDelivery <- withCheck context \check -> withSupervisor check \supervisor -> do
      Pool.use runtime.runtimePool (Session.script "CREATE SCHEMA IF NOT EXISTS kenshou_fx; CREATE TABLE IF NOT EXISTS kenshou_fx.queue_effects (payload text NOT NULL)") >>= either (fail . show) pure
      spec <- roleProcess check "keiro/queue-worker" 0 (object ["queue" .= workerJob.jobQueue.logicalName])
      child <- spawn supervisor spec
      awaitReady child 10000
      sendCommand child CtlStart
      awaitMark child "running" 30000
      sent <- runJobEff runtime (enqueueWithHeaders workerJob (MessageHeaders preservedHeaders) ("worker-done" :: Text))
      _ <- either (fail . show) pure sent
      awaitMark child "delivery" 10000
      let waitDone = do
            snapshot <- atomically (progress child)
            depth <- queueCount workerJob
            if snapshot.count >= 1 && depth == 0 then pure True else threadDelay 100000 >> waitDone
      completed <- maybe False id <$> timeout 10000000 waitDone
      snapshot <- atomically (progress child)
      killChild supervisor child
      let delivery = Map.lookup "delivery" snapshot.marks >>= parseMaybe (withObject "worker delivery" (\o -> (,) <$> o .: "attempt" <*> o .: "headers"))
      pure (completed, delivery :: Maybe (Maybe Word, Maybe Value))
    workerOutcomes <- withCheck context \check -> withSupervisor check \supervisor -> do
      let runArm index target mode payload expectedEffects terminal = do
            spec <- roleProcess check "keiro/queue-worker" index (object ["queue" .= target.jobQueue.logicalName, "mode" .= (mode :: Text)])
            child <- spawn supervisor spec
            awaitReady child 10000
            sendCommand child CtlStart
            awaitMark child "running" 30000
            sent <- runJobEff runtime (enqueueWithHeaders target (MessageHeaders preservedHeaders) payload)
            _ <- either (fail . show) pure sent
            let awaitTerminal = do
                  effects <- effectCount payload
                  depth <- queueCount target
                  dlq <- deadLetter target
                  if effects >= expectedEffects && depth == 0 && terminal dlq
                    then pure (effects, dlq)
                    else threadDelay 100000 >> awaitTerminal
            result <- timeout 15000000 awaitTerminal
            snapshot <- atomically (progress child)
            killChild supervisor child
            pure (result, snapshot.count, sent)
      retryResult <- runArm 1 workerRetryJob "retry-once" "worker-retry" 2 (const True)
      deadResult <- runArm 2 workerDeadJob "dead" "worker-dead" 1 (\(count, reason) -> count == 1 && Text.isPrefixOf "poison_pill" reason)
      throwResult <- runArm 3 workerThrowJob "throw-once" "worker-throw" 2 (const True)
      pure (retryResult, deadResult, throwResult)
    workerDlq <- runJobEff runtime (readDlq workerDeadJob 1) >>= either (fail . show) pure
    boundaryCells <- workerBoundaryChecks context runtime preservedHeaders
    let (_, (_, _, workerDeadId), _) = workerOutcomes
    encodeFile (context.outDir </> "logs/queue-physical-outcomes.json") $
      object
        [ "schema" .= ("kenshou.queue-physical-outcomes/v1" :: Text),
          "sentHeaders" .= preservedHeaders,
          "batchPayloads" .= (["one", "two", "three"] :: [Text]),
          "batchReturnedIds" .= map unMessageId batchIds,
          "batchRows" .= batchRows,
          "archivePayload" .= ("archive" :: Text),
          "archiveReturnedId" .= unMessageId archiveId,
          "archiveRows" .= archivedRows,
          "deadPayload" .= ("dead" :: Text),
          "deadReturnedId" .= unMessageId deadId,
          "deadContextHeaders" .= drainDeadHeaders,
          "drainDeadEntries" .= map (.rawBody) drainDlq,
          "workerDeadPayload" .= ("worker-dead" :: Text),
          "workerDeadReturnedId" .= either (const Nothing) (Just . unMessageId) workerDeadId,
          "workerDeadEntries" .= map (.rawBody) workerDlq,
          "workerContext" .= fmap (\(attempt, headers) -> object ["attempt" .= attempt, "headers" .= headers]) (snd workerDelivery),
          "malformedHandlerCalls" .= malformedHandlerCalls,
          "futureHandlerCalls" .= futureHandlerCalls
        ]
    recordCells context $
      [ ("done-deletes", done == 1 && doneDepth == (0 :: Int64)),
        ("retry-delay-and-attempt", retried == 1 && beforeRetry == 0 && afterRetry == 1 && observedAttempts == [Just 0, Just 1]),
        ("enqueue-delay", beforeDelay == 0 && afterDelay == 1),
        ("dead-letter", dead == 1 && deadDepth == (0 :: Int64) && fst deadLettered == (1 :: Int64) && Text.isPrefixOf "poison_pill" (snd deadLettered)),
        ("default-retry-delay", defaultFirst == 1 && defaultEarly == 0 && defaultSecond == 1 && observedDefaultAttempts == [Just 0, Just 1]),
        ("archive-when-dlq-disabled", archiveHandled == 1 && archiveDepth == 0 && archived == 1),
        ("batch-ids-and-rows", length batchIds == 3 && length (nub batchIds) == 3 && batchDepth == 3),
        ("batch-id-order-and-payloads", Oracle.batchRowsMatch (map unMessageId batchIds) ["one", "two", "three"] batchRows),
        ("drain-context-preserves-headers", drainDeadHeaders == [Just preservedHeaders]),
        ("drain-dead-wrapper", Oracle.deadLetterPreserves "dead" (unMessageId deadId) preservedHeaders drainDlq),
        ("archive-preserves-message", archivedRows == [(unMessageId archiveId, String "archive", Just preservedHeaders, 1)]),
        ("malformed-skips-handler", malformedHandlerCalls == 0),
        ("future-skips-handler", futureHandlerCalls == 0),
        ("group-header", groupedHeaders == 1),
        ("drain-handler-exception", thrownResult == 0 && thrownEarly == 0 && thrownDepth == 1 && thrownRedelivery == 1),
        ("malformed-payload", malformedHandled == 1 && malformedDepth == 0 && fst malformedDead == 1 && Text.isPrefixOf "invalid_payload" (snd malformedDead)),
        ("future-payload-retries", futureHandled == 1 && futureEarly == 0 && futureDepth == 1 && futureFirstReadCount == 1 && futureSecond == 1 && futureSecondReadCount == 2),
        ("worker-done-and-context", fst workerDelivery && snd workerDelivery == Just (Just 0, Nothing)),
        ("worker-retry", case workerOutcomes of ((Just (effects, _), _, _), _, _) -> effects == 2; _ -> False),
        ("worker-dead-letter", case workerOutcomes of (_, (Just (effects, (count, reason)), _, _), _) -> effects == 1 && count == 1 && Text.isPrefixOf "poison_pill" reason; _ -> False),
        ("worker-dead-wrapper", case workerDeadId of Right identifier -> Oracle.deadLetterPreserves "worker-dead" (unMessageId identifier) preservedHeaders workerDlq; Left _ -> False),
        ("worker-handler-exception-redelivery", case workerOutcomes of (_, _, (Just (effects, _), _, _)) -> effects == 2; _ -> False)
      ]
        <> boundaryCells

maxRetriesBeforeHandler :: Scenario
maxRetriesBeforeHandler =
  consumptionConfigRejections
    { id = either (error . show) id (parseScenarioId "keiro/queue/correctness/max-retries-before-handler"),
      revision = 1,
      summary = "Checks the retry ceiling dead letters before a fourth handler call, including a zero ceiling.",
      tier = TierStandard,
      run = runMaxRetriesBeforeHandler
    }

runMaxRetriesBeforeHandler :: RunContext -> IO ScenarioReport
runMaxRetriesBeforeHandler context =
  withJobRuntime (requirePostgres context).connectionString Nothing \runtime -> do
    calls <- newIORef (0 :: Int)
    let queue = queueRef (sourceName context "retries")
        zeroQueue = queueRef (sourceName context "zero-retries")
        job = Job "retry-probe" queue (aesonJobCodec @Text) Unordered defaultRetryPolicy {maxRetries = 3}
        zeroJob = job {jobQueue = zeroQueue, jobPolicy = defaultRetryPolicy {maxRetries = 0}}
        handler _ _ = do
          liftIO $ atomicModifyIORef' calls (\count -> (count + 1, ()))
          pure (Retry (RetryDelay 0))
        runOnce target = runJobEff runtime (runJobOnceWithContext defaultJobTuning 1 target handler) >>= either (fail . show) pure
        dlqState target = do
          let table = "pgmq.q_" <> queueNameToText target.jobQueue.dlqName
              statement = Statement.preparable ("SELECT count(*), coalesce(max(message->>'dead_letter_reason'),'')::text, coalesce(max((message->>'read_count')::bigint),0)::bigint FROM " <> table) Encoders.noParams (Decoders.singleRow ((,,) <$> Decoders.column (Decoders.nonNullable Decoders.int8) <*> Decoders.column (Decoders.nonNullable Decoders.text) <*> Decoders.column (Decoders.nonNullable Decoders.int8)))
          Pool.use runtime.runtimePool (Session.statement () statement) >>= either (fail . show) pure
    setup <- runJobEff runtime do
      ensureJobQueue job
      ensureJobQueue zeroJob
      _ <- enqueue job ("retry" :: Text)
      enqueue zeroJob ("zero" :: Text)
    _ <- either (fail . show) pure setup
    counts <- sequence [runOnce job | _ <- [1 .. 4 :: Int]]
    actualCalls <- readIORef calls
    dead <- dlqState job
    _ <- runOnce zeroJob
    zeroCalls <- readIORef calls
    zeroDead <- dlqState zeroJob
    recordCells
      context
      [ ("three-handler-calls", actualCalls == 3),
        ("fourth-read-dead-letters", dead == (1 :: Int64, "max_retries_exceeded", 4 :: Int64) && length counts == 4),
        ("zero-ceiling-skips-handler", zeroCalls == actualCalls && zeroDead == (1 :: Int64, "max_retries_exceeded", 1 :: Int64))
      ]

consumptionConfigRejections :: Scenario
consumptionConfigRejections =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/queue/correctness/consumption-config-rejections"),
      revision = 2,
      summary = "Checks drain and worker configuration validation and precedence before reading a job.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgFsyncOff :| [PgDurable]) PgFsyncOff),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaPgmq] [] False)},
      knownDefect = Nothing,
      run = runConsumptionConfigRejections
    }

runConsumptionConfigRejections :: RunContext -> IO ScenarioReport
runConsumptionConfigRejections context =
  withJobRuntime (requirePostgres context).connectionString Nothing \runtime -> do
    let job = Job "config-probe" (queueRef (sourceName context "config")) (aesonJobCodec @Text) Unordered defaultRetryPolicy
        handler _ _ = pure Done
        invalidVisibility = defaultJobTuning {visibilityTimeout = 0}
        invalidBatch = defaultJobTuning {batchSize = 0}
        invalidPolling = defaultJobTuning {polling = PollEvery 0}
        throughputJob = job {jobOrdering = FifoThroughput}
        roundRobinJob = job {jobOrdering = FifoRoundRobin}
        throughputTuning = (withOrdering FifoThroughput defaultJobTuning) {batchSize = 2}
        roundRobinTuning = (withOrdering FifoRoundRobin defaultJobTuning) {batchSize = 2}
        cases =
          [ ("invalid-visibility", invalidVisibility, job, InvalidJobTuning (NonPositiveVisibilityTimeout 0)),
            ("invalid-batch", invalidBatch, job, InvalidJobTuning (NonPositiveBatchSize 0)),
            ("invalid-polling", invalidPolling, job, InvalidJobTuning NonPositivePollInterval),
            ("invalid-long-poll-limit", defaultJobTuning {polling = LongPoll 0 100}, job, InvalidJobTuning NonPositivePollInterval),
            ("invalid-long-poll-interval", defaultJobTuning {polling = LongPoll 5 0}, job, InvalidJobTuning NonPositivePollInterval),
            ("ordering-mismatch", withOrdering FifoHeads defaultJobTuning, job, JobOrderingMismatch Unordered FifoHeads),
            ("unsafe-legacy-batch", throughputTuning, throughputJob, UnsafeLegacyFifoBatch FifoThroughput 2),
            ("unsafe-round-robin-batch", roundRobinTuning, roundRobinJob, UnsafeLegacyFifoBatch FifoRoundRobin 2),
            ("validation-precedence", withOrdering FifoHeads invalidVisibility, job, InvalidJobTuning (NonPositiveVisibilityTimeout 0)),
            ("mismatch-before-unsafe-batch", throughputTuning, job, JobOrderingMismatch Unordered FifoThroughput)
          ]
        drainAttempt tuning target = try @JobConsumptionConfigError (runJobEff runtime (runJobOnceWithContext tuning 1 target handler >> pure ()))
        workerAttempt tuning target = try @JobConsumptionConfigError (runJobEff runtime (jobProcessorWithContext tuning target handler >> pure ()))
        queueTable = "pgmq.q_" <> queueNameToText job.jobQueue.physicalName
        readState = Statement.preparable ("SELECT count(*), coalesce(max(read_ct),0)::bigint FROM " <> queueTable) Encoders.noParams (Decoders.singleRow ((,) <$> Decoders.column (Decoders.nonNullable Decoders.int8) <*> Decoders.column (Decoders.nonNullable Decoders.int8)))
        state = Pool.use runtime.runtimePool (Session.statement () readState) >>= either (fail . show) pure
        matches expected = either (== expected) (const False)
        observation result = case result of
          Left err -> object ["status" .= ("rejected" :: Text), "detail" .= show err]
          Right resultValue -> object ["status" .= ("accepted" :: Text), "detail" .= show resultValue]
    setup <- runJobEff runtime do
      ensureJobQueue job
      enqueue job ("one" :: Text)
    _ <- either (fail . show) pure setup
    arms <- forM cases \(label, tuning, target, expected) -> do
      drainResult <- drainAttempt tuning target
      afterDrain <- state
      workerResult <- workerAttempt tuning target
      afterWorker <- state
      pure
        ( [(label, matches expected drainResult && afterDrain == (1, 0)), ("worker-" <> label, matches expected workerResult && afterWorker == (1, 0))],
          object
            [ "case" .= label,
              "expectedError" .= show expected,
              "drain" .= observation drainResult,
              "worker" .= observation workerResult,
              "afterDrain" .= afterDrain,
              "afterWorker" .= afterWorker
            ]
        )
    before <- state
    drained <- runJobEff runtime (runJobOnceWithContext defaultJobTuning 1 job handler)
    empty <- runJobEff runtime (runJobOnceWithContext defaultJobTuning 1 job handler)
    encodeFile (context.outDir </> "logs/queue-config-rejections.json") $
      object ["schema" .= ("kenshou.queue-config-rejections/v1" :: Text), "cases" .= map snd arms, "beforeValidDrain" .= before, "validDrain" .= either (const Nothing) Just drained, "emptyDrain" .= either (const Nothing) Just empty]
    recordCells context $
      concatMap fst arms
        <> [ ("read-count-untouched", before == (1 :: Int64, 0 :: Int64)),
             ("rejections-did-not-consume-job", either (const False) (== 1) drained && either (const False) (== 0) empty)
           ]
