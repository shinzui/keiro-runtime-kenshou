module Kenshou.Suite.Keiro.Shard.Mismatch (scenarios) where

import Control.Concurrent.STM (atomically, retry)
import Data.Aeson (object, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Data.UUID qualified as UUID
import Keiro.Subscription.Shard (ShardLease (..), WorkerId (..), ensureShards, ownershipSnapshotFor)
import Kenshou.Check.Process (ProgressSnapshot (..), awaitReady, progress, roleProcess, sendCommand, spawn, withSupervisor)
import Kenshou.Check.Scenario (finishWithVerdicts, withCheck)
import Kenshou.Check.Verdict (InvariantClass (..), Verdict (..), VerdictStatus (..))
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..), WorkerMessage (..))
import Kenshou.Core.Scenario (CohortScope (..), KnownDefect (..), Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Workflow.Fixture (durableKirokuStore, withDurableStore)
import Kiroku.Store (defaultConnectionSettings, runStoreIO)
import Kiroku.Store.Subscription.Types (SubscriptionName (..))
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [mismatchProbe]

-- | The direct ensure path exercised here is the same path used by a shard
-- worker on startup. A larger misconfigured worker may commit extra rows
-- before the mismatch is thrown.
mismatchProbe :: Scenario
mismatchProbe =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/shard/correctness/shard-count-mismatch"),
      revision = 1,
      summary = "Starts separate workers with mismatched shard counts and checks that they cannot poison a correctly configured subscription.",
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
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku, SchemaKeiro] [] False)},
      knownDefect = Just (KnownDefect "mori://shinzui/keiro/okf/improvement-requests/concepts/IR-49" "A larger mismatched worker inserts extra shard rows before rejecting itself" ["shard-larger-worker-left-four", "shard-correct-worker-recovers"] AllCohorts),
      run = runMismatchProbe
    }

runMismatchProbe :: RunContext -> IO ScenarioReport
runMismatchProbe context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let store = durableKirokuStore fixture
        name = SubscriptionName "kenshouShardMismatch"
        worker = WorkerId UUID.nil
        lease count = ShardLease name worker count 10
        mismatch = \case
          Just (WrkError message) -> "ShardCountMismatch" `Text.isInfixOf` message
          _ -> False
        succeeded = (== Just (WrkDone Nothing))
    initial <- runStoreIO store (ensureShards (lease 4))
    (short, before, large, after, fresh) <- withSupervisor check \supervisor -> do
      let runWorker index count = do
            spec <- roleProcess check "keiro/shard-worker" index (object ["subscription" .= ("kenshouShardMismatch" :: Text), "shardCount" .= count])
            child <- spawn supervisor spec
            awaitReady child 10000
            sendCommand child CtlStart
            timeout 10000000 $ atomically do
              snapshot <- progress child
              case snapshot.lastMessage of
                Just message@(WrkDone _) -> pure message
                Just message@(WrkError _) -> pure message
                _ -> retry
      short <- runWorker 0 (2 :: Int)
      before <- runStoreIO store (ownershipSnapshotFor name)
      large <- runWorker 1 (6 :: Int)
      after <- runStoreIO store (ownershipSnapshotFor name)
      fresh <- runWorker 2 (4 :: Int)
      pure (short, before, large, after, fresh)
    now <- getCurrentTime
    let rowCount = either (const (-1)) length
        observed = rowCount after
        cells =
          [ ("initial-four", initial == Right ()),
            ("smaller-worker-rejected", mismatch short),
            ("smaller-worker-left-four", rowCount before == 4),
            ("larger-worker-rejected", mismatch large),
            ("larger-worker-left-four", observed == 4),
            ("correct-worker-recovers", succeeded fresh)
          ]
        verdict (nameText, held) =
          Verdict
            { checker = "shard-" <> nameText,
              invariant = nameText,
              cls = Contract,
              status = if held then Held else Violated,
              reason = Nothing,
              summary = if held then "Shard-count startup contract held" else "Shard-count startup contract failed",
              counts = Map.fromList [("expectedRows", 4), ("observedRows", fromIntegral observed)],
              parameters = object ["subscription" .= ("kenshouShardMismatch" :: Text)],
              counterExamples = if held then [] else [object ["rowsAfterLargerWorker" .= observed, "configuredShardCount" .= (4 :: Int)]],
              counterExamplesTruncated = False,
              inputs = [],
              replay = Nothing,
              checkedAt = now,
              durationMillis = 0
            }
    finishWithVerdicts check (map verdict cells)
