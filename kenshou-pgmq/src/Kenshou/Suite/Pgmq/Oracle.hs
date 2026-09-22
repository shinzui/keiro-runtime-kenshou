module Kenshou.Suite.Pgmq.Oracle
  ( LeaseFinding (..),
    EarlyDelivery (..),
    checkLeaseIntervals,
    checkNotBeforeDue,
  )
where

import Data.Function (on)
import Data.Int (Int64)
import Data.List (groupBy, sortOn)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Time (UTCTime)
import Kenshou.Suite.Pgmq.Facts (PgmqFact (..))

data LeaseFinding
  = DuplicateReadCount {messageId :: Int64, readCount :: Int64}
  | OverlappingLease {messageId :: Int64, earlierVisibleAt :: UTCTime, laterReadAt :: UTCTime}
  deriving stock (Eq, Show)

data EarlyDelivery = EarlyDelivery {key :: Text, dueAt :: UTCTime, readAt :: UTCTime}
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
