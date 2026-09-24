module Kenshou.Suite.Keiro.Queue.Correctness (scenarios) where

import Control.Exception (try)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Keiro.PGMQ.Codec (aesonJobCodec)
import Keiro.PGMQ.Job (Job (..), JobConsumptionConfigError (..), JobOrdering (..), JobOutcome (..), JobPolling (..), JobTuning (..), JobTuningConfigError (..), defaultJobTuning, defaultRetryPolicy, enqueue, ensureJobQueue, runJobOnceWithContext, withOrdering)
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
scenarios = [consumptionConfigRejections]

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
