module Kenshou.Suite.Keiro.Router.Concurrency (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically)
import Control.Monad (forM)
import Data.Aeson (object, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Keiro.Command (CommandResult (..), defaultRunCommandOptions, runCommand)
import Kenshou.Check.Process (ProgressSnapshot (..), awaitMark, awaitReady, childPid, killChild, progress, roleProcess, sendCommand, spawn, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobInt, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Command.Correctness (recordCells)
import Kenshou.Suite.Keiro.Fixture.Account
import Kenshou.Suite.Keiro.Fixture.Bonus
import Kenshou.Suite.Keiro.Fixture.Domain
import Kenshou.Suite.Keiro.Fixture.Oracle qualified as Oracle
import Kenshou.Suite.Keiro.Fixture.Projection (ensureFixtureReadModels)
import Kenshou.Suite.Keiro.Fixture.Runtime
import Kiroku.Store (defaultConnectionSettings)
import Kiroku.Store.Types (EventType (..))
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [sigkillMidFanout]

sigkillMidFanout :: Scenario
sigkillMidFanout =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/router/concurrency/sigkill-mid-fanout"),
      revision = 1,
      summary = "Kills a router worker after a partial fanout and checks its durable recovery.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs =
        [ KnobSpec (knobName "router.fanout") "Distinct bonus recipients" KnobInt (VInt 32) (IntRange 2 1000) [],
          KnobSpec (knobName "router.kill-after-targets") "Committed recipients before SIGKILL" KnobInt (VInt 16) (IntRange 1 999) []
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
      run = runSigkillMidFanout
    }

knobName :: Text -> KnobName
knobName = either (error . show) id . mkKnobName

runSigkillMidFanout :: RunContext -> IO ScenarioReport
runSigkillMidFanout context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture ->
    withCheck context \check -> withSupervisor check \supervisor -> do
      let KeiroRunner runFixture = fixture.runner
          fanout = fromIntegral (knobInt context.knobs (knobName "router.fanout")) :: Int
          killAfter = fromIntegral (knobInt context.knobs (knobName "router.kill-after-targets")) :: Int
          recipients = [AccountId ("crash-bonus-" <> Text.pack (show i)) | i <- [0 .. fanout - 1]]
          bonusId = BonusId "crash-bonus"
          accountEvents = accountEventStream SnapNever
          subscription = "kenshou-keiro-router-crash" :: Text
          accepted = \case Right (Right result) -> result.eventsAppended == 1; _ -> False
      if killAfter >= fanout
        then recordCells context [("valid-kill-position", False)]
        else do
          _ <- runFixture ensureFixtureReadModels >>= either (fail . show) pure
          opened <- forM recipients \account -> runFixture (runCommand defaultRunCommandOptions accountEvents (accountStream account) (OpenAccount (OpenAccountData account 0)))
          acquired <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-router-crash-oracle")
          connection <- either (fail . show) pure acquired
          _ <- forM recipients \(AccountId account) ->
            Connection.use connection (Session.statement account insertRecipient) >>= either (fail . show) pure
          declared <- runFixture (runCommand defaultRunCommandOptions bonusEventStream (bonusStream bonusId) (DeclareBonus (DeclareBonusData bonusId "all" 3)))
          armedSpec <- roleProcess check "keiro/router-worker" 0 (object ["subscription" .= subscription, "parkBeforeAppend" .= (killAfter + 1)])
          armed <- spawn supervisor armedSpec
          awaitReady armed 10000
          sendCommand armed CtlStart
          awaitMark armed "parked" 30000
          parked <- atomically (progress armed)
          beforeRows <- Oracle.readCategoryLog connection "account"
          killChild supervisor armed
          resumedSpec <- roleProcess check "keiro/router-worker" 1 (object ["subscription" .= subscription])
          resumed <- spawn supervisor resumedSpec
          awaitReady resumed 10000
          sendCommand resumed CtlStart
          completed <- timeout 90000000 (awaitCredits connection fanout)
          afterRows <- Oracle.readCategoryLog connection "account"
          Connection.release connection
          killChild supervisor resumed
          let bonusCredits rows = [row | row <- rows, row.eventType == EventType "BonusCredited"]
              cells =
                [ ("source-setup", all accepted opened && case declared of Right (Right result) -> result.eventsAppended == 1; _ -> False),
                  ("partial-fanout-before-kill", Map.member "parked" parked.marks && length (bonusCredits beforeRows) == killAfter),
                  ("killed-and-restarted", childPid armed /= childPid resumed && completed == Just True),
                  ("fanout-exactly-once", length (bonusCredits afterRows) == fanout && all (\account -> length [() | row <- bonusCredits afterRows, row.streamName == accountStreamName account] == 1) recipients),
                  ("log-is-well-formed", Oracle.logWellFormed afterRows)
                ]
          recordCells context cells
  where
    insertRecipient =
      Statement.preparable
        "INSERT INTO kenshou_keiro.account_directory (account_id, segment) VALUES ($1, 'all')"
        (Encoders.param (Encoders.nonNullable Encoders.text))
        Decoders.noResult
    awaitCredits connection count = do
      rows <- Oracle.readCategoryLog connection "account"
      if length [() | row <- rows, row.eventType == EventType "BonusCredited"] == count
        then pure True
        else threadDelay 100000 >> awaitCredits connection count
