module Kenshou.Suite.Keiro.Outbox.Workload
  ( sourceName,
    enqueueInline,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (forM_)
import Data.Aeson (object, (.=))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time (getCurrentTime)
import Keiro.Integration.Event (IntegrationContentType (..), IntegrationEvent (..))
import Keiro.Outbox (enqueueIntegrationEventTx, freshOutboxId)
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Id (renderRunId)
import Kenshou.Suite.Keiro.Fixture.Runtime (FixtureEnv (..), KeiroRunner (..))
import Kiroku.Store (runTransaction)

sourceName :: RunContext -> Text -> Text
sourceName context suffix = "kenshou-" <> Text.take 8 (renderRunId context.runId) <> "-" <> suffix

-- Each transaction starts after the previous one commits so PostgreSQL's
-- created_at ordering is unambiguous even on a fast local database.
enqueueInline :: FixtureEnv -> Text -> [(Text, Maybe Text, Int)] -> IO ()
enqueueInline fixture source entries = forM_ entries \(messageId, key, sequenceNo) -> do
  now <- getCurrentTime
  let KeiroRunner runFixture = fixture.runner
  outboxId <- runFixture freshOutboxId >>= either (fail . show) pure
  let event =
        IntegrationEvent
          { messageId,
            source,
            destination = "kenshou.outbox.v1",
            key,
            eventType = "OutboxProbe",
            schemaVersion = 1,
            contentType = ApplicationJson,
            schemaReference = Nothing,
            sourceEventId = Nothing,
            sourceGlobalPosition = Nothing,
            payloadBytes = TextEncoding.encodeUtf8 messageId,
            occurredAt = now,
            causationId = Nothing,
            correlationId = Nothing,
            traceContext = Nothing,
            attributes = Just (object ["sequence" .= sequenceNo])
          }
  runFixture (runTransaction (enqueueIntegrationEventTx outboxId event)) >>= either (fail . show) pure
  threadDelay 1000
