module Kenshou.Suite.Keiro.Workflow.CrashWindows
  ( scenarios,
    childWindowLanded,
    leaseLossEffectsHeld,
  )
where

import Control.Concurrent (threadDelay)
import Data.Aeson (Value (..), object, withObject, (.:), (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.Types (parseMaybe)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Keiro.Codec (decodeRecorded)
import Keiro.Timer (TimerRow (..), TimerStatus (..), lookupTimer)
import Keiro.Workflow (WorkflowId (..), WorkflowJournalEvent (..), WorkflowName (..), WorkflowOutcome (..), loadStepIndex, runWorkflow, workflowJournalCodec, workflowStreamName)
import Keiro.Workflow.Child (childResultStepName)
import Keiro.Workflow.Child.Schema (ChildStatus (..), lookupChild)
import Keiro.Workflow.Child.Schema qualified as ChildSchema
import Keiro.Workflow.Instance (WorkflowInstanceRow (..), WorkflowStatus (..), lookupInstance, upsertInstanceTx)
import Keiro.Workflow.Sleep (sleepTimerId)
import Kenshou.Check.Fact (Fact (..), FactKind (..), ProcId (..))
import Kenshou.Check.Ledger (sealLedger)
import Kenshou.Check.Ledger.Read (discoverLedgers, foldFacts)
import Kenshou.Check.Process (Child, ChildSignal (..), Supervisor, awaitMark, awaitReady, readChildMessages, roleProcess, sendCommand, signalChild, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (CheckEnv (..), withCheck)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (ScenarioId, parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobDouble, knobInt, knobText)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..), WorkerMessage (..))
import Kenshou.Core.Scenario (CohortScope (..), KnownDefect (..), Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Timer.Knobs (timerKnobs)
import Kenshou.Suite.Keiro.Workflow.Definitions (DefinitionParams (..), childName, defaultDefinitionParams, expectedLinearSteps, linearName, parentName, parentWorkflow, sleeperName, sleeperWorkflow)
import Kenshou.Suite.Keiro.Workflow.Effects (EffectSink (..))
import Kenshou.Suite.Keiro.Workflow.Fixture (durableKirokuStore, withDurableStore)
import Kenshou.Suite.Keiro.Workflow.Knobs (workflowKnobName, workflowKnobs)
import Kenshou.Suite.Keiro.Workflow.Oracle (journalStepIdentity, recordWorkflowCells)
import Kiroku.Store (KirokuStore, defaultConnectionSettings, readStreamForward, runStoreIO, runTransaction)
import Kiroku.Store.Types (RecordedEvent (..), StreamVersion (..))

scenarios :: [Scenario]
scenarios = [childCompletionCrashWindow, sleepFireCrashWindow, leaseLossStopsSideEffects]

durableOnly :: DimensionSupport
durableOnly =
  DimensionSupport
    { tracing = Supported (Support (TracingOff :| []) TracingOff),
      metrics = Supported (Support (MetricsOff :| []) MetricsOff),
      pgDurability = Supported (Support (PgDurable :| []) PgDurable),
      pgVersion = Supported (Support (Pg18 :| []) Pg18)
    }

keiroPostgres :: EnvRequirements
keiroPostgres = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku, SchemaKeiro] [] False)}

sid :: Text -> ScenarioId
sid = either (error . show) Prelude.id . parseScenarioId

-- ---------------------------------------------------------------------------
-- Child completion: the child's own marker commits before the parent wake.
-- ---------------------------------------------------------------------------

childCompletionCrashWindow :: Scenario
childCompletionCrashWindow =
  Scenario
    { id = sid "keiro/workflow/concurrency/child-completion-crash-window",
      revision = 1,
      summary = "SIGKILLs a child runner after the child's completion marker commits and before the parent is woken, then requires the parent to complete.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = workflowKnobs,
      dimensions = durableOnly,
      phases = zeroPhases,
      requires = keiroPostgres,
      knownDefect = Just (KnownDefect "mori://shinzui/keiro/okf/bug-reports/concepts/BUG-8" "A child killed between its completion marker and the parent wake strands the parent" ["workflow-parent-completes-after-child-marker-crash"] AllCohorts),
      run = runChildWindow
    }

-- | The window is reached only when the child's own journal is closed, the
-- link row still says running, and the parent has no result step. Any other
-- state means the kill landed elsewhere and the run proves nothing.
childWindowLanded :: Maybe WorkflowStatus -> Maybe ChildStatus -> Bool -> Bool
childWindowLanded childInstance link parentHasResult =
  childInstance == Just WfCompleted && link == Just Running && not parentHasResult

runChildWindow :: RunContext -> IO ScenarioReport
runChildWindow context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let store = durableKirokuStore fixture
        quiet = EffectSink (\_ -> pure ()) (\_ -> pure ())
        controlParent = WorkflowId "child-window-control"
        windowParent = WorkflowId "child-window-marker"
        childOf (WorkflowId wid) = WorkflowId (wid <> "-child")
        park wid = runStoreIO store (runWorkflow parentName wid (parentWorkflow quiet wid))
        deadline = quiescenceSeconds context
    parked <- traverse park [controlParent, windowParent]
    sealLedger check.ledger
    (controlArmed, windowArmed, windowState, controlDone, windowDone) <- withSupervisor check \supervisor -> do
      let runChild index wid ordinal = do
            spec <- roleProcess check "keiro/workflow-driver" index (object ["op" .= ("run-child" :: Text), "childId" .= unWorkflowId (childOf wid), "killOnAppend" .= (ordinal :: Int)])
            driver <- spawn supervisor spec
            awaitReady driver 10000
            sendCommand driver CtlStart
            armed <- awaitCrashArm check "keiro/workflow-driver" index 400
            threadDelay 300000
            pure armed
      -- Append one is the child's only step; append two is its completion marker.
      controlArmed <- runChild 0 controlParent 1
      windowArmed <- runChild 1 windowParent 2
      windowState <- childState store windowParent (childOf windowParent)
      workers <- traverse (startResumeWorker supervisor check (object [])) [0, 1]
      controlDone <- waitUntil (instanceIs store parentName controlParent WfCompleted) (deadline * 4)
      windowDone <- waitUntil (instanceIs store parentName windowParent WfCompleted) (deadline * 4)
      mapM_ (\worker -> stopGracefully supervisor worker 5000) workers
      pure (controlArmed, windowArmed, windowState, controlDone, windowDone)
    finalControl <- childState store controlParent (childOf controlParent)
    finalWindow <- childState store windowParent (childOf windowParent)
    effects <- effectCounts check
    let (childInstance, link, parentHasResult, _) = windowState
        workKey wid = unWorkflowId (childOf wid) <> "/work"
        workOnce wid = Map.findWithDefault 0 (workKey wid) effects == (1 :: Int)
        render (instanceStatus, linkStatus, hasResult, parentStatus) =
          object
            [ "childInstance" .= fmap (Text.pack . show) instanceStatus,
              "link" .= fmap (Text.pack . show) linkStatus,
              "parentHasResult" .= hasResult,
              "parentStatus" .= fmap (Text.pack . show) parentStatus
            ]
    putSummary context Measurements "child-completion-crash-window" (object ["deadlineSeconds" .= deadline, "afterCrash" .= render windowState, "finalWindow" .= render finalWindow, "finalControl" .= render finalControl])
    recordWorkflowCells
      check
      [ ("parents-parked-on-children", parked == [Right Suspended, Right Suspended]),
        ("control-crash-armed", controlArmed),
        ("control-parent-completed", controlDone),
        ("window-crash-armed", windowArmed),
        ("window-reached-between-marker-and-wake", childWindowLanded childInstance link parentHasResult),
        ("parent-completes-after-child-marker-crash", windowDone),
        ("child-work-effect-once", workOnce controlParent && workOnce windowParent)
      ]

childState :: KirokuStore -> WorkflowId -> WorkflowId -> IO (Maybe WorkflowStatus, Maybe ChildStatus, Bool, Maybe WorkflowStatus)
childState store parent child = do
  instanceRow <- runStoreIO store (lookupInstance childName child)
  link <- runStoreIO store (lookupChild (unWorkflowId child) (unWorkflowName childName))
  index <- runStoreIO store (loadStepIndex parentName parent 0)
  parentRow <- runStoreIO store (lookupInstance parentName parent)
  pure
    ( either (const Nothing) (fmap (.status)) instanceRow,
      either (const Nothing) (fmap (.status)) link,
      either (const False) (Map.member (childResultStepName child)) index,
      either (const Nothing) (fmap (.status)) parentRow
    )

-- ---------------------------------------------------------------------------
-- Sleep fire: the completion is journaled, the timer is not yet marked fired.
-- ---------------------------------------------------------------------------

sleepFireCrashWindow :: Scenario
sleepFireCrashWindow =
  Scenario
    { id = sid "keiro/workflow/concurrency/sleep-fire-crash-window",
      revision = 1,
      summary = "SIGKILLs a timer worker after a sleep completion is journaled and before the timer is marked fired, then checks requeue, one journal entry, and completion.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = workflowKnobs <> timerKnobs,
      dimensions = durableOnly,
      phases = zeroPhases,
      requires = keiroPostgres,
      knownDefect = Nothing,
      run = runSleepWindow
    }

runSleepWindow :: RunContext -> IO ScenarioReport
runSleepWindow context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let store = durableKirokuStore fixture
        quiet = EffectSink (\_ -> pure ()) (\_ -> pure ())
        wid = WorkflowId "sleep-fire-crash"
        timerId = sleepTimerId sleeperName wid 0 "sleep:nap"
        deadline = quiescenceSeconds context
        timerStatus = either (const Nothing) (fmap (\row -> (row.status, row.attempts))) <$> runStoreIO store (lookupTimer timerId)
    parked <- runStoreIO store (runWorkflow sleeperName wid (sleeperWorkflow quiet True wid))
    -- The fixture sleep is 200 ms; let it become due before any worker exists.
    threadDelay 500000
    sealLedger check.ledger
    (armed, afterCrash, journaledAtCrash, fired, completed) <- withSupervisor check \supervisor -> do
      killerSpec <- roleProcess check "keiro/timer-worker" 0 (object ["killAfterSleepFire" .= True])
      killer <- spawn supervisor killerSpec
      awaitReady killer 10000
      sendCommand killer CtlStart
      armed <- awaitCrashArm check "keiro/timer-worker" 0 400
      threadDelay 300000
      afterCrash <- timerStatus
      journaledAtCrash <- either (const False) (Map.member "sleep:nap") <$> runStoreIO store (loadStepIndex sleeperName wid 0)
      survivorSpec <- roleProcess check "keiro/timer-worker" 1 (object [])
      survivor <- spawn supervisor survivorSpec
      awaitReady survivor 10000
      sendCommand survivor CtlStart
      fired <- waitUntil ((\case Just (Fired, _) -> True; _ -> False) <$> timerStatus) (deadline * 4)
      worker <- startResumeWorker supervisor check (object []) 0
      completed <- waitUntil (instanceIs store sleeperName wid WfCompleted) (deadline * 4)
      mapM_ (\child -> stopGracefully supervisor child 5000) [survivor, worker]
      pure (armed, afterCrash, journaledAtCrash, fired, completed)
    final <- timerStatus
    journal <- runStoreIO store (readStreamForward (workflowStreamName sleeperName wid) (StreamVersion 0) 64)
    instanceRow <- runStoreIO store (lookupInstance sleeperName wid)
    effects <- effectCounts check
    let decoded = either (const []) (\events -> either (const []) id (traverse (decodeRecorded workflowJournalCodec) (Vector.toList events))) journal
        sleepEntries = length [() | StepRecorded name _ _ <- decoded, name == "sleep:nap"]
    putSummary context Measurements "sleep-fire-crash-window" (object ["afterCrash" .= fmap renderTimer afterCrash, "final" .= fmap renderTimer final, "sleepEntries" .= sleepEntries])
    recordWorkflowCells
      check
      [ ("sleeper-parked", parked == Right Suspended),
        ("crash-armed", armed),
        ("crash-left-timer-firing-after-journal", journaledAtCrash && fmap fst afterCrash == Just Firing),
        ("timer-requeued-and-fired", final == Just (Fired, 2) && fired),
        ("one-sleep-journal-entry", sleepEntries == 1),
        ("workflow-completed-without-attempt", completed && case instanceRow of Right (Just row) -> row.status == WfCompleted && row.attempts == 0; _ -> False),
        ("after-step-effect-once", Map.lookup (unWorkflowId wid <> "/0/after") effects == Just 1)
      ]
  where
    renderTimer (status, attempts) = object ["status" .= Text.pack (show status), "attempts" .= attempts]

-- ---------------------------------------------------------------------------
-- Lease loss: a stale owner must not start another step.
-- ---------------------------------------------------------------------------

leaseLossStopsSideEffects :: Scenario
leaseLossStopsSideEffects =
  Scenario
    { id = sid "keiro/workflow/concurrency/lease-loss-stops-side-effects",
      revision = 1,
      summary = "Holds one worker inside a step past the lease, lets a second worker finish the workflow, and checks that the stale owner starts no further step.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = workflowKnobs <> [mechanismKnob],
      dimensions = durableOnly,
      phases = zeroPhases,
      requires = keiroPostgres,
      knownDefect = Nothing,
      run = runLeaseLoss
    }

mechanismKnob :: KnobSpec
mechanismKnob =
  KnobSpec (workflowKnobName "workflow.lease-loss-mechanism") "How the first owner outlives its lease" KnobText (VText "sigstop") (OneOf (VText "sigstop" :| [VText "slow-step"])) []

-- | The step after the held one must run exactly once, and only in the new
-- owner. The held step may run in both owners: that duplicate is the
-- documented at-least-once window.
leaseLossEffectsHeld :: Text -> Text -> Map (Text, Int) Int -> Bool
leaseLossEffectsHeld heldKey nextKey effects =
  let total key = sum [count | ((effectKey, _), count) <- Map.toList effects, effectKey == key]
   in total heldKey >= 1
        && total heldKey <= 2
        && Map.findWithDefault 0 (nextKey, 1) effects == 1
        && total nextKey == 1

runLeaseLoss :: RunContext -> IO ScenarioReport
runLeaseLoss context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let store = durableKirokuStore fixture
        wid = WorkflowId "lease-loss"
        leaseTtl = knobDouble context.knobs (workflowKnobName "workflow.lease-ttl-seconds")
        mechanism = knobText context.knobs (workflowKnobName "workflow.lease-loss-mechanism")
        steps = expectedLinearSteps defaultDefinitionParams {steps = fromIntegral (knobInt context.knobs (workflowKnobName "workflow.steps"))}
        holdMicros = if mechanism == "slow-step" then round ((leaseTtl + 4) * 1000000) else 1000000 :: Int
        deadline = quiescenceSeconds context
    seeded <- runStoreIO store (runTransaction (upsertInstanceTx (unWorkflowId wid) (unWorkflowName linearName) 0 WfRunning Nothing))
    -- SIGSTOP and SIGCONT record a disturbance window in the harness ledger,
    -- so it is sealed only after the supervisor is done.
    (completed, staleMessages) <- withSupervisor check \supervisor -> do
      staleSpec <- roleProcess check "keiro/workflow-resume-worker" 0 (object ["stepDelayMicros" .= holdMicros])
      stale <- spawn supervisor staleSpec
      awaitReady stale 10000
      sendCommand stale CtlStart
      awaitMark stale "effect-flushed" 20000
      if mechanism == "sigstop" then signalChild supervisor stale Stop else pure ()
      threadDelay (round ((leaseTtl + 1.5) * 1000000))
      replacement <- startResumeWorker supervisor check (object []) 1
      completed <- waitUntil (instanceIs store linearName wid WfCompleted) (deadline * 4)
      if mechanism == "sigstop" then signalChild supervisor stale Cont else pure ()
      -- Give the stale owner several passes to observe the loss.
      threadDelay (holdMicros + 3000000)
      _ <- stopGracefully supervisor replacement 5000
      _ <- stopGracefully supervisor stale 5000
      messages <- readChildMessages stale
      pure (completed, messages)
    sealLedger check.ledger
    journal <- runStoreIO store (readStreamForward (workflowStreamName linearName wid) (StreamVersion 0) (fromIntegral (length steps + 2)))
    instanceRow <- runStoreIO store (lookupInstance linearName wid)
    effects <- effectCountsByProcess check
    let (held, next) = case steps of first : second : _ -> (first, second); _ -> ("s0", "s1")
        keyOf name = unWorkflowId wid <> "/0/" <> name
        leaseSkips = sum [count | WrkCustom "resume-pass" payload <- staleMessages, Just count <- [intField "leaseSkipped" payload]]
        decodedSteps = case journal of
          Right events -> case traverse (decodeRecorded workflowJournalCodec) (Vector.toList events) of
            Right decoded -> Just ([(name, event.eventId) | (event, StepRecorded name _ _) <- zip (Vector.toList events) decoded], length [() | WorkflowCompleted {} <- decoded])
            Left _ -> Nothing
          Left _ -> Nothing
    putSummary context Measurements "lease-loss-stops-side-effects" (object ["mechanism" .= mechanism, "staleLeaseSkips" .= leaseSkips, "heldStepEffects" .= sum [count | ((key, _), count) <- Map.toList effects, key == keyOf held]])
    recordWorkflowCells
      check
      [ ("instance-seeded", seeded == Right ()),
        ("replacement-completed", completed),
        ("next-step-once-by-new-owner", leaseLossEffectsHeld (keyOf held) (keyOf next) effects),
        ("stale-owner-recorded-lease-skip", leaseSkips >= 1),
        ("no-attempt-consumed", case instanceRow of Right (Just row) -> row.status == WfCompleted && row.attempts == 0; _ -> False),
        ("journal-exactly-once", case decodedSteps of Just (rows, markers) -> markers == 1 && journalStepIdentity linearName wid 0 steps rows; Nothing -> False)
      ]

-- ---------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------

-- | leaseTtl + 10 polls + 5 s, with a 30 s floor so a negative result is not
-- an artifact of a busy host.
quiescenceSeconds :: RunContext -> Int
quiescenceSeconds context =
  let leaseTtl = knobDouble context.knobs (workflowKnobName "workflow.lease-ttl-seconds")
      poll = fromIntegral (knobInt context.knobs (workflowKnobName "workflow.poll-interval-ms")) / 1000
   in max 30 (ceiling (leaseTtl + 10 * poll + 5))

startResumeWorker :: Supervisor -> CheckEnv -> Value -> Int -> IO Child
startResumeWorker supervisor check arguments index = do
  spec <- roleProcess check "keiro/workflow-resume-worker" index arguments
  worker <- spawn supervisor spec
  awaitReady worker 10000
  sendCommand worker CtlStart
  pure worker

instanceIs :: KirokuStore -> WorkflowName -> WorkflowId -> WorkflowStatus -> IO Bool
instanceIs store name wid expected = do
  row <- runStoreIO store (lookupInstance name wid)
  pure case row of
    Right (Just current) -> current.status == expected
    _ -> False

-- | Poll every 250 ms; @seconds@ bounds the total wait.
waitUntil :: IO Bool -> Int -> IO Bool
waitUntil predicate seconds = go (seconds * 4)
  where
    go 0 = predicate
    go remaining = do
      done <- predicate
      if done then pure True else threadDelay 250000 >> go (remaining - 1)

awaitCrashArm :: CheckEnv -> Text -> Int -> Int -> IO Bool
awaitCrashArm _ _ _ 0 = pure False
awaitCrashArm check role index remaining = do
  ledgers <- discoverLedgers check.ledgerDirectory
  found <- foldFacts ledgers False \seen fact -> pure (seen || fact.kind == Mark && fact.id == "crash-armed" && fact.proc.role == role && fact.proc.index == index)
  if found then pure True else threadDelay 50000 >> awaitCrashArm check role index (remaining - 1)

effectCounts :: CheckEnv -> IO (Map Text Int)
effectCounts check = do
  byProcess <- effectCountsByProcess check
  pure (Map.fromListWith (+) [(key, count) | ((key, _), count) <- Map.toList byProcess])

effectCountsByProcess :: CheckEnv -> IO (Map (Text, Int) Int)
effectCountsByProcess check = do
  ledgers <- discoverLedgers check.ledgerDirectory
  foldFacts ledgers Map.empty \counts fact ->
    pure if fact.kind == Effect then Map.insertWith (+) (fact.key, fact.proc.index) 1 counts else counts

intField :: Text -> Value -> Maybe Int
intField name = parseMaybe (withObject "resume pass" (.: Key.fromText name))
