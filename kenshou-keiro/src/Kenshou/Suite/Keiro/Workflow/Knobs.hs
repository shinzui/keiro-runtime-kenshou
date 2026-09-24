module Kenshou.Suite.Keiro.Workflow.Knobs
  ( workflowKnobs,
    runOptionsFrom,
    resumeOptionsFrom,
    workflowKnobName,
  )
where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Keiro.EventStream (SnapshotPolicy (..))
import Keiro.Workflow (WorkflowRunOptions (..), defaultWorkflowRunOptions)
import Keiro.Workflow.Resume (WorkflowResumeOptions (..), defaultWorkflowResumeOptions)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), ResolvedKnobs, knobDouble, knobInt, knobText, mkKnobName)

workflowKnobName :: Text -> KnobName
workflowKnobName = either (error . Text.unpack) id . mkKnobName

workflowKnobs :: [KnobSpec]
workflowKnobs =
  [ decimal "workflow.lease-ttl-seconds" 3 0.1 3600,
    integer "workflow.max-attempts" 5 1 100,
    integer "workflow.max-concurrent-advances" 1 1 64,
    integer "workflow.poll-interval-ms" 100 1 60000,
    KnobSpec (workflowKnobName "workflow.snapshot-policy") "Journal snapshot policy" KnobText (VText "never") AnyValue [],
    integer "workflow.page-size" 100 1 100000,
    choices "workflow.wake-mode" "poll" ["push", "push-never-wake", "push-lossy"],
    choices "workflow.loop" "harness" ["keiro"],
    choices "workflow.start-mode" "deferred" ["inline"],
    integer "workflow.resume-processes" 2 1 64,
    integer "workflow.pool-size" 10 1 100,
    integer "workflow.steps" 8 1 100000,
    integer "workflow.instances" 100 1 100000,
    integer "workflow.children" 3 0 1000,
    integer "workflow.rotations" 4 0 100000,
    integer "workflow.population.parked" 2000 0 1000000,
    choices "workflow.parked-on" "awakeable" ["sleep", "child"]
  ]
  where
    integer key def low high = KnobSpec (workflowKnobName key) key KnobInt (VInt def) (IntRange low high) []
    decimal key def low high = KnobSpec (workflowKnobName key) key KnobDouble (VDouble def) (DoubleRange low high) []
    choices key def rest = KnobSpec (workflowKnobName key) key KnobText (VText def) (OneOf (VText def :| map VText rest)) []

runOptionsFrom :: ResolvedKnobs -> Either Text WorkflowRunOptions
runOptionsFrom knobs = do
  snapshot <- parseSnapshot (knobText knobs (workflowKnobName "workflow.snapshot-policy"))
  pure
    defaultWorkflowRunOptions
      { snapshotPolicy = snapshot,
        pageSize = fromIntegral (knobInt knobs (workflowKnobName "workflow.page-size"))
      }

resumeOptionsFrom :: ResolvedKnobs -> Either Text WorkflowResumeOptions
resumeOptionsFrom knobs = do
  runOptions <- runOptionsFrom knobs
  pure
    defaultWorkflowResumeOptions
      { runOptions = runOptions,
        pollInterval = fromIntegral (knobInt knobs (workflowKnobName "workflow.poll-interval-ms")) * 1000,
        maxAttempts = fromIntegral (knobInt knobs (workflowKnobName "workflow.max-attempts")),
        leaseTtl = realToFrac (knobDouble knobs (workflowKnobName "workflow.lease-ttl-seconds")),
        maxConcurrentAdvances = fromIntegral (knobInt knobs (workflowKnobName "workflow.max-concurrent-advances"))
      }

parseSnapshot :: Text -> Either Text (SnapshotPolicy state)
parseSnapshot "never" = Right Never
parseSnapshot "on-terminal" = Right OnTerminal
parseSnapshot text = case Text.stripPrefix "every-" text of
  Just countText -> case reads (Text.unpack countText) of
    [(count, "")] | count > 0 -> Right (Every count)
    _ -> Left "workflow.snapshot-policy: expected every-<positive integer>"
  Nothing -> Left "workflow.snapshot-policy: expected never, on-terminal, or every-<positive integer>"
