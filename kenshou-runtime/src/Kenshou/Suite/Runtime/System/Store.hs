module Kenshou.Suite.Runtime.System.Store
  ( ContextEff,
    ContextStore (..),
    withContextStore,
    runContext,
    runContextOrThrow,
    runSql,
    deterministicEventId,
  )
where

import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding
import Data.UUID.V5 qualified as UUID.V5
import Effectful (Eff, IOE, runEff)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Hasql.Transaction qualified as Tx
import Kiroku.Store (KirokuStore, Store, defaultConnectionSettings, runTransaction, withStore)
import Kiroku.Store.Connection (ConnectionSettingsM (..))
import Kiroku.Store.Effect (runStoreResource)
import Kiroku.Store.Effect.Resource (KirokuStoreResource, runKirokuStoreWith)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Types (EventId (..))

-- | The effect stack every keiro command, process manager and router needs.
type ContextEff = Eff '[Store, Error StoreError, KirokuStoreResource, IOE]

-- | One bounded context's event store, opened by a single role process.
newtype ContextStore = ContextStore {store :: KirokuStore}

withContextStore :: Text -> Int -> (ContextStore -> IO value) -> IO value
withContextStore connection size action =
  withStore ((defaultConnectionSettings connection) {poolSize = max 2 size}) (action . ContextStore)

runContext :: ContextStore -> ContextEff value -> IO (Either StoreError value)
runContext context = runEff . runKirokuStoreWith context.store . runErrorNoCallStack . runStoreResource

runContextOrThrow :: ContextStore -> ContextEff value -> IO value
runContextOrThrow context action = runContext context action >>= either (ioError . userError . show) pure

runSql :: ContextStore -> Tx.Transaction value -> IO (Either StoreError value)
runSql context = runContext context . runTransaction

-- | Name-based identifiers make a resubmission after a crash a duplicate.
deterministicEventId :: Text -> EventId
deterministicEventId seed =
  EventId (UUID.V5.generateNamed UUID.V5.namespaceURL (ByteString.unpack (TextEncoding.encodeUtf8 ("kenshou-runtime/" <> seed))))
