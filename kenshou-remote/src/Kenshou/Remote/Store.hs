module Kenshou.Remote.Store
  ( Bucket (..),
    ObjectName (..),
    Precondition (..),
    ObjectMeta (..),
    PutOutcome (..),
    ObjectStore (..),
  )
where

import Data.ByteString.Lazy (ByteString)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (UTCTime)

newtype Bucket = Bucket {unBucket :: Text} deriving stock (Eq, Ord, Show)

newtype ObjectName = ObjectName {unObjectName :: Text} deriving stock (Eq, Ord, Show)

data Precondition = NoPrecondition | DoesNotExist | GenerationIs !Int64
  deriving stock (Eq, Show)

data ObjectMeta = ObjectMeta
  { generation :: !Int64,
    size :: !Int64,
    updated :: !UTCTime,
    contentType :: !Text
  }
  deriving stock (Eq, Show)

data PutOutcome = Written !ObjectMeta | PreconditionFailed
  deriving stock (Eq, Show)

data ObjectStore = ObjectStore
  { getObject :: Bucket -> ObjectName -> IO (Maybe (ByteString, ObjectMeta)),
    statObject :: Bucket -> ObjectName -> IO (Maybe ObjectMeta),
    putObject :: Bucket -> ObjectName -> Text -> Precondition -> ByteString -> IO PutOutcome,
    putFile :: Bucket -> ObjectName -> Text -> Precondition -> FilePath -> IO PutOutcome,
    downloadTo :: Bucket -> ObjectName -> FilePath -> IO (Maybe ObjectMeta),
    deleteObject :: Bucket -> ObjectName -> Precondition -> IO Bool,
    listObjects :: Bucket -> Text -> IO [(ObjectName, ObjectMeta)],
    serverTime :: IO UTCTime
  }
