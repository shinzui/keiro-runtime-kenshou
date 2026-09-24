module Kenshou.Suite.Keiro.Queue.Concurrency (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically)
import Data.Aeson (object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.Int (Int64)
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
import Keiro.PGMQ.Job (Job (..), JobOrdering (..), RetryDelay (..), RetryPolicy (..), defaultRetryPolicy, enqueue, enqueueBatch, ensureJobQueue)
import Keiro.PGMQ.Runtime (JobRuntime (..), QueueRef (..), queueRef, runJobEff, withJobRuntime)
import Kenshou.Check.Fault (Fault (..))
import Kenshou.Check.Fault.Postgres (Backend (..), BackendSelector (..), listBackends, terminateOneBackend)
import Kenshou.Check.Process (ProgressSnapshot (..), awaitMark, awaitReady, childPid, killChild, progress, roleProcess, sendCommand, spawn, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobText, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Core.Scenario (CohortScope (..), KnownDefect (..), Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Messaging.Verdict (recordMessagingCells)
import Kenshou.Suite.Keiro.Outbox.Workload (sourceName)
import Pgmq.Types (queueNameToText)
import System.Timeout (timeout)
import Text.Read (readMaybe)

scenarios :: [Scenario]
scenarios = [workersSurviveTransientPollingError, crashRedeliveryCadence]

crashRedeliveryCadence :: Scenario
crashRedeliveryCadence =
  workersSurviveTransientPollingError
    { id = either (error . show) id (parseScenarioId "keiro/queue/concurrency/crash-redelivery-cadence"),
      summary = "Checks a killed handler redelivers at the visibility timeout rather than the policy retry delay.",
      knobs = [KnobSpec (knobName "queue.polling") "Job worker polling mode" KnobText (VText "poll-every") (OneOf (VText "poll-every" :| [VText "long-poll"])) [VText "long-poll"]],
      knownDefect = Just (KnownDefect "mori://shinzui/keiro/issues/5" "Long-poll workers may consume reads without handler delivery after process death" ["visibility-cadence", "crashes-consume-attempts", "retry-ceiling-dead-letters"] AllCohorts),
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
      knownDefect = Just (KnownDefect "mori://shinzui/keiro/issues/4" "Polling backend termination can stop the worker after an unexpected row-count error" ["faults-injected", "processing-resumed", "no-loss"] AllCohorts),
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
