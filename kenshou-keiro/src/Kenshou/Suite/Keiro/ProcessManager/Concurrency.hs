module Kenshou.Suite.Keiro.ProcessManager.Concurrency (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically)
import Data.Aeson (object, (.=))
import Data.Foldable (traverse_)
import Data.List (nub, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Keiro.Command (CommandResult (..), defaultRunCommandOptions, runCommand)
import Kenshou.Check.Process (ProgressSnapshot (..), awaitMark, awaitReady, childPid, killChild, progress, roleProcess, sendCommand, spawn, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobInt, knobText, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Command.Correctness (recordCells)
import Kenshou.Suite.Keiro.Fixture.Account
import Kenshou.Suite.Keiro.Fixture.Domain
import Kenshou.Suite.Keiro.Fixture.Oracle qualified as Oracle
import Kenshou.Suite.Keiro.Fixture.Runtime
import Kiroku.Store (defaultConnectionSettings)
import Kiroku.Store.Types (EventType (..))
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [sigkillCrashWindows, topologies]

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
              let args = object (["subscription" .= subscription] <> if topology == "consumer-group" then ["groupMember" .= index, "groupSize" .= processCount] else [])
              spec <- roleProcess check (if topology == "sharded" then "keiro/pm-sharded-worker" else "keiro/pm-worker") index args
              spawn supervisor spec
          )
          [0 .. processCount - 1]
      traverse_ (\child -> awaitReady child 10000 >> sendCommand child CtlStart) children
      acquired <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-topology-oracle")
      connection <- either (fail . show) pure acquired
      completed <- timeout 90000000 (awaitTopology connection transferCount)
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
      putSummary context Measurements "topologies" (object ["topology" .= topology, "workers" .= processCount, "transfers" .= transferCount, "announceFirstFraction" .= (fromIntegral (length (filter (== EventType "AnnounceObserved") firstSagaEvents)) / fromIntegral transferCount :: Double)])
      recordCells context cells
  where
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
