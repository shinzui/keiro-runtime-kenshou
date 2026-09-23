module Kenshou.Suite.Kiroku.Fixture.Oracle
  ( AllRow (..),
    GapRange (..),
    GapReport (..),
    StreamAnomaly (..),
    DeadLetterRow (..),
    foldAllLog,
    gapReport,
    threeCounts,
    streamAudit,
    checkpoints,
    deadLetters,
    partitionSlots,
    deadlockCount,
  )
where

import Control.Monad (unless)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Int (Int32, Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement

data AllRow = AllRow
  { position :: Int64,
    eventId :: Text,
    originStreamId :: Int64,
    originVersion :: Int64
  }
  deriving stock (Eq, Show)

data GapRange = GapRange {first :: Int64, last :: Int64}
  deriving stock (Eq, Show)

data GapReport = GapReport
  { minimumPosition :: Maybe Int64,
    maximumPosition :: Maybe Int64,
    rowCount :: Int64,
    missingRanges :: [GapRange]
  }
  deriving stock (Eq, Show)

data StreamAnomaly = StreamAnomaly
  { streamId :: Int64,
    headVersion :: Int64,
    observedRows :: Int64,
    firstVersion :: Maybe Int64,
    lastVersion :: Maybe Int64
  }
  deriving stock (Eq, Show)

data DeadLetterRow = DeadLetterRow
  { member :: Int32,
    position :: Int64,
    eventId :: Text,
    reasonSummary :: Text,
    attempts :: Int32
  }
  deriving stock (Eq, Show)

foldAllLog :: Pool -> (AllRow -> IO ()) -> IO ()
foldAllLog pool consume = go 0
  where
    go cursor = do
      rows <- query pool (Session.statement cursor allPageStatement)
      mapM_ consume rows
      unless (null rows) (go (last rows).position)

gapReport :: Pool -> IO GapReport
gapReport pool = do
  ref <- newIORef (Nothing, 0 :: Int64, [] :: [GapRange])
  foldAllLog pool \row -> do
    (previous, count, gaps) <- readIORef ref
    let nextGaps = case previous of
          Just prior | row.position > prior + 1 -> GapRange (prior + 1) (row.position - 1) : gaps
          Nothing | row.position > 1 -> GapRange 1 (row.position - 1) : gaps
          _ -> gaps
    writeIORef ref (Just row.position, count + 1, nextGaps)
  (lastPosition, count, reversedGaps) <- readIORef ref
  (_, _, headVersion) <- threeCounts pool
  firstPosition <- if count == 0 then pure Nothing else fmap (fmap (.position)) (query pool (Session.statement () firstAllStatement))
  let trailing = case lastPosition of
        Just lastVisible | headVersion > lastVisible -> [GapRange (lastVisible + 1) headVersion]
        Nothing | headVersion > 0 -> [GapRange 1 headVersion]
        _ -> []
  pure (GapReport firstPosition lastPosition count (reverse reversedGaps <> trailing))

threeCounts :: Pool -> IO (Int64, Int64, Int64)
threeCounts pool = query pool (Session.statement () countStatement)

streamAudit :: Pool -> IO [StreamAnomaly]
streamAudit pool = query pool (Session.statement () auditStatement)

checkpoints :: Pool -> IO [(Text, Int32, Int64)]
checkpoints pool = query pool (Session.statement () checkpointStatement)

deadLetters :: Pool -> Text -> IO [DeadLetterRow]
deadLetters pool name = query pool (Session.statement name deadLetterStatement)

partitionSlots :: Pool -> Int32 -> IO (Map Int64 Int32)
partitionSlots pool size = Map.fromList <$> query pool (Session.statement size partitionStatement)

deadlockCount :: Pool -> IO Int64
deadlockCount pool = query pool (Session.statement () deadlockStatement)

query :: Pool -> Session.Session result -> IO result
query pool session = Pool.use pool session >>= either (fail . show) pure

allPageStatement :: Statement.Statement Int64 [AllRow]
allPageStatement =
  Statement.preparable
    "select stream_version, event_id::text, original_stream_id, original_stream_version from kiroku.stream_events where stream_id = 0 and stream_version > $1 order by stream_version limit 1000"
    (Encoders.param (Encoders.nonNullable Encoders.int8))
    (Decoders.rowList (AllRow <$> int8 <*> text <*> int8 <*> int8))

firstAllStatement :: Statement.Statement () (Maybe AllRow)
firstAllStatement =
  Statement.preparable
    "select stream_version, event_id::text, original_stream_id, original_stream_version from kiroku.stream_events where stream_id = 0 order by stream_version limit 1"
    Encoders.noParams
    (Decoders.rowMaybe (AllRow <$> int8 <*> text <*> int8 <*> int8))

countStatement :: Statement.Statement () (Int64, Int64, Int64)
countStatement =
  Statement.preparable
    "select (select count(*) from kiroku.events), (select count(*) from kiroku.stream_events where stream_id = 0), (select stream_version from kiroku.streams where stream_id = 0)"
    Encoders.noParams
    (Decoders.singleRow ((,,) <$> int8 <*> int8 <*> int8))

auditStatement :: Statement.Statement () [StreamAnomaly]
auditStatement =
  Statement.preparable
    "select s.stream_id, s.stream_version, count(se.event_id), min(se.stream_version), max(se.stream_version) from kiroku.streams s left join kiroku.stream_events se on se.stream_id = s.stream_id where s.stream_id <> 0 group by s.stream_id, s.stream_version having count(se.event_id) <> s.stream_version or min(se.stream_version) <> 1 or max(se.stream_version) <> s.stream_version order by s.stream_id"
    Encoders.noParams
    (Decoders.rowList (StreamAnomaly <$> int8 <*> int8 <*> int8 <*> nullableInt8 <*> nullableInt8))

checkpointStatement :: Statement.Statement () [(Text, Int32, Int64)]
checkpointStatement =
  Statement.preparable
    "select subscription_name, consumer_group_member, checkpoint_position from kiroku.subscription_checkpoints_v1 order by subscription_name, consumer_group_member"
    Encoders.noParams
    (Decoders.rowList ((,,) <$> text <*> int4 <*> int8))

deadLetterStatement :: Statement.Statement Text [DeadLetterRow]
deadLetterStatement =
  Statement.preparable
    "select consumer_group_member, global_position, event_id::text, reason_summary, attempt_count from kiroku.dead_letters where subscription_name = $1 order by consumer_group_member, global_position"
    (Encoders.param (Encoders.nonNullable Encoders.text))
    (Decoders.rowList (DeadLetterRow <$> int4 <*> int8 <*> text <*> text <*> int4))

partitionStatement :: Statement.Statement Int32 [(Int64, Int32)]
partitionStatement =
  Statement.preparable
    "select stream_id, (((hashtextextended(stream_id::text, 0) % $1) + $1) % $1)::int from kiroku.streams where stream_id <> 0 order by stream_id"
    (Encoders.param (Encoders.nonNullable Encoders.int4))
    (Decoders.rowList ((,) <$> int8 <*> int4))

deadlockStatement :: Statement.Statement () Int64
deadlockStatement =
  Statement.preparable
    "select deadlocks from pg_stat_database where datname = current_database()"
    Encoders.noParams
    (Decoders.singleRow int8)

int8 :: Decoders.Row Int64
int8 = Decoders.column (Decoders.nonNullable Decoders.int8)

int4 :: Decoders.Row Int32
int4 = Decoders.column (Decoders.nonNullable Decoders.int4)

text :: Decoders.Row Text
text = Decoders.column (Decoders.nonNullable Decoders.text)

nullableInt8 :: Decoders.Row (Maybe Int64)
nullableInt8 = Decoders.column (Decoders.nullable Decoders.int8)
