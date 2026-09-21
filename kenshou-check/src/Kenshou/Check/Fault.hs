module Kenshou.Check.Fault
  ( Duration (..),
    milliseconds,
    seconds,
    Availability (..),
    FaultHandle (..),
    Fault (..),
    Schedule,
    at,
    every,
    during,
    onMark,
    holding,
    withSchedule,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async
import Control.Concurrent.MVar
import Control.Exception (Exception, bracket, bracketOnError, throwIO)
import Control.Monad (forM_)
import Data.Aeson (Value)
import Data.Text (Text)
import Kenshou.Check.Fact (FactKind (..))
import Kenshou.Check.Ledger (recordDurable)
import Kenshou.Check.Process (Child, awaitMark)
import Kenshou.Check.Scenario
import Kenshou.Core.Phase (PhaseName)

newtype Duration = Duration {micros :: Int}
  deriving stock (Eq, Ord, Show)

milliseconds :: Int -> Duration
milliseconds value = Duration (value * 1000)

seconds :: Int -> Duration
seconds value = Duration (value * 1000000)

data Availability = Available | Unavailable Text deriving stock (Eq, Show)

data FaultHandle = FaultHandle
  { heal :: IO (),
    details :: Value
  }

data Fault = Fault
  { name :: Text,
    target :: Text,
    availability :: IO Availability,
    inject :: IO FaultHandle
  }

data Scheduled = Scheduled
  { delay :: !Duration,
    waitForMark :: !(Maybe (Child, Text)),
    fault :: !Fault
  }

newtype Schedule = Schedule [Scheduled]

instance Semigroup Schedule where Schedule left <> Schedule right = Schedule (left <> right)

instance Monoid Schedule where mempty = Schedule []

newtype FaultInjectionFailed = FaultInjectionFailed Text deriving stock (Eq, Show)

instance Exception FaultInjectionFailed

at :: Duration -> Fault -> Schedule
at delay fault = Schedule [Scheduled delay Nothing fault]

every :: Duration -> Fault -> Schedule
every = at

during :: PhaseName -> Schedule -> Schedule
during _ = id

onMark :: Child -> Text -> Fault -> Schedule
onMark child mark fault = Schedule [Scheduled (Duration 0) (Just (child, mark)) fault]

holding :: Duration -> Fault -> Fault
holding duration fault =
  fault
    { inject = do
        bracketOnError fault.inject (.heal) \handle -> do
          threadDelay duration.micros
          handle.heal
          pure handle {heal = pure ()}
    }

withSchedule :: CheckEnv -> Schedule -> IO value -> IO value
withSchedule environment (Schedule scheduled) action = bracket start stop (const action)
  where
    start = do
      active <- newMVar []
      workers <- traverse (async . runOne active) scheduled
      pure (workers, active)
    stop (workers, active) = do
      mapM_ cancel workers
      readMVar active >>= mapM_ (.heal)
    runOne active item = do
      forM_ item.waitForMark \(child, mark) -> awaitMark child mark 600000
      threadDelay item.delay.micros
      availability <- item.fault.availability
      case availability of
        Unavailable reason -> throwIO (FaultInjectionFailed (item.fault.name <> ": " <> reason))
        Available -> do
          recordDurable environment.ledger DisturbanceStart item.fault.target 0 item.fault.name mempty
          handle <- item.fault.inject
          modifyMVar_ active (pure . (handle :))
          recordDurable environment.ledger DisturbanceEnd item.fault.target 0 item.fault.name mempty
