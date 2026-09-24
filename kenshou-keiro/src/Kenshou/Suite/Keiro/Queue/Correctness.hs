module Kenshou.Suite.Keiro.Queue.Correctness (scenarios) where

import Control.Exception (try)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Effectful (liftIO)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Keiro.PGMQ.Codec (aesonJobCodec)
import Keiro.PGMQ.Job (Job (..), JobConsumptionConfigError (..), JobOrdering (..), JobOutcome (..), JobPolling (..), JobTuning (..), JobTuningConfigError (..), RetryDelay (..), RetryPolicy (..), defaultJobTuning, defaultRetryPolicy, enqueue, ensureJobQueue, runJobOnceWithContext, withOrdering)
import Keiro.PGMQ.Runtime (JobRuntime (..), QueueRef (..), queueRef, runJobEff, withJobRuntime)
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Command.Correctness (recordCells)
import Kenshou.Suite.Keiro.Outbox.Workload (sourceName)
import Pgmq.Types (queueNameToText)

scenarios :: [Scenario]
scenarios = [consumptionConfigRejections, maxRetriesBeforeHandler]

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
