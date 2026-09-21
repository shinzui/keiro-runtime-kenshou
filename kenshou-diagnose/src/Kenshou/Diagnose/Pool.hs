module Kenshou.Diagnose.Pool
  ( PoolStats (..),
    newPoolObserver,
  )
where

import Control.Applicative ((<|>))
import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.!=), (.:), (.:?), (.=))
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (UTCTime, diffUTCTime, getCurrentTime)
import Data.UUID (UUID)
import Hasql.Pool.Observation

data PoolStats = PoolStats
  { name :: !Text,
    size :: !Int,
    connecting :: !Int,
    ready :: !Int,
    inUse :: !Int,
    terminated :: !Int,
    saturatedSeconds :: !Double
  }
  deriving stock (Eq, Show)

data ObserverState = ObserverState {statuses :: Map UUID ConnectionStatus, saturatedSince :: Maybe UTCTime}

newPoolObserver :: Text -> Int -> IO (Observation -> IO (), IO PoolStats)
newPoolObserver name size = do
  state <- newIORef (ObserverState Map.empty Nothing)
  let observe (ConnectionObservation connection status) = do
        now <- getCurrentTime
        atomicModifyIORef' state \current ->
          let statuses = Map.insert connection status current.statuses
              inUse = length [() | InUseConnectionStatus <- Map.elems statuses]
              saturatedSince = if inUse >= size then current.saturatedSince <|> Just now else Nothing
           in (ObserverState statuses saturatedSince, ())
      snapshot = do
        now <- getCurrentTime
        current <- readIORef state
        let statuses = Map.elems current.statuses
            count predicate = length (filter predicate statuses)
            saturatedSeconds = maybe 0 (realToFrac . diffUTCTime now) current.saturatedSince
        pure (PoolStats name size (count isConnecting) (count isReady) (count isInUse) (count isTerminated) saturatedSeconds)
  pure (observe, snapshot)
  where
    isConnecting ConnectingConnectionStatus = True
    isConnecting _ = False
    isReady (ReadyForUseConnectionStatus _) = True
    isReady _ = False
    isInUse InUseConnectionStatus = True
    isInUse _ = False
    isTerminated (TerminatedConnectionStatus _) = True
    isTerminated _ = False

instance ToJSON PoolStats where toJSON stats = object ["name" .= stats.name, "size" .= stats.size, "connecting" .= stats.connecting, "ready" .= stats.ready, "inUse" .= stats.inUse, "terminated" .= stats.terminated, "saturatedSeconds" .= stats.saturatedSeconds]

instance FromJSON PoolStats where parseJSON = withObject "PoolStats" \value -> PoolStats <$> value .: "name" <*> value .: "size" <*> value .:? "connecting" .!= 0 <*> value .:? "ready" .!= 0 <*> value .:? "inUse" .!= 0 <*> value .:? "terminated" .!= 0 <*> value .:? "saturatedSeconds" .!= 0
