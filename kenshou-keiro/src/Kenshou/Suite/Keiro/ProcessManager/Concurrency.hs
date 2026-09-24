module Kenshou.Suite.Keiro.ProcessManager.Concurrency (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync)
import Control.Concurrent.MVar (modifyMVar_, newMVar, readMVar)
import Control.Concurrent.STM (atomically)
import Control.Exception (mask_)
import Control.Monad (forM, when)
import Data.Aeson (object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.Foldable (traverse_)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Int (Int32)
import Data.List (nub, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Clock (getMonotonicTimeNSec)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Keiro.Command (CommandResult (..), defaultRunCommandOptions, runCommand)
import Kenshou.Check.Fault (Fault (..), FaultHandle (..))
import Kenshou.Check.Fault.Postgres (BackendSelector (..), terminateOneBackend)
import Kenshou.Check.Process (ProgressSnapshot (..), awaitMark, awaitReady, childPid, killChild, progress, roleProcess, sendCommand, spawn, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId, renderRunId, unSeed)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobBool, knobInt, knobText, mkKnobName)
import Kenshou.Core.Outcome (Outcome (..), worstOutcome)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport (..), Tier (..))
import Kenshou.Suite.Keiro.Command.Correctness (recordCells)
import Kenshou.Suite.Keiro.Fixture.Account
import Kenshou.Suite.Keiro.Fixture.Domain
import Kenshou.Suite.Keiro.Fixture.Oracle qualified as Oracle
import Kenshou.Suite.Keiro.Fixture.Runtime
import Kenshou.Suite.Keiro.Fixture.Workload qualified as Workload
import Kiroku.Store (defaultConnectionSettings)
import Kiroku.Store.Types (EventType (..))
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [sigkillCrashWindows, randomKillExactlyOnce, topologies]

randomKillExactlyOnce :: Scenario
randomKillExactlyOnce =
  sigkillCrashWindows
    { id = either (error . show) id (parseScenarioId "keiro/process-manager/concurrency/random-kill-exactly-once"),
      summary = "Restarts a durable saga worker repeatedly while paced transfer commands continue.",
      knobs =
        [ KnobSpec (knobName "command.rate-per-second") "Transfer submission rate" KnobInt (VInt 50) (IntRange 1 500) [],
          KnobSpec (knobName "fault.kill-interval-seconds") "Seconds between worker restarts" KnobInt (VInt 4) (IntRange 1 120) [],
          KnobSpec (knobName "command.duration-seconds") "Transfer submission duration" KnobInt (VInt 120) (IntRange 1 3600) [],
          KnobSpec (knobName "command.accounts") "Independent source and destination account pairs" KnobInt (VInt 100) (IntRange 1 1000) [],
          KnobSpec (knobName "fault.backend-terminate") "Terminate one worker backend on alternate restarts" KnobBool (VBool True) AnyValue []
        ],
      run = runRandomKill
    }

runRandomKill :: RunContext -> IO ScenarioReport
runRandomKill context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture ->
    withCheck context \check -> withSupervisor check \supervisor -> do
      let KeiroRunner runFixture = fixture.runner
          accountEvents = accountEventStream SnapNever
          subscription = "kenshou-keiro-random-kill" :: Text
          rate = fromIntegral (knobInt context.knobs (knobName "command.rate-per-second")) :: Int
          duration = fromIntegral (knobInt context.knobs (knobName "command.duration-seconds")) :: Int
          accounts = fromIntegral (knobInt context.knobs (knobName "command.accounts")) :: Int
          interval = fromIntegral (knobInt context.knobs (knobName "fault.kill-interval-seconds")) :: Int
          terminateBackend = knobBool context.knobs (knobName "fault.backend-terminate")
          total = rate * duration
          source index = AccountId ("kill-source-" <> Text.pack (show (index `mod` accounts)))
          destination index = AccountId ("kill-destination-" <> Text.pack (show (index `mod` accounts)))
          submit account command = runFixture (runCommand defaultRunCommandOptions accountEvents (accountStream account) command)
          accepted = \case Right (Right result) -> result.eventsAppended == 1; _ -> False
          spawnManager index = do
            spec <- roleProcess check "keiro/pm-worker" index (object ["subscription" .= subscription])
            child <- spawn supervisor spec
            awaitReady child 10000
            sendCommand child CtlStart
            pure child
          transferId index = TransferId ("kill-transfer-" <> Text.pack (show index))
          submitTransfer index = do
            let transfer = transferId index
                currentSource = source index
                currentDestination = destination index
                operation = Workload.Op 0 (fromIntegral index) (Workload.ActTransfer transfer currentSource currentDestination 1)
                debit = DebitTransfer (DebitTransferData currentSource transfer currentDestination 1 4102444800)
                announce = AnnounceTransfer (AnnounceTransferData currentSource transfer)
            first <- submitAccountCommand fixture accountEvents RunnerPlain defaultRunCommandOptions 3 (Workload.opEventId (unSeed context.seed) operation 0) debit
            second <- submitAccountCommand fixture accountEvents RunnerPlain defaultRunCommandOptions 3 (Workload.opEventId (unSeed context.seed) operation 1) announce
            pure [first, second]
          successful = \case SubmitAppended {} -> True; SubmitDuplicate -> True; _ -> False
      setup <- forM [0 .. accounts - 1] \index -> do
        let currentSource = source index
            currentDestination = destination index
        openedSource <- submit currentSource (OpenAccount (OpenAccountData currentSource (total + 10)))
        openedDestination <- submit currentDestination (OpenAccount (OpenAccountData currentDestination 0))
        pure [openedSource, openedDestination]
      initial <- spawnManager 0
      current <- newMVar initial
      restarts <- newIORef (0 :: Int)
      backendFaults <- newIORef (0 :: Int)
      let cycleWorker index = do
            threadDelay (interval * 1000000)
            mask_ $ modifyMVar_ current \old -> do
              when (terminateBackend && even index) do
                let appName = "kenshou-" <> Text.take 8 (renderRunId context.runId) <> "-keiro/pm-worker-" <> Text.pack (show (index - 1))
                handle <- (terminateOneBackend (requirePostgres context) (ByApplicationName appName)).inject
                let victims = parseMaybe (withObject "backend termination" (.: "victims")) handle.details :: Maybe [Int32]
                modifyIORef' backendFaults (+ maybe 0 length victims)
              killChild supervisor old
              replacement <- spawnManager index
              modifyIORef' restarts (+ 1)
              pure replacement
            cycleWorker (index + 1)
      (outcomes, submissionSeconds) <- withAsync (cycleWorker 1) \_ -> do
        started <- getMonotonicTimeNSec
        results <- forM [0 .. total - 1] \index -> do
          now <- getMonotonicTimeNSec
          let target = started + fromIntegral index * 1000000000 `div` fromIntegral rate
          when (target > now) (threadDelay (fromIntegral ((target - now) `div` 1000)))
          submitTransfer index
        ended <- getMonotonicTimeNSec
        pure (results, fromIntegral (ended - started) / 1000000000 :: Double)
      acquired <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-random-kill-oracle")
      connection <- either (fail . show) pure acquired
      quiescent <- timeout 60000000 (awaitQuiescence connection total)
      accountRows <- Oracle.readCategoryLog connection "account"
      sagaRows <- Oracle.readCategoryLog connection "pm:transferSaga"
      deadLetters <- Oracle.readDispatchDeadLetters connection
      subscriptionDeadLetters <- Connection.use connection (Session.statement () subscriptionLetterCount) >>= either (fail . show) pure
      Connection.release connection
      readMVar current >>= killChild supervisor
      restartCount <- readIORef restarts
      backendCount <- readIORef backendFaults
      let count kind = length [() | row <- accountRows, row.eventType == EventType kind]
          cells =
            [ ("source-setup", all accepted (concat setup)),
              ("commands-submitted", length outcomes == total && all successful (concat outcomes) && count "TransferDebited" == total),
              ("worker-restarted", restartCount >= 1 && (not terminateBackend || backendCount >= 1)),
              ("exactly-once-target-effects", quiescent == Just True && count "TransferAnnounced" == total && count "TransferCredited" == total && count "TransferConfirmed" == total && length sagaRows == 2 * total),
              ("no-dead-letters", null deadLetters && subscriptionDeadLetters == 0),
              ("logs-well-formed", Oracle.logWellFormed accountRows && Oracle.logWellFormed sagaRows)
            ]
      let pacingHealthy = submissionSeconds <= fromIntegral duration * 1.1
      putSummary context Measurements "random-kill" (object ["accounts" .= accounts, "transfers" .= total, "submissionSeconds" .= submissionSeconds, "effectiveTransfersPerSecond" .= (fromIntegral total / submissionSeconds :: Double), "pacingHealthy" .= pacingHealthy, "restarts" .= restartCount, "backendTerminations" .= backendCount])
      base <- recordCells context cells
      pure (base {outcome = worstOutcome (base.outcome :| [if pacingHealthy then Passed else Inconclusive])})
  where
    awaitQuiescence connection expected = do
      rows <- Oracle.readCategoryLog connection "account"
      let count kind = length [() | row <- rows, row.eventType == EventType kind]
      if count "TransferCredited" == expected && count "TransferConfirmed" == expected
        then pure True
        else threadDelay 200000 >> awaitQuiescence connection expected
    subscriptionLetterCount =
      Statement.preparable
        "SELECT count(*) FROM kiroku.dead_letters WHERE subscription_name = 'kenshou-keiro-random-kill'"
        Encoders.noParams
        (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

knobName :: Text -> KnobName
knobName = either (error . show) id . mkKnobName

topologies :: Scenario
topologies =
  sigkillCrashWindows
    { id = either (error . show) id (parseScenarioId "keiro/process-manager/concurrency/topologies"),
      summary = "Checks duplicate subscribers, consumer groups, and shard workers converge on one effect per transfer.",
      knobs =
        [ KnobSpec (either (error . show) id (mkKnobName "pm.topology")) "Worker subscription layout" KnobText (VText "duplicate-subscribers") (OneOf (VText "duplicate-subscribers" :| [VText "consumer-group", VText "sharded"])) [],
          KnobSpec (either (error . show) id (mkKnobName "pm.processes")) "Workers in the layout" KnobInt (VInt 2) (IntRange 2 4) []
        ],
      run = runTopology
    }

runTopology :: RunContext -> IO ScenarioReport
runTopology context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture ->
    withCheck context \check -> withSupervisor check \supervisor -> do
      let KeiroRunner runFixture = fixture.runner
          topology = knobText context.knobs (either (error . show) id (mkKnobName "pm.topology"))
          processCount = fromIntegral (knobInt context.knobs (either (error . show) id (mkKnobName "pm.processes"))) :: Int
          transferCount = 10 :: Int
          accountEvents = accountEventStream SnapNever
          source index = AccountId ("topology-source-" <> Text.pack (show index))
          destination index = AccountId ("topology-destination-" <> Text.pack (show index))
          transfer index = TransferId ("topology-transfer-" <> Text.pack (show index))
          submit account command = runFixture (runCommand defaultRunCommandOptions accountEvents (accountStream account) command)
          accepted = \case Right (Right result) -> result.eventsAppended == 1; _ -> False
          subscription = "kenshou-keiro-topologies" :: Text
      seeded <-
        traverse
          ( \index -> do
              openedSource <- submit (source index) (OpenAccount (OpenAccountData (source index) 10))
              openedDestination <- submit (destination index) (OpenAccount (OpenAccountData (destination index) 0))
              let announce = submit (source index) (AnnounceTransfer (AnnounceTransferData (source index) (transfer index)))
                  debit = submit (source index) (DebitTransfer (DebitTransferData (source index) (transfer index) (destination index) 2 4102444800))
              legs <- if even index then sequence [announce, debit] else sequence [debit, announce]
              pure (openedSource : openedDestination : legs)
          )
          [0 .. transferCount - 1]
      children <-
        traverse
          ( \index -> do
              let args = object (["subscription" .= subscription, "reportManagerReplay" .= (topology /= "sharded")] <> if topology == "consumer-group" then ["groupMember" .= index, "groupSize" .= processCount] else [])
              spec <- roleProcess check (if topology == "sharded" then "keiro/pm-sharded-worker" else "keiro/pm-worker") index args
              spawn supervisor spec
          )
          [0 .. processCount - 1]
      traverse_ (\child -> awaitReady child 10000 >> sendCommand child CtlStart) children
      acquired <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-topology-oracle")
      connection <- either (fail . show) pure acquired
      completed <- timeout 90000000 (awaitTopology connection transferCount)
      replayObserved <- if topology == "sharded" then pure True else maybe False id <$> timeout 10000000 (awaitReplay children)
      sagaRows <- Oracle.readCategoryLog connection "pm:transferSaga"
      accountRows <- Oracle.readCategoryLog connection "account"
      Connection.release connection
      if topology == "sharded" then traverse_ (killChild supervisor) children else pure ()
      let firstSagaEvents = [row.eventType | row <- sagaRows, row.streamVersion == 1]
          sagaStreams = Map.fromListWith (<>) [(row.streamName, [row.eventType]) | row <- sagaRows]
          joined = Map.size sagaStreams == transferCount && all (\types -> sort types == sort [EventType "AnnounceObserved", EventType "DebitObserved"]) (Map.elems sagaStreams)
          credits = [row | row <- accountRows, row.eventType == EventType "TransferCredited"]
          confirmations = [row | row <- accountRows, row.eventType == EventType "TransferConfirmed"]
          cells =
            [ ("source-setup", all accepted (concat seeded)),
              ("workers-distinct", length (nub (map childPid children)) == processCount),
              ("both-input-orders", EventType "AnnounceObserved" `elem` firstSagaEvents && EventType "DebitObserved" `elem` firstSagaEvents),
              ("all-sagas-joined", completed == Just True && joined),
              ("exactly-once-target-effects", length credits == transferCount && length confirmations == transferCount),
              ("logs-well-formed", Oracle.logWellFormed accountRows && Oracle.logWellFormed sagaRows)
            ]
              <> if topology == "sharded" then [] else [("manager-state-duplicate-replay", replayObserved)]
      putSummary context Measurements "topologies" (object ["topology" .= topology, "workers" .= processCount, "transfers" .= transferCount, "announceFirstFraction" .= (fromIntegral (length (filter (== EventType "AnnounceObserved") firstSagaEvents)) / fromIntegral transferCount :: Double)])
      recordCells context cells
  where
    awaitReplay children = do
      snapshots <- traverse (atomically . progress) children
      let duplicate snapshot = case Map.lookup "manager-replay" snapshot.marks of
            Just value -> parseMaybe (withObject "manager replay" (.: "stateDuplicate")) value == Just True
            Nothing -> False
      if any duplicate snapshots
        then pure True
        else threadDelay 100000 >> awaitReplay children
    awaitTopology connection transferCount = do
      sagaRows <- Oracle.readCategoryLog connection "pm:transferSaga"
      accountRows <- Oracle.readCategoryLog connection "account"
      if length sagaRows == transferCount * 2 && length [() | row <- accountRows, row.eventType == EventType "TransferCredited"] == transferCount && length [() | row <- accountRows, row.eventType == EventType "TransferConfirmed"] == transferCount
        then pure True
        else threadDelay 100000 >> awaitTopology connection transferCount

sigkillCrashWindows :: Scenario
sigkillCrashWindows =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/process-manager/concurrency/sigkill-crash-windows"),
      revision = 1,
      summary = "Kills a process-manager worker at each durable dispatch boundary and resumes it.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs =
        [ KnobSpec
            (either (error . show) id (mkKnobName "pm.kill-window"))
            "Process-manager crash window"
            KnobText
            (VText "between-manager-and-target")
            (OneOf (VText "before-manager-append" :| [VText "between-manager-and-target", VText "between-targets", VText "after-targets-before-ack"]))
            [VText "before-manager-append", VText "between-manager-and-target", VText "between-targets", VText "after-targets-before-ack"]
        ],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku, SchemaKeiro] [] False)},
      knownDefect = Nothing,
      run = runCrashWindow
    }

runCrashWindow :: RunContext -> IO ScenarioReport
runCrashWindow context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture ->
    withCheck context \check -> withSupervisor check \supervisor -> do
      let KeiroRunner runFixture = fixture.runner
          window = knobText context.knobs (either (error . show) id (mkKnobName "pm.kill-window"))
          parkAppend = case window of
            "before-manager-append" -> Just (1 :: Int)
            "between-manager-and-target" -> Just 2
            "between-targets" -> Just 3
            _ -> Nothing
          parkAck = window == "after-targets-before-ack"
          subscription = "kenshou-keiro-crash-window" :: Text
          accountEvents = accountEventStream SnapNever
          source = AccountId "crash-source"
          destination = AccountId "crash-destination"
          transfer = TransferId "crash-transfer"
          neighbourSource = AccountId "neighbour-source"
          neighbourDestination = AccountId "neighbour-destination"
          neighbourTransfer = TransferId "neighbour-transfer"
          submit account command = runFixture (runCommand defaultRunCommandOptions accountEvents (accountStream account) command)
          accepted = \case Right (Right result) -> result.eventsAppended == 1; _ -> False
      seeded <-
        sequence
          [ submit source (OpenAccount (OpenAccountData source 10)),
            submit destination (OpenAccount (OpenAccountData destination 0)),
            submit source (DebitTransfer (DebitTransferData source transfer destination 2 4102444800)),
            submit neighbourSource (OpenAccount (OpenAccountData neighbourSource 10)),
            submit neighbourDestination (OpenAccount (OpenAccountData neighbourDestination 0)),
            submit neighbourSource (DebitTransfer (DebitTransferData neighbourSource neighbourTransfer neighbourDestination 3 4102444800))
          ]
      armedSpec <- roleProcess check "keiro/pm-worker" 0 (object ["subscription" .= subscription, "parkBeforeAppend" .= parkAppend, "parkBeforeAck" .= parkAck])
      armed <- spawn supervisor armedSpec
      awaitReady armed 10000
      sendCommand armed CtlStart
      awaitMark armed "parked" 30000
      parked <- atomically (progress armed)
      acquired <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-crash-oracle")
      connection <- either (fail . show) pure acquired
      beforeSaga <- Oracle.readCategoryLog connection "pm:transferSaga"
      beforeAccounts <- Oracle.readCategoryLog connection "account"
      killChild supervisor armed
      resumedSpec <- roleProcess check "keiro/pm-worker" 1 (object ["subscription" .= subscription])
      resumed <- spawn supervisor resumedSpec
      awaitReady resumed 10000
      sendCommand resumed CtlStart
      completed <- timeout 90000000 (awaitEffects connection)
      sagaRows <- Oracle.readCategoryLog connection "pm:transferSaga"
      accountRows <- Oracle.readCategoryLog connection "account"
      Connection.release connection
      killChild supervisor resumed
      let count kind rows = length [() | row <- rows, row.eventType == EventType kind]
          expectedBefore = case window of
            "before-manager-append" -> (0, 0, 0)
            "between-manager-and-target" -> (1, 0, 0)
            "between-targets" -> (1, 1, 0)
            _ -> (1, 1, 1)
          observedBefore = (length beforeSaga, count "TransferCredited" beforeAccounts, count "TransferConfirmed" beforeAccounts)
          cells =
            [ ("source-setup", all accepted seeded),
              ("parked-at-window", Map.member "parked" parked.marks && observedBefore == expectedBefore),
              ("killed-and-restarted", childPid armed /= childPid resumed && completed == Just True),
              ("exactly-once-target-effects", length sagaRows == 2 && count "TransferCredited" accountRows == 2 && count "TransferConfirmed" accountRows == 2),
              ("neighbour-completed", length [() | row <- accountRows, row.streamName == accountStreamName neighbourDestination, row.eventType == EventType "TransferCredited"] == 1),
              ("log-is-well-formed", Oracle.logWellFormed accountRows && Oracle.logWellFormed sagaRows)
            ]
      recordCells context cells
  where
    awaitEffects connection = do
      sagaRows <- Oracle.readCategoryLog connection "pm:transferSaga"
      accountRows <- Oracle.readCategoryLog connection "account"
      if length sagaRows == 2 && length [() | row <- accountRows, row.eventType == EventType "TransferCredited"] == 2 && length [() | row <- accountRows, row.eventType == EventType "TransferConfirmed"] == 2
        then pure True
        else threadDelay 100000 >> awaitEffects connection
