module Kenshou.Suite.Keiro.Queue.Concurrency (scenarios, fifoGroupOrder) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically)
import Control.Exception (bracket)
import Data.Aeson (object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.Int (Int64)
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, diffUTCTime)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Keiro.PGMQ.Codec (aesonJobCodec)
import Keiro.PGMQ.Job (Job (..), JobOrdering (..), RetryDelay (..), RetryPolicy (..), defaultRetryPolicy, enqueue, enqueueBatch, enqueueToGroup, ensureJobQueue)
import Keiro.PGMQ.Runtime (JobRuntime (..), QueueRef (..), queueRef, runJobEff, withJobRuntime)
import Kenshou.Check.Fault (Fault (..), FaultHandle (..))
import Kenshou.Check.Fault.Postgres (Backend (..), BackendSelector (..), LockTarget (..), holdLock, listBackends, terminateOneBackend)
import Kenshou.Check.Process (ProgressSnapshot (..), awaitMark, awaitReady, childPid, killChild, progress, roleProcess, sendCommand, spawn, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Check.Verdict (InvariantClass (..))
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobBool, knobInt, knobText, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Core.Scenario (CohortScope (..), KnownDefect (..), Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Messaging.Verdict (recordMessagingCells, recordMessagingCellsClassified)
import Kenshou.Suite.Keiro.Outbox.Workload (sourceName)
import Pgmq.Types (queueNameToText)
import System.Timeout (timeout)
import Text.Read (readMaybe)

scenarios :: [Scenario]
scenarios = [workersSurviveTransientPollingError, crashRedeliveryCadence, leaseExtension, fifoHeadsStrictOrder, deadLetterWindowDrainPath]

deadLetterWindowDrainPath :: Scenario
deadLetterWindowDrainPath =
  workersSurviveTransientPollingError
    { id = either (error . show) id (parseScenarioId "keiro/queue/concurrency/dead-letter-window-drain-path"),
      summary = "Pins the drain path's send-then-delete dead-letter crash window.",
      tier = TierSmoke,
      knobs = [KnobSpec (knobName "queue.crash-mode") "Interrupt the blocked drain delete" KnobText (VText "sigkill") (OneOf (VText "sigkill" :| [VText "backend-kill"])) [VText "backend-kill"]],
      knownDefect = Just (KnownDefect "mori://shinzui/keiro/okf/user-documentation/concepts/DOC-25" "The bounded drain path sends to the DLQ before deleting the source row" ["exactly-one-place"] AllCohorts),
      run = runDeadLetterWindowDrainPath
    }

runDeadLetterWindowDrainPath :: RunContext -> IO ScenarioReport
runDeadLetterWindowDrainPath context =
  withJobRuntime (requirePostgres context).connectionString Nothing \runtime ->
    withCheck context \check -> withSupervisor check \supervisor -> do
      let postgres = requirePostgres context
          queue = sourceName context "dead-window"
          crashMode = knobText context.knobs (knobName "queue.crash-mode")
          job = Job "queue-poll-probe" (queueRef queue) (aesonJobCodec @Text) Unordered defaultRetryPolicy
          mainTable = "pgmq.q_" <> queueNameToText job.jobQueue.physicalName
          dlqTable = "pgmq.q_" <> queueNameToText job.jobQueue.dlqName
          lockFault = holdLock postgres (RowLock "pgmq" ("q_" <> queueNameToText job.jobQueue.physicalName))
          countRows table = do
            let statement = Statement.preparable ("SELECT count(*) FROM " <> table) Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))
            Pool.use runtime.runtimePool (Session.statement () statement) >>= either (fail . show) pure
          waitDlq = do
            count <- countRows dlqTable
            if count > 0 then pure count else threadDelay 10000 >> waitDlq
      setup <- runJobEff runtime do
        ensureJobQueue job
        enqueue job ("dead-window" :: Text)
      _ <- either (fail . show) pure setup
      spec <- roleProcess check "keiro/queue-worker" 0 (object ["queue" .= queue, "mode" .= ("dead-drain" :: Text)])
      child <- spawn supervisor spec
      awaitReady child 10000
      sendCommand child CtlStart
      awaitMark child "running" 30000
      awaitMark child "delivery" 10000
      (observedDlq, mainWhileLocked) <- bracket lockFault.inject (.heal) \_ -> do
        sendCommand child (CtlCustom "continue" (object []))
        observed <- maybe False (> 0) <$> timeout 10000000 waitDlq
        mainCount <- countRows mainTable
        if crashMode == "sigkill" then killChild supervisor child else pure ()
        backends <- listBackends postgres
        mapM_ (\backend -> do _ <- (terminateOneBackend postgres (ByPid backend.pid)).inject; pure ()) [backend | backend <- backends, "queue-worker-0" `Text.isInfixOf` backend.applicationName]
        if crashMode == "backend-kill" then killChild supervisor child else pure ()
        pure (observed, mainCount)
      mainAfter <- countRows mainTable
      dlqAfter <- countRows dlqTable
      let schedule = observedDlq && mainWhileLocked == 1
      recordMessagingCellsClassified
        context
        (Map.fromList [("mainWhileLocked", mainWhileLocked), ("mainAfter", mainAfter), ("dlqAfter", dlqAfter)])
        (object ["observedDlqBeforeKill" .= observedDlq, "crashMode" .= crashMode])
        [ ("schedule-realised", Contract, schedule),
          ("exactly-one-place", Implementation, mainAfter + dlqAfter == 1),
          ("never-nowhere", Contract, mainAfter + dlqAfter >= 1)
        ]

fifoHeadsStrictOrder :: Scenario
fifoHeadsStrictOrder =
  workersSurviveTransientPollingError
    { id = either (error . show) id (parseScenarioId "keiro/queue/concurrency/fifo-heads-strict-order"),
      summary = "Checks per-group start and finish order with competing FIFO-head workers.",
      knobs =
        [ KnobSpec (knobName "queue.groups") "Number of FIFO groups" KnobInt (VInt 32) (IntRange 2 32) [],
          KnobSpec (knobName "queue.jobs-per-group") "Jobs in each FIFO group" KnobInt (VInt 50) (IntRange 2 50) [],
          KnobSpec (knobName "queue.workers") "Competing worker processes" KnobInt (VInt 4) (IntRange 2 8) [],
          KnobSpec (knobName "queue.kill-worker") "Kill the worker holding group zero's head" KnobBool (VBool True) AnyValue [VBool False]
        ],
      knownDefect = Nothing,
      run = runFifoHeadsStrictOrder
    }

runFifoHeadsStrictOrder :: RunContext -> IO ScenarioReport
runFifoHeadsStrictOrder context =
  withJobRuntime (requirePostgres context).connectionString Nothing \runtime ->
    withCheck context \check -> withSupervisor check \supervisor -> do
      let groups = fromIntegral (knobInt context.knobs (knobName "queue.groups")) :: Int
          jobsPerGroup = fromIntegral (knobInt context.knobs (knobName "queue.jobs-per-group")) :: Int
          workers = fromIntegral (knobInt context.knobs (knobName "queue.workers")) :: Int
          killWorker = knobBool context.knobs (knobName "queue.kill-worker")
          expected = groups * jobsPerGroup
          queue = sourceName context "fifo-heads"
          job = Job "queue-poll-probe" (queueRef queue) (aesonJobCodec @Text) FifoHeads defaultRetryPolicy
          spansStatement = Statement.preparable "SELECT payload, started_at, finished_at FROM kenshou_fx.queue_fifo_spans ORDER BY id" Encoders.noParams (Decoders.rowList ((,,) <$> Decoders.column (Decoders.nonNullable Decoders.text) <*> Decoders.column (Decoders.nonNullable Decoders.timestamptz) <*> Decoders.column (Decoders.nullable Decoders.timestamptz)))
          readSpans = Pool.use runtime.runtimePool (Session.statement () spansStatement) >>= either (fail . show) pure
          depthStatement = Statement.preparable ("SELECT count(*) FROM pgmq.q_" <> queueNameToText job.jobQueue.physicalName) Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))
          readDepth = Pool.use runtime.runtimePool (Session.statement () depthStatement) >>= either (fail . show) pure
          waitComplete = do
            spans <- readSpans
            if length [() | (_, _, Just _) <- spans] == expected then pure spans else threadDelay 100000 >> waitComplete
      Pool.use runtime.runtimePool (Session.script "CREATE SCHEMA IF NOT EXISTS kenshou_fx; CREATE TABLE IF NOT EXISTS kenshou_fx.queue_fifo_spans (id bigserial PRIMARY KEY, payload text NOT NULL, started_at timestamptz NOT NULL, finished_at timestamptz)") >>= either (fail . show) pure
      let enqueueCoordinate (groupIndex, sequenceIndex) = enqueueToGroup job (Text.pack (show groupIndex)) (Text.pack (show groupIndex <> ":" <> show sequenceIndex))
      setup <- runJobEff runtime do
        ensureJobQueue job
        enqueueCoordinate (0, 0)
      _ <- either (fail . show) pure setup
      let startWorker index = do
            child <- roleProcess check "keiro/queue-worker" index (object ["queue" .= queue, "mode" .= ("fifo" :: Text)]) >>= spawn supervisor
            awaitReady child 10000
            sendCommand child CtlStart
            awaitMark child "running" 30000
            pure child
          waitHead = do
            spans <- readSpans
            if any (\(payload, _, _) -> payload == "0:0") spans then pure () else threadDelay 10000 >> waitHead
      first <- startWorker 0
      _ <- maybe (fail "FIFO head did not start") pure =<< timeout 10000000 waitHead
      secondSetup <- runJobEff runtime (enqueueCoordinate (1, 0))
      _ <- either (fail . show) pure secondSetup
      peers <- traverse startWorker [1 .. workers - 1]
      let waitOtherGroup = do
            spans <- readSpans
            if any (\(payload, _, finished) -> payload == "1:0" && finished /= Nothing) spans
              then pure (any (\(payload, _, finished) -> payload == "0:0" && finished == Nothing) spans)
              else threadDelay 10000 >> waitOtherGroup
      blockedAtKill <-
        if killWorker
          then do
            observed <- maybe False id <$> timeout 10000000 waitOtherGroup
            killChild supervisor first
            pure observed
          else pure True
      let coordinates = [(groupIndex, sequenceIndex) | sequenceIndex <- [0 .. jobsPerGroup - 1], groupIndex <- [0 .. groups - 1], (groupIndex, sequenceIndex) /= (0, 0), (groupIndex, sequenceIndex) /= (1, 0)]
      restSetup <- runJobEff runtime (traverse enqueueCoordinate coordinates)
      _ <- either (fail . show) pure restSetup
      let children = if killWorker then peers else first : peers
      maybeSpans <- timeout 120000000 waitComplete
      spans <- maybe readSpans pure maybeSpans
      depth <- readDepth
      mapM_ (killChild supervisor) children
      let parsePayload payload = case Text.splitOn ":" payload of
            [groupText, sequenceText] -> (,) <$> readMaybe (Text.unpack groupText) <*> readMaybe (Text.unpack sequenceText)
            _ -> Nothing
          parsed = [(groupIndex, sequenceIndex, started, finished) | (payload, started, Just finished) <- spans, Just (groupIndex, sequenceIndex) <- [parsePayload payload]]
          byGroup = Map.fromListWith (<>) [(groupIndex, [(sequenceIndex, started, finished)]) | (groupIndex, sequenceIndex, started, finished) <- parsed]
          ordered groupIndex = maybe False (fifoGroupOrder jobsPerGroup) (Map.lookup groupIndex byGroup)
          blockedHead = [finished | (0, 0, _, finished) <- parsed]
          abandonedHead = length [() | (payload, _, Nothing) <- spans, payload == "0:0"]
          otherProgress = case blockedHead of
            [finished] -> any (\(groupIndex, _, _, otherFinished) -> groupIndex /= 0 && otherFinished < finished) parsed
            _ -> False
          cells =
            [ ("schedule-realised", blockedAtKill && (not killWorker || abandonedHead == 1)),
              ("all-jobs-completed", length parsed == expected && depth == 0),
              ("strict-group-order", all ordered [0 .. groups - 1]),
              ("other-groups-progress", otherProgress)
            ]
      recordMessagingCells context (Map.fromList [("groups", fromIntegral groups), ("jobs", fromIntegral (length parsed)), ("workers", fromIntegral workers), ("queueDepth", depth), ("abandonedHeads", fromIntegral abandonedHead)]) (object ["timedOut" .= maybe True (const False) maybeSpans, "groupSizes" .= fmap length byGroup, "killWorker" .= killWorker]) cells

fifoGroupOrder :: Int -> [(Int, UTCTime, UTCTime)] -> Bool
fifoGroupOrder jobsPerGroup groupSpans =
  let sorted = sortOn (\(sequenceIndex, _, _) -> sequenceIndex) groupSpans
   in map (\(sequenceIndex, _, _) -> sequenceIndex) sorted == [0 .. jobsPerGroup - 1]
        && and (zipWith (\(_, _, previousFinished) (_, nextStarted, _) -> previousFinished <= nextStarted) sorted (drop 1 sorted))

leaseExtension :: Scenario
leaseExtension =
  workersSurviveTransientPollingError
    { id = either (error . show) id (parseScenarioId "keiro/queue/concurrency/lease-extension"),
      summary = "Checks that extending a live job lease prevents a second worker from handling it.",
      knobs = [KnobSpec (knobName "queue.execution-shape") "Worker or bounded drain" KnobText (VText "worker") (OneOf (VText "worker" :| [VText "drain"])) [VText "drain"]],
      knownDefect = Nothing,
      run = runLeaseExtension
    }

runLeaseExtension :: RunContext -> IO ScenarioReport
runLeaseExtension context =
  withJobRuntime (requirePostgres context).connectionString Nothing \runtime ->
    withCheck context \check -> withSupervisor check \supervisor -> do
      let makeJob name = Job "queue-poll-probe" (queueRef (sourceName context name)) (aesonJobCodec @Text) Unordered defaultRetryPolicy
          draining = knobText context.knobs (knobName "queue.execution-shape") == "drain"
          unextended = makeJob "unextended"
          extended = makeJob "extended"
          countEffects payload = do
            let statement = Statement.preparable "SELECT count(*) FROM kenshou_fx.queue_effects WHERE payload = $1" (Encoders.param (Encoders.nonNullable Encoders.text)) (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))
            Pool.use runtime.runtimePool (Session.statement payload statement) >>= either (fail . show) pure
          awaitEffects payload expected = do
            count <- countEffects payload
            if count >= expected then pure True else threadDelay 100000 >> awaitEffects payload expected
          startWorker index job extend = do
            spec <- roleProcess check "keiro/queue-worker" index (object ["queue" .= job.jobQueue.logicalName, "mode" .= (if draining then "lease-drain" else "lease" :: Text), "extend" .= extend])
            child <- spawn supervisor spec
            awaitReady child 10000
            sendCommand child CtlStart
            awaitMark child "running" 30000
            pure child
          runArm index job extend payload expected = do
            if draining
              then do
                sent <- runJobEff runtime (enqueue job payload)
                _ <- either (fail . show) pure sent
                pure ()
              else pure ()
            first <- startWorker index job extend
            if draining
              then do
                awaitMark first "delivery" 10000
                threadDelay 2500000
              else pure ()
            second <- startWorker (index + 1) job extend
            if draining
              then pure ()
              else do
                sent <- runJobEff runtime (enqueue job payload)
                _ <- either (fail . show) pure sent
                pure ()
            observed <- maybe False id <$> timeout 20000000 (awaitEffects payload expected)
            threadDelay 2000000
            count <- countEffects payload
            firstSnapshot <- atomically (progress first)
            secondSnapshot <- atomically (progress second)
            let attempt snapshot = Map.lookup "delivery" snapshot.marks >>= parseMaybe (withObject "delivery" (.: "attempt"))
                attempts = (attempt firstSnapshot :: Maybe Word, attempt secondSnapshot :: Maybe Word)
            if draining
              then do
                awaitMark first "stopped" 10000
                awaitMark second "stopped" 10000
              else do
                killChild supervisor first
                killChild supervisor second
            pure (observed, count, attempts)
      Pool.use runtime.runtimePool (Session.script "CREATE SCHEMA IF NOT EXISTS kenshou_fx; CREATE TABLE IF NOT EXISTS kenshou_fx.queue_effects (payload text NOT NULL)") >>= either (fail . show) pure
      setup <- runJobEff runtime (ensureJobQueue unextended >> ensureJobQueue extended)
      _ <- either (fail . show) pure setup
      (duplicateObserved, unextendedCount, unextendedAttempts) <- runArm 0 unextended False "unextended" 2
      (singleObserved, extendedCount, extendedAttempts) <- runArm 2 extended True "extended" 1
      recordMessagingCells
        context
        (Map.fromList [("unextendedEffects", unextendedCount), ("extendedEffects", extendedCount)])
        (object ["executionShape" .= knobText context.knobs (knobName "queue.execution-shape"), "unextendedAttempts" .= unextendedAttempts, "extendedAttempts" .= extendedAttempts])
        [ ("unextended-lease-expires", duplicateObserved && unextendedCount >= 2),
          ("extension-prevents-duplicate", singleObserved && extendedCount == 1),
          ("extended-read-count-one", extendedAttempts == (Just 0, Nothing) || extendedAttempts == (Nothing, Just 0))
        ]

crashRedeliveryCadence :: Scenario
crashRedeliveryCadence =
  workersSurviveTransientPollingError
    { id = either (error . show) id (parseScenarioId "keiro/queue/concurrency/crash-redelivery-cadence"),
      summary = "Checks a killed handler redelivers at the visibility timeout rather than the policy retry delay.",
      knobs = [KnobSpec (knobName "queue.polling") "Job worker polling mode" KnobText (VText "poll-every") (OneOf (VText "poll-every" :| [VText "long-poll"])) [VText "long-poll"]],
      knownDefect = Just (KnownDefect "mori://shinzui/keiro/okf/bug-reports/concepts/BUG-4" "Long-poll workers may consume reads without handler delivery after process death" ["visibility-cadence", "crashes-consume-attempts", "retry-ceiling-dead-letters"] AllCohorts),
      run = runCrashRedeliveryCadence
    }

runCrashRedeliveryCadence :: RunContext -> IO ScenarioReport
runCrashRedeliveryCadence context =
  withJobRuntime (requirePostgres context).connectionString Nothing \runtime ->
    withCheck context \check -> withSupervisor check \supervisor -> do
      let queue = sourceName context "cadence"
          pollingMode = knobText context.knobs (knobName "queue.polling")
          job = Job "queue-poll-probe" (queueRef queue) (aesonJobCodec @Text) Unordered (RetryPolicy 3 (RetryDelay 60) True)
          dlqTable = "pgmq.q_" <> queueNameToText job.jobQueue.dlqName
          dlqStatement = Statement.preparable ("SELECT count(*), coalesce(max(message->>'dead_letter_reason'),'')::text, coalesce(max((message->>'read_count')::bigint),0)::bigint FROM " <> dlqTable) Encoders.noParams (Decoders.singleRow ((,,) <$> Decoders.column (Decoders.nonNullable Decoders.int8) <*> Decoders.column (Decoders.nonNullable Decoders.text) <*> Decoders.column (Decoders.nonNullable Decoders.int8)))
          dlqState = Pool.use runtime.runtimePool (Session.statement () dlqStatement) >>= either (fail . show) pure
          waitDlq = do
            state <- dlqState
            if state == (1, "max_retries_exceeded", 4) then pure True else threadDelay 100000 >> waitDlq
          decodeDelivery value = do
            (attempt, at) <- parseMaybe (withObject "delivery" (\o -> (,) <$> o .: "attempt" <*> o .: "at")) value
            stamp <- readMaybe at
            pure (attempt :: Maybe Word, stamp :: UTCTime)
          waitDelivery children = do
            observed <-
              traverse
                ( \child -> do
                    snapshot <- atomically (progress child)
                    pure (fmap (\delivery -> (child, delivery)) (Map.lookup "delivery" snapshot.marks >>= decodeDelivery))
                )
                children
            case [answer | Just answer <- observed] of
              answer : _ -> pure answer
              [] -> threadDelay 100000 >> waitDelivery children
          startWorker index = do
            spec <- roleProcess check "keiro/queue-worker" index (object ["queue" .= queue, "mode" .= ("hold" :: Text), "polling" .= pollingMode])
            child <- spawn supervisor spec
            awaitReady child 10000
            sendCommand child CtlStart
            awaitMark child "running" 30000
            pure child
      setup <- runJobEff runtime do
        ensureJobQueue job
        enqueue job ("cadence" :: Text)
      _ <- either (fail . show) pure setup
      first <- startWorker 0
      second <- startWorker 1
      (firstOwner, firstDelivery) <- maybe (fail "first queue delivery timed out") pure =<< timeout 15000000 (waitDelivery [first, second])
      killChild supervisor firstOwner
      let survivor = if childPid firstOwner == childPid first then second else first
      (secondOwner, secondDelivery) <- maybe (fail "second queue delivery timed out") pure =<< timeout 15000000 (waitDelivery [survivor])
      killChild supervisor secondOwner
      third <- startWorker 2
      fourth <- startWorker 3
      thirdResult <- timeout 15000000 (waitDelivery [third, fourth])
      case thirdResult of
        Nothing -> do
          finalState <- dlqState
          thirdSnapshot <- atomically (progress third)
          fourthSnapshot <- atomically (progress fourth)
          killChild supervisor third
          killChild supervisor fourth
          let gap = realToFrac (diffUTCTime (snd secondDelivery) (snd firstDelivery)) :: Double
          recordMessagingCells
            context
            (Map.fromList [("kills", 2), ("deliveries", 2)])
            (object ["attempts" .= fmap fst [firstDelivery, secondDelivery], "gapsSeconds" .= [gap], "dlq" .= show finalState, "thirdDeliveryTimedOut" .= True])
            [ ("visibility-cadence", gap >= 2.8 && gap <= 5),
              ("crashes-consume-attempts", False),
              ("retry-ceiling-dead-letters", False),
              ("no-fourth-handler-call", not (Map.member "delivery" thirdSnapshot.marks || Map.member "delivery" fourthSnapshot.marks))
            ]
        Just (thirdOwner, thirdDelivery) -> do
          killChild supervisor thirdOwner
          let finalSurvivor = if childPid thirdOwner == childPid third then fourth else third
          deadLettered <- maybe False id <$> timeout 15000000 waitDlq
          finalState <- dlqState
          finalSnapshot <- atomically (progress finalSurvivor)
          killChild supervisor finalSurvivor
          let starts = [firstDelivery, secondDelivery, thirdDelivery]
              attempts = fmap fst starts
              gaps = zipWith (\(_, a) (_, b) -> realToFrac (diffUTCTime b a) :: Double) starts (drop 1 starts)
              cells =
                [ ("visibility-cadence", all (\gap -> gap >= 2.8 && gap <= 5) gaps),
                  ("crashes-consume-attempts", attempts == [Just 0, Just 1, Just 2]),
                  ("retry-ceiling-dead-letters", deadLettered && finalState == (1, "max_retries_exceeded", 4)),
                  ("no-fourth-handler-call", not (Map.member "delivery" finalSnapshot.marks))
                ]
          recordMessagingCells context (Map.fromList [("kills", 3), ("deliveries", 3)]) (object ["attempts" .= attempts, "gapsSeconds" .= gaps, "dlq" .= show finalState]) cells

knobName :: Text -> KnobName
knobName = either (error . show) id . mkKnobName

workersSurviveTransientPollingError :: Scenario
workersSurviveTransientPollingError =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/queue/concurrency/workers-survive-transient-polling-error"),
      revision = 1,
      summary = "Checks the continuous job worker resumes after repeated PostgreSQL backend terminations.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = [],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaPgmq] [] False)},
      knownDefect = Just (KnownDefect "mori://shinzui/keiro/okf/bug-reports/concepts/BUG-3" "Polling backend termination can stop the worker after an unexpected row-count error" ["faults-injected", "processing-resumed", "no-loss"] AllCohorts),
      run = runWorkersSurviveTransientPollingError
    }

effectCountsStatement :: Statement.Statement () (Int64, Int64)
effectCountsStatement = Statement.preparable "SELECT count(*), count(DISTINCT payload) FROM kenshou_fx.queue_effects" Encoders.noParams (Decoders.singleRow ((,) <$> Decoders.column (Decoders.nonNullable Decoders.int8) <*> Decoders.column (Decoders.nonNullable Decoders.int8)))

runWorkersSurviveTransientPollingError :: RunContext -> IO ScenarioReport
runWorkersSurviveTransientPollingError context =
  withJobRuntime (requirePostgres context).connectionString Nothing \runtime ->
    withCheck context \check -> withSupervisor check \supervisor -> do
      let postgres = requirePostgres context
          queue = sourceName context "polling"
          job = Job "queue-poll-probe" (queueRef queue) (aesonJobCodec @Text) Unordered defaultRetryPolicy
          readCounts = Pool.use runtime.runtimePool (Session.statement () effectCountsStatement) >>= either (fail . show) pure
          waitBackend = do
            backends <- listBackends postgres
            case [backend.pid | backend <- backends, "queue-worker-0" `Text.isInfixOf` backend.applicationName] of
              pid : _ -> pure (Just pid)
              [] -> threadDelay 100000 >> waitBackend
      Pool.use runtime.runtimePool (Session.script "CREATE SCHEMA IF NOT EXISTS kenshou_fx; CREATE TABLE IF NOT EXISTS kenshou_fx.queue_effects (payload text NOT NULL)") >>= either (fail . show) pure
      setup <- runJobEff runtime (ensureJobQueue job)
      _ <- either (fail . show) pure setup
      spec <- roleProcess check "keiro/queue-worker" 0 (object ["queue" .= queue])
      child <- spawn supervisor spec
      awaitReady child 10000
      sendCommand child CtlStart
      awaitMark child "running" 30000
      let waitDistinct expected = do
            (_, distinct) <- readCounts
            snapshot <- atomically (progress child)
            if distinct >= expected
              then pure True
              else
                if Map.member "stopped" snapshot.marks then pure False else threadDelay 100000 >> waitDistinct expected
          runBatches [] = pure []
          runBatches (batch : rest) = do
            let payloads = [Text.pack (show index) | index <- [batch * 20 + 1 .. batch * 20 + 20 :: Int]]
            sent <- runJobEff runtime (enqueueBatch job payloads)
            _ <- either (fail . show) pure sent
            completed <- maybe False id <$> timeout 30000000 (waitDistinct (fromIntegral ((batch + 1) * 20)))
            if not completed
              then pure [(False, False)]
              else do
                victim <- maybe Nothing id <$> timeout 10000000 waitBackend
                case victim of
                  Nothing -> pure [(True, False)]
                  Just pid -> do
                    _ <- (terminateOneBackend postgres (ByPid pid)).inject
                    ((True, True) :) <$> runBatches rest
      faultResults <- runBatches [0 .. 4 :: Int]
      final <- if length faultResults == 5 then maybe False id <$> timeout 30000000 (waitDistinct 100) else pure False
      (total, distinct) <- readCounts
      let queueTable = "pgmq.q_" <> queueNameToText job.jobQueue.physicalName
          depthStatement = Statement.preparable ("SELECT count(*) FROM " <> queueTable) Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))
      threadDelay 1000000
      depth <- Pool.use runtime.runtimePool (Session.statement () depthStatement) >>= either (fail . show) pure
      snapshot <- atomically (progress child)
      if Map.member "stopped" snapshot.marks then pure () else killChild supervisor child
      let enqueued = fromIntegral (length faultResults * 20)
          injectedFaults = fromIntegral (length (filter snd faultResults))
          cells =
            [ ("faults-injected", length faultResults == 5 && all snd faultResults),
              ("processing-resumed", all fst faultResults && final && snapshot.count >= 100 && not (Map.member "stopped" snapshot.marks)),
              ("no-loss", distinct == enqueued && depth == 0),
              ("bounded-duplicates", total >= distinct && total <= enqueued + injectedFaults)
            ]
      recordMessagingCells context (Map.fromList [("enqueued", enqueued), ("effects", total), ("distinctEffects", distinct), ("faults", injectedFaults)]) (object ["faultResults" .= faultResults, "workerStopped" .= Map.member "stopped" snapshot.marks]) cells
