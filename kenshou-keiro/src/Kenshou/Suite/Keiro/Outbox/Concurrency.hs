module Kenshou.Suite.Keiro.Outbox.Concurrency (scenarios) where

import Control.Concurrent (threadDelay)
import Data.Aeson (object, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Keiro.Integration.Event (IntegrationEvent (..), headerMessageId)
import Keiro.Outbox (BackoffSchedule (..), OutboxMaintenanceOptions (..), OutboxMaintenanceSummary (..), OutboxPublishOptions (..), OutboxPublishSummary (..), OutboxRow (..), OutboxStatus (..), countOutboxBacklog, defaultPublishOptions, listOutbox, outboxMaintenancePass, publishClaimedOutbox)
import Kenshou.Check.Process (awaitMark, awaitReady, childPid, killChild, roleProcess, sendCommand, spawn, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobInt, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Fixture.Runtime (FixtureEnv (..), KeiroRunner (..), withFixtureEnv)
import Kenshou.Suite.Keiro.Messaging.Verdict (recordMessagingCells)
import Kenshou.Suite.Keiro.Outbox.Broker qualified as Broker
import Kenshou.Suite.Keiro.Outbox.Oracle qualified as Oracle
import Kenshou.Suite.Keiro.Outbox.Workload (enqueueInline, sourceName)
import Kiroku.Store (defaultConnectionSettings)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [crashBetweenPublishAndMark, multiProcessPublishers]

multiProcessPublishers :: Scenario
multiProcessPublishers =
  crashBetweenPublishAndMark
    { id = either (error . show) id (parseScenarioId "keiro/outbox/concurrency/multi-process-publishers"),
      summary = "Checks four live publisher processes claim disjoint rows and preserve key order.",
      knobs =
        [ KnobSpec (knobName "outbox.rows") "Number of integration events" KnobInt (VInt 20000) (IntRange 32 20000) [],
          KnobSpec (knobName "outbox.key-cardinality") "Number of partition keys" KnobInt (VInt 200) (IntRange 1 200) []
        ],
      run = runMultiProcessPublishers
    }

runMultiProcessPublishers :: RunContext -> IO ScenarioReport
runMultiProcessPublishers context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture ->
    Broker.withTableBroker (requirePostgres context).connectionString \broker ->
      withCheck context \check -> withSupervisor check \supervisor -> do
        let KeiroRunner runFixture = fixture.runner
            source = sourceName context "multi-publisher"
            rowCount = fromIntegral (knobInt context.knobs (knobName "outbox.rows"))
            keyCardinality = fromIntegral (knobInt context.knobs (knobName "outbox.key-cardinality"))
            entries = [(Text.pack (show index), Just ("key-" <> Text.pack (show (index `mod` keyCardinality))), index) | index <- [1 .. rowCount :: Int]]
        enqueueInline fixture source entries
        children <- traverse (\index -> roleProcess check "keiro/outbox-publisher" index (object ["loop" .= True]) >>= spawn supervisor) [0 .. 3 :: Int]
        mapM_ (\child -> awaitReady child 10000) children
        mapM_ (\child -> sendCommand child CtlStart) children
        mapM_ (\child -> awaitMark child "finished" 300000) children
        rows <- runFixture (listOutbox source) >>= either (fail . show) pure
        records <- Broker.readBroker broker
        let messageIds = [value | record <- records, (name, value) <- record.headers, name == TextEncoding.encodeUtf8 headerMessageId]
            counts = Map.fromListWith (+) [(messageId, 1 :: Int) | messageId <- messageIds]
            expectedIds = map (TextEncoding.encodeUtf8 . (.messageId) . (.event)) rows
            expectedOrder = Map.fromList [(TextEncoding.encodeUtf8 messageId, (key, index)) | (messageId, Just key, index) <- entries]
            observedOrder = [pair | messageId <- messageIds, Just pair <- [Map.lookup messageId expectedOrder]]
            publisherCounts = Map.fromListWith (+) [(record.publisher, 1 :: Int) | record <- records]
            cells =
              [ ("no-loss", length rows == rowCount && all ((== OutboxSent) . (.status)) rows && all (`Map.member` counts) expectedIds),
                ("disjoint-ownership", length records == rowCount && all (== 1) (Map.elems counts) && all ((== 1) . (.attemptCount)) rows),
                ("per-key-order", length observedOrder == rowCount && Oracle.perKeyOrder observedOrder)
              ]
            evidence = Map.fromList [("enqueued", fromIntegral rowCount), ("brokerRecords", fromIntegral (length records)), ("publishers", 4)]
        recordMessagingCells context evidence (object ["publisherCounts" .= publisherCounts]) cells

crashBetweenPublishAndMark :: Scenario
crashBetweenPublishAndMark =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/outbox/concurrency/crash-between-publish-and-mark"),
      revision = 1,
      summary = "Kills a publisher after durable broker append and checks maintenance reclamation and bounded replay.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs =
        [ KnobSpec (knobName "outbox.rows") "Number of integration events" KnobInt (VInt 2000) (IntRange 32 20000) [],
          KnobSpec (knobName "outbox.kills") "Publisher processes killed after broker append" KnobInt (VInt 3) (IntRange 1 8) [],
          KnobSpec (knobName "outbox.key-cardinality") "Number of partition keys" KnobInt (VInt 20) (IntRange 1 200) []
        ],
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

knobName :: Text.Text -> KnobName
knobName = either (error . show) id . mkKnobName

runCrashBetweenPublishAndMark :: RunContext -> IO ScenarioReport
runCrashBetweenPublishAndMark context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture ->
    Broker.withTableBroker (requirePostgres context).connectionString \broker ->
      withCheck context \check -> withSupervisor check \supervisor -> do
        let KeiroRunner runFixture = fixture.runner
            source = sourceName context "crash"
            rowCount = fromIntegral (knobInt context.knobs (knobName "outbox.rows"))
            killCount = fromIntegral (knobInt context.knobs (knobName "outbox.kills"))
            keyCardinality = fromIntegral (knobInt context.knobs (knobName "outbox.key-cardinality"))
            entries = [(Text.pack (show index), Just ("key-" <> Text.pack (show (index `mod` keyCardinality))), index) | index <- [1 .. rowCount :: Int]]
            options = defaultPublishOptions {batchSize = 32, backoff = ConstantBackoff 0}
            hooks = Broker.PublishHook (const (pure ())) (const (pure ()))
            callback = Broker.publishScripted broker (Broker.BrokerModel 0 0 4) (const Broker.Succeed) hooks "recovery"
            readRows = runFixture (listOutbox source) >>= either (fail . show) pure
        enqueueInline fixture source entries
        let recordIds records = [value | record <- records, (name, value) <- record.headers, name == TextEncoding.encodeUtf8 headerMessageId]
            killOne index = do
              before <- Broker.readBroker broker
              spec <- roleProcess check "keiro/outbox-publisher" index (object ["parkAfterAppend" .= True])
              child <- spawn supervisor spec
              awaitReady child 10000
              sendCommand child CtlStart
              awaitMark child "broker-appended" 30000
              after <- Broker.readBroker broker
              killChild supervisor child
              stranded <- readRows
              threadDelay (if index == 0 then 6000000 else 1500000)
              stillStranded <- readRows
              preMaintenance <- runFixture (publishClaimedOutbox callback options Nothing) >>= either (fail . show) pure
              maintenance <- runFixture (outboxMaintenancePass (OutboxMaintenanceOptions 10 1) Nothing) >>= either (fail . show) pure
              reclaimed <- readRows
              let newIds = drop (length before) (recordIds after)
                  publishing rows = Set.fromList [TextEncoding.encodeUtf8 row.event.messageId | row <- rows, row.status == OutboxPublishing]
                  failed rows = Set.fromList [TextEncoding.encodeUtf8 row.event.messageId | row <- rows, row.status == OutboxFailed]
                  held = length newIds == 32 && publishing stranded == Set.fromList newIds && publishing stillStranded == Set.fromList newIds && preMaintenance.claimed == 0 && maintenance.requeued == 32 && Set.fromList newIds `Set.isSubsetOf` failed reclaimed
              pure (newIds, held, fromIntegral (childPid child) :: Int)
        kills <- traverse killOne [0 .. killCount - 1]
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
        let messageIds = recordIds records
            counts = Map.fromListWith (+) [(messageId, 1 :: Int) | messageId <- messageIds]
            expectedIds = map (TextEncoding.encodeUtf8 . (.messageId) . (.event)) rows
            killedIds = Set.fromList (concat [ids | (ids, _, _) <- kills])
            firstIds = reverse (snd (foldl (\(seen, acc) messageId -> if Set.member messageId seen then (seen, acc) else (Set.insert messageId seen, messageId : acc)) (Set.empty, []) messageIds))
            expectedOrder = Map.fromList [(TextEncoding.encodeUtf8 messageId, (key, index)) | (messageId, Just key, index) <- entries]
            observedOrder = [pair | messageId <- firstIds, Just pair <- [Map.lookup messageId expectedOrder]]
            extras = length records - rowCount
            cells =
              [ ("kill-window-realised", length kills == killCount && all (not . null . (\(ids, _, _) -> ids)) kills),
                ("reclaimed-only-by-maintenance", all (\(_, held, _) -> held) kills),
                ("drained-before-deadline", maybe False (const True) finished),
                ("no-loss", length rows == rowCount && all ((== OutboxSent) . (.status)) rows && all (`Map.member` counts) expectedIds),
                ("bounded-duplicates", extras <= 32 * killCount && all (\(messageId, count) -> count <= 1 + killCount && (count == 1 || Set.member messageId killedIds)) (Map.toList counts)),
                ("per-key-order", length observedOrder == rowCount && Oracle.perKeyOrder observedOrder)
              ]
            evidence = Map.fromList [("enqueued", fromIntegral rowCount), ("brokerRecords", fromIntegral (length records)), ("killedPublishers", fromIntegral killCount), ("duplicatedMessages", fromIntegral (length [() | count <- Map.elems counts, count > 1]))]
        recordMessagingCells context evidence (object ["killedPids" .= [pid | (_, _, pid) <- kills]]) cells
