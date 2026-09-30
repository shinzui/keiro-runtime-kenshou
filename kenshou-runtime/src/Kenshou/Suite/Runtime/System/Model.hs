module Kenshou.Suite.Runtime.System.Model
  ( OrderPhase (..),
    OrderAction (..),
    FulfilmentPhase (..),
    FulfilmentAction (..),
    TransitionError (..),
    advanceOrder,
    advanceFulfilment,
    matchingTerminal,
  )
where

-- This model is an oracle for the event streams, separate from their Keiki
-- transducers. It describes the terminal-state contract without sharing code
-- with the runtime implementation under test.

data OrderPhase = OrderNotPlaced | OrderPlaced | OrderCompleted | OrderRejected | OrderExpired
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data OrderAction = PlaceOrder | CompleteOrder | RejectOrder | ExpireOrder
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data FulfilmentPhase = FulfilmentNotRequested | FulfilmentRequested | FulfilmentShipped | FulfilmentRefused | FulfilmentExpired
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data FulfilmentAction = RequestFulfilment | RefuseFulfilment | ShipFulfilment | ExpireFulfilment
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data TransitionError = InvalidOrderTransition OrderPhase OrderAction | InvalidFulfilmentTransition FulfilmentPhase FulfilmentAction
  deriving stock (Eq, Show)

advanceOrder :: OrderPhase -> OrderAction -> Either TransitionError OrderPhase
advanceOrder OrderNotPlaced PlaceOrder = Right OrderPlaced
advanceOrder OrderPlaced CompleteOrder = Right OrderCompleted
advanceOrder OrderPlaced RejectOrder = Right OrderRejected
advanceOrder OrderPlaced ExpireOrder = Right OrderExpired
advanceOrder phase action = Left (InvalidOrderTransition phase action)

advanceFulfilment :: FulfilmentPhase -> FulfilmentAction -> Either TransitionError FulfilmentPhase
advanceFulfilment FulfilmentNotRequested RequestFulfilment = Right FulfilmentRequested
advanceFulfilment FulfilmentNotRequested RefuseFulfilment = Right FulfilmentRefused
advanceFulfilment FulfilmentRequested ShipFulfilment = Right FulfilmentShipped
advanceFulfilment FulfilmentRequested ExpireFulfilment = Right FulfilmentExpired
advanceFulfilment phase action = Left (InvalidFulfilmentTransition phase action)

matchingTerminal :: OrderPhase -> FulfilmentPhase -> Bool
matchingTerminal OrderCompleted FulfilmentShipped = True
matchingTerminal OrderRejected FulfilmentRefused = True
matchingTerminal OrderExpired FulfilmentExpired = True
matchingTerminal _ _ = False
