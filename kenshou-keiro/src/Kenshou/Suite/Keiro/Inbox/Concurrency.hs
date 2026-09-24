module Kenshou.Suite.Keiro.Inbox.Concurrency (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (wait, withAsync)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically)
import Data.Aeson (object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Data.UUID qualified as UUID
import Data.Vector qualified as Vector
import Hasql.Transaction qualified as Tx
import Keiro.Command (defaultRunCommandOptions)
import Keiro.Inbox (InboxDedupePolicy (..), InboxResult (..), InboxRow (..), InboxStatus (..), dedupeKeyFor, garbageCollectCompleted, listInbox, runInboxTransaction)
import Keiro.Inbox.Delegated (delegatedEventId)
import Keiro.Integration.Event (IntegrationEvent (..))
import Keiro.Outbox (OutboxRow (..), listOutbox)
import Kenshou.Check.Fault (Fault (..))
import Kenshou.Check.Fault.Network (armQueryBarrier, proxiedConnectionString, queryBarrierReached, releaseQueryBarrier, withTcpProxy)
import Kenshou.Check.Fault.Postgres (Backend (..), BackendSelector (..), listBackends, terminateOneBackend)
import Kenshou.Check.Process (ProgressSnapshot (..), awaitMark, awaitReady, killChild, progress, roleProcess, sendCommand, spawn, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Check.Verdict (InvariantClass (..))
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobText, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Core.Scenario (CohortScope (..), KnownDefect (..), Placement (..), Scenario (..), ScenarioReport, Tier (..), inconclusiveBecause)
import Kenshou.Suite.Keiro.Fixture.Account (AccountSnapshotPolicy (..), accountEventStream, accountStreamName)
import Kenshou.Suite.Keiro.Fixture.Domain (AccountCommand (..), AccountId (..), OpenAccountData (..))
import Kenshou.Suite.Keiro.Fixture.Runtime (CommandRunner (..), FixtureEnv (..), KeiroRunner (..), SubmitOutcome (..), submitAccountCommand, withFixtureEnv)
import Kenshou.Suite.Keiro.Inbox.Correctness (effectInsertStatement, effectReadStatement, ensureEffectTable)
import Kenshou.Suite.Keiro.Messaging.Verdict (recordMessagingCells, recordMessagingCellsClassified)
import Kenshou.Suite.Keiro.Outbox.Workload (enqueueInline, sourceName)
import Kiroku.Store (defaultConnectionSettings)
import Kiroku.Store.Read (readStreamForward)
import Kiroku.Store.Transaction qualified as KirokuTransaction
import Kiroku.Store.Types (EventId (..), RecordedEvent (..), StreamVersion (..))
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [raceOneKey, gcVsInsertRace]

gcVsInsertRace :: Scenario
gcVsInsertRace =
  raceOneKey
    { id = either (error . show) id (parseScenarioId "keiro/inbox/concurrency/gc-vs-insert-race"),
      summary = "Races completed-row garbage collection with a conflicting inbox insert and lookup.",
      knobs = [],
      knownDefect = Just (KnownDefect "mori://shinzui/keiro/okf/user-documentation/concepts/DOC-10" "Garbage collection can remove a completed receipt between conflicting insert and lookup" ["effectively-once"] AllCohorts),
      run = runGcVsInsertRace
    }

runGcVsInsertRace :: RunContext -> IO ScenarioReport
runGcVsInsertRace context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let KeiroRunner runFixture = fixture.runner
        source = sourceName context "gc-race"
        postgres = requirePostgres context
        endpoint = maybe (error "PostgreSQL TCP endpoint unavailable") (\(host, port) -> pure (Text.unpack host, fromIntegral port)) postgres.tcpEndpoint
        handler event = Tx.statement event.messageId effectInsertStatement
    ensureEffectTable fixture
    enqueueInline fixture source [("raced", Just "key", 1)]
    sourceRows <- runFixture (listOutbox source) >>= either (fail . show) pure
    event <- case sourceRows of
      [row] -> pure row.event
      _ -> fail "GC race fixture did not contain exactly one event"
    first <- runFixture (runInboxTransaction Nothing PreferIntegrationMessageId event Nothing handler) >>= either (fail . show) pure
    seedRows <- runFixture (listInbox source) >>= either (fail . show) pure
    seedBackends <- listBackends postgres
    withTcpProxy endpoint \proxy -> do
      ready <- newEmptyMVar
      start <- newEmptyMVar
      let connection = proxiedConnectionString postgres proxy <> " application_name=kenshou_inbox_gc_race"
      withAsync
        ( withFixtureEnv (defaultConnectionSettings connection) \proxyFixture -> do
            let KeiroRunner runProxy = proxyFixture.runner
            _ <- runProxy (listOutbox source) >>= either (fail . show) pure
            putMVar ready ()
            takeMVar start
            runProxy (runInboxTransaction Nothing PreferIntegrationMessageId event Nothing handler)
        )
        \consumer -> do
          prepared <- maybe False (const True) <$> timeout 15000000 (takeMVar ready)
          barrier <- armQueryBarrier proxy "WHERE source = $1 AND dedupe_key = $2"
          if prepared then putMVar start () else pure ()
          observed <- if prepared then maybe False (const True) <$> timeout 15000000 (queryBarrierReached barrier) else pure False
          beforeGcRows <- runFixture (listInbox source) >>= either (fail . show) pure
          deleted <-
            if observed
              then do
                now <- getCurrentTime
                removed <- runFixture (garbageCollectCompleted 0 now) >>= either (fail . show) pure
                pure removed
              else pure 0
          releaseQueryBarrier proxy barrier
          second <- wait consumer >>= either (fail . show) pure
          rows <- runFixture (listInbox source) >>= either (fail . show) pure
          effects <- runFixture (KirokuTransaction.runTransaction (Tx.statement () effectReadStatement)) >>= either (fail . show) pure
          let reprocessObserved = first == Right (InboxProcessed ()) && observed && deleted == 1 && second == Right (InboxProcessed ()) && length effects == 2
              schedule = first == Right (InboxProcessed ()) && observed && deleted == 1 && second == Right (InboxProcessed ()) && null rows
              cells =
                [ ("schedule-realised", Contract, schedule),
                  ("gc-reprocess-observed", Implementation, reprocessObserved),
                  ("effectively-once", Implementation, length effects == 1),
                  ("at-least-once", Contract, not (null effects))
                ]
          report <- recordMessagingCellsClassified context (Map.fromList [("effects", fromIntegral (length effects)), ("deleted", fromIntegral deleted), ("rows", fromIntegral (length rows))]) (object ["observedInsert" .= observed, "first" .= show first, "second" .= show second, "seedRows" .= map (\row -> (row.dedupeKey, show row.receivedAt)) seedRows, "beforeGcRows" .= map (\row -> (row.dedupeKey, show row.receivedAt)) beforeGcRows, "afterRows" .= map (\row -> (row.dedupeKey, show row.receivedAt)) rows, "seedMatchingBackends" .= length [backend | backend <- seedBackends, backend.applicationName == "kenshou_inbox_gc_race"]]) cells
          pure (if schedule then report else inconclusiveBecause "the inbox insert/GC interleaving was not observed")

raceOneKey :: Scenario
raceOneKey =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/inbox/concurrency/race-one-key"),
      revision = 1,
      summary = "Races four consumer processes on one dedupe key with table or delegated idempotence.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs =
        [ KnobSpec (knobName "inbox.kill-winner") "Interrupt the first handler inside its SQL transaction" KnobText (VText "none") (OneOf (VText "none" :| [VText "sigkill", VText "backend-kill"])) [VText "sigkill", VText "backend-kill"],
          KnobSpec (knobName "inbox.idempotence") "Receipt owner for concurrent intake" KnobText (VText "inbox-table") (OneOf (VText "inbox-table" :| [VText "delegated"])) [VText "delegated"]
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
      run = runRaceOneKey
    }

knobName :: Text -> KnobName
knobName = either (error . show) id . mkKnobName

runRaceOneKey :: RunContext -> IO ScenarioReport
runRaceOneKey context
  | knobText context.knobs (knobName "inbox.idempotence") == "delegated" = runDelegatedRace context
runRaceOneKey context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture ->
    withCheck context \check -> withSupervisor check \supervisor -> do
      let KeiroRunner runFixture = fixture.runner
          source = sourceName context "race"
          faultMode = knobText context.knobs (knobName "inbox.kill-winner")
          killWinner = faultMode /= "none"
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
      if faultMode == "sigkill" then killChild supervisor firstChild else pure ()
      case entered of
        Just pid -> do
          _ <- (terminateOneBackend postgres (ByPid pid)).inject
          pure ()
        Nothing -> pure ()
      if faultMode == "backend-kill" then awaitMark firstChild "finished" 30000 else pure ()
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
      firstClassification <-
        if faultMode == "backend-kill"
          then do
            snapshot <- atomically (progress firstChild)
            pure $ Map.lookup "finished" snapshot.marks >>= (\value -> parseMaybe (withObject "finished" (.: "classification")) value :: Maybe Text)
          else pure Nothing
      restartedClassification <-
        if killWinner
          then do
            spec <- roleProcess check "keiro/inbox-consumer" 4 (object ["source" .= source, "messageId" .= ("race-message" :: Text), "parkInHandler" .= False])
            restarted <- spawn supervisor spec
            awaitReady restarted 10000
            sendCommand restarted CtlStart
            awaitMark restarted "finished" 30000
            snapshot <- atomically (progress restarted)
            pure $ Map.lookup "finished" snapshot.marks >>= (\value -> parseMaybe (withObject "finished" (.: "classification")) value :: Maybe Text)
          else pure Nothing
      rows <- runFixture (listInbox source) >>= either (fail . show) pure
      effects <- runFixture (KirokuTransaction.runTransaction (Tx.statement () effectReadStatement)) >>= either (fail . show) pure
      let cells =
            [ ("schedule-realised", length sourceRows == 1 && (not killWinner || entered /= Nothing) && null preKillEffects && null prePeerRows),
              ("one-effect", effects == ["race-message"] && case rows of [row] -> row.status == InboxCompleted; _ -> False),
              ("one-winner", length (filter (== Just "processed") classifications) == 1 && length (filter (== Just "duplicate") classifications) == if killWinner then 2 else 3),
              ("no-in-progress", Just "in-progress" `notElem` classifications),
              ("backend-interruption-visible", faultMode /= "backend-kill" || maybe False (Text.isPrefixOf "unexpected:") firstClassification),
              ("restarted-delivery-duplicate", not killWinner || restartedClassification == Just "duplicate")
            ]
      recordMessagingCells context (Map.fromList [("consumers", 4), ("effects", fromIntegral (length effects)), ("killed", if killWinner then 1 else 0)]) (object ["classifications" .= classifications, "firstClassification" .= firstClassification, "restartedClassification" .= restartedClassification, "faultMode" .= faultMode]) cells

runDelegatedRace :: RunContext -> IO ScenarioReport
runDelegatedRace context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture ->
    withCheck context \check -> withSupervisor check \supervisor -> do
      let KeiroRunner runFixture = fixture.runner
          source = sourceName context "delegated-race"
          target = AccountId (source <> "-account")
          targetName = accountStreamName target
          openingId = EventId (UUID.fromWords 0 2 0 1)
          faultMode = knobText context.knobs (knobName "inbox.kill-winner")
      seeded <- submitAccountCommand fixture (accountEventStream SnapNever) RunnerPlain defaultRunCommandOptions 0 openingId (OpenAccount (OpenAccountData target 0))
      enqueueInline fixture source [("race-message", Just "key", 1)]
      sourceRows <- runFixture (listOutbox source) >>= either (fail . show) pure
      event <- case sourceRows of
        [row] -> pure row.event
        _ -> fail "delegated race fixture did not contain exactly one event"
      dedupe <- either (fail . show) pure (dedupeKeyFor PreferIntegrationMessageId event Nothing)
      let receipt = delegatedEventId "kenshou-consumer" source dedupe targetName "deposit"
      let roleArgs park = object ["source" .= source, "messageId" .= ("race-message" :: Text), "delegated" .= True, "target" .= (source <> "-account"), "parkInHandler" .= park]
      children <- traverse (\index -> roleProcess check "keiro/inbox-consumer" index (roleArgs (faultMode /= "none" && index == 0)) >>= spawn supervisor) [0 .. 3 :: Int]
      (firstChild, otherChildren) <- case children of
        first : rest -> pure (first, rest)
        [] -> fail "delegated race has no consumers"
      mapM_ (\child -> awaitReady child 10000) children
      let postgres = requirePostgres context
          waitEntered = do
            backends <- listBackends postgres
            case [backend | backend <- backends, "inbox-consumer-0" `Text.isInfixOf` backend.applicationName, "pg_sleep(30)" `Text.isInfixOf` backend.query, backend.state == "active"] of
              backend : _ -> pure (Just backend.pid)
              [] -> threadDelay 10000 >> waitEntered
      entered <-
        if faultMode == "none"
          then pure Nothing
          else do
            sendCommand firstChild CtlStart
            maybe Nothing id <$> timeout 10000000 waitEntered
      preKillRows <- if faultMode == "none" then pure [] else runFixture (listInbox source) >>= either (fail . show) pure
      preKillEvents <- if faultMode == "none" then pure Vector.empty else runFixture (readStreamForward targetName (StreamVersion 0) 10) >>= either (fail . show) pure
      if faultMode == "sigkill" then killChild supervisor firstChild else pure ()
      case entered of
        Just pid -> do
          _ <- (terminateOneBackend postgres (ByPid pid)).inject
          pure ()
        Nothing -> pure ()
      if faultMode == "backend-kill" then awaitMark firstChild "finished" 30000 else pure ()
      let liveChildren = if faultMode == "none" then children else otherChildren
      mapM_ (\child -> sendCommand child CtlStart) liveChildren
      mapM_ (\child -> awaitMark child "finished" 30000) liveChildren
      classifications <-
        traverse
          ( \child -> do
              snapshot <- atomically (progress child)
              pure $ Map.lookup "finished" snapshot.marks >>= (\value -> parseMaybe (withObject "finished" (.: "classification")) value :: Maybe Text)
          )
          liveChildren
      firstClassification <-
        if faultMode == "backend-kill"
          then do
            snapshot <- atomically (progress firstChild)
            pure $ Map.lookup "finished" snapshot.marks >>= (\value -> parseMaybe (withObject "finished" (.: "classification")) value :: Maybe Text)
          else pure Nothing
      restartedClassification <-
        if faultMode == "none"
          then pure Nothing
          else do
            spec <- roleProcess check "keiro/inbox-consumer" 4 (roleArgs False)
            restarted <- spawn supervisor spec
            awaitReady restarted 10000
            sendCommand restarted CtlStart
            awaitMark restarted "finished" 30000
            snapshot <- atomically (progress restarted)
            pure $ Map.lookup "finished" snapshot.marks >>= (\value -> parseMaybe (withObject "finished" (.: "classification")) value :: Maybe Text)
      rows <- runFixture (listInbox source) >>= either (fail . show) pure
      recorded <- runFixture (readStreamForward targetName (StreamVersion 0) 10) >>= either (fail . show) pure
      let markers = map (.eventId) (Vector.toList recorded)
          cells =
            [ ("schedule-realised", length sourceRows == 1 && seeded == SubmitAppended (StreamVersion 1) && (faultMode == "none" || entered /= Nothing && null preKillRows && map (.eventId) (Vector.toList preKillEvents) == [openingId])),
              ("one-winner", length (filter (== Just "processed") classifications) == 1 && length (filter (== Just "duplicate") classifications) == if faultMode == "none" then 3 else 2),
              ("one-effect", markers == [openingId, receipt]),
              ("delegated-no-inbox-rows", null rows),
              ("backend-interruption-visible", faultMode /= "backend-kill" || firstClassification == Just "unexpected"),
              ("restarted-delivery-duplicate", faultMode == "none" || restartedClassification == Just "duplicate")
            ]
      recordMessagingCells context (Map.fromList [("consumers", 4), ("effects", fromIntegral (length markers - 1)), ("killed", if faultMode == "none" then 0 else 1)]) (object ["classifications" .= classifications, "markers" .= map show markers, "receipt" .= show receipt, "faultMode" .= faultMode, "firstClassification" .= firstClassification, "restartedClassification" .= restartedClassification]) cells
