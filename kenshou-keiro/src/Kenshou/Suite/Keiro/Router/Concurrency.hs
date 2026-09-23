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
import Kiroku.Store.Types (EventType (..), StreamName (..))
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [sigkillMidFanout, deadLetterIdentityUnderReorderedRedelivery]

deadLetterIdentityUnderReorderedRedelivery :: Scenario
deadLetterIdentityUnderReorderedRedelivery =
  sigkillMidFanout
    { id = either (error . show) id (parseScenarioId "keiro/router/correctness/dead-letter-identity-under-reordered-redelivery"),
      summary = "Checks rejected router targets retain their own dead letters after reordered redelivery.",
      tier = TierSmoke,
      knobs = [],
      run = runDeadLetterIdentity
    }

runDeadLetterIdentity :: RunContext -> IO ScenarioReport
runDeadLetterIdentity context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture ->
    withCheck context \check -> withSupervisor check \supervisor -> do
      let KeiroRunner runFixture = fixture.runner
          accountEvents = accountEventStream SnapNever
          recipients = [AccountId "dead-identity-a", AccountId "dead-identity-b"]
          bonusId = BonusId "dead-identity"
          subscription = "kenshou-keiro-dead-identity" :: Text
          accepted = \case Right (Right result) -> result.eventsAppended == 1; _ -> False
      _ <- runFixture ensureFixtureReadModels >>= either (fail . show) pure
      opened <- forM recipients \account -> runFixture (runCommand defaultRunCommandOptions accountEvents (accountStream account) (OpenAccount (OpenAccountData account 0)))
      closed <- forM recipients \account -> runFixture (runCommand defaultRunCommandOptions accountEvents (accountStream account) (CloseAccount (CloseAccountData account)))
      acquired <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-dead-identity-oracle")
      connection <- either (fail . show) pure acquired
      _ <- forM recipients \(AccountId account) ->
        Connection.use connection (Session.statement account directoryInsert) >>= either (fail . show) pure
      declared <- runFixture (runCommand defaultRunCommandOptions bonusEventStream (bonusStream bonusId) (DeclareBonus (DeclareBonusData bonusId "all" 3)))
      firstSpec <- roleProcess check "keiro/router-worker" 0 (object ["subscription" .= subscription, "parkBeforeAck" .= True, "rejectedDeadLetter" .= True])
      first <- spawn supervisor firstSpec
      awaitReady first 10000
      sendCommand first CtlStart
      awaitMark first "parked" 30000
      firstLetters <- Oracle.readDispatchDeadLetters connection
      killChild supervisor first
      secondSpec <- roleProcess check "keiro/router-worker" 1 (object ["subscription" .= subscription, "reverseRecipients" .= True, "rejectedDeadLetter" .= True, "reportAcks" .= True])
      second <- spawn supervisor secondSpec
      awaitReady second 10000
      sendCommand second CtlStart
      awaitMark second "acknowledged" 30000
      acknowledged <- atomically (progress second)
      secondLetters <- Oracle.readDispatchDeadLetters connection
      accountRows <- Oracle.readCategoryLog connection "account"
      Connection.release connection
      killChild supervisor second
      let targetNames = map accountStreamName recipients
          lettersWellFormed letters =
            length letters == 2
              && all (\(StreamName target) -> length [() | letter <- letters, letter.targetStreamName == target] == 1) targetNames
              && all (\letter -> letter.dispatcherKind == "router" && letter.dispatcherName == bonusRouterName && letter.errorClass == "command_rejected") letters
          cells =
            [ ("source-setup", all accepted opened && all accepted closed && case declared of Right (Right result) -> result.eventsAppended == 1; _ -> False),
              ("two-dead-letters-before-kill", lettersWellFormed firstLetters),
              ("redelivery-acknowledged", Map.member "acknowledged" acknowledged.marks && childPid first /= childPid second),
              ("one-dead-letter-per-target", lettersWellFormed secondLetters),
              ("no-credits-to-closed-targets", null [() | row <- accountRows, row.eventType == EventType "BonusCredited"])
            ]
      recordCells context cells

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
            Connection.use connection (Session.statement account directoryInsert) >>= either (fail . show) pure
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
    awaitCredits connection count = do
      rows <- Oracle.readCategoryLog connection "account"
      if length [() | row <- rows, row.eventType == EventType "BonusCredited"] == count
        then pure True
        else threadDelay 100000 >> awaitCredits connection count

directoryInsert :: Statement.Statement Text ()
directoryInsert =
  Statement.preparable
    "INSERT INTO kenshou_keiro.account_directory (account_id, segment) VALUES ($1, 'all')"
    (Encoders.param (Encoders.nonNullable Encoders.text))
    Decoders.noResult
