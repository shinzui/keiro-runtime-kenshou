module Kenshou.Check.Fault.Wake
  ( WakeControl,
    WakePolicy (..),
    newWakeControl,
    setWakePolicy,
    faultyWait,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM

data WakePolicy = PassThrough | DropAll | DropFraction Double | DelayMicros Int
  deriving stock (Eq, Show)

newtype WakeControl = WakeControl (TVar WakePolicy)

newWakeControl :: IO WakeControl
newWakeControl = WakeControl <$> newTVarIO PassThrough

setWakePolicy :: WakeControl -> WakePolicy -> IO ()
setWakePolicy (WakeControl policy) = atomically . writeTVar policy

faultyWait :: WakeControl -> (result -> Bool) -> result -> (Int -> IO result) -> Int -> IO result
faultyWait (WakeControl policy) isNotification timeoutResult wait timeoutMicros = do
  result <- wait timeoutMicros
  current <- readTVarIO policy
  if not (isNotification result)
    then pure result
    else case current of
      PassThrough -> pure result
      DropAll -> threadDelay timeoutMicros >> pure timeoutResult
      DropFraction fraction | fraction >= 1 -> threadDelay timeoutMicros >> pure timeoutResult
      DropFraction _ -> pure result
      DelayMicros delay -> threadDelay delay >> pure result
