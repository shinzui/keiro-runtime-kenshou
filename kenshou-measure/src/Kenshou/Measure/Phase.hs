module Kenshou.Measure.Phase
  ( Phase (..),
    SteadyBound (..),
    PhasePlan (..),
    PhaseClock,
    newPhaseClock,
    enterPhase,
    currentPhase,
    phaseOf,
    renderPhase,
  )
where

import Data.IORef
import Data.Text (Text)
import Data.Word (Word64)
import Kenshou.Measure.Clock

data Phase = Setup | WarmUp | Steady | Drain | Done
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data SteadyBound = SteadyFor !Nanos | SteadyCount !Word64
  deriving stock (Eq, Show)

data PhasePlan = PhasePlan
  { warmUp :: !Nanos,
    steady :: !SteadyBound,
    drain :: !Nanos
  }
  deriving stock (Eq, Show)

data PhaseClock = PhaseClock
  { current :: !(IORef Phase),
    boundaries :: !(IORef [(Word64, Phase)]),
    onPhase :: !(Phase -> Origin -> IO ())
  }

newPhaseClock :: (Phase -> Origin -> IO ()) -> PhasePlan -> IO PhaseClock
newPhaseClock onPhase _plan = do
  origin <- captureOrigin
  current <- newIORef Setup
  boundaries <- newIORef [(origin.monoNs, Setup)]
  onPhase Setup origin
  pure PhaseClock {current, boundaries, onPhase}

enterPhase :: PhaseClock -> Phase -> IO ()
enterPhase clock phase = do
  origin <- captureOrigin
  writeIORef clock.current phase
  modifyIORef' clock.boundaries (<> [(origin.monoNs, phase)])
  clock.onPhase phase origin

currentPhase :: PhaseClock -> IO Phase
currentPhase = readIORef . (.current)

phaseOf :: PhaseClock -> Word64 -> IO Phase
phaseOf clock intendedStart = do
  boundaries <- readIORef clock.boundaries
  pure (foldl choose Setup boundaries)
  where
    choose selected (at, phase) = if at <= intendedStart then phase else selected

renderPhase :: Phase -> Text
renderPhase Setup = "setup"
renderPhase WarmUp = "warm-up"
renderPhase Steady = "steady"
renderPhase Drain = "drain"
renderPhase Done = "done"
