module Kenshou.Suite.Keiro.Outbox.Concurrency (scenarios) where

import Control.Concurrent (threadDelay)
import Data.Aeson (object, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Keiro.Integration.Event (IntegrationEvent (..), headerMessageId)
import Keiro.Outbox (BackoffSchedule (..), OutboxMaintenanceOptions (..), OutboxMaintenanceSummary (..), OutboxPublishOptions (..), OutboxPublishSummary (..), OutboxRow (..), OutboxStatus (..), countOutboxBacklog, defaultMaintenanceOptions, defaultPublishOptions, listOutbox, outboxMaintenancePass, publishClaimedOutbox)
import Kenshou.Check.Process (awaitMark, awaitReady, killChild, roleProcess, sendCommand, spawn, withSupervisor)
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
import Kenshou.Suite.Keiro.Fixture.Runtime (FixtureEnv (..), KeiroRunner (..), withFixtureEnv)
import Kenshou.Suite.Keiro.Outbox.Broker qualified as Broker
import Kenshou.Suite.Keiro.Outbox.Workload (enqueueInline, sourceName)
import Kiroku.Store (defaultConnectionSettings)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [crashBetweenPublishAndMark]

crashBetweenPublishAndMark :: Scenario
crashBetweenPublishAndMark =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/outbox/concurrency/crash-between-publish-and-mark"),
      revision = 1,
      summary = "Kills a publisher after durable broker append and checks maintenance reclamation and bounded replay.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = [],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku, SchemaKeiro] [] False)},
      knownDefect = Nothing,
      run = runCrashBetweenPublishAndMark
    }

runCrashBetweenPublishAndMark :: RunContext -> IO ScenarioReport
runCrashBetweenPublishAndMark context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture ->
    Broker.withTableBroker (requirePostgres context).connectionString \broker ->
      withCheck context \check -> withSupervisor check \supervisor -> do
        let KeiroRunner runFixture = fixture.runner
            source = sourceName context "crash"
            entries = [(Text.pack (show index), Just "key", index) | index <- [1 .. 32 :: Int]]
            options = defaultPublishOptions {batchSize = 32, backoff = ConstantBackoff 0}
            hooks = Broker.PublishHook (const (pure ())) (const (pure ()))
            callback = Broker.publishScripted broker (Broker.BrokerModel 0 0 4) (const Broker.Succeed) hooks "recovery"
            readRows = runFixture (listOutbox source) >>= either (fail . show) pure
        enqueueInline fixture source entries
        spec <- roleProcess check "keiro/outbox-publisher" 0 (object ["parkAfterAppend" .= True])
        child <- spawn supervisor spec
        awaitReady child 10000
        sendCommand child CtlStart
        awaitMark child "broker-appended" 30000
        firstRecords <- Broker.readBroker broker
        killChild supervisor child
        stranded <- readRows
        threadDelay 1500000
        stillStranded <- readRows
        preMaintenance <- runFixture (publishClaimedOutbox callback options Nothing) >>= either (fail . show) pure
        maintenance <- runFixture (outboxMaintenancePass defaultMaintenanceOptions {publishingTimeout = 1} Nothing) >>= either (fail . show) pure
        reclaimed <- readRows
        let drain = do
              backlog <- runFixture countOutboxBacklog >>= either (fail . show) pure
              if backlog == 0
                then pure ()
                else do
                  _ <- runFixture (publishClaimedOutbox callback options Nothing) >>= either (fail . show) pure
                  threadDelay 10000
                  drain
        finished <- timeout (300 * 1000000) drain
        rows <- readRows
        records <- Broker.readBroker broker
        let messageIds = [value | record <- records, (name, value) <- record.headers, name == TextEncoding.encodeUtf8 headerMessageId]
            counts = Map.fromListWith (+) [(messageId, 1 :: Int) | messageId <- messageIds]
            expectedIds = map (TextEncoding.encodeUtf8 . (.messageId) . (.event)) rows
            cells =
              [ ("kill-window-realised", length firstRecords == 32 && all ((== OutboxPublishing) . (.status)) stranded),
                ("reclaimed-only-by-maintenance", all ((== OutboxPublishing) . (.status)) stillStranded && preMaintenance.claimed == 0 && maintenance.requeued == 32 && all ((== OutboxFailed) . (.status)) reclaimed),
                ("drained-before-deadline", maybe False (const True) finished),
                ("no-loss", length rows == 32 && all ((== OutboxSent) . (.status)) rows && all (`Map.member` counts) expectedIds),
                ("bounded-duplicates", length records == 64 && all (\messageId -> Map.lookup messageId counts == Just 2) expectedIds)
              ]
        recordCells context cells
