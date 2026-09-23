module Kenshou.Suite.Keiro.Fixture.Runtime
  ( KeiroEff,
    KeiroRunner (..),
    FixtureEnv (..),
    CommandRunner (..),
    SubmitOutcome (..),
    keiroRunner,
    withFixtureEnv,
    submitAccountCommand,
    submitBonusCommand,
  )
where

import Effectful (Eff, IOE, runEff)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Keiro.Command (CommandError (..), CommandResult (..), RunCommandOptions (..), runCommand, runCommandWithSql)
import Keiro.ProcessManager (confirmBenignDuplicate)
import Keiro.Projection (InlineProjection, runCommandWithProjections)
import Keiro.Stream qualified as Stream
import Kenshou.Suite.Keiro.Fixture.Account
import Kenshou.Suite.Keiro.Fixture.Bonus
import Kenshou.Suite.Keiro.Fixture.Domain
import Kiroku.Store (ConnectionSettings, KirokuStore, Store, withStore)
import Kiroku.Store.Effect (runStoreResource)
import Kiroku.Store.Effect.Resource (KirokuStoreResource, runKirokuStoreWith)
import Kiroku.Store.Error (StoreError (..))
import Kiroku.Store.Types (EventId, StreamVersion)

type KeiroEff = Eff '[Store, Error StoreError, KirokuStoreResource, IOE]

newtype KeiroRunner = KeiroRunner
  { run :: forall a. KeiroEff a -> IO (Either StoreError a)
  }

data FixtureEnv = FixtureEnv
  { store :: !KirokuStore,
    runner :: !KeiroRunner
  }

data CommandRunner
  = RunnerPlain
  | RunnerWithSql
  | RunnerWithProjections ![InlineProjection AccountEvent]

data SubmitOutcome
  = SubmitAppended !StreamVersion
  | SubmitDuplicate
  | SubmitNoOp
  | SubmitRejected
  | SubmitFailed !CommandError
  deriving stock (Eq, Show)

keiroRunner :: KirokuStore -> KeiroRunner
keiroRunner store =
  KeiroRunner (runEff . runKirokuStoreWith store . runErrorNoCallStack . runStoreResource)

withFixtureEnv :: ConnectionSettings -> (FixtureEnv -> IO a) -> IO a
withFixtureEnv settings action = withStore settings \store -> action (FixtureEnv store (keiroRunner store))

submitAccountCommand :: FixtureEnv -> ValidatedAccountEventStream -> CommandRunner -> RunCommandOptions -> Int -> EventId -> AccountCommand -> IO SubmitOutcome
submitAccountCommand fixture accountEvents runnerKind options clientBudget eventId command = attempt (max 0 clientBudget)
  where
    target = accountStream (commandAccountId command)
    KeiroRunner runFixture = fixture.runner
    withId = options {eventIds = [eventId]}
    execute = case runnerKind of
      RunnerPlain -> runCommand withId accountEvents target command
      RunnerWithSql -> fmap (fmap fst) (runCommandWithSql withId accountEvents target command (\_ -> pure ()))
      RunnerWithProjections projections -> runCommandWithProjections withId accountEvents target command projections
    attempt remaining = do
      outcome <- runFixture execute
      case outcome of
        Left storeError -> pure (SubmitFailed (StoreFailed storeError))
        Right (Right result)
          | result.eventsAppended == 0 -> pure SubmitNoOp
          | otherwise -> pure (SubmitAppended result.streamVersion)
        Right (Left CommandRejected) -> pure SubmitRejected
        Right (Left commandError) -> do
          confirmed <- runFixture (confirmBenignDuplicate (Stream.streamName target) eventId commandError)
          case confirmed of
            Right True -> pure SubmitDuplicate
            _
              | remaining > 0 && retryable commandError -> attempt (remaining - 1)
              | otherwise -> pure (SubmitFailed commandError)
    retryable = \case
      RetryExhausted {} -> True
      StoreFailed (TransientTransactionFailure {}) -> True
      _ -> False

submitBonusCommand :: FixtureEnv -> RunCommandOptions -> EventId -> BonusCommand -> IO SubmitOutcome
submitBonusCommand fixture options eventId command = do
  let bonusId = case command of DeclareBonus d -> d.bonusId
      target = bonusStream bonusId
      KeiroRunner runFixture = fixture.runner
  outcome <- runFixture (runCommand options {eventIds = [eventId]} bonusEventStream target command)
  pure case outcome of
    Left storeError -> SubmitFailed (StoreFailed storeError)
    Right (Right result)
      | result.eventsAppended == 0 -> SubmitNoOp
      | otherwise -> SubmitAppended result.streamVersion
    Right (Left CommandRejected) -> SubmitRejected
    Right (Left commandError) -> SubmitFailed commandError
