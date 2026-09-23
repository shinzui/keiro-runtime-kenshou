module Kenshou.Suite.Keiro.ProcessManager.Concurrency (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically)
import Data.Aeson (object, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Keiro.Command (CommandResult (..), defaultRunCommandOptions, runCommand)
import Kenshou.Check.Process (ProgressSnapshot (..), awaitMark, awaitReady, childPid, killChild, progress, roleProcess, sendCommand, spawn, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobText, mkKnobName)
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
scenarios = [sigkillCrashWindows]

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
