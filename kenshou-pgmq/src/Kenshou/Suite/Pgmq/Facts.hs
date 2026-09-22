module Kenshou.Suite.Pgmq.Facts (PgmqFact (..)) where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (UTCTime)
import Kenshou.Suite.Pgmq.Knobs (AckMode)

data PgmqFact
  = Intent {key :: Text, batch :: Maybe Text}
  | Sent {key :: Text, msgId :: Int64, batch :: Maybe Text, group :: Maybe Text, dueAt :: Maybe UTCTime}
  | Leased {key :: Text, msgId :: Int64, readCount :: Int64, lastReadAt :: UTCTime, visibleAt :: UTCTime, group :: Maybe Text}
  | Handled {key :: Text, msgId :: Int64, readCount :: Int64}
  | Released {msgId :: Int64, newVisibleAt :: UTCTime}
  | Acked {msgId :: Int64, mode :: AckMode, affected :: Bool}
  deriving stock (Eq, Show)
