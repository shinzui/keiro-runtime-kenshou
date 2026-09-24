module Kenshou.Suite.Keiro.Inbox.Concurrency (scenarios) where

import Control.Concurrent.STM (atomically)
import Data.Aeson (object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Hasql.Transaction qualified as Tx
import Keiro.Inbox (InboxRow (..), InboxStatus (..), listInbox)
import Keiro.Outbox (listOutbox)
import Kenshou.Check.Process (ProgressSnapshot (..), awaitMark, awaitReady, progress, roleProcess, sendCommand, spawn, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Fixture.Runtime (FixtureEnv (..), KeiroRunner (..), withFixtureEnv)
import Kenshou.Suite.Keiro.Inbox.Correctness (effectReadStatement, ensureEffectTable)
import Kenshou.Suite.Keiro.Messaging.Verdict (recordMessagingCells)
import Kenshou.Suite.Keiro.Outbox.Workload (enqueueInline, sourceName)
import Kiroku.Store (defaultConnectionSettings)
import Kiroku.Store.Transaction qualified as KirokuTransaction

scenarios :: [Scenario]
scenarios = [raceOneKey]

raceOneKey :: Scenario
raceOneKey =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/inbox/concurrency/race-one-key"),
      revision = 1,
      summary = "Races four consumer processes on one dedupe key with a slow transactional handler.",
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
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku, SchemaKeiro] [] False)},
      knownDefect = Nothing,
      run = runRaceOneKey
    }

runRaceOneKey :: RunContext -> IO ScenarioReport
runRaceOneKey context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture ->
    withCheck context \check -> withSupervisor check \supervisor -> do
      let KeiroRunner runFixture = fixture.runner
          source = sourceName context "race"
      ensureEffectTable fixture
      enqueueInline fixture source [("race-message", Just "key", 1)]
      sourceRows <- runFixture (listOutbox source) >>= either (fail . show) pure
      children <- traverse (\index -> roleProcess check "keiro/inbox-consumer" index (object ["source" .= source, "messageId" .= ("race-message" :: Text)]) >>= spawn supervisor) [0 .. 3 :: Int]
      mapM_ (\child -> awaitReady child 10000) children
      mapM_ (\child -> sendCommand child CtlStart) children
      mapM_ (\child -> awaitMark child "finished" 30000) children
      classifications <-
        traverse
          ( \child -> do
              snapshot <- atomically (progress child)
              pure $ Map.lookup "finished" snapshot.marks >>= (\value -> parseMaybe (withObject "finished" (.: "classification")) value :: Maybe Text)
          )
          children
      rows <- runFixture (listInbox source) >>= either (fail . show) pure
      effects <- runFixture (KirokuTransaction.runTransaction (Tx.statement () effectReadStatement)) >>= either (fail . show) pure
      let cells =
            [ ("schedule-realised", length sourceRows == 1 && length classifications == 4),
              ("one-effect", effects == ["race-message"] && case rows of [row] -> row.status == InboxCompleted; _ -> False),
              ("one-winner", length (filter (== Just "processed") classifications) == 1 && length (filter (== Just "duplicate") classifications) == 3),
              ("no-in-progress", Just "in-progress" `notElem` classifications)
            ]
      recordMessagingCells context (Map.fromList [("consumers", 4), ("effects", fromIntegral (length effects))]) (object ["classifications" .= classifications]) cells
