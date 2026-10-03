module Kenshou.Suite.Keiro.Fixture.Oracle
  ( LoggedEvent (..),
    TimerRow (..),
    DispatchDeadLetter (..),
    SubscriptionDeadLetter (..),
    CheckpointRow (..),
    StageCounts (..),
    readCategoryLog,
    readBalanceTable,
    readActivityTable,
    readSnapshots,
    readTimers,
    readDispatchDeadLetters,
    readSubscriptionDeadLetters,
    readCheckpoints,
    readStageCounts,
    stageBacklog,
    expectedSagaStateId,
    expectedSagaCommandId,
    expectedRouterCommandId,
    modelFromLog,
    logWellFormed,
  )
where

import Data.Aeson (Value)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString.Char8
import Data.Int (Int32, Int64)
import Data.List (group, sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (UTCTime)
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID.V5
import Hasql.Connection qualified as Connection
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Keiro.Codec (Codec (..))
import Kenshou.Suite.Keiro.Fixture.Account (accountCodec, accountStreamName)
import Kenshou.Suite.Keiro.Fixture.Domain
import Kenshou.Suite.Keiro.Fixture.Model qualified as Model
import Kiroku.Store.Types (EventId (..), EventType (..), StreamName (..))

expectedSagaStateId :: Text -> TransferId -> EventId -> EventId
expectedSagaStateId manager transfer source = expectedSagaCommandId manager transfer source (-1)

expectedSagaCommandId :: Text -> TransferId -> EventId -> Int -> EventId
expectedSagaCommandId manager (TransferId transfer) (EventId source) index =
  EventId (UUID.V5.generateNamed UUID.V5.namespaceURL (ByteString.unpack (Text.encodeUtf8 seed)))
  where
    seed = Text.intercalate ":" ["keiro", "process-manager", manager, transfer, UUID.toText source, Text.pack (show index)]

expectedRouterCommandId :: Text -> BonusId -> EventId -> AccountId -> Int -> EventId
expectedRouterCommandId router (BonusId bonus) (EventId source) account occurrence =
  EventId (UUID.V5.generateNamed UUID.V5.namespaceURL (ByteString.unpack encoded))
  where
    StreamName target = accountStreamName account
    fields = ["keiro", "router", router, bonus, UUID.toText source, target, Text.pack (show occurrence)]
    encodeField field =
      let bytes = Text.encodeUtf8 field
       in ByteString.concat [ByteString.Char8.pack (show (ByteString.length bytes)), ByteString.singleton 58, bytes]
    encoded = ByteString.concat (map encodeField fields)

data LoggedEvent = LoggedEvent
  { streamName :: !StreamName,
    streamVersion :: !Int64,
    globalPosition :: !Int64,
    eventId :: !EventId,
    eventType :: !EventType,
    payload :: !Value
  }
  deriving stock (Eq, Show)

data TimerRow = TimerRow
  { timerId :: !Text,
    processManagerName :: !Text,
    correlationId :: !Text,
    fireAt :: !UTCTime,
    status :: !Text
  }
  deriving stock (Eq, Show)

data DispatchDeadLetter = DispatchDeadLetter
  { dispatcherKind :: !Text,
    dispatcherName :: !Text,
    emitIndex :: !Int32,
    targetStreamName :: !Text,
    errorClass :: !Text
  }
  deriving stock (Eq, Show)

readDispatchDeadLetters :: Connection.Connection -> IO [DispatchDeadLetter]
readDispatchDeadLetters connection = do
  rows <- Connection.use connection (Session.statement () statement) >>= either (fail . show) pure
  pure [DispatchDeadLetter kind name index target category | (kind, name, index, target, category) <- rows]
  where
    statement =
      Statement.preparable
        "SELECT dispatcher_kind, dispatcher_name, emit_index, target_stream_name, error_class FROM keiro.keiro_dead_letters ORDER BY dead_letter_id"
        Encoders.noParams
        (Decoders.rowList ((,,,,) <$> text <*> text <*> Decoders.column (Decoders.nonNullable Decoders.int4) <*> text <*> text))
    text = Decoders.column (Decoders.nonNullable Decoders.text)

data SubscriptionDeadLetter = SubscriptionDeadLetter
  { subscriptionName :: !Text,
    consumerGroupMember :: !Int32,
    globalPosition :: !Int64,
    reasonKind :: !(Maybe Text),
    attemptCount :: !Int32
  }
  deriving stock (Eq, Show)

-- | Rows of @kiroku.dead_letters@, read directly from the table rather than
-- through the subscription API under test.
readSubscriptionDeadLetters :: Connection.Connection -> IO [SubscriptionDeadLetter]
readSubscriptionDeadLetters connection = do
  rows <- Connection.use connection (Session.statement () statement) >>= either (fail . show) pure
  pure [SubscriptionDeadLetter name member position kind attempts | (name, member, position, kind, attempts) <- rows]
  where
    statement =
      Statement.preparable
        "SELECT subscription_name, consumer_group_member, global_position, reason->>'kind', attempt_count FROM kiroku.dead_letters ORDER BY dead_letter_id"
        Encoders.noParams
        (Decoders.rowList ((,,,,) <$> text <*> int4 <*> Decoders.column (Decoders.nonNullable Decoders.int8) <*> Decoders.column (Decoders.nullable Decoders.text) <*> int4))
    text = Decoders.column (Decoders.nonNullable Decoders.text)
    int4 = Decoders.column (Decoders.nonNullable Decoders.int4)

data CheckpointRow = CheckpointRow
  { subscriptionName :: !Text,
    consumerGroupMember :: !Int32,
    consumerGroupSize :: !Int32,
    lastSeen :: !Int64
  }
  deriving stock (Eq, Show)

-- | Durable subscription checkpoints (@kiroku.subscriptions.last_seen@).
readCheckpoints :: Connection.Connection -> IO [CheckpointRow]
readCheckpoints connection = do
  rows <- Connection.use connection (Session.statement () statement) >>= either (fail . show) pure
  pure [CheckpointRow name member size seen | (name, member, size, seen) <- rows]
  where
    statement =
      Statement.preparable
        "SELECT subscription_name, consumer_group_member, consumer_group_size, last_seen FROM kiroku.subscriptions ORDER BY subscription_name, consumer_group_member"
        Encoders.noParams
        (Decoders.rowList ((,,,) <$> Decoders.column (Decoders.nonNullable Decoders.text) <*> int4 <*> int4 <*> Decoders.column (Decoders.nonNullable Decoders.int8)))
    int4 = Decoders.column (Decoders.nonNullable Decoders.int4)

-- | Durable counts for every stage of the write-side pipeline. Unlike
-- 'readCategoryLog' this reads no payloads, so a scenario may sample it while
-- the system is under load.
data StageCounts = StageCounts
  { transferDebited :: !Int64,
    transferAnnounced :: !Int64,
    transferCredited :: !Int64,
    transferConfirmed :: !Int64,
    sagaEvents :: !Int64,
    bonusDeclared :: !Int64,
    bonusCredited :: !Int64,
    accountEvents :: !Int64,
    activityApplied :: !Int64
  }
  deriving stock (Eq, Show)

readStageCounts :: Connection.Connection -> IO StageCounts
readStageCounts connection = do
  rows <- Connection.use connection (Session.statement () statement) >>= either (fail . show) pure
  applied <- Connection.use connection (Session.statement () activityStatement) >>= either (fail . show) pure
  let count kind = sum [n | (name, n) <- rows, name == kind]
      accountKinds = ["AccountOpened", "Deposited", "Withdrawn", "TransferDebited", "TransferAnnounced", "TransferCredited", "TransferConfirmed", "BonusCredited", "AccountClosed"]
  pure
    StageCounts
      { transferDebited = count "TransferDebited",
        transferAnnounced = count "TransferAnnounced",
        transferCredited = count "TransferCredited",
        transferConfirmed = count "TransferConfirmed",
        sagaEvents = count "DebitObserved" + count "AnnounceObserved",
        bonusDeclared = count "BonusDeclared",
        bonusCredited = count "BonusCredited",
        accountEvents = sum (map count accountKinds),
        activityApplied = applied
      }
  where
    statement =
      Statement.preparable
        "SELECT event_type, count(*) FROM kiroku.events GROUP BY event_type"
        Encoders.noParams
        (Decoders.rowList ((,) <$> Decoders.column (Decoders.nonNullable Decoders.text) <*> Decoders.column (Decoders.nonNullable Decoders.int8)))
    activityStatement =
      Statement.preparable
        "SELECT coalesce(sum(events_applied), 0)::bigint FROM kenshou_keiro.account_activity"
        Encoders.noParams
        (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

-- | Work accepted by an upstream stage but not yet completed downstream, for a
-- router fanout. Every value is zero exactly when the pipeline is quiescent.
stageBacklog :: Int64 -> StageCounts -> [(Text, Int64)]
stageBacklog fanout counts =
  [ ("announce", counts.transferDebited - counts.transferAnnounced),
    ("credit", counts.transferDebited - counts.transferCredited),
    ("confirm", counts.transferDebited - counts.transferConfirmed),
    ("saga", 2 * counts.transferDebited - counts.sagaEvents),
    ("bonus", counts.bonusDeclared * fanout - counts.bonusCredited),
    ("activity", counts.accountEvents - counts.activityApplied)
  ]

readTimers :: Connection.Connection -> IO [TimerRow]
readTimers connection = do
  rows <- Connection.use connection (Session.statement () statement) >>= either (fail . show) pure
  pure [TimerRow identifier manager correlation due state | (identifier, manager, correlation, due, state) <- rows]
  where
    statement =
      Statement.preparable
        "SELECT timer_id::text, process_manager_name, correlation_id, fire_at, status FROM keiro.keiro_timers ORDER BY timer_id"
        Encoders.noParams
        (Decoders.rowList ((,,,,) <$> text <*> text <*> text <*> Decoders.column (Decoders.nonNullable Decoders.timestamptz) <*> text))
    text = Decoders.column (Decoders.nonNullable Decoders.text)

readCategoryLog :: Connection.Connection -> Text -> IO [LoggedEvent]
readCategoryLog connection category = do
  rows <- Connection.use connection (Session.statement category categoryLogStatement) >>= either (fail . show) pure
  traverse convert rows
  where
    convert (name, version, position, identifier, kind, payload) =
      case UUID.fromText identifier of
        Nothing -> fail ("invalid event UUID in log: " <> Text.unpack identifier)
        Just uuid -> pure (LoggedEvent (StreamName name) version position (EventId uuid) (EventType kind) payload)

readBalanceTable :: Connection.Connection -> IO (Map.Map AccountId (Int64, Int64, Int64))
readBalanceTable connection = do
  rows <- Connection.use connection (Session.statement () statement) >>= either (fail . show) pure
  pure (Map.fromList [(AccountId accountId, (balance, entries, version)) | (accountId, balance, entries, version) <- rows])
  where
    statement =
      Statement.preparable
        "SELECT account_id, balance, entries, last_version FROM kenshou_keiro.account_balance ORDER BY account_id"
        Encoders.noParams
        (Decoders.rowList ((,,,) <$> text <*> int8 <*> int8 <*> int8))
    text = Decoders.column (Decoders.nonNullable Decoders.text)
    int8 = Decoders.column (Decoders.nonNullable Decoders.int8)

readActivityTable :: Connection.Connection -> IO (Map.Map AccountId (Int64, Int64))
readActivityTable connection = do
  rows <- Connection.use connection (Session.statement () statement) >>= either (fail . show) pure
  pure (Map.fromList [(AccountId accountId, (eventsApplied, netAmount)) | (accountId, eventsApplied, netAmount) <- rows])
  where
    statement =
      Statement.preparable
        "SELECT account_id, events_applied, net_amount FROM kenshou_keiro.account_activity ORDER BY account_id"
        Encoders.noParams
        (Decoders.rowList ((,,) <$> Decoders.column (Decoders.nonNullable Decoders.text) <*> Decoders.column (Decoders.nonNullable Decoders.int8) <*> Decoders.column (Decoders.nonNullable Decoders.int8)))

readSnapshots :: Connection.Connection -> IO (Map.Map StreamName (Int64, Value))
readSnapshots connection = do
  rows <- Connection.use connection (Session.statement () statement) >>= either (fail . show) pure
  pure (Map.fromList [(StreamName name, (version, state)) | (name, version, state) <- rows])
  where
    statement =
      Statement.preparable
        "SELECT s.stream_name, sn.stream_version, sn.state FROM keiro.keiro_snapshots sn JOIN kiroku.streams s ON s.stream_id = sn.stream_id ORDER BY s.stream_name"
        Encoders.noParams
        (Decoders.rowList ((,,) <$> Decoders.column (Decoders.nonNullable Decoders.text) <*> Decoders.column (Decoders.nonNullable Decoders.int8) <*> Decoders.column (Decoders.nonNullable Decoders.jsonb)))

categoryLogStatement :: Statement.Statement Text [(Text, Int64, Int64, Text, Text, Value)]
categoryLogStatement =
  Statement.preparable
    "SELECT s.stream_name, se.stream_version, g.stream_version AS global_position, e.event_id::text, e.event_type, e.data FROM kiroku.streams s JOIN kiroku.stream_events se ON se.stream_id = s.stream_id AND se.original_stream_id = s.stream_id JOIN kiroku.events e ON e.event_id = se.event_id JOIN kiroku.stream_events g ON g.event_id = e.event_id AND g.stream_id = 0 WHERE s.category = $1 ORDER BY s.stream_name, se.stream_version"
    (Encoders.param (Encoders.nonNullable Encoders.text))
    (Decoders.rowList ((,,,,,) <$> text <*> int8 <*> int8 <*> text <*> text <*> jsonb))
  where
    text = Decoders.column (Decoders.nonNullable Decoders.text)
    int8 = Decoders.column (Decoders.nonNullable Decoders.int8)
    jsonb = Decoders.column (Decoders.nonNullable Decoders.jsonb)

logWellFormed :: [LoggedEvent] -> Bool
logWellFormed rows =
  uniqueIds && all contiguous (Map.elems byStream)
  where
    uniqueIds = let identifiers = sort (map (.eventId) rows) in all ((== 1) . length) (group identifiers)
    byStream = Map.fromListWith (<>) [(row.streamName, [row.streamVersion]) | row <- rows]
    contiguous versions = sort versions == [1 .. fromIntegral (length versions)]

modelFromLog :: [LoggedEvent] -> Either Text Model.Model
modelFromLog = foldl step (Right Model.emptyModel)
  where
    step (Left issue) _ = Left issue
    step (Right model) row = do
      event <- accountCodec.decode row.eventType row.payload
      let current = Model.lookupAccount (eventAccountId event) model
      if valid current event
        then Right (Model.apply event model)
        else Left ("invalid event transition in " <> case row.streamName of StreamName name -> name)
    valid current = \case
      AccountOpened d -> current.state == AcctUnopened && d.openingBalance >= 0
      Deposited d -> current.state == AcctOpen && d.amount > 0
      Withdrawn d -> current.state == AcctOpen && d.amount > 0 && current.balance >= d.amount
      TransferDebited d -> current.state == AcctOpen && d.amount > 0 && current.balance >= d.amount
      TransferAnnounced {} -> current.state == AcctOpen
      TransferCredited d -> current.state == AcctOpen && d.amount > 0
      TransferConfirmed {} -> current.state == AcctOpen
      BonusCredited d -> current.state == AcctOpen && d.amount > 0
      AccountClosed {} -> current.state == AcctOpen && current.balance == 0
