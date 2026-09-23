module Kenshou.Suite.Kiroku.Fixture.Store (StoreOptions (..), storeOptionsFromKnobs, storeOptionsFromValues, withKirokuStore, withKirokuStoreWithTap, withKirokuStoreWithEnricher, withKirokuStoreWithCallbacks, withKirokuStoreWithDecodeHook) where

import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (RunId, renderRunId)
import Kenshou.Core.Knob (ResolvedKnobs, knobBool, knobInt, mkKnobName)
import Kenshou.Suite.Kiroku.Knobs qualified as Knobs
import Kiroku.Store (ConnectionSettingsM (..), EventData, KirokuEvent, KirokuStore, RecordedEvent, StoreSettings (..), defaultConnectionSettings, defaultStoreSettings, withStore)

data StoreOptions = StoreOptions
  { poolSize :: Int,
    statementTimeout :: Maybe Int,
    idleInTransactionTimeout :: Int,
    applicationName :: Text,
    keepalives :: Bool,
    decodeHook :: Maybe (RecordedEvent -> IO RecordedEvent),
    eventTap :: Maybe (KirokuEvent -> IO ())
  }

storeOptionsFromKnobs :: RunContext -> Text -> StoreOptions
storeOptionsFromKnobs context = storeOptionsFromValues context.knobs context.runId

storeOptionsFromValues :: ResolvedKnobs -> RunId -> Text -> StoreOptions
storeOptionsFromValues knobs runId role =
  StoreOptions
    { poolSize = Knobs.poolSize knobs,
      statementTimeout = if seconds == 0 then Nothing else Just (fromIntegral seconds),
      idleInTransactionTimeout = fromIntegral (knobInt knobs (name "kiroku.idle-in-transaction-timeout-seconds")),
      applicationName = "kenshou-kiroku-" <> role <> "-" <> Text.take 8 (Text.filter (/= '-') (renderRunId runId)),
      keepalives = knobBool knobs (name "kiroku.conn.keepalives"),
      decodeHook = Nothing,
      eventTap = Nothing
    }
  where
    seconds = knobInt knobs (name "kiroku.statement-timeout-seconds")
    name = either (error . show) id . mkKnobName

withKirokuStore :: RunContext -> (KirokuStore -> IO result) -> IO result
withKirokuStore context = withConfiguredStore context Nothing Nothing Nothing

withKirokuStoreWithTap :: RunContext -> Maybe (KirokuEvent -> IO ()) -> (KirokuStore -> IO result) -> IO result
withKirokuStoreWithTap context tap = withConfiguredStore context tap Nothing Nothing

withKirokuStoreWithEnricher :: RunContext -> Maybe (EventData -> IO EventData) -> (KirokuStore -> IO result) -> IO result
withKirokuStoreWithEnricher context enricher = withConfiguredStore context Nothing enricher Nothing

withKirokuStoreWithCallbacks :: RunContext -> Maybe (KirokuEvent -> IO ()) -> Maybe (EventData -> IO EventData) -> (KirokuStore -> IO result) -> IO result
withKirokuStoreWithCallbacks context tap enricher = withConfiguredStore context tap enricher Nothing

withKirokuStoreWithDecodeHook :: RunContext -> (RecordedEvent -> IO RecordedEvent) -> Maybe (KirokuEvent -> IO ()) -> (KirokuStore -> IO result) -> IO result
withKirokuStoreWithDecodeHook context hook tap = withConfiguredStore context tap Nothing (Just hook)

withConfiguredStore :: RunContext -> Maybe (KirokuEvent -> IO ()) -> Maybe (EventData -> IO EventData) -> Maybe (RecordedEvent -> IO RecordedEvent) -> (KirokuStore -> IO result) -> IO result
withConfiguredStore context tap enricher hook action =
  withStore settings action
  where
    options = (storeOptionsFromKnobs context "scenario") {eventTap = tap, decodeHook = hook}
    settings =
      (defaultConnectionSettings connectionString)
        { poolSize = options.poolSize,
          statementTimeout = options.statementTimeout,
          idleInTransactionTimeout = options.idleInTransactionTimeout,
          eventHandler = options.eventTap,
          storeSettings = defaultStoreSettings {enrichEvent = enricher, decodeHook = options.decodeHook}
        }
    connectionString =
      (requirePostgres context).connectionString
        <> " application_name="
        <> options.applicationName
        <> if options.keepalives
          then " keepalives=1 keepalives_idle=5 keepalives_interval=2 keepalives_count=3 tcp_user_timeout=10000"
          else ""
