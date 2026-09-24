module Kenshou.Suite.Keiro.Outbox.ProducerReplay (scenarios, role) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically, putTMVar)
import Control.Exception (finally)
import Control.Monad (forM, forever)
import Data.Aeson (Value, object, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseMaybe)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.UUID qualified as UUID
import Keiro.Command (defaultRunCommandOptions)
import Keiro.Integration.Event (IntegrationContentType (..), IntegrationEvent (..), headerMessageId)
import Keiro.Outbox (IntegrationEventDraft (..), IntegrationProducer (..), OutboxPublishOptions (..), OutboxRow (..), OutboxStatus (..), ProducerEnqueueOutcome (..), ProducerIdentity (..), countOutboxBacklog, defaultPublishOptions, enqueueProducerEventTx, listOutbox, mkIntegrationProducer, publishClaimedOutbox, recordProducerEnqueueOutcome)
import Kenshou.Check.Process (awaitMark, awaitReady, killChild, readChildMessages, roleProcess, sendCommand, spawn, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..), PostgresConnInfo (..), RoleContext (..), RoleName, WorkerInit (..), WorkerMessage (..), WorkerRole (..), mkRoleName)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Fixture.Account (AccountSnapshotPolicy (..), accountEventStream)
import Kenshou.Suite.Keiro.Fixture.Domain (AccountCommand (..), AccountId (..), DepositData (..), OpenAccountData (..))
import Kenshou.Suite.Keiro.Fixture.Runtime (CommandRunner (..), FixtureEnv (..), KeiroRunner (..), SubmitOutcome (..), submitAccountCommand, withFixtureEnv)
import Kenshou.Suite.Keiro.Messaging.Verdict (recordMessagingCells)
import Kenshou.Suite.Keiro.Outbox.Broker qualified as Broker
import Kenshou.Suite.Keiro.Outbox.Workload (sourceName)
import Kiroku.Store (defaultConnectionSettings, runTransaction)
import Kiroku.Store.Subscription.Stream (AckItem (..), subscriptionAckStream)
import Kiroku.Store.Subscription.Types (SubscriptionName (..), SubscriptionResult (..), SubscriptionTarget (..), defaultSubscriptionConfig)
import Kiroku.Store.Types (CategoryName (..), EventId (..), RecordedEvent (..), StreamVersion (..))
import Streamly.Data.Stream qualified as Streamly
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [subscriptionCrashReplay]

role :: WorkerRole
role = WorkerRole roleName "Enqueues account subscription events and can park before acknowledgement." producerWorker

roleName :: RoleName
roleName = either (error . Text.unpack) id (mkRoleName "keiro/outbox-producer")

data EnqueueMark = EnqueueMark
  { version :: !Int,
    eventId :: !Text,
    messageId :: !Text,
    outcome :: !Text
  }
  deriving stock (Eq, Show)

decodeMark :: Value -> Maybe EnqueueMark
decodeMark = parseMaybe (withObject "producer enqueue mark" (\value -> EnqueueMark <$> value .: "version" <*> value .: "eventId" <*> value .: "messageId" <*> value .: "outcome"))

producerWorker :: RoleContext -> IO ()
producerWorker context = case context.init.postgres of
  Nothing -> context.send (WrkError "outbox producer requires PostgreSQL")
  Just postgres -> case parseMaybe (withObject "producer args" (\value -> (,,,) <$> value .: "source" <*> value .: "subscription" <*> value .: "targetVersion" <*> value .: "parkAtVersion")) context.init.args of
    Nothing -> context.send (WrkError "invalid outbox producer arguments")
    Just (source, subscription, targetVersion, parkAtVersion) -> do
      context.send WrkReady
      context.receive >>= \case
        Just CtlStart -> withFixtureEnv (defaultConnectionSettings postgres.connectionString) \fixture -> do
          let KeiroRunner runFixture = fixture.runner
              producer :: IntegrationProducer ()
              producer = either (error . show) id (mkIntegrationProducer (IntegrationProducer "subscription-crash-replay" source "kenshou" (\recorded _ -> Just (draftFor recorded))))
              draftFor recorded =
                IntegrationEventDraft
                  { destination = "kenshou.outbox.v1",
                    key = Just source,
                    eventType = "AccountReplay",
                    schemaVersion = 1,
                    contentType = ApplicationJson,
                    schemaReference = Nothing,
                    sourceEventId = Nothing,
                    sourceGlobalPosition = Nothing,
                    payloadBytes = LazyByteString.toStrict (Aeson.encode recorded.payload),
                    occurredAt = recorded.createdAt,
                    causationId = Nothing,
                    correlationId = Nothing,
                    traceContext = Nothing,
                    attributes = Nothing
                  }
              config = defaultSubscriptionConfig (SubscriptionName subscription) (Category (CategoryName "account")) (\_ -> pure Continue)
              consume stream = do
                next <- timeout 30000000 (Streamly.uncons stream)
                case next of
                  Nothing -> fail "producer subscription timed out"
                  Just Nothing -> fail "producer subscription stopped before target version"
                  Just (Just (item, rest)) -> do
                    let recorded = item.ackEvent
                        StreamVersion version = recorded.streamVersion
                    draft <- maybe (fail "producer mapper skipped an account event") pure (producer.mapEvent recorded ())
                    result <- runFixture (runTransaction (enqueueProducerEventTx producer recorded 0 draft)) >>= either (fail . show) pure
                    recordProducerEnqueueOutcome Nothing result
                    let (label, identity) = case result of
                          ProducerInserted value -> ("inserted" :: Text, value)
                          ProducerDuplicateIdentical value -> ("duplicate", value)
                          ProducerIdentityConflict value _ -> ("conflict", value)
                    context.send (WrkCustom "producer-enqueued" (object ["version" .= version, "eventId" .= show recorded.eventId, "messageId" .= identity.messageId, "outcome" .= label]))
                    if version == parkAtVersion
                      then context.send (WrkCustom "producer-parked" (object ["version" .= version])) >> forever (threadDelay 1000000)
                      else do
                        atomically (putTMVar item.ackReply (if version == targetVersion then Stop else Continue))
                        if version == targetVersion
                          then do
                            stopped <- timeout 30000000 (Streamly.uncons rest)
                            case stopped of
                              Just Nothing -> context.send (WrkCustom "finished" (object ["version" .= version]))
                              _ -> fail "producer subscription did not stop after acknowledgement"
                          else consume rest
          (stream, cancelStream) <- subscriptionAckStream fixture.store config 4
          finally (consume stream) cancelStream
        _ -> pure ()

subscriptionCrashReplay :: Scenario
subscriptionCrashReplay =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/outbox/concurrency/producer-subscription-crash-replay"),
      revision = 1,
      summary = "Kills the producer before checkpoint acknowledgement and checks stable outbox identities on replay.",
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
      run = runSubscriptionCrashReplay
    }

runSubscriptionCrashReplay :: RunContext -> IO ScenarioReport
runSubscriptionCrashReplay context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture ->
    Broker.withTableBroker (requirePostgres context).connectionString \broker ->
      withCheck context \check -> withSupervisor check \supervisor -> do
        let account = AccountId (sourceName context "replay-account")
            source = sourceName context "replay-source"
            subscription = sourceName context "replay-subscription"
            submit version command = submitAccountCommand fixture (accountEventStream SnapNever) RunnerPlain defaultRunCommandOptions 0 (EventId (UUID.fromWords 0 0 0 (fromIntegral version))) command
            start index parkVersion = do
              spec <- roleProcess check "keiro/outbox-producer" index (object ["source" .= source, "subscription" .= subscription, "targetVersion" .= (8 :: Int), "parkAtVersion" .= parkVersion])
              child <- spawn supervisor spec
              awaitReady child 10000
              sendCommand child CtlStart
              pure child
        submissions <- forM [1 .. 8 :: Int] \version ->
          submit version (if version == 1 then OpenAccount (OpenAccountData account 0) else Deposit (DepositData account 1 ("replay-" <> Text.pack (show version))))
        killed <- forM [1 .. 3 :: Int] \version -> do
          child <- start version version
          awaitMark child "producer-parked" 30000
          killChild supervisor child
          readChildMessages child
        final <- start 4 (0 :: Int)
        awaitMark final "finished" 30000
        finalMessages <- readChildMessages final
        let marks = [mark | messages <- killed <> [finalMessages], WrkCustom "producer-enqueued" payload <- messages, Just mark <- [decodeMark payload]]
            byVersion = Map.fromListWith (<>) [(mark.version, [mark]) | mark <- marks]
            versions = [1 .. 8 :: Int]
            oneIdentity version = case Map.lookup version byVersion of
              Nothing -> False
              Just events -> Set.size (Set.fromList (map (.messageId) events)) == 1 && length [() | event <- events, event.outcome == "inserted"] == 1 && all ((/= "conflict") . (.outcome)) events
            replayed = all (\version -> maybe False (any ((== "duplicate") . (.outcome))) (Map.lookup version byVersion)) [1 .. 3 :: Int]
            KeiroRunner runFixture = fixture.runner
            callback = Broker.publishScripted broker (Broker.BrokerModel 0 0 4) (const Broker.Succeed) (Broker.PublishHook (const (pure ())) (const (pure ()))) "replay-publisher"
        _ <- runFixture (publishClaimedOutbox callback defaultPublishOptions {batchSize = 32} Nothing) >>= either (fail . show) pure
        rows <- runFixture (listOutbox source) >>= either (fail . show) pure
        records <- Broker.readBroker broker
        backlog <- runFixture countOutboxBacklog >>= either (fail . show) pure
        let rowEvents = [(Text.pack (show eventId), row.event.messageId) | row <- rows, Just eventId <- [row.event.sourceEventId]]
            expectedEvents = [(mark.eventId, mark.messageId) | version <- versions, Just (mark : _) <- [Map.lookup version byVersion]]
            brokerIds = [TextEncoding.decodeUtf8 value | record <- records, (name, value) <- record.headers, name == TextEncoding.encodeUtf8 headerMessageId]
            expectedOrder = [messageId | version <- versions, Just (mark : _) <- [Map.lookup version byVersion], let messageId = mark.messageId]
            cells =
              [ ("schedule-realised", length killed == 3 && replayed && all oneIdentity versions),
                ("one-row-per-source-event", length rows == 8 && sortOn fst rowEvents == sortOn fst expectedEvents && all ((== OutboxSent) . (.status)) rows),
                ("per-key-order", brokerIds == expectedOrder),
                ("no-conflicts-or-loss", all (\case SubmitAppended _ -> True; _ -> False) submissions && backlog == 0 && length records == 8 && all ((/= "conflict") . (.outcome)) marks)
              ]
        recordMessagingCells context (Map.fromList [("sourceEvents", 8), ("producerKills", 3), ("brokerRecords", fromIntegral (length records))]) (object ["deliveryVersions" .= map (.version) marks, "outcomes" .= map (.outcome) marks]) cells
