module Kenshou.Diagnose.Progress
  ( ProgressCounter,
    ProgressSnapshot (..),
    newProgressCounter,
    tick,
    tickBy,
    snapshotProgress,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.=))
import Data.IORef
import Data.Text (Text)
import Data.Time (UTCTime, getCurrentTime)
import Data.Word (Word64)

data ProgressCounter = ProgressCounter
  { name :: !Text,
    required :: !Bool,
    value :: !(IORef Word64),
    lastAdvancedAt :: !(IORef UTCTime)
  }

data ProgressSnapshot = ProgressSnapshot
  { name :: !Text,
    required :: !Bool,
    value :: !Word64,
    lastAdvancedAt :: !UTCTime
  }
  deriving stock (Eq, Show)

newProgressCounter :: Text -> Bool -> IO ProgressCounter
newProgressCounter name required = do
  now <- getCurrentTime
  ProgressCounter name required <$> newIORef 0 <*> newIORef now

tick :: ProgressCounter -> IO ()
tick counter = tickBy counter 1

tickBy :: ProgressCounter -> Word64 -> IO ()
tickBy counter amount = do
  atomicModifyIORef' counter.value (\value -> (value + amount, ()))
  getCurrentTime >>= writeIORef counter.lastAdvancedAt

snapshotProgress :: ProgressCounter -> IO ProgressSnapshot
snapshotProgress counter = ProgressSnapshot counter.name counter.required <$> readIORef counter.value <*> readIORef counter.lastAdvancedAt

instance ToJSON ProgressSnapshot where
  toJSON snapshot = object ["name" .= snapshot.name, "required" .= snapshot.required, "value" .= snapshot.value, "lastAdvancedAt" .= snapshot.lastAdvancedAt]

instance FromJSON ProgressSnapshot where
  parseJSON = withObject "ProgressSnapshot" \value -> ProgressSnapshot <$> value .: "name" <*> value .: "required" <*> value .: "value" <*> value .: "lastAdvancedAt"
