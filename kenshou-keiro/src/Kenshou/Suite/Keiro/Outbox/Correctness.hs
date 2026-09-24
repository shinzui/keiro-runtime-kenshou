module Kenshou.Suite.Keiro.Outbox.Correctness (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM)
import Data.ByteString qualified as ByteString
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Time (getCurrentTime)
import Keiro.Integration.Event (IntegrationContentType (..), IntegrationEvent (..))
import Keiro.Outbox (BackoffSchedule (..), OutboxPublishOptions (..), OutboxPublishSummary (..), OutboxRow (..), OutboxStatus (..), defaultPublishOptions, enqueueIntegrationEventTx, freshOutboxId, listOutbox, publishClaimedOutbox)
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Command.Correctness (recordCells)
import Kenshou.Suite.Keiro.Fixture.Runtime (FixtureEnv (..), KeiroRunner (..), withFixtureEnv)
import Kenshou.Suite.Keiro.Outbox.Broker qualified as Broker
import Kiroku.Store (defaultConnectionSettings, runTransaction)

scenarios :: [Scenario]
scenarios = [failureSkipsSuccessors]

failureSkipsSuccessors :: Scenario
failureSkipsSuccessors =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/outbox/correctness/failure-skips-successors"),
      revision = 1,
      summary = "Checks that a failed row skips later rows of its key without consuming their attempts.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgFsyncOff :| [PgDurable]) PgFsyncOff),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku, SchemaKeiro] [] False)},
      knownDefect = Nothing,
      run = runFailureSkipsSuccessors
    }

runFailureSkipsSuccessors :: RunContext -> IO ScenarioReport
runFailureSkipsSuccessors context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let KeiroRunner runFixture = fixture.runner
        source = "kenshou-outbox-failure-skips"
        entries = [("a" <> suffix, "a") | suffix <- ["1", "2", "3", "4", "5"]] <> [("b" <> suffix, "b") | suffix <- ["1", "2", "3", "4", "5"]]
    _ <- forM entries \(messageId, key) -> do
      now <- getCurrentTime
      outboxId <- runFixture freshOutboxId >>= either (fail . show) pure
      let event =
            IntegrationEvent
              { messageId,
                source,
                destination = "kenshou.outbox.v1",
                key = Just key,
                eventType = "OutboxProbe",
                schemaVersion = 1,
                contentType = ApplicationJson,
                schemaReference = Nothing,
                sourceEventId = Nothing,
                sourceGlobalPosition = Nothing,
                payloadBytes = ByteString.empty,
                occurredAt = now,
                causationId = Nothing,
                correlationId = Nothing,
                traceContext = Nothing,
                attributes = Nothing
              }
      runFixture (runTransaction (enqueueIntegrationEventTx outboxId event)) >>= either (fail . show) pure
      threadDelay 1000
    broker <- Broker.newBroker
    let model = Broker.BrokerModel 0 0 4
        hooks = Broker.PublishHook (const (pure ())) (const (pure ()))
        choose row = if row.event.messageId == "a2" then Broker.FailOnce else Broker.Succeed
        callback = Broker.publishScripted broker model choose hooks "publisher"
        options = defaultPublishOptions {batchSize = 16, backoff = ConstantBackoff 0}
    summary <- runFixture (publishClaimedOutbox callback options Nothing) >>= either (fail . show) pure
    rows <- runFixture (listOutbox source) >>= either (fail . show) pure
    records <- Broker.readBroker broker
    let byId = Map.fromList [(row.event.messageId, row) | row <- rows]
        isState messageId status attempts = case Map.lookup messageId byId of
          Just row -> row.status == status && row.attemptCount == attempts
          Nothing -> False
        cells =
          [ ("ten-rows", length rows == 10),
            ("first-sent", isState "a1" OutboxSent 1),
            ("pivot-failed", isState "a2" OutboxFailed 1),
            ("successors-skipped", all (\messageId -> isState messageId OutboxFailed 0) ["a3", "a4", "a5"]),
            ("independent-key-sent", all (\messageId -> isState messageId OutboxSent 1) ["b1", "b2", "b3", "b4", "b5"]),
            ("broker-six-records", length records == 6),
            ("pass-summary", summary.published == 6 && summary.retried == 4)
          ]
    recordCells context cells
