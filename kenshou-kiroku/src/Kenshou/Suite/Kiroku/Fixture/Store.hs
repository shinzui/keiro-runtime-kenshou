module Kenshou.Suite.Kiroku.Fixture.Store (withKirokuStore, withKirokuStoreWithTap, withKirokuStoreWithEnricher) where

import Data.Text qualified as Text
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (renderRunId)
import Kenshou.Core.Knob (knobBool, knobInt, mkKnobName)
import Kenshou.Suite.Kiroku.Knobs qualified as Knobs
import Kiroku.Store (ConnectionSettingsM (..), EventData, KirokuEvent, KirokuStore, StoreSettings (..), defaultConnectionSettings, defaultStoreSettings, withStore)

withKirokuStore :: RunContext -> (KirokuStore -> IO result) -> IO result
withKirokuStore context = withConfiguredStore context Nothing Nothing

withKirokuStoreWithTap :: RunContext -> Maybe (KirokuEvent -> IO ()) -> (KirokuStore -> IO result) -> IO result
withKirokuStoreWithTap context tap = withConfiguredStore context tap Nothing

withKirokuStoreWithEnricher :: RunContext -> Maybe (EventData -> IO EventData) -> (KirokuStore -> IO result) -> IO result
withKirokuStoreWithEnricher context enricher = withConfiguredStore context Nothing enricher

withConfiguredStore :: RunContext -> Maybe (KirokuEvent -> IO ()) -> Maybe (EventData -> IO EventData) -> (KirokuStore -> IO result) -> IO result
withConfiguredStore context tap enricher action =
  withStore settings action
  where
    settings =
      (defaultConnectionSettings connectionString)
        { poolSize = Knobs.poolSize context.knobs,
          statementTimeout = timeout,
          idleInTransactionTimeout = fromIntegral (knobInt context.knobs (name "kiroku.idle-in-transaction-timeout-seconds")),
          eventHandler = tap,
          storeSettings = defaultStoreSettings {enrichEvent = enricher}
        }
    seconds = knobInt context.knobs (name "kiroku.statement-timeout-seconds")
    timeout = if seconds == 0 then Nothing else Just (fromIntegral seconds)
    connectionString =
      (requirePostgres context).connectionString
        <> " application_name=kenshou-kiroku-scenario-"
        <> Text.take 8 (Text.filter (/= '-') (renderRunId context.runId))
        <> if knobBool context.knobs (name "kiroku.conn.keepalives")
          then " keepalives=1 keepalives_idle=5 keepalives_interval=2 keepalives_count=3 tcp_user_timeout=10000"
          else ""
    name = either (error . show) id . mkKnobName
