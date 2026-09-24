module Kenshou.Suite.Keiro.Inbox.Concurrency (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically)
import Data.Aeson (object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Hasql.Transaction qualified as Tx
import Keiro.Inbox (InboxRow (..), InboxStatus (..), listInbox)
import Keiro.Outbox (listOutbox)
import Kenshou.Check.Fault (Fault (..))
import Kenshou.Check.Fault.Postgres (Backend (..), BackendSelector (..), listBackends, terminateOneBackend)
import Kenshou.Check.Process (ProgressSnapshot (..), awaitMark, awaitReady, killChild, progress, roleProcess, sendCommand, spawn, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobText, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Fixture.Runtime (FixtureEnv (..), KeiroRunner (..), withFixtureEnv)
import Kenshou.Suite.Keiro.Inbox.Correctness (effectReadStatement, ensureEffectTable)
import Kenshou.Suite.Keiro.Messaging.Verdict (recordMessagingCells)
import Kenshou.Suite.Keiro.Outbox.Workload (enqueueInline, sourceName)
import Kiroku.Store (defaultConnectionSettings)
import Kiroku.Store.Transaction qualified as KirokuTransaction
import System.Timeout (timeout)

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
      knobs = [KnobSpec (knobName "inbox.kill-winner") "Kill the first handler inside its SQL transaction" KnobText (VText "none") (OneOf (VText "none" :| [VText "sigkill"])) [VText "sigkill"]],
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

knobName :: Text -> KnobName
knobName = either (error . show) id . mkKnobName

runRaceOneKey :: RunContext -> IO ScenarioReport
runRaceOneKey context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture ->
    withCheck context \check -> withSupervisor check \supervisor -> do
      let KeiroRunner runFixture = fixture.runner
          source = sourceName context "race"
          killWinner = knobText context.knobs (knobName "inbox.kill-winner") == "sigkill"
      ensureEffectTable fixture
      enqueueInline fixture source [("race-message", Just "key", 1)]
      sourceRows <- runFixture (listOutbox source) >>= either (fail . show) pure
      children <- traverse (\index -> roleProcess check "keiro/inbox-consumer" index (object ["source" .= source, "messageId" .= ("race-message" :: Text), "parkInHandler" .= (killWinner && index == 0)]) >>= spawn supervisor) [0 .. 3 :: Int]
      (firstChild, otherChildren) <- case children of
        first : rest -> pure (first, rest)
        [] -> fail "inbox race has no consumers"
      mapM_ (\child -> awaitReady child 10000) children
      let postgres = requirePostgres context
          waitEntered = do
            backends <- listBackends postgres
            case [backend | backend <- backends, "inbox-consumer-0" `Text.isInfixOf` backend.applicationName, "pg_sleep(30)" `Text.isInfixOf` backend.query, backend.state == "active"] of
              backend : _ -> pure (Just backend.pid)
              [] -> threadDelay 10000 >> waitEntered
      entered <-
        if killWinner
          then do
            sendCommand firstChild CtlStart
            maybe Nothing id <$> timeout 10000000 waitEntered
          else pure Nothing
      preKillEffects <- if killWinner then runFixture (KirokuTransaction.runTransaction (Tx.statement () effectReadStatement)) >>= either (fail . show) pure else pure []
      if killWinner then killChild supervisor firstChild else pure ()
      case entered of
        Just pid -> do
          _ <- (terminateOneBackend postgres (ByPid pid)).inject
          pure ()
        Nothing -> pure ()
      prePeerRows <- if killWinner then runFixture (listInbox source) >>= either (fail . show) pure else pure []
      let liveChildren = if killWinner then otherChildren else children
      mapM_ (\child -> sendCommand child CtlStart) liveChildren
      mapM_ (\child -> awaitMark child "finished" 30000) liveChildren
      classifications <-
        traverse
          ( \child -> do
              snapshot <- atomically (progress child)
              pure $ Map.lookup "finished" snapshot.marks >>= (\value -> parseMaybe (withObject "finished" (.: "classification")) value :: Maybe Text)
          )
          liveChildren
      rows <- runFixture (listInbox source) >>= either (fail . show) pure
      effects <- runFixture (KirokuTransaction.runTransaction (Tx.statement () effectReadStatement)) >>= either (fail . show) pure
      let cells =
            [ ("schedule-realised", length sourceRows == 1 && (not killWinner || entered /= Nothing) && null preKillEffects && null prePeerRows),
              ("one-effect", effects == ["race-message"] && case rows of [row] -> row.status == InboxCompleted; _ -> False),
              ("one-winner", length (filter (== Just "processed") classifications) == 1 && length (filter (== Just "duplicate") classifications) == if killWinner then 2 else 3),
              ("no-in-progress", Just "in-progress" `notElem` classifications)
            ]
      recordMessagingCells context (Map.fromList [("consumers", 4), ("effects", fromIntegral (length effects)), ("killed", if killWinner then 1 else 0)]) (object ["classifications" .= classifications]) cells
