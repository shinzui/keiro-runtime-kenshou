module Kenshou.Suite.Keiro.Inbox.Bench (scenarios) where

import Data.Aeson (object, (.=))
import Data.ByteString qualified as ByteString
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Data.UUID qualified as UUID
import Data.Vector qualified as Vector
import Hasql.Transaction qualified as Tx
import Keiro.Command (defaultRunCommandOptions, runCommand)
import Keiro.Inbox (InboxDedupePolicy (..), InboxPersistence (..), InboxResult (..), listInbox, runInboxDelegated, runInboxDelegatedBatch, runInboxTransactionBatch, runInboxTransactionWith)
import Keiro.Inbox.Delegated (delegatedCommand, delegatedEventId)
import Keiro.Integration.Event (IntegrationEvent (..))
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (Kind (..), parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobInt, knobText, mkKnobName)
import Kenshou.Core.Phase qualified as CorePhase
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport (..), Tier (..), failedWith)
import Kenshou.Measure.Knobs (measureKnobs)
import Kenshou.Measure.Load (ClosedConfig (..), LoadModel (..), LoadReport (..), Operation (..), runLoad)
import Kenshou.Measure.Phase (PhasePlan (..), SteadyBound (..))
import Kenshou.Measure.Recorder (ErrorCause (..), OpName (..), OpResult (..))
import Kenshou.Measure.Session (MeasureConfig (..), measureConfigFromKnobs, measuredOutcome, phasePlanFromCore, withMeasurement)
import Kenshou.Suite.Keiro.Command.Correctness (recordCells)
import Kenshou.Suite.Keiro.Fixture.Account (AccountSnapshotPolicy (..), accountEventStream, accountStream, accountStreamName)
import Kenshou.Suite.Keiro.Fixture.Domain (AccountCommand (..), AccountId (..), DepositData (..), OpenAccountData (..))
import Kenshou.Suite.Keiro.Fixture.Runtime (CommandRunner (..), FixtureEnv (..), KeiroRunner (..), KeiroTelemetry (..), SubmitOutcome (..), keiroTelemetry, submitAccountCommand, withFixtureTelemetryEnv)
import Kenshou.Suite.Keiro.Inbox.Correctness (effectInsertStatement, effectReadStatement, ensureEffectTable)
import Kenshou.Suite.Keiro.Outbox.Workload (inlineEvent, sourceName)
import Kenshou.Telemetry (telemetryKnobs, telemetrySpecFromContext, withTelemetry)
import Kiroku.Store (defaultConnectionSettings)
import Kiroku.Store.Read (readStreamForward)
import Kiroku.Store.Transaction qualified as KirokuTransaction
import Kiroku.Store.Types (EventId (..), StreamVersion (..))

scenarios :: [Scenario]
scenarios = [intakeThroughput]

intakeThroughput :: Scenario
intakeThroughput =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/inbox/benchmark/intake-throughput"),
      revision = 1,
      summary = "Measures durable inbox-table and delegated-stream intake under fresh and redelivered traffic.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs =
        telemetryKnobs
          <> measureKnobs Benchmark
          <> [ intKnob "inbox.cycles" 1500 1 100000,
               intKnob "inbox.consumers" 4 1 32,
               intKnob "inbox.batch-size" 0 0 100,
               intKnob "inbox.payload-bytes" 1024 1 1000000,
               textKnob "inbox.idempotence" "inbox-table" ["delegated"],
               textKnob "inbox.persistence" "full-envelope" ["dedupe-only"],
               textKnob "inbox.redelivery-ratio" "0.5" ["0", "1"]
             ],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| [TracingNoop, TracingSdkInMemory, TracingSdkOtlp]) TracingOff),
            metrics = Supported (Support (MetricsOff :| [MetricsCollect, MetricsServe, MetricsServeScraped]) MetricsOff),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      phases = CorePhase.PhasePlan 0 1 1,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku, SchemaKeiro] [("shared_preload_libraries", "'pg_stat_statements'")] False)},
      knownDefect = Nothing,
      run = runIntakeThroughput
    }

runIntakeThroughput :: RunContext -> IO ScenarioReport
runIntakeThroughput context = case (measureConfigFromKnobs context (phasePlanFromCore (CorePhase.PhasePlan 0 1 1)), telemetrySpecFromContext context) of
  (Left reason, _) -> pure (failedWith ["invalid-measure-config"] reason)
  (_, Left reason) -> pure (failedWith ["invalid-telemetry-config"] reason)
  (Right config, Right telemetrySpec) -> withTelemetry telemetrySpec \telemetry -> do
    runtimeTelemetry <- keiroTelemetry telemetry
    withFixtureTelemetryEnv (defaultConnectionSettings (requirePostgres context).connectionString) runtimeTelemetry \fixture -> do
      let KeiroRunner runFixture = fixture.runner
          source = sourceName context "inbox-bench"
          delegated = knobText context.knobs (name "inbox.idempotence") == "delegated"
          persistence = if knobText context.knobs (name "inbox.persistence") == "dedupe-only" then PersistDedupeOnly else PersistFullEnvelope
          ratio = knobText context.knobs (name "inbox.redelivery-ratio")
          batch = max 1 (fromIntegral (knobInt context.knobs (name "inbox.batch-size")) :: Int)
          batched = knobInt context.knobs (name "inbox.batch-size") > 0
          consumers = fromIntegral (knobInt context.knobs (name "inbox.consumers")) :: Int
          payloadBytes = fromIntegral (knobInt context.knobs (name "inbox.payload-bytes")) :: Int
          cycles = fromIntegral (knobInt context.knobs (name "inbox.cycles"))
          measuredConfig = config {defaultPhases = (config.defaultPhases) {steady = SteadyCount cycles}}
          account worker = AccountId (source <> "-account-" <> Text.pack (show worker))
          makeEvent messageName now = (inlineEvent source messageName Nothing 0 now) {payloadBytes = ByteString.replicate payloadBytes 65}
          seedEvent worker now = makeEvent ("seed-" <> Text.pack (show worker)) now
          tableHandler event = Tx.statement event.messageId effectInsertStatement
          normalize = \case
            InboxProcessed _ -> InboxProcessed ()
            InboxDuplicate -> InboxDuplicate
            InboxInProgress -> InboxInProgress
            InboxPreviouslyFailed reason -> InboxPreviouslyFailed reason
            InboxHandlerFailed reason attempts -> InboxHandlerFailed reason attempts
          delegatedHandler worker dedupe event = do
            let target = account worker
                targetName = accountStreamName target
                marker = delegatedEventId "kenshou-bench" event.source dedupe targetName "deposit"
            result <- delegatedCommand defaultRunCommandOptions targetName marker \prepared ->
              runCommand prepared (accountEventStream (SnapEvery 50)) (accountStream target) (Deposit (DepositData target 1 "inbox-bench"))
            either (error . show) pure result
          intake worker events =
            if delegated
              then
                fmap
                  (fmap (map (fmap normalize)))
                  ( runFixture
                      ( if batched
                          then runInboxDelegatedBatch runtimeTelemetry.keiroMetrics PreferIntegrationMessageId [(event, Nothing) | event <- events] (delegatedHandler worker)
                          else traverse (\event -> runInboxDelegated runtimeTelemetry.keiroMetrics PreferIntegrationMessageId event Nothing (delegatedHandler worker)) events
                      )
                  )
              else
                runFixture
                  ( if batched
                      then runInboxTransactionBatch runtimeTelemetry.keiroMetrics 3 PreferIntegrationMessageId persistence [(event, Nothing) | event <- events] tableHandler
                      else traverse (\event -> runInboxTransactionWith runtimeTelemetry.keiroMetrics persistence PreferIntegrationMessageId event Nothing tableHandler) events
                  )
      ensureEffectTable fixture
      now <- getCurrentTime
      if delegated
        then do
          seeded <- traverse (\worker -> submitAccountCommand fixture (accountEventStream (SnapEvery 50)) RunnerPlain defaultRunCommandOptions 0 (EventId (UUID.fromWords 0 0 0 (fromIntegral worker + 1))) (OpenAccount (OpenAccountData (account worker) 0))) [0 .. consumers - 1]
          if all (== SubmitAppended (StreamVersion 1)) seeded then pure () else fail "delegated benchmark account setup failed"
        else pure ()
      seeds <- traverse (\worker -> intake worker [seedEvent worker now]) [0 .. consumers - 1]
      if all (\result -> case result of Right [Right (InboxProcessed ())] -> True; _ -> False) seeds then pure () else fail "inbox benchmark seed delivery failed"
      (generated, report) <- withMeasurement context measuredConfig \measurement -> do
        let runOne worker sequenceNumber = do
              stamped <- getCurrentTime
              let base = Text.pack (show worker) <> "-" <> Text.pack (show sequenceNumber)
                  fresh = [makeEvent (base <> "-" <> Text.pack (show index)) stamped | index <- [1 .. batch]]
                  deliveries = case ratio of
                    "0" -> fresh
                    "1" -> replicate batch (seedEvent worker now)
                    _ -> fresh <> fresh
                  expectedFresh = if ratio == "1" then 0 else batch
                  expectedDuplicates = length deliveries - expectedFresh
              result <- intake worker deliveries
              pure case result of
                Left err -> OpFailed (ErrorCause (Text.pack (show err)))
                Right outcomes ->
                  let freshCount = length [() | Right (InboxProcessed ()) <- outcomes]
                      duplicateCount = length [() | Right InboxDuplicate <- outcomes]
                   in if freshCount == expectedFresh && duplicateCount == expectedDuplicates
                        then OpOk (length deliveries)
                        else OpFailed (ErrorCause "intake-classification")
        runLoad measurement (ClosedLoop (ClosedConfig consumers 0 0)) (Operation (OpName "inbox.intake") runOne)
      let completed = fromIntegral generated.completed :: Int
          expectedFresh = if ratio == "1" then 0 else completed * batch
          expectedEffects = consumers + expectedFresh
      rows <- runFixture (listInbox source) >>= either (fail . show) pure
      effectCount <-
        if delegated
          then
            fmap sum $
              traverse
                ( \worker -> do
                    events <- runFixture (readStreamForward (accountStreamName (account worker)) (StreamVersion 0) (fromIntegral (completed * batch + 10))) >>= either (fail . show) pure
                    pure (Vector.length events - 1)
                )
                [0 .. consumers - 1]
          else do
            effects <- runFixture (KirokuTransaction.runTransaction (Tx.statement () effectReadStatement)) >>= either (fail . show) pure
            pure (length effects)
      let cells =
            [ ("intake-classification", completed > 0 && generated.failed == 0),
              ("durable-effects-no-loss", effectCount == expectedEffects && if delegated then null rows else length rows == expectedEffects)
            ]
      putSummary context Measurements "inbox-intake-throughput" (object ["idempotence" .= (if delegated then "delegated" else "inbox-table" :: Text), "persistence" .= show persistence, "batchSize" .= batch, "consumers" .= consumers, "redeliveryRatio" .= ratio, "completedCycles" .= completed, "expectedFresh" .= expectedFresh, "durableEffects" .= effectCount, "inboxRows" .= length rows])
      base <- recordCells context cells
      pure (base {outcome = measuredOutcome report base.outcome})

intKnob :: Text -> Int -> Int -> Int -> KnobSpec
intKnob key def low high = KnobSpec (name key) key KnobInt (VInt (fromIntegral def)) (IntRange (fromIntegral low) (fromIntegral high)) []

textKnob :: Text -> Text -> [Text] -> KnobSpec
textKnob key def alternatives = KnobSpec (name key) key KnobText (VText def) (OneOf (VText def :| map VText alternatives)) (map VText alternatives)

name :: Text -> KnobName
name = either (error . show) id . mkKnobName
