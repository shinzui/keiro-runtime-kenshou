module Kenshou.Suite.Keiro.Queue.Correctness (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically)
import Control.Exception (try)
import Data.Aeson (Value, object, withObject, (.:), (.=))
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
import Keiro.PGMQ.Job (Job (..), JobConsumptionConfigError (..), JobContext (..), JobOrdering (..), JobOutcome (..), JobPolling (..), JobTuning (..), JobTuningConfigError (..), RetryDelay (..), RetryPolicy (..), defaultJobTuning, defaultRetryPolicy, enqueue, enqueueBatch, enqueueToGroup, enqueueWithDelay, ensureJobQueue, runJobOnceWithContext, withOrdering)
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
import Pgmq.Types (queueNameToText)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [consumptionConfigRejections, maxRetriesBeforeHandler, jobOutcomeSemantics]

jobOutcomeSemantics :: Scenario
jobOutcomeSemantics =
  consumptionConfigRejections
    { id = either (error . show) id (parseScenarioId "keiro/queue/correctness/job-outcome-semantics"),
      summary = "Checks done, explicit retry, delayed delivery, and terminal dead-letter outcomes.",
      tier = TierStandard,
      run = runJobOutcomeSemantics
    }

runJobOutcomeSemantics :: RunContext -> IO ScenarioReport
runJobOutcomeSemantics context =
  withJobRuntime (requirePostgres context).connectionString Nothing \runtime -> do
    attempts <- newIORef ([] :: [Maybe Word])
    defaultAttempts <- newIORef ([] :: [Maybe Word])
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
        doneHandler _ _ = pure Done
        retryHandler jobContext _ = do
          liftIO $ atomicModifyIORef' attempts (\seen -> (seen <> [jobContext.attempt], ()))
          pure $ if jobContext.attempt == Just 0 then Retry (RetryDelay 1) else Done
        deadHandler _ _ = pure (Dead "bad-work")
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
      _ <- enqueue deadJob ("dead" :: Text)
      _ <- enqueueWithDelay delayJob 1 ("delayed" :: Text)
      _ <- enqueue defaultJob ("default" :: Text)
      _ <- enqueue archiveJob ("archive" :: Text)
      batchIds <- enqueueBatch batchJob (["one", "two", "three"] :: [Text])
      _ <- enqueueToGroup groupJob "alpha" ("grouped" :: Text)
      _ <- enqueue thrownJob ("throw" :: Text)
      _ <- enqueue malformedJob ("malformed" :: Text)
      _ <- enqueue futureJob ("future" :: Text)
      pure batchIds
    batchIds <- either (fail . show) pure setup
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
    defaultFirst <- runOne defaultJob defaultHandler
    defaultEarly <- runOne defaultJob defaultHandler
    archiveHandled <- runOne archiveJob deadHandler
    archiveDepth <- queueCount archiveJob
    archived <- archiveCount archiveJob
    groupedHeaders <- groupHeaderCount
    batchDepth <- queueCount batchJob
    thrownResult <- runThrown throwingHandler
    thrownEarly <- runThrown doneHandler
    thrownDepth <- queueCount thrownJob
    malformedHandled <- runOne malformedJob doneHandler
    malformedDepth <- queueCount malformedJob
    malformedDead <- deadLetter malformedJob
    futureHandled <- runOne futureJob doneHandler
    futureEarly <- runOne futureJob doneHandler
    futureDepth <- queueCount futureJob
    futureFirstReadCount <- queueReadCount futureJob
    threadDelay 1200000
    defaultSecond <- runOne defaultJob defaultHandler
    thrownRedelivery <- runThrown doneHandler
    futureSecond <- runOne futureJob doneHandler
    futureSecondReadCount <- queueReadCount futureJob
    observedDefaultAttempts <- readIORef defaultAttempts
    workerDelivery <- withCheck context \check -> withSupervisor check \supervisor -> do
      Pool.use runtime.runtimePool (Session.script "CREATE SCHEMA IF NOT EXISTS kenshou_fx; CREATE TABLE IF NOT EXISTS kenshou_fx.queue_effects (payload text NOT NULL)") >>= either (fail . show) pure
      spec <- roleProcess check "keiro/queue-worker" 0 (object ["queue" .= workerJob.jobQueue.logicalName])
      child <- spawn supervisor spec
      awaitReady child 10000
      sendCommand child CtlStart
      awaitMark child "running" 30000
      sent <- runJobEff runtime (enqueue workerJob ("worker-done" :: Text))
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
      pure (completed, delivery == Just (Just (0 :: Word), Nothing :: Maybe Value))
    workerOutcomes <- withCheck context \check -> withSupervisor check \supervisor -> do
      let runArm index target mode payload expectedEffects terminal = do
            spec <- roleProcess check "keiro/queue-worker" index (object ["queue" .= target.jobQueue.logicalName, "mode" .= (mode :: Text)])
            child <- spawn supervisor spec
            awaitReady child 10000
            sendCommand child CtlStart
            awaitMark child "running" 30000
            sent <- runJobEff runtime (enqueue target payload)
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
            pure (result, snapshot.count)
      retryResult <- runArm 1 workerRetryJob "retry-once" "worker-retry" 2 (const True)
      deadResult <- runArm 2 workerDeadJob "dead" "worker-dead" 1 (\(count, reason) -> count == 1 && Text.isPrefixOf "poison_pill" reason)
      throwResult <- runArm 3 workerThrowJob "throw-once" "worker-throw" 2 (const True)
      pure (retryResult, deadResult, throwResult)
    recordCells
      context
      [ ("done-deletes", done == 1 && doneDepth == (0 :: Int64)),
        ("retry-delay-and-attempt", retried == 1 && beforeRetry == 0 && afterRetry == 1 && observedAttempts == [Just 0, Just 1]),
        ("enqueue-delay", beforeDelay == 0 && afterDelay == 1),
        ("dead-letter", dead == 1 && deadDepth == (0 :: Int64) && fst deadLettered == (1 :: Int64) && Text.isPrefixOf "poison_pill" (snd deadLettered)),
        ("default-retry-delay", defaultFirst == 1 && defaultEarly == 0 && defaultSecond == 1 && observedDefaultAttempts == [Just 0, Just 1]),
        ("archive-when-dlq-disabled", archiveHandled == 1 && archiveDepth == 0 && archived == 1),
        ("batch-ids-and-rows", length batchIds == 3 && length (nub batchIds) == 3 && batchDepth == 3),
        ("group-header", groupedHeaders == 1),
        ("drain-handler-exception", thrownResult == 0 && thrownEarly == 0 && thrownDepth == 1 && thrownRedelivery == 1),
        ("malformed-payload", malformedHandled == 1 && malformedDepth == 0 && fst malformedDead == 1 && Text.isPrefixOf "invalid_payload" (snd malformedDead)),
        ("future-payload-retries", futureHandled == 1 && futureEarly == 0 && futureDepth == 1 && futureFirstReadCount == 1 && futureSecond == 1 && futureSecondReadCount == 2),
        ("worker-done-and-context", fst workerDelivery && snd workerDelivery),
        ("worker-retry", case workerOutcomes of ((Just (effects, _), _), _, _) -> effects == 2; _ -> False),
        ("worker-dead-letter", case workerOutcomes of (_, (Just (effects, (count, reason)), _), _) -> effects == 1 && count == 1 && Text.isPrefixOf "poison_pill" reason; _ -> False),
        ("worker-handler-exception-redelivery", case workerOutcomes of (_, _, (Just (effects, _), _)) -> effects == 2; _ -> False)
      ]

maxRetriesBeforeHandler :: Scenario
maxRetriesBeforeHandler =
  consumptionConfigRejections
    { id = either (error . show) id (parseScenarioId "keiro/queue/correctness/max-retries-before-handler"),
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
      revision = 1,
      summary = "Checks job tuning validation runs before a queued message is read.",
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
        mismatched = withOrdering FifoHeads defaultJobTuning
        legacyJob = job {jobOrdering = FifoThroughput}
        legacyTuning = (withOrdering FifoThroughput defaultJobTuning) {batchSize = 2}
        attempt tuning target = try @JobConsumptionConfigError (runJobEff runtime (runJobOnceWithContext tuning 1 target handler))
    setup <- runJobEff runtime do
      ensureJobQueue job
      enqueue job ("one" :: Text)
    _ <- either (fail . show) pure setup
    visibility <- attempt invalidVisibility job
    batch <- attempt invalidBatch job
    polling <- attempt invalidPolling job
    mismatch <- attempt mismatched job
    unsafeBatch <- attempt legacyTuning legacyJob
    precedence <- attempt (withOrdering FifoHeads invalidVisibility) job
    let queueTable = "pgmq.q_" <> queueNameToText job.jobQueue.physicalName
        readState = Statement.preparable ("SELECT count(*), coalesce(max(read_ct),0)::bigint FROM " <> queueTable) Encoders.noParams (Decoders.singleRow ((,) <$> Decoders.column (Decoders.nonNullable Decoders.int8) <*> Decoders.column (Decoders.nonNullable Decoders.int8)))
    before <- Pool.use runtime.runtimePool (Session.statement () readState) >>= either (fail . show) pure
    drained <- runJobEff runtime (runJobOnceWithContext defaultJobTuning 1 job handler)
    empty <- runJobEff runtime (runJobOnceWithContext defaultJobTuning 1 job handler)
    let cells =
          [ ("invalid-visibility", visibility == Left (InvalidJobTuning (NonPositiveVisibilityTimeout 0))),
            ("invalid-batch", batch == Left (InvalidJobTuning (NonPositiveBatchSize 0))),
            ("invalid-polling", polling == Left (InvalidJobTuning NonPositivePollInterval)),
            ("ordering-mismatch", mismatch == Left (JobOrderingMismatch Unordered FifoHeads)),
            ("unsafe-legacy-batch", unsafeBatch == Left (UnsafeLegacyFifoBatch FifoThroughput 2)),
            ("validation-precedence", precedence == Left (InvalidJobTuning (NonPositiveVisibilityTimeout 0))),
            ("read-count-untouched", before == (1 :: Int64, 0 :: Int64)),
            ("rejections-did-not-consume-job", either (const False) (== 1) drained && either (const False) (== 0) empty)
          ]
    recordCells context cells
