module Kenshou.Suite.Keiro.Fixture.Runtime
  ( KeiroEff,
    KeiroRunner (..),
    FixtureEnv (..),
    keiroRunner,
    withFixtureEnv,
  )
where

import Effectful (Eff, IOE, runEff)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Kiroku.Store (ConnectionSettings, KirokuStore, Store, StoreError, withStore)
import Kiroku.Store.Effect (runStoreResource)
import Kiroku.Store.Effect.Resource (KirokuStoreResource, runKirokuStoreWith)

type KeiroEff = Eff '[Store, Error StoreError, KirokuStoreResource, IOE]

newtype KeiroRunner = KeiroRunner
  { run :: forall a. KeiroEff a -> IO (Either StoreError a)
  }

data FixtureEnv = FixtureEnv
  { store :: !KirokuStore,
    runner :: !KeiroRunner
  }

keiroRunner :: KirokuStore -> KeiroRunner
keiroRunner store =
  KeiroRunner (runEff . runKirokuStoreWith store . runErrorNoCallStack . runStoreResource)

withFixtureEnv :: ConnectionSettings -> (FixtureEnv -> IO a) -> IO a
withFixtureEnv settings action = withStore settings \store -> action (FixtureEnv store (keiroRunner store))
