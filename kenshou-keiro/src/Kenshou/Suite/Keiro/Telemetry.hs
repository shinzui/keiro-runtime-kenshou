module Kenshou.Suite.Keiro.Telemetry (scenarios) where

import Data.Aeson (object, (.=))
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List (nub)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Vector qualified as Vector
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Keiro.Command (CommandError (..), CommandResult (..), RunCommandOptions (..), commandErrorClass, defaultRunCommandOptions, runCommand)
import Keiro.ProcessManager (PoisonPolicy (..), RejectedCommandPolicy (..))
import Keiro.ProcessManager qualified as ProcessManager
import Keiro.Router (runRouterWorkerWith)
import Keiro.Stream qualified as Stream
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId, unSeed)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith)
import Kenshou.Suite.Keiro.Command.Correctness (recordCells)
import Kenshou.Suite.Keiro.Fixture.Account
import Kenshou.Suite.Keiro.Fixture.Bonus
import Kenshou.Suite.Keiro.Fixture.Bridge (AckRecord (..), listAdapter)
import Kenshou.Suite.Keiro.Fixture.Domain
import Kenshou.Suite.Keiro.Fixture.Oracle qualified as Oracle
import Kenshou.Suite.Keiro.Fixture.Projection (ensureFixtureReadModels)
import Kenshou.Suite.Keiro.Fixture.Runtime
import Kenshou.Suite.Keiro.Fixture.Workload qualified as Workload
import Kenshou.Telemetry (TelemetryHandles (..), telemetryKnobs, telemetrySpecFromContext, withTelemetry)
import Kenshou.Telemetry.Tracing.Probe (SpanView (..), readSpans)
import Kiroku.Store (defaultConnectionSettings)
import Kiroku.Store.Error (StoreError (..))
import Kiroku.Store.Read (readStreamForward)
import Kiroku.Store.Types (StreamName (..), StreamVersion (..))
import OpenTelemetry.Attributes (Attribute (..), PrimitiveAttribute (..), lookupAttribute)
import Shibuya.Core.Ack (AckDecision (..))

scenarios :: [Scenario]
scenarios = [writeSideSignals]

writeSideSignals :: Scenario
writeSideSignals =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/telemetry/correctness/write-side-signals"),
      revision = 1,
      summary = "Checks command spans and duplicate metrics against the durable account log.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = telemetryKnobs,
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| [TracingSdkInMemory]) TracingSdkInMemory),
            metrics = Supported (Support (MetricsOff :| [MetricsCollect]) MetricsCollect),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku, SchemaKeiro] [] False)},
      knownDefect = Nothing,
      run = runWriteSideSignals
    }

runWriteSideSignals :: RunContext -> IO ScenarioReport
runWriteSideSignals context = case telemetrySpecFromContext context of
  Left reason -> pure (failedWith ["invalid-telemetry-config"] reason)
  Right spec -> withTelemetry spec \telemetry -> do
    runtimeTelemetry <- keiroTelemetry telemetry
    withFixtureTelemetryEnv (defaultConnectionSettings (requirePostgres context).connectionString) runtimeTelemetry \fixture -> do
      let KeiroRunner runFixture = fixture.runner
          account = AccountId "telemetry-account"
          target = accountStream account
          accountEvents = accountEventStream SnapNever
          depositId = Workload.opEventId (unSeed context.seed) (Workload.Op 0 0 (Workload.ActDeposit account 2)) 0
      _ <- runFixture ensureFixtureReadModels >>= either (fail . show) pure
      let options = keiroCommandOptions runtimeTelemetry
          depositOptions = options {eventIds = [depositId]}
      opened <- runFixture (runCommand options accountEvents target (OpenAccount (OpenAccountData account 10)))
      deposited <- runFixture (runCommand depositOptions accountEvents target (Deposit (DepositData account 2 "telemetry")))
      duplicate <- runFixture (runCommand depositOptions accountEvents target (Deposit (DepositData account 2 "telemetry")))
      injected <- newIORef False
      let hook = do
            first <- atomicModifyIORef' injected (\seen -> (True, not seen))
            if first
              then do
                _ <- runFixture (runCommand defaultRunCommandOptions accountEvents target (Deposit (DepositData account 1 "foreign")))
                pure ()
              else pure ()
      conflicted <- runFixture (runCommand options {beforeAppend = hook} accountEvents target (Deposit (DepositData account 3 "conflict")))
      let snapshotAccount = AccountId "telemetry-snapshot"
          snapshotEvents = accountEventStream (SnapEvery 1)
      snapshotOpen <- runFixture (runCommand options snapshotEvents (accountStream snapshotAccount) (OpenAccount (OpenAccountData snapshotAccount 0)))
      snapshotDeposit <- runFixture (runCommand options snapshotEvents (accountStream snapshotAccount) (Deposit (DepositData snapshotAccount 1 "snapshot")))
      let closedAccount = AccountId "telemetry-closed"
          closedTarget = accountStream closedAccount
          bonus = BonusId "telemetry-bonus"
          repeatedBonus = BonusId "telemetry-repeat-bonus"
      closedOpen <- runFixture (runCommand defaultRunCommandOptions accountEvents closedTarget (OpenAccount (OpenAccountData closedAccount 0)))
      closedClose <- runFixture (runCommand defaultRunCommandOptions accountEvents closedTarget (CloseAccount (CloseAccountData closedAccount)))
      bonusDeclared <- runFixture (runCommand defaultRunCommandOptions bonusEventStream (bonusStream bonus) (DeclareBonus (DeclareBonusData bonus "all" 1)))
      repeatedDeclared <- runFixture (runCommand defaultRunCommandOptions bonusEventStream (bonusStream repeatedBonus) (DeclareBonus (DeclareBonusData repeatedBonus "all" 1)))
      poisonBatch <- runFixture (readStreamForward (accountStreamName closedAccount) (StreamVersion 0) 1)
      bonusBatch <- runFixture (readStreamForward (Stream.streamName (bonusStream bonus)) (StreamVersion 0) 1)
      repeatedBatch <- runFixture (readStreamForward (Stream.streamName (bonusStream repeatedBonus)) (StreamVersion 0) 1)
      ackLog <- newIORef []
      dispatch <- case (poisonBatch, bonusBatch) of
        (Right poisonEvents, Right bonusEvents) -> case (Vector.toList poisonEvents, Vector.toList bonusEvents) of
          ([poison], [source]) -> do
            let router = bonusRouterWith bonusRouterName accountEvents (\_ -> pure [closedAccount])
                routerOptions = (keiroWorkerOptions runtimeTelemetry) {ProcessManager.poisonPolicy = PoisonSkip (const (pure ())), ProcessManager.rejectedCommandPolicy = RejectedDeadLetter}
                adapter = listAdapter "telemetry-router" ackLog [(poison, Nothing), (source, Nothing)]
            Just <$> runFixture (runRouterWorkerWith routerOptions defaultRunCommandOptions router adapter decodeBonusDeclared)
          _ -> pure Nothing
        _ -> pure Nothing
      duplicateAckLog <- newIORef []
      repeatedDispatch <- case repeatedBatch of
        Right events -> case Vector.toList events of
          [source] -> do
            let router = bonusRouterWith bonusRouterName accountEvents (\_ -> pure [account])
                routerOptions = keiroWorkerOptions runtimeTelemetry
                adapter = listAdapter "telemetry-router-repeat" duplicateAckLog [(source, Nothing), (source, Just 1)]
            Just <$> runFixture (runRouterWorkerWith routerOptions defaultRunCommandOptions router adapter decodeBonusDeclared)
          _ -> pure Nothing
        _ -> pure Nothing
      _ <- telemetry.flushTelemetry
      exportedSpans <- maybe (pure []) readSpans telemetry.spans
      metricSums <- telemetry.readMetricSums
      acquired <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-telemetry-oracle")
      connection <- either (fail . show) pure acquired
      rows <- Oracle.readCategoryLog connection "account"
      letters <- Oracle.readDispatchDeadLetters connection
      Connection.release connection
      acks <- readIORef ackLog
      duplicateAcks <- readIORef duplicateAckLog
      let oneAppend = \case Right (Right result) -> result.eventsAppended == 1; _ -> False
          isDuplicate = case duplicate of Right (Left (StoreFailed (DuplicateEvent _))) -> True; _ -> False
          hasText spanValue key expected = lookupAttribute spanValue.attributes key == Just (AttributeValue (TextAttribute expected))
          hasInt spanValue key expected = lookupAttribute spanValue.attributes key == Just (AttributeValue (IntAttribute expected))
          metric name = sum [value | (key, value) <- metricSums, key == name]
          tracingOn = maybe False (const True) telemetry.tracer
          metricsOn = telemetry.metricsLive
          spanChecks = if tracingOn then length exportedSpans == 6 && all (\spanValue -> spanValue.name `elem` ["account-telemetry-account", "account-telemetry-snapshot"] && show spanValue.kind == "Internal" && hasText spanValue "keiro.stream.name" spanValue.name && hasText spanValue "db.system.name" "postgresql") exportedSpans && length [() | spanValue <- exportedSpans, hasInt spanValue "keiro.events.appended" 1] == 5 && length [() | spanValue <- exportedSpans, hasText spanValue "error.type" (commandErrorClass (StoreFailed (DuplicateEvent (Just depositId))))] == 1 && all (\spanValue -> hasInt spanValue "keiro.retry.attempt" 1 || hasInt spanValue "keiro.retry.attempt" 2) exportedSpans else null exportedSpans
          metricChecks = if metricsOn then metric "keiro.command.duplicates" == 1 && metric "keiro.command.conflicts" == 1 && metric "keiro.command.retries" == 1 && metric "keiro.dispatch.failed" == 1 && metric "keiro.dispatch.deadlettered" == 1 && metric "keiro.dispatch.poison" == 1 && metric "keiro.dispatch.duplicates" == 1 && metric "keiro.snapshot.read.hits" == 1 && metric "keiro.snapshot.read.misses" == 1 else null metricSums
          cells =
            [ ("source-outcomes", oneAppend opened && oneAppend deposited && isDuplicate && oneAppend conflicted && oneAppend snapshotOpen && oneAppend snapshotDeposit && oneAppend closedOpen && oneAppend closedClose && (case bonusDeclared of Right (Right result) -> result.eventsAppended == 1; _ -> False) && (case repeatedDeclared of Right (Right result) -> result.eventsAppended == 1; _ -> False)),
              ("durable-single-deposit", length rows == 9 && length [() | row <- rows, row.eventId == depositId] == 1 && Oracle.logWellFormed rows),
              ("rejected-router-dispatch", maybe False (either (const False) (const True)) dispatch && length acks == 2 && all (\ack -> ack.decision == AckOk) acks && case letters of [letter] -> letter == Oracle.DispatchDeadLetter "router" bonusRouterName 0 (case accountStreamName closedAccount of StreamName value -> value) "command_rejected"; _ -> False),
              ("router-redelivery", maybe False (either (const False) (const True)) repeatedDispatch && length duplicateAcks == 2 && all (\ack -> ack.decision == AckOk) duplicateAcks),
              ("command-spans", spanChecks),
              ("duplicate-counter", metricChecks)
            ]
      putSummary context Measurements "write-side-signals" (object ["spanCount" .= length exportedSpans, "distinctSpanNames" .= length (nub [spanValue.name | spanValue <- exportedSpans]), "metricSums" .= metricSums])
      recordCells context cells
