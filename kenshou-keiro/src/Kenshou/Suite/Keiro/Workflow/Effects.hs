module Kenshou.Suite.Keiro.Workflow.Effects
  ( EffectFact (..),
    BoundaryPoint (..),
    CrashPlan (..),
    EffectSink (..),
    withEffectSink,
    shouldCrash,
  )
where

import Control.Monad (when)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Check.Fact (FactKind (..), ProcId (..))
import Kenshou.Check.Ledger (defaultLedgerConfig, recordDurable, withLedger)
import Kenshou.Core.Id (renderRunId)
import Kenshou.Core.Role (RoleContext (..), WorkerInit (..), renderRoleName)
import System.FilePath ((</>))
import System.Posix.Signals (raiseSignal, sigKILL)

-- | An effect observed before the step that caused it returns.
data EffectFact = EffectFact
  { kind :: !Text,
    key :: !Text,
    process :: !Text,
    attributes :: !Value
  }
  deriving stock (Eq, Show)

-- | Each value names a point where a real process death has distinct semantics.
data BoundaryPoint
  = AfterStepAction !Text
  | AfterTimerFire
  | AfterSleepJournalAppend
  | AfterChildCompletionMarker
  | AfterAwakeableAllocation
  deriving stock (Eq, Ord, Show)

data CrashPlan = CrashPlan
  { point :: !BoundaryPoint,
    occurrence :: !Int
  }
  deriving stock (Eq, Show)

data EffectSink = EffectSink
  { recordEffect :: EffectFact -> IO (),
    boundary :: BoundaryPoint -> IO ()
  }

-- | The occurrence counts only hits for the matching point. Invalid ordinals
-- never arm a kill. Keeping the matcher pure makes the crash schedule testable.
shouldCrash :: [CrashPlan] -> BoundaryPoint -> Int -> Bool
shouldCrash plans reached nth =
  nth > 0 && any (\plan -> plan.point == reached && plan.occurrence == nth) plans

-- | Keep the ledger handle open for the lifetime of the role. Every effect and
-- armed crash record is flushed before execution continues or SIGKILL is raised.
withEffectSink :: RoleContext -> [CrashPlan] -> (EffectSink -> IO a) -> IO a
withEffectSink context plans action = do
  counts <- newIORef Map.empty
  let worker = context.init
      label = renderRoleName worker.role
      proc = ProcId label (workerIndex worker.instanceName) 0
      config = defaultLedgerConfig (worker.outDir </> "verdicts" </> "ledger") proc (renderRunId worker.runId)
  withLedger config \ledger -> do
    let writeEffect fact =
          recordDurable ledger Effect fact.key 0 fact.key $
            KeyMap.fromList
              [ ("effect-kind", String fact.kind),
                ("process", String fact.process),
                ("attributes", fact.attributes)
              ]
        hit reached = do
          nth <- atomicModifyIORef' counts \previous ->
            let next = Map.insertWith (+) reached 1 previous
             in (next, Map.findWithDefault 0 reached next)
          when (shouldCrash plans reached nth) do
            recordDurable ledger Mark (boundaryKey reached) (fromIntegral nth) "crash-armed" $
              KeyMap.fromList [("boundary", object ["point" .= boundaryKey reached, "occurrence" .= nth])]
            _ <- raiseSignal sigKILL
            pure ()
    action (EffectSink writeEffect hit)

workerIndex :: Text -> Int
workerIndex name = case reads (Text.unpack (Text.takeWhileEnd (/= '-') name)) of
  [(value, "")] -> value
  _ -> 0

boundaryKey :: BoundaryPoint -> Text
boundaryKey = \case
  AfterStepAction stepName -> "after-step-action:" <> stepName
  AfterTimerFire -> "after-timer-fire"
  AfterSleepJournalAppend -> "after-sleep-journal-append"
  AfterChildCompletionMarker -> "after-child-completion-marker"
  AfterAwakeableAllocation -> "after-awakeable-allocation"
