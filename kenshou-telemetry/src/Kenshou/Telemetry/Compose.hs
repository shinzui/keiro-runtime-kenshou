module Kenshou.Telemetry.Compose
  ( HandlerStats,
    HandlerStatsSnapshot (..),
    AsyncHandlerStats (..),
    newHandlerStats,
    snapshotHandlerStats,
    composeHandlers,
    timedHandler,
    slowHandler,
    asyncHandler,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async)
import Control.Concurrent.STM
import Control.Monad (forever)
import Data.Aeson (ToJSON (..), object, (.=))
import Data.IORef
import Data.List (sort)
import Data.Text (Text)
import GHC.Clock (getMonotonicTimeNSec)

newtype HandlerStats = HandlerStats (IORef [Integer])

data HandlerStatsSnapshot = HandlerStatsSnapshot
  { name :: Text,
    calls :: Int,
    durationP50Ns :: Integer,
    durationP99Ns :: Integer,
    durationMaxNs :: Integer
  }
  deriving stock (Eq, Show)

data AsyncHandlerStats = AsyncHandlerStats
  { accepted :: Int,
    dropped :: Int,
    handled :: Int,
    queueDepth :: Int
  }
  deriving stock (Eq, Show)

instance ToJSON HandlerStatsSnapshot where
  toJSON value = object ["name" .= value.name, "calls" .= value.calls, "durationNs" .= object ["p50" .= value.durationP50Ns, "p99" .= value.durationP99Ns, "max" .= value.durationMaxNs]]

instance ToJSON AsyncHandlerStats where
  toJSON value = object ["accepted" .= value.accepted, "dropped" .= value.dropped, "handled" .= value.handled, "queueDepth" .= value.queueDepth]

newHandlerStats :: IO HandlerStats
newHandlerStats = HandlerStats <$> newIORef []

snapshotHandlerStats :: Text -> HandlerStats -> IO HandlerStatsSnapshot
snapshotHandlerStats name (HandlerStats ref) = do
  durations <- sort <$> readIORef ref
  pure (HandlerStatsSnapshot name (length durations) (quantile 0.50 durations) (quantile 0.99 durations) (maybe 0 last (nonEmpty durations)))

composeHandlers :: [a -> IO ()] -> a -> IO ()
composeHandlers [] = const (pure ())
composeHandlers handlers = \value -> mapM_ ($ value) handlers

timedHandler :: HandlerStats -> Text -> (a -> IO ()) -> a -> IO ()
timedHandler (HandlerStats ref) _name handler value = do
  started <- getMonotonicTimeNSec
  handler value
  ended <- getMonotonicTimeNSec
  modifyIORef' ref (fromIntegral (ended - started) :)

slowHandler :: Int -> a -> IO ()
slowHandler micros _ = threadDelay (max 0 micros)

asyncHandler :: Int -> (a -> IO ()) -> IO (a -> IO (), IO AsyncHandlerStats)
asyncHandler requestedCapacity handler = do
  let capacity = max 1 requestedCapacity
  queue <- newTBQueueIO (fromIntegral capacity)
  acceptedRef <- newIORef 0
  droppedRef <- newIORef 0
  handledRef <- newIORef 0
  _ <- async . forever $ do
    value <- atomically (readTBQueue queue)
    handler value
    modifyIORef' handledRef (+ 1)
  let submit value = do
        accepted <- atomically do
          full <- isFullTBQueue queue
          if full then pure False else writeTBQueue queue value >> pure True
        modifyIORef' (if accepted then acceptedRef else droppedRef) (+ 1)
      snapshot = AsyncHandlerStats <$> readIORef acceptedRef <*> readIORef droppedRef <*> readIORef handledRef <*> (fromIntegral <$> atomically (lengthTBQueue queue))
  pure (submit, snapshot)

quantile :: Double -> [Integer] -> Integer
quantile _ [] = 0
quantile fraction values = values !! min (length values - 1) (floor (fraction * fromIntegral (length values - 1)))

nonEmpty :: [a] -> Maybe [a]
nonEmpty [] = Nothing
nonEmpty values = Just values
