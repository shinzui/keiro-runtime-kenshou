module Kenshou.Suite.Keiro.Command.SteadyState (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (poll, withAsync)
import Control.Concurrent.MVar (modifyMVar_, newMVar, readMVar)
import Control.Concurrent.STM (atomically)
import Control.Exception (bracket, mask_, throwIO)
import Control.Monad (forM, forever, when)
import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time (addUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Vector qualified as Vector
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Keiro.Command (CommandResult (..), defaultRunCommandOptions)
import Keiro.Projection (countAsyncProjectionDedupForBefore, pruneAsyncProjectionDedupForBefore, runCommandWithProjections)
import Kenshou.Check.Process (Child, ProcessSpec, ProgressSnapshot (..), Supervisor, awaitReady, childPid, killChild, progress, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Context qualified as Core
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (Kind (..), parseScenarioId, renderRunId, unSeed)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobInt, knobText, mkKnobName)
import Kenshou.Core.Outcome (Outcome (..), worstOutcome)
import Kenshou.Core.Phase (PhasePlan (..))
import Kenshou.Core.Role (ControlMessage (..), WorkerMessage (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport (..), Tier (..), failedWith)
import Kenshou.Diagnose.Leak (LeakReport (..), LeakSpec (..), ProbeReport (..), ProbeSpec (..), analyseSeriesDirectory, defaultLeakSpec, judgeLeaksWithWindow, leakOutcome)
import Kenshou.Diagnose.Series (SeriesBinding (..), readBinding)
import Kenshou.Measure.Knobs (measureKnobs)
import Kenshou.Measure.Load (ClosedConfig (..), LoadModel (..), Operation (..), runLoad)
import Kenshou.Measure.Recorder (OpName (..), OpResult (..))
import Kenshou.Measure.Sampler.Csv (CsvWriter, appendCsv, closeCsv, openCsv)
import Kenshou.Measure.Session (measureConfigFromKnobs, phasePlanFromCore, withMeasurement)
import Kenshou.Measure.Stats (exactQuantile)
import Kenshou.Suite.Keiro.Command.Backlog (CapacityClass (..), DrainReport (..), StageSample (..), StageTrend (..), classifyCapacity, drainReport, renderCapacity, steadyTrends)
import Kenshou.Suite.Keiro.Command.Correctness (recordCells)
import Kenshou.Suite.Keiro.Fixture.Account
import Kenshou.Suite.Keiro.Fixture.Domain
import Kenshou.Suite.Keiro.Fixture.Model qualified as Model
import Kenshou.Suite.Keiro.Fixture.Oracle (StageCounts (..))
import Kenshou.Suite.Keiro.Fixture.Oracle qualified as Oracle
import Kenshou.Suite.Keiro.Fixture.Projection (accountActivityReadModelName, accountBalanceProjection, ensureFixtureReadModels)
import Kenshou.Suite.Keiro.Fixture.Runtime
import Kenshou.Telemetry (telemetryKnobs)
import Kiroku.Store (defaultConnectionSettings)
import Kiroku.Store.Types (EventType (..))
import System.Exit (ExitCode (..))
import System.FilePath ((</>))

scenarios :: [Scenario]
scenarios = [steadyState False, steadyState True]

-- Revision 3 adds the finding 44 and 46 controls: a configurable drain
-- budget with a durable stage-count series, the writers-only and
-- generate-only isolation topologies, writer snapshot and seed-verification
-- knobs, and child-owned telemetry for every tracing and metrics arm.
steadyState :: Bool -> Scenario
steadyState reduced =
  Scenario
    { id = either (error . show) id (parseScenarioId (if reduced then "keiro/command/soak/write-side-steady-state-reduced" else "keiro/command/soak/write-side-steady-state")),
      revision = 3,
      summary = "Runs two command writers with durable saga, router, and projection workers, then checks quiescent effects.",
      tier = if reduced then TierExtended else TierSoak,
      placement = if reduced then PlaceEither else PlaceCell,
      knobs =
        telemetryKnobs
          <> measureKnobs Soak
          <> [ intKnob "soak.duration-minutes" (if reduced then 20 else 240) 1 1440,
               intKnob "command.rate-per-second" 200 1 2000,
               intKnob "command.accounts" 100 4 1000,
               intKnob "router.fanout" 4 1 100,
               intKnob "soak.kill-interval-seconds" 0 0 3600,
               intKnob "projection.prune-interval-seconds" 300 0 3600,
               intKnob "projection.dedup-retention-seconds" 3600 600 86400,
               intKnob "soak.drain-seconds" 120 0 14400,
               intKnob "soak.stage-sample-seconds" 10 0 600,
               enumKnob "soak.topology" "Processes started: every worker, or only the command writers" "full" ["full", "writers-only"],
               enumKnob "writer.submit-mode" "Writers submit Keiro commands or only generate them" "keiro" ["keiro", "generate-only"],
               enumKnob "snapshot.policy" "Writer account snapshot policy" "every-100" ["never", "every-1", "every-10", "every-100", "on-terminal"],
               intKnob "snapshot.seed-verify-sample-rate" 1000 0 100000
             ],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| [TracingNoop, TracingSdkInMemory, TracingSdkOtlp]) TracingOff),
            metrics = Supported (Support (MetricsOff :| [MetricsCollect, MetricsServe, MetricsServeScraped]) MetricsOff),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      phases = PhasePlan 5 (if reduced then 1200 else 14400) 5,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku, SchemaKeiro] [("shared_preload_libraries", "'pg_stat_statements'")] False)},
      knownDefect = Nothing,
      run = runSteadyState
    }

data Topology = Full | WritersOnly deriving stock (Eq, Show)

runSteadyState :: RunContext -> IO ScenarioReport
runSteadyState context
  | topologyText `notElem` ["full", "writers-only"] = pure (failedWith ["invalid-knobs"] ("unknown soak.topology " <> topologyText))
  | submitMode == "generate-only" && topology /= WritersOnly = pure (failedWith ["invalid-knobs"] "writer.submit-mode=generate-only requires soak.topology=writers-only")
  | topology == WritersOnly && knob "soak.kill-interval-seconds" /= 0 = pure (failedWith ["invalid-knobs"] "soak.kill-interval-seconds needs the downstream workers of soak.topology=full")
  | Left issue <- parseAccountSnapshotPolicy policyText = pure (failedWith ["invalid-knobs"] issue)
  | otherwise = case measureConfigFromKnobs context (phasePlanFromCore (PhasePlan 5 (fromIntegral minutes * 60) 5)) of
      Left reason -> pure (failedWith ["invalid-measure-config"] reason)
      Right config ->
        withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture ->
          withCheck context \check -> withSupervisor check \supervisor -> do
            let KeiroRunner runFixture = fixture.runner
                accounts = knob "command.accounts"
                fanout = knob "router.fanout"
                rate = knob "command.rate-per-second"
                killInterval = knob "soak.kill-interval-seconds"
                pruneInterval = knob "projection.prune-interval-seconds"
                retention = knob "projection.dedup-retention-seconds"
                drainBudget = knob "soak.drain-seconds"
                sampleInterval = knob "soak.stage-sample-seconds"
                account index = AccountId (Text.pack (show index))
                accountEvents = accountEventStream (either (const (SnapEvery 100)) id (parseAccountSnapshotPolicy policyText))
                cutoff = addUTCTime (negate (fromIntegral retention)) <$> getCurrentTime
                pruneAt before =
                  runFixture (pruneAsyncProjectionDedupForBefore accountActivityReadModelName before) >>= either (fail . show) pure
                pruneLoop = forever $ threadDelay (pruneInterval * 1000000) >> cutoff >>= pruneAt >> pure ()
            _ <- runFixture ensureFixtureReadModels >>= either (fail . show) pure
            seeded <- forM [0 .. accounts - 1] \index -> do
              let current = account index
              runFixture (runCommandWithProjections defaultRunCommandOptions accountEvents (accountStream current) (OpenAccount (OpenAccountData current 10000)) [accountBalanceProjection])
            connection <- acquireConnection "kenshou-keiro-steady-oracle"
            _ <- forM [0 .. fanout - 1] \index -> Connection.use connection (Session.statement (Text.pack (show index)) directoryInsert) >>= either (fail . show) pure
            let dispatcher role index subscription extra = do
                  spec <- roleProcess check role index (object (["subscription" .= (subscription :: Text.Text), "sampleProcess" .= True, "telemetry" .= telemetryOn] <> extra))
                  startChild supervisor spec
                spawnProjection index = do
                  spec <- roleProcess check "keiro/projection-worker" index (object ["batchSize" .= (100 :: Int), "sampleProcess" .= True, "telemetry" .= telemetryOn])
                  startChild supervisor spec
                spawnManager index = dispatcher "keiro/pm-worker" index "kenshou-keiro-steady-pm" ["inlineProjection" .= True]
                spawnRouter index = dispatcher "keiro/router-worker" index "kenshou-keiro-steady-router" []
            downstream <-
              if topology == Full
                then do
                  manager <- spawnManager 0 >>= newMVar
                  router <- spawnRouter 0 >>= newMVar
                  projection <- spawnProjection 0 >>= newMVar
                  pure [(manager, spawnManager), (router, spawnRouter), (projection, spawnProjection)]
                else pure []
            workerKills <- newIORef (0 :: Int)
            let restartLoop generation = do
                  threadDelay (killInterval * 1000000)
                  mask_ do
                    let slot = (generation - 1) `mod` length downstream
                        index = (generation - 1) `div` length downstream + 1
                        (current, spawnNext) = downstream !! slot
                    modifyMVar_ current \old -> do
                      killChild supervisor old
                      replacement <- spawnNext index
                      modifyIORef' workerKills (+ 1)
                      pure replacement
                  restartLoop (generation + 1)
            writers <- forM [0, 1 :: Int] \index -> do
              let delay = max 1 (2000000 `div` rate)
                  args =
                    object
                      [ "worker" .= index,
                        "workers" .= (2 :: Int),
                        "count" .= (100000000 :: Int),
                        "accounts" .= accounts,
                        "inlineProjection" .= True,
                        "reportEvery" .= (1000 :: Int),
                        "postSubmissionDelayMicros" .= delay,
                        "sampleProcess" .= True,
                        "snapshotPolicy" .= policyText,
                        "seedVerifySampleRate" .= knob "snapshot.seed-verify-sample-rate",
                        "submitMode" .= submitMode,
                        "telemetry" .= telemetryOn
                      ]
              spec <- roleProcess check "keiro/command-writer" index args
              startChild supervisor spec
            phaseRef <- newIORef ("steady" :: Text.Text)
            samplesRef <- newIORef []
            startedNs <- getMonotonicTimeNSec
            stagesPath <- Core.artifactPath context Core.SeriesDir "write-side-stages.csv"
            when (sampleInterval > 0) (Core.declareMediaType context "series/write-side-stages.csv" "text/csv")
            let sampler =
                  if sampleInterval == 0
                    then forever (threadDelay 60000000)
                    else bracket (acquireConnection "kenshou-keiro-steady-stages") Connection.release \stageConnection ->
                      bracket (openCsv stagesPath stageColumns) closeCsv \csv ->
                        forever do
                          sampleStages stageConnection csv startedNs (fromIntegral fanout) phaseRef samplesRef
                          threadDelay (sampleInterval * 1000000)
            (writerExits, drain) <- withAsync sampler \stageSampler -> do
              _ <- withAsync (if pruneInterval == 0 || topology /= Full then pure () else pruneLoop) \pruner ->
                withAsync (if killInterval == 0 then pure () else restartLoop 1) \killer -> do
                  measured <- withMeasurement context config \measurement ->
                    runLoad measurement (ClosedLoop (ClosedConfig 1 10000000 0)) (Operation (OpName "soak-heartbeat") (\_ _ -> pure (OpOk 1)))
                  poll pruner >>= maybe (pure ()) (either throwIO (const (pure ())))
                  poll killer >>= maybe (pure ()) (either throwIO (const (pure ())))
                  pure measured
              exits <- traverse (\child -> stopGracefully supervisor child writerStopGraceMillis) writers
              writeIORef phaseRef "drain"
              atStop <- Oracle.readStageCounts connection
              drainStarted <- getMonotonicTimeNSec
              (atEnd, quiescentAfter) <- awaitDrain connection (fromIntegral fanout) drainStarted (fromIntegral drainBudget)
              drainEnded <- getMonotonicTimeNSec
              poll stageSampler >>= maybe (pure ()) (either throwIO (const (pure ())))
              pure (exits, drainReport (fromIntegral fanout) atStop atEnd (nanosToSeconds (drainEnded - drainStarted)) quiescentAfter)
            let quiescent = drain.quiescentAfterSeconds /= Nothing
            accountRows <- Oracle.readCategoryLog connection "account"
            bonusRows <- Oracle.readCategoryLog connection "bonus"
            sagaRows <- Oracle.readCategoryLog connection "pm:transferSaga"
            balances <- Oracle.readBalanceTable connection
            activity <- Oracle.readActivityTable connection
            deadLetters <- Oracle.readDispatchDeadLetters connection
            subscriptionDeadLetters <- Oracle.readSubscriptionDeadLetters connection
            checkpoints <- Oracle.readCheckpoints connection
            snapshotCounts <- Connection.use connection (Session.statement () snapshotCount) >>= either (fail . show) pure
            dedupCutoff <- cutoff
            pruned <- if pruneInterval == 0 || topology /= Full then pure 0 else pruneAt dedupCutoff
            oldDedup <-
              if pruneInterval == 0 || topology /= Full
                then pure 0
                else runFixture (countAsyncProjectionDedupForBefore accountActivityReadModelName dedupCutoff) >>= either (fail . show) pure
            dedupCount <- Connection.use connection (Session.statement () projectionDedupCount) >>= either (fail . show) pure
            Connection.release connection
            finalDownstream <- traverse (readMVar . fst) downstream
            mapM_ (killChild supervisor) finalDownstream
            killCount <- readIORef workerKills
            writerStates <- traverse (atomically . progress) writers
            samples <- reverse <$> readIORef samplesRef
            latencySamples <- fmap concat $ forM [0, 1 :: Int] \index -> do
              let relative = "children/keiro-command-writer-" <> show index <> "/latency.csv"
              result <- readBinding (context.outDir </> "series" </> relative) (SeriesBinding relative "t_mono_ns" "duration_ns" Map.empty)
              Vector.toList <$> either (fail . show) pure result
            let (earlyP99, lateP99, earlyCount, lateCount, latencyVerdict) = compareLatencyDeciles latencySamples
                count kind rows = length [() | row <- rows, row.eventType == EventType kind]
                transfers = count "TransferDebited" accountRows
                bonuses = length bonusRows
                money = Oracle.modelFromLog accountRows
                modelMatches = case money of
                  Left _ -> False
                  Right model -> all (\index -> let current = account index; expected = Model.lookupAccount current model in case Map.lookup current balances of Just (balance, entries, _) -> fromIntegral expected.balance == balance && fromIntegral expected.entries == entries; Nothing -> False) [0 .. accounts - 1]
                activityMatches = sum [applied | (applied, _) <- Map.elems activity] == fromIntegral (length accountRows) && maybe False (\model -> sum [net | (_, net) <- Map.elems activity] == fromIntegral (Model.totalMoney model)) (either (const Nothing) Just money)
                noWriterError = all (\snapshot -> case snapshot.lastMessage of Just (WrkError _) -> False; _ -> True) writerStates
                duration = fromIntegral minutes * 60 :: Double
                leakSpec = defaultLeakSpec {warmupCutSeconds = 0, minDurationSeconds = max 30 (duration * 0.7), minPoints = 10, envelopeWindowSeconds = max 2 (min 30 (duration / 40))}
                trends = steadyTrends (fromIntegral fanout) samples
                steadySampleCount = length [() | sample <- samples, sample.phase == "steady"]
                capacity = if topology == Full then classifyCapacity (steadySampleCount `div` 2) trends else InsufficientSamples
                children = [("keiro/command-writer", 0 :: Int), ("keiro/command-writer", 1)] <> (if topology == Full then [("keiro/pm-worker", 0), ("keiro/router-worker", 0), ("keiro/projection-worker", 0)] else [])
            leak <- judgeLeaksWithWindow context (Just (5, 5 + duration)) leakSpec
            childLeaks <- forM children \(role, index) -> do
              let label = Text.unpack (Text.replace "/" "-" role) <> "-" <> show index
                  appName = "kenshou-" <> Text.take 8 (renderRunId context.runId) <> "-" <> role <> "-" <> Text.pack (show index)
                  prefix = "children" </> label
                  childSpec = childLeakSpec prefix appName leakSpec
              report <- analyseSeriesDirectory context.outDir childSpec (unSeed context.seed)
              let named = nameLeakReport (Text.pack label) report
                  relative = "diagnosis/leak-" <> label <> ".json"
              path <- Core.artifactPath context Core.DiagnosisDir ("leak-" <> label <> ".json")
              LazyByteString.writeFile path (encode named)
              Core.declareMediaType context relative "application/json"
              pure (label, named)
            putSummary
              context
              Measurements
              "write-side-steady"
              ( object
                  [ "topology" .= topologyText,
                    "submitMode" .= submitMode,
                    "snapshotPolicy" .= policyText,
                    "seedVerifySampleRate" .= knob "snapshot.seed-verify-sample-rate",
                    "childTelemetry" .= telemetryOn,
                    "accounts" .= accounts,
                    "fanout" .= fanout,
                    "workerKills" .= killCount,
                    "transfers" .= transfers,
                    "transferAnnounced" .= count "TransferAnnounced" accountRows,
                    "transferCredited" .= count "TransferCredited" accountRows,
                    "transferConfirmed" .= count "TransferConfirmed" accountRows,
                    "bonuses" .= bonuses,
                    "bonusCredited" .= count "BonusCredited" accountRows,
                    "sagaEvents" .= length sagaRows,
                    "accountEvents" .= length accountRows,
                    "activityApplied" .= sum [applied | (applied, _) <- Map.elems activity],
                    "quiescentWithinTimeout" .= quiescent,
                    "drain" .= drainValue drainBudget drain,
                    "capacity" .= capacityValue capacity trends steadySampleCount,
                    "subscriptionCheckpoints" .= [object ["subscription" .= row.subscriptionName, "member" .= row.consumerGroupMember, "lastSeen" .= row.lastSeen] | row <- checkpoints],
                    "inlineBalancesMatch" .= modelMatches,
                    "asyncActivityMatches" .= activityMatches,
                    "prunedDedupRowsFinal" .= pruned,
                    "oldDedupRows" .= oldDedup,
                    "dedupRows" .= dedupCount,
                    "commandLatency" .= object ["firstDecileP99Ns" .= earlyP99, "lastDecileP99Ns" .= lateP99, "firstDecileSamples" .= earlyCount, "lastDecileSamples" .= lateCount, "verdict" .= show latencyVerdict],
                    "leakVerdict" .= show leak.verdict,
                    "childLeakVerdicts" .= [(label, show report.verdict) | (label, report) <- childLeaks]
                  ]
              )
            let common =
                  [ ("writers-stopped", all (== ExitSuccess) writerExits && noWriterError && case writers of [left, right] -> childPid left /= childPid right; _ -> False),
                    ("source-setup", all (\case Right (Right result) -> result.eventsAppended == 1; _ -> False) seeded),
                    ("no-dead-letters", null deadLetters && null subscriptionDeadLetters),
                    ("bounded-snapshots", fst snapshotCounts <= fromIntegral accounts && fst snapshotCounts == snd snapshotCounts),
                    ("logs-well-formed", Oracle.logWellFormed accountRows && Oracle.logWellFormed bonusRows && Oracle.logWellFormed sagaRows)
                  ]
                cells = case (topology, submitMode) of
                  (Full, _) ->
                    common
                      <> [ ("scheduled-worker-kills", killInterval == 0 || killCount > 0),
                           ("exactly-once-target-effects", quiescent && count "TransferCredited" accountRows == transfers && count "TransferConfirmed" accountRows == transfers && count "BonusCredited" accountRows == bonuses * fanout && length sagaRows == 2 * transfers),
                           ("inline-balances", modelMatches),
                           ("async-activity", activityMatches),
                           ("dedup-retention", pruneInterval == 0 || oldDedup == 0)
                         ]
                  (WritersOnly, "generate-only") ->
                    common <> [("no-commands-submitted", length accountRows == accounts && null bonusRows && null sagaRows)]
                  (WritersOnly, _) ->
                    common <> [("inline-balances", modelMatches), ("no-downstream-effects", null sagaRows && count "TransferCredited" accountRows == 0 && count "BonusCredited" accountRows == 0)]
            base <- recordCells context cells
            pure (base {outcome = worstOutcome (base.outcome :| (leakOutcome leak : latencyVerdict : fmap (leakOutcome . snd) childLeaks))})
  where
    knob name = fromIntegral (knobInt context.knobs (knobName name)) :: Int
    minutes = knob "soak.duration-minutes"
    topologyText = knobText context.knobs (knobName "soak.topology")
    topology = if topologyText == "writers-only" then WritersOnly else Full
    submitMode = knobText context.knobs (knobName "writer.submit-mode")
    policyText = knobText context.knobs (knobName "snapshot.policy")
    Dimensions tracingArm metricsArm _ _ = context.dimensions
    telemetryOn = maybe False (/= TracingOff) tracingArm || maybe False (/= MetricsOff) metricsArm
    -- A writer with child telemetry flushes its providers and, for scraped
    -- metrics, waits two scrape intervals before exiting.
    writerStopGraceMillis =
      30000 + (if telemetryOn then 2 * knob "metrics.scrape-interval-ms" + knob "otel.shutdown-timeout-ms" + 5000 else 0)
    acquireConnection name = Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName name) >>= either (fail . show) pure
    awaitDrain connection fanout started budget = do
      current <- Oracle.readStageCounts connection
      now <- getMonotonicTimeNSec
      let elapsed = nanosToSeconds (now - started)
      if all ((== 0) . snd) (Oracle.stageBacklog fanout current)
        then pure (current, Just elapsed)
        else
          if elapsed >= budget
            then pure (current, Nothing)
            else threadDelay 2000000 >> awaitDrain connection fanout started budget

startChild :: Supervisor -> ProcessSpec -> IO Child
startChild supervisor spec = do
  child <- spawn supervisor spec
  awaitReady child 10000
  sendCommand child CtlStart
  pure child

nanosToSeconds :: (Integral a) => a -> Double
nanosToSeconds nanos = fromIntegral nanos / 1.0e9

stageColumns :: [Text.Text]
stageColumns = ["t_mono_ns", "wall_ms", "phase", "transfer_debited", "transfer_announced", "transfer_credited", "transfer_confirmed", "saga_events", "bonus_declared", "bonus_credited", "account_events", "activity_applied", "backlog_credit", "backlog_confirm", "backlog_saga", "backlog_bonus", "backlog_activity"]

sampleStages :: Connection.Connection -> CsvWriter -> Word64 -> Int64 -> IORef Text.Text -> IORef [StageSample] -> IO ()
sampleStages connection csv started fanout phaseRef samplesRef = do
  counts <- Oracle.readStageCounts connection
  now <- getMonotonicTimeNSec
  wall <- getPOSIXTime
  phase <- readIORef phaseRef
  let offset = now - started
      backlog name = maybe 0 id (lookup name (Oracle.stageBacklog fanout counts))
      render :: (Show value) => value -> Text.Text
      render = Text.pack . show
  appendCsv
    csv
    ( [render offset, render (round (wall * 1000) :: Integer), phase]
        <> map render [counts.transferDebited, counts.transferAnnounced, counts.transferCredited, counts.transferConfirmed, counts.sagaEvents, counts.bonusDeclared, counts.bonusCredited, counts.accountEvents, counts.activityApplied]
        <> map (render . backlog) ["credit", "confirm", "saga", "bonus", "activity"]
    )
  modifyIORef' samplesRef (StageSample (nanosToSeconds offset) phase counts :)

drainValue :: Int -> DrainReport -> Value
drainValue budget report =
  object
    [ "budgetSeconds" .= budget,
      "elapsedSeconds" .= report.elapsedSeconds,
      "quiescentAfterSeconds" .= report.quiescentAfterSeconds,
      "backlogAtWriterStop" .= Map.fromList report.backlogAtStop,
      "backlogAtEnd" .= Map.fromList report.backlogAtEnd,
      "projectedRemainingSeconds" .= report.projectedRemainingSeconds
    ]

capacityValue :: CapacityClass -> [StageTrend] -> Int -> Value
capacityValue capacity trends sampleCount =
  object
    [ "class" .= renderCapacity capacity,
      "fallingBehind" .= case capacity of FallingBehind stages -> stages; _ -> [],
      "steadySamples" .= sampleCount,
      "window" .= ("second half of the steady samples" :: Text.Text),
      "stages" .= [object ["stage" .= trend.stage, "arrivalPerSecond" .= trend.arrivalPerSecond, "completionPerSecond" .= trend.completionPerSecond, "backlogSlopePerSecond" .= trend.backlogSlopePerSecond] | trend <- trends]
    ]

childLeakSpec :: FilePath -> Text.Text -> LeakSpec -> LeakSpec
childLeakSpec prefix appName (LeakSpec probes warmup points duration envelope resamples confidence) =
  LeakSpec
    [ probe {binding = if probe.name == "pg.connections" then probe.binding {filters = Map.insert "application_name" appName probe.binding.filters} else probe.binding {file = prefix </> probe.binding.file}}
    | probe <- probes,
      probe.name `elem` ["heap.live-bytes", "process.native-bytes", "haskell.threads", "os.threads", "os.fds", "pg.connections"]
    ]
    warmup
    points
    duration
    envelope
    resamples
    confidence

nameLeakReport :: Text.Text -> LeakReport -> LeakReport
nameLeakReport label (LeakReport verdict window seed policy probes) =
  LeakReport verdict window seed policy [probe {process = label} | probe <- probes]

compareLatencyDeciles :: [(Double, Double)] -> (Maybe Double, Maybe Double, Int, Int, Outcome)
compareLatencyDeciles [] = (Nothing, Nothing, 0, 0, Inconclusive)
compareLatencyDeciles samples@((firstTime, _) : rest) =
  let start = foldl' (\value (time, _) -> min value time) firstTime rest
      end = foldl' (\value (time, _) -> max value time) firstTime rest
      width = (end - start) / 10
      early = [latency | (time, latency) <- samples, time <= start + width]
      late = [latency | (time, latency) <- samples, time >= end - width]
      firstP99 = exactQuantile 0.99 early
      lastP99 = exactQuantile 0.99 late
      verdict = if length early < 100 || length late < 100 then Inconclusive else if lastP99 <= firstP99 * 1.2 then Passed else Inconclusive
   in (Just firstP99, Just lastP99, length early, length late, verdict)

directoryInsert :: Statement.Statement Text.Text ()
directoryInsert =
  Statement.preparable
    "INSERT INTO kenshou_keiro.account_directory (account_id, segment) VALUES ($1, 'all')"
    (Encoders.param (Encoders.nonNullable Encoders.text))
    Decoders.noResult

snapshotCount :: Statement.Statement () (Int64, Int64)
snapshotCount =
  Statement.preparable
    "SELECT count(*), count(DISTINCT stream_id) FROM keiro.keiro_snapshots"
    Encoders.noParams
    (Decoders.singleRow ((,) <$> Decoders.column (Decoders.nonNullable Decoders.int8) <*> Decoders.column (Decoders.nonNullable Decoders.int8)))

projectionDedupCount :: Statement.Statement () Int64
projectionDedupCount =
  Statement.preparable
    "SELECT count(*) FROM keiro.keiro_projection_dedup WHERE projection_name = 'kenshou-account-activity'"
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

intKnob :: Text.Text -> Int -> Int -> Int -> KnobSpec
intKnob key def low high = KnobSpec (knobName key) key KnobInt (VInt (fromIntegral def)) (IntRange (fromIntegral low) (fromIntegral high)) []

enumKnob :: Text.Text -> Text.Text -> Text.Text -> [Text.Text] -> KnobSpec
enumKnob key summary def values = KnobSpec (knobName key) summary KnobText (VText def) (OneOf (VText def :| [VText value | value <- values, value /= def])) []

knobName :: Text.Text -> KnobName
knobName = either (error . show) id . mkKnobName
