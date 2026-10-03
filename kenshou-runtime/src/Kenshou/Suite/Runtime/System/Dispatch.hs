module Kenshou.Suite.Runtime.System.Dispatch
  ( Dispatched (..),
    dispatchOnce,
    dispatchSucceeded,
  )
where

import Data.List.NonEmpty (NonEmpty (..))
import Keiki.Core (BoolAlg, RegFile)
import Keiro.Command (CommandError (..), RunCommandOptions (..))
import Keiro.EventStream (EventStream)
import Keiro.EventStream.Validate (ValidatedEventStream)
import Keiro.ProcessManager (dispatchDeduplicatedCommand)
import Keiro.Projection (InlineProjection, runCommandWithProjections)
import Keiro.Stream (Stream)
import Keiro.Stream qualified as Stream
import Kenshou.Suite.Runtime.System.Store (ContextEff)
import Kiroku.Store.Types (EventId)

data Dispatched
  = DispatchAppended
  | DispatchDuplicate
  | -- | The aggregate refused the command in its current state. For a
    -- terminal-state race this is the expected "already decided" answer.
    DispatchRejected
  | DispatchFailed !CommandError
  deriving stock (Eq, Show)

dispatchSucceeded :: Dispatched -> Bool
dispatchSucceeded = \case
  DispatchAppended -> True
  DispatchDuplicate -> True
  _ -> False

-- | Every command issued from an at-least-once context goes through Keiro's
-- deduplicated dispatch with a caller-supplied deterministic identifier, so a
-- replay after a crash is recognised as a duplicate rather than re-decided.
dispatchOnce ::
  (BoolAlg phi (RegFile rs, ci), Eq co) =>
  RunCommandOptions ->
  ValidatedEventStream phi rs s ci co ->
  Stream (EventStream phi rs s ci co) ->
  EventId ->
  ci ->
  [InlineProjection co] ->
  ContextEff Dispatched
dispatchOnce options eventStream target eventId command projections =
  dispatchDeduplicatedCommand
    options
    (Stream.streamName target)
    (eventId :| [])
    (const DispatchDuplicate)
    classify
    (const DispatchAppended)
    (runCommandWithProjections options {eventIds = [eventId]} eventStream target command projections)
  where
    classify = \case
      CommandRejected -> DispatchRejected
      other -> DispatchFailed other
