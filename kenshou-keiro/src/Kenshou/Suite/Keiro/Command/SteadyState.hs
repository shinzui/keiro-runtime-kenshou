module Kenshou.Suite.Keiro.Command.SteadyState (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically)
import Control.Monad (forM)
import Data.Aeson (object, (.=))
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Keiro.Command (CommandResult (..), defaultRunCommandOptions)
import Keiro.Projection (runCommandWithProjections)
import Kenshou.Check.Process (ProgressSnapshot (..), awaitReady, childPid, killChild, progress, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (Kind (..), parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobInt, mkKnobName)
import Kenshou.Core.Outcome (Outcome (..), worstOutcome)
import Kenshou.Core.Phase (PhasePlan (..))
import Kenshou.Core.Role (ControlMessage (..), WorkerMessage (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport (..), Tier (..), failedWith)
import Kenshou.Diagnose.Leak (LeakReport (..), LeakSpec (..), defaultLeakSpec, judgeLeaks, leakOutcome)
import Kenshou.Measure.Knobs (measureKnobs)
import Kenshou.Measure.Load (ClosedConfig (..), LoadModel (..), Operation (..), runLoad)
import Kenshou.Measure.Recorder (OpName (..), OpResult (..))
import Kenshou.Measure.Session (measureConfigFromKnobs, phasePlanFromCore, withMeasurement)
import Kenshou.Suite.Keiro.Command.Correctness (recordCells)
import Kenshou.Suite.Keiro.Fixture.Account
import Kenshou.Suite.Keiro.Fixture.Domain
import Kenshou.Suite.Keiro.Fixture.Model qualified as Model
import Kenshou.Suite.Keiro.Fixture.Oracle qualified as Oracle
import Kenshou.Suite.Keiro.Fixture.Projection (accountBalanceProjection, ensureFixtureReadModels)
import Kenshou.Suite.Keiro.Fixture.Runtime
import Kiroku.Store (defaultConnectionSettings)
import Kiroku.Store.Types (EventType (..))
import System.Exit (ExitCode (..))
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [steadyState False, steadyState True]

steadyState :: Bool -> Scenario
steadyState reduced =
  Scenario
    { id = either (error . show) id (parseScenarioId (if reduced then "keiro/command/soak/write-side-steady-state-reduced" else "keiro/command/soak/write-side-steady-state")),
      revision = 1,
      summary = "Runs two command writers with durable saga, router, and projection workers, then checks quiescent effects.",
      tier = if reduced then TierExtended else TierSoak,
      placement = if reduced then PlaceEither else PlaceCell,
      knobs =
        measureKnobs Soak
          <> [ intKnob "soak.duration-minutes" (if reduced then 20 else 240) 1 1440,
               intKnob "command.rate-per-second" 200 1 2000,
               intKnob "command.accounts" 100 4 1000,
               intKnob "router.fanout" 4 1 100
             ],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      phases = PhasePlan 5 (if reduced then 1200 else 14400) 5,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku, SchemaKeiro] [("shared_preload_libraries", "'pg_stat_statements'")] False)},
      knownDefect = Nothing,
      run = runSteadyState
    }

runSteadyState :: RunContext -> IO ScenarioReport
runSteadyState context = case measureConfigFromKnobs context (phasePlanFromCore (PhasePlan 5 (fromIntegral minutes * 60) 5)) of
  Left reason -> pure (failedWith ["invalid-measure-config"] reason)
  Right config ->
    withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture ->
      withCheck context \check -> withSupervisor check \supervisor -> do
        let KeiroRunner runFixture = fixture.runner
            accounts = fromIntegral (knobInt context.knobs (knobName "command.accounts")) :: Int
            fanout = fromIntegral (knobInt context.knobs (knobName "router.fanout")) :: Int
            rate = fromIntegral (knobInt context.knobs (knobName "command.rate-per-second")) :: Int
            account index = AccountId (Text.pack (show index))
            accountEvents = accountEventStream (SnapEvery 100)
        _ <- runFixture ensureFixtureReadModels >>= either (fail . show) pure
        seeded <- forM [0 .. accounts - 1] \index -> do
          let current = account index
          runFixture (runCommandWithProjections defaultRunCommandOptions accountEvents (accountStream current) (OpenAccount (OpenAccountData current 10000)) [accountBalanceProjection])
        acquired <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-steady-oracle")
        connection <- either (fail . show) pure acquired
        _ <- forM [0 .. fanout - 1] \index -> Connection.use connection (Session.statement (Text.pack (show index)) directoryInsert) >>= either (fail . show) pure
        let dispatcher role index subscription extra = do
              spec <- roleProcess check role index (object (["subscription" .= (subscription :: Text.Text)] <> extra))
              child <- spawn supervisor spec
              awaitReady child 10000
              sendCommand child CtlStart
              pure child
        manager <- dispatcher "keiro/pm-worker" 0 "kenshou-keiro-steady-pm" ["inlineProjection" .= True]
        router <- dispatcher "keiro/router-worker" 0 "kenshou-keiro-steady-router" []
        projectionSpec <- roleProcess check "keiro/projection-worker" 0 (object ["batchSize" .= (100 :: Int)])
        projection <- spawn supervisor projectionSpec
        awaitReady projection 10000
        sendCommand projection CtlStart
        writers <- forM [0, 1 :: Int] \index -> do
          let delay = max 1 (2000000 `div` rate)
              args = object ["worker" .= index, "workers" .= (2 :: Int), "count" .= (100000000 :: Int), "accounts" .= accounts, "inlineProjection" .= True, "reportEvery" .= (1000 :: Int), "postSubmissionDelayMicros" .= delay]
          spec <- roleProcess check "keiro/command-writer" index args
          child <- spawn supervisor spec
          awaitReady child 10000
          sendCommand child CtlStart
          pure child
        (_, _) <- withMeasurement context config \measurement ->
          runLoad measurement (ClosedLoop (ClosedConfig 1 10000000 0)) (Operation (OpName "soak-heartbeat") (\_ _ -> pure (OpOk 1)))
        writerExits <- traverse (\child -> stopGracefully supervisor child 30000) writers
        quiescent <- timeout 120000000 (awaitQuiescence connection fanout)
        accountRows <- Oracle.readCategoryLog connection "account"
        bonusRows <- Oracle.readCategoryLog connection "bonus"
        sagaRows <- Oracle.readCategoryLog connection "pm:transferSaga"
        balances <- Oracle.readBalanceTable connection
        activity <- Oracle.readActivityTable connection
        deadLetters <- Oracle.readDispatchDeadLetters connection
        subscriptionDeadLetters <- Connection.use connection (Session.statement () subscriptionLetterCount) >>= either (fail . show) pure
        snapshotCounts <- Connection.use connection (Session.statement () snapshotCount) >>= either (fail . show) pure
        Connection.release connection
        mapM_ (killChild supervisor) [manager, router, projection]
        writerStates <- traverse (atomically . progress) writers
        let count kind rows = length [() | row <- rows, row.eventType == EventType kind]
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
        leak <- judgeLeaks context leakSpec
        putSummary context Measurements "write-side-steady" (object ["accounts" .= accounts, "fanout" .= fanout, "transfers" .= transfers, "bonuses" .= bonuses, "accountEvents" .= length accountRows, "leakVerdict" .= show leak.verdict, "coverageStatus" .= ("partial: child process leak probes and projection pruning pending" :: Text.Text)])
        base <-
          recordCells
            context
            [ ("writers-stopped", all (== ExitSuccess) writerExits && noWriterError && case writers of [left, right] -> childPid left /= childPid right; _ -> False),
              ("source-setup", all (\case Right (Right result) -> result.eventsAppended == 1; _ -> False) seeded),
              ("exactly-once-target-effects", quiescent == Just True && count "TransferCredited" accountRows == transfers && count "TransferConfirmed" accountRows == transfers && count "BonusCredited" accountRows == bonuses * fanout && length sagaRows == 2 * transfers),
              ("inline-balances", modelMatches),
              ("async-activity", activityMatches),
              ("no-dead-letters", null deadLetters && subscriptionDeadLetters == 0),
              ("bounded-snapshots", fst snapshotCounts <= fromIntegral accounts && fst snapshotCounts == snd snapshotCounts),
              ("logs-well-formed", Oracle.logWellFormed accountRows && Oracle.logWellFormed bonusRows && Oracle.logWellFormed sagaRows)
            ]
        pure (base {outcome = worstOutcome (base.outcome :| [leakOutcome leak, Inconclusive])})
  where
    minutes = fromIntegral (knobInt context.knobs (knobName "soak.duration-minutes")) :: Int
    awaitQuiescence connection fanout = do
      accountRows <- Oracle.readCategoryLog connection "account"
      bonusRows <- Oracle.readCategoryLog connection "bonus"
      sagaRows <- Oracle.readCategoryLog connection "pm:transferSaga"
      activity <- Oracle.readActivityTable connection
      let count kind = length [() | row <- accountRows, row.eventType == EventType kind]
          transfers = count "TransferDebited"
          ready = count "TransferAnnounced" == transfers && count "TransferCredited" == transfers && count "TransferConfirmed" == transfers && count "BonusCredited" == length bonusRows * fanout && length sagaRows == 2 * transfers && sum [applied | (applied, _) <- Map.elems activity] == fromIntegral (length accountRows)
      if ready then pure True else threadDelay 2000000 >> awaitQuiescence connection fanout

directoryInsert :: Statement.Statement Text.Text ()
directoryInsert =
  Statement.preparable
    "INSERT INTO kenshou_keiro.account_directory (account_id, segment) VALUES ($1, 'all')"
    (Encoders.param (Encoders.nonNullable Encoders.text))
    Decoders.noResult

subscriptionLetterCount :: Statement.Statement () Int64
subscriptionLetterCount =
  Statement.preparable
    "SELECT count(*) FROM kiroku.dead_letters"
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

snapshotCount :: Statement.Statement () (Int64, Int64)
snapshotCount =
  Statement.preparable
    "SELECT count(*), count(DISTINCT stream_id) FROM keiro.keiro_snapshots"
    Encoders.noParams
    (Decoders.singleRow ((,) <$> Decoders.column (Decoders.nonNullable Decoders.int8) <*> Decoders.column (Decoders.nonNullable Decoders.int8)))

intKnob :: Text.Text -> Int -> Int -> Int -> KnobSpec
intKnob key def low high = KnobSpec (knobName key) key KnobInt (VInt (fromIntegral def)) (IntRange (fromIntegral low) (fromIntegral high)) []

knobName :: Text.Text -> KnobName
knobName = either (error . show) id . mkKnobName
