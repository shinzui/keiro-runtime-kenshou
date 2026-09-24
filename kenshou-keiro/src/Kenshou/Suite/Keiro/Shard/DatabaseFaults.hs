module Kenshou.Suite.Keiro.Shard.DatabaseFaults (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically, retry)
import Control.Exception (bracket)
import Data.Aeson (object, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx
import Keiro.Subscription.Shard (ownershipSnapshotFor)
import Kenshou.Check.Fault (Availability (..), Fault (..), FaultHandle (..))
import Kenshou.Check.Fault.Postgres (Backend (..), BackendSelector (..), CrashMode (..), crashPostmaster, listBackends, terminateBackends, withApplicationName)
import Kenshou.Check.Process (ProgressSnapshot (..), awaitReady, progress, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (knobInt)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..), WorkerMessage (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Shard.Knobs (shardKnobName, shardKnobs)
import Kenshou.Suite.Keiro.Shard.Oracle (recordShardCells)
import Kenshou.Suite.Keiro.Workflow.Fixture (durableKirokuStore, ensureDurableTables, runDurable, withDurableStore)
import Kiroku.Store (defaultConnectionSettings, runStoreIO, runTransaction)
import Kiroku.Store.Subscription.Types (SubscriptionName (..))
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [databaseFaults]

databaseFaults :: Scenario
databaseFaults =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/shard/concurrency/database-faults"),
      revision = 1,
      summary = "Terminates shard reader backends and restarts the local postmaster while checking error hooks and delivery recovery.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = shardKnobs,
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgFsyncOff :| [PgDurable]) PgFsyncOff),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku, SchemaKeiro] [] False)},
      knownDefect = Nothing,
      run = runDatabaseFaults
    }

runDatabaseFaults :: RunContext -> IO ScenarioReport
runDatabaseFaults context = withCheck context \check -> do
  let postgres = requirePostgres context
  withDurableStore (defaultConnectionSettings postgres.connectionString) \fixture -> do
    ensureDurableTables fixture
    let store = durableKirokuStore fixture
        name = SubscriptionName "kenshouShardDatabaseFaults"
        bucketCount = fromIntegral (knobInt context.knobs (shardKnobName "shard.shard-count")) :: Int
        eventCount = fromIntegral (knobInt context.knobs (shardKnobName "shard.events")) :: Int
        streamCount = fromIntegral (knobInt context.knobs (shardKnobName "shard.streams")) :: Int
        sinkCount = runDurable fixture (runTransaction (Tx.statement () sinkCountStatement))
        ownership = runStoreIO store (ownershipSnapshotFor name)
        covered result = case result of Right rows -> length rows == bucketCount && all (\(_, owner, _) -> owner /= Nothing) rows; Left _ -> False
    (appenderDone, backendPresent, hookSeen, postmasterRecovered, workerStayedAlive, drained, finalCoverage) <- withSupervisor check \supervisor -> do
      appenderSpec <- roleProcess check "keiro/shard-appender" 0 (object ["eventCount" .= eventCount, "streamCount" .= streamCount, "idPrefix" .= ("kenshou:shard:database-fault:" :: Text), "streamPrefix" .= ("account-database-fault-" :: Text)])
      appender <- spawn supervisor appenderSpec
      awaitReady appender 10000
      sendCommand appender CtlStart
      appenderDone <- timeout 180000000 $ atomically do
        state <- progress appender
        case state.lastMessage of
          Just (WrkDone Nothing) -> pure True
          Just (WrkError _) -> pure False
          _ -> retry
      workerSpec <- roleProcess check "keiro/shard-worker" 0 (object ["subscription" .= ("kenshouShardDatabaseFaults" :: Text), "shardCount" .= bucketCount, "delivery" .= True, "handlerDelayMicros" .= (5000 :: Int)])
      worker <- spawn supervisor (withApplicationName "kenshou-shard-fault" workerSpec)
      awaitReady worker 10000
      sendCommand worker CtlStart
      _ <- waitUntil (covered <$> ownership) 160
      _ <- waitUntil ((\count -> case count of Right value -> value > 0 && value < eventCount; Left _ -> False) <$> sinkCount) 80
      backends <- listBackends postgres
      let backendPresent = any (Text.isPrefixOf "kenshou-shard-fault" . (.applicationName)) backends
      handle <- (terminateBackends postgres (ByApplicationName "kenshou-shard-fault%")).inject
      handle.heal
      let postmasterFault = crashPostmaster postgres KillPostmaster
      available <- postmasterFault.availability
      postmasterRecovered <- case available of
        Unavailable _ -> pure False
        Available -> bracket postmasterFault.inject (.heal) (\_ -> threadDelay 500000) >> pure True
      hookSeen <-
        waitUntil
          ( do
              state <- atomically (progress worker)
              pure (Map.member "shard-error-reader-died" state.marks || Map.member "shard-error-acquire-failed" state.marks)
          )
          80
      drained <- waitUntil ((== Right eventCount) <$> sinkCount) (max 200 (eventCount `div` 10))
      finalCoverage <- covered <$> ownership
      state <- atomically (progress worker)
      let workerStayedAlive = case state.lastMessage of Just (WrkError _) -> False; Just (WrkDone _) -> False; _ -> True
      _ <- stopGracefully supervisor worker 5000
      pure (appenderDone == Just True, backendPresent, hookSeen, postmasterRecovered, workerStayedAlive, drained, finalCoverage)
    recordShardCells
      check
      [ ("appender-prepared-events", appenderDone),
        ("reader-backend-terminated", backendPresent),
        ("error-hook-reported-reader-or-acquire", hookSeen),
        ("postmaster-restarted", postmasterRecovered),
        ("worker-survived-faults", workerStayedAlive),
        ("all-events-delivered", drained),
        ("ownership-recovered", finalCoverage)
      ]

waitUntil :: IO Bool -> Int -> IO Bool
waitUntil _ 0 = pure False
waitUntil predicate remaining = do
  complete <- predicate
  if complete then pure True else threadDelay 250000 >> waitUntil predicate (remaining - 1)

sinkCountStatement :: Statement.Statement () Int
sinkCountStatement =
  Statement.preparable
    "SELECT count(*)::int FROM kenshou_durable.shard_sink"
    Encoders.noParams
    (fromIntegral <$> Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int4)))
