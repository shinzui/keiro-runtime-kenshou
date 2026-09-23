module Kenshou.Suite.Keiro.Fixture.Oracle
  ( LoggedEvent (..),
    readCategoryLog,
    readBalanceTable,
    modelFromLog,
    logWellFormed,
  )
where

import Data.Aeson (Value)
import Data.Int (Int64)
import Data.List (group, sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.UUID qualified as UUID
import Hasql.Connection qualified as Connection
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Keiro.Codec (Codec (..))
import Kenshou.Suite.Keiro.Fixture.Account (accountCodec)
import Kenshou.Suite.Keiro.Fixture.Domain
import Kenshou.Suite.Keiro.Fixture.Model qualified as Model
import Kiroku.Store.Types (EventId (..), EventType (..), StreamName (..))

data LoggedEvent = LoggedEvent
  { streamName :: !StreamName,
    streamVersion :: !Int64,
    globalPosition :: !Int64,
    eventId :: !EventId,
    eventType :: !EventType,
    payload :: !Value
  }
  deriving stock (Eq, Show)

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
