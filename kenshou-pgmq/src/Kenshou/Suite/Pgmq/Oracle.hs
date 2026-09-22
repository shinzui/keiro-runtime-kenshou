module Kenshou.Suite.Pgmq.Oracle
  ( LeaseFinding (..),
    EarlyDelivery (..),
    ConservationFinding (..),
    checkLeaseIntervals,
    checkNotBeforeDue,
    queueKeys,
    archiveKeys,
    conservation,
  )
where

import Data.Function (on)
import Data.Int (Int64)
import Data.List (groupBy, sortOn)
import Data.Maybe (mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time (UTCTime)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Kenshou.Suite.Pgmq.Facts (PgmqFact (..))
import Kenshou.Suite.Pgmq.Knobs (AckMode (..))
import Pgmq.Types (QueueName, queueNameToText)

data LeaseFinding
  = DuplicateReadCount {messageId :: Int64, readCount :: Int64}
  | OverlappingLease {messageId :: Int64, earlierVisibleAt :: UTCTime, laterReadAt :: UTCTime}
  deriving stock (Eq, Show)

data EarlyDelivery = EarlyDelivery {key :: Text, dueAt :: UTCTime, readAt :: UTCTime}
  deriving stock (Eq, Show)

data ConservationFinding = ConservationFinding
  { missingKeys :: Set Text,
    unexpectedKeys :: Set Text,
    durableKeys :: Set Text,
    deletedMessageIds :: Set Int64
  }
  deriving stock (Eq, Show)

checkLeaseIntervals :: [PgmqFact] -> [LeaseFinding]
checkLeaseIntervals facts = concatMap findingsFor grouped
  where
    leases = sortOn leaseOrder [(mid, count, readAt, visibleAt) | Leased _ mid count readAt visibleAt _ <- facts]
    leaseOrder (mid, count, _, _) = (mid, count)
    grouped = groupBy ((==) `on` firstOf4) leases
    firstOf4 (value, _, _, _) = value
    findingsFor entries = duplicateFindings entries <> overlapFindings entries
    duplicateFindings entries =
      [ DuplicateReadCount mid count
      | counts@((mid, count, _, _) : _) <- groupBy ((==) `on` secondOf4) entries,
        length counts > 1
      ]
    secondOf4 (_, value, _, _) = value
    overlapFindings entries =
      [ OverlappingLease mid cutoff nextReadAt
      | ((mid, _, earlierReadAt, visibleAt), (_, _, nextReadAt, _)) <- zip entries (drop 1 entries),
        let releases = [newVisibleAt | Released releasedId newVisibleAt <- facts, releasedId == mid, newVisibleAt >= earlierReadAt],
        let cutoff = minimum (visibleAt : releases),
        nextReadAt < cutoff
      ]

checkNotBeforeDue :: [PgmqFact] -> [EarlyDelivery]
checkNotBeforeDue facts = mapMaybe early leases
  where
    dueByMessage = [(mid, (key, due)) | Sent key mid _ _ (Just due) <- facts]
    leases = [(mid, readAt) | Leased _ mid _ readAt _ _ <- facts]
    early (mid, readAt) = case lookup mid dueByMessage of
      Just (key, due) | readAt < due -> Just (EarlyDelivery key due readAt)
      _ -> Nothing

queueKeys :: Pool -> QueueName -> IO (Set Text)
queueKeys pool queue = readKeys pool (qualifiedTable "q_" queue)

archiveKeys :: Pool -> QueueName -> IO (Set Text)
archiveKeys pool queue = readKeys pool (qualifiedTable "a_" queue)

conservation :: Pool -> QueueName -> [PgmqFact] -> IO ConservationFinding
conservation pool queue facts = do
  queued <- queueKeys pool queue
  archived <- archiveKeys pool queue
  let sent = Set.fromList [key | Sent key _ _ _ _ <- facts]
      deleted = Set.fromList [messageId | Acked messageId mode True <- facts, mode `elem` [AckDelete, AckBatchDelete]]
      deletedKeys = Set.fromList [key | Sent key messageId _ _ _ <- facts, messageId `Set.member` deleted]
      durable = queued <> archived <> deletedKeys
  pure
    ConservationFinding
      { missingKeys = sent `Set.difference` durable,
        unexpectedKeys = durable `Set.difference` sent,
        durableKeys = durable,
        deletedMessageIds = deleted
      }

readKeys :: Pool -> Text -> IO (Set Text)
readKeys pool table = do
  result <- Pool.use pool (Session.statement () statement)
  either (ioError . userError . show) (pure . Set.fromList) result
  where
    statement =
      Statement.unpreparable
        ("select message->>'k' from " <> table <> " where message ? 'k' order by msg_id")
        Encoders.noParams
        (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.text)))

qualifiedTable :: Text -> QueueName -> Text
qualifiedTable prefix queue =
  "pgmq.\"" <> prefix <> queueNameToText queue <> "\""
