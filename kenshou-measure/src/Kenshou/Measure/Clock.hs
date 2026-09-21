module Kenshou.Measure.Clock
  ( Nanos (..),
    Origin (..),
    nowNs,
    captureOrigin,
    sleepUntilNs,
  )
where

import Control.Concurrent (threadDelay)
import Data.Int (Int64)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)

newtype Nanos = Nanos Word64
  deriving stock (Eq, Ord, Show)

data Origin = Origin
  { monoNs :: !Word64,
    wallUnixNs :: !Int64
  }
  deriving stock (Eq, Show)

nowNs :: IO Word64
nowNs = getMonotonicTimeNSec

captureOrigin :: IO Origin
captureOrigin = do
  monotonic <- nowNs
  wall <- getPOSIXTime
  pure (Origin monotonic (floor (wall * 1_000_000_000)))

sleepUntilNs :: Word64 -> IO ()
sleepUntilNs deadline = do
  current <- nowNs
  if current >= deadline
    then pure ()
    else do
      let remainingMicros = max 1 ((deadline - current) `div` 1_000)
      threadDelay (fromIntegral (min remainingMicros 1_000_000))
      sleepUntilNs deadline
