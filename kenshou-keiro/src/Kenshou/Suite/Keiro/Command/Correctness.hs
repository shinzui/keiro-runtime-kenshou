module Kenshou.Suite.Keiro.Command.Correctness (scenarios) where

import Control.Monad (foldM, when)
import Data.Aeson (object, (.=))
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx
import Keiro.Command (CommandError (..), CommandResult (..), RunCommandOptions (..), SqlCommandOutcome (..), SqlTransactionDecision (..), defaultRunCommandOptions, runCommand, runCommandWithSqlEventsControlled)
import Keiro.Projection (runCommandWithProjections)
import Kenshou.Check.Verdict (InvariantClass (..), RunInfo (..), Verdict (..), VerdictStatus (..), writeVerdict)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId, unSeed)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobInt, knobText, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Suite.Keiro.Fixture.Account
import Kenshou.Suite.Keiro.Fixture.Domain
import Kenshou.Suite.Keiro.Fixture.Model qualified as Model
import Kenshou.Suite.Keiro.Fixture.Oracle qualified as Oracle
import Kenshou.Suite.Keiro.Fixture.Projection
import Kenshou.Suite.Keiro.Fixture.Runtime
import Kenshou.Suite.Keiro.Fixture.Workload qualified as Workload
import Kiroku.Store (defaultConnectionSettings, runStoreIO, runTransaction, withStore)
import Kiroku.Store.Error (StoreError (..))
import Kiroku.Store.Types (StreamName (..))
import System.FilePath ((</>))

scenarios :: [Scenario]
scenarios = [fixtureRoundtrip, idempotentEventIds, occRetryAndExhaustion, controlledRollback]

controlledRollback :: Scenario
controlledRollback =
  fixtureRoundtrip
    { id = either (error . show) id (parseScenarioId "keiro/command/correctness/controlled-rollback"),
      summary = "Checks controlled SQL rollback leaves neither the event nor its read-model effect.",
      knobs = [],
      run = runControlledRollback
    }

runControlledRollback :: RunContext -> IO ScenarioReport
runControlledRollback context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let KeiroRunner runFixture = fixture.runner
        eventStream = accountEventStream (SnapEvery 1)
        account name = AccountId name
        command name = OpenAccount (OpenAccountData (account name) 0)
        target name = accountStream (account name)
        eventId name =
          let index = case name of "commit" -> 0; "rollback" -> 1; _ -> 2
           in Workload.opEventId (unSeed context.seed) (Workload.Op 0 index (Workload.ActOpen (account name) 0)) 0
        opts name = defaultRunCommandOptions {eventIds = [eventId name]}
        committed _ _ = do
          Tx.sql "INSERT INTO kenshou_keiro.controlled_effects (label) VALUES ('commit')"
          pure (CommitSqlTransaction ())
        rolledBack _ _ = do
          Tx.sql "INSERT INTO kenshou_keiro.controlled_effects (label) VALUES ('rollback')"
          pure (RollbackSqlTransaction ())
        sqlError _ _ = do
          Tx.sql "SELECT 1/0"
          pure (CommitSqlTransaction ())
    _ <- runFixture (runTransaction (Tx.sql "CREATE SCHEMA IF NOT EXISTS kenshou_keiro")) >>= either (fail . show) pure
    _ <- runFixture (runTransaction (Tx.sql "CREATE TABLE IF NOT EXISTS kenshou_keiro.controlled_effects (label text NOT NULL)")) >>= either (fail . show) pure
    commitResult <- runFixture (runCommandWithSqlEventsControlled (opts "commit") eventStream (target "commit") (command "commit") committed)
    rollbackResult <- runFixture (runCommandWithSqlEventsControlled (opts "rollback") eventStream (target "rollback") (command "rollback") rolledBack)
    rollbackConnectionResult <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-rollback-intermediate")
    rollbackConnection <- either (fail . show) pure rollbackConnectionResult
    rowsAfterRollback <- Oracle.readCategoryLog rollbackConnection "account"
    Connection.release rollbackConnection
    retryResult <- runFixture (runCommandWithSqlEventsControlled (opts "rollback") eventStream (target "rollback") (command "rollback") committed)
    errorResult <- runFixture (runCommandWithSqlEventsControlled (opts "error") eventStream (target "error") (command "error") sqlError)
    openSilent <- runFixture (runCommand defaultRunCommandOptions eventStream (target "silent") (command "silent"))
    closeSilent <- runFixture (runCommand defaultRunCommandOptions eventStream (target "silent") (CloseAccount (CloseAccountData (account "silent"))))
    silentResult <- runFixture (runCommandWithSqlEventsControlled defaultRunCommandOptions eventStream (target "silent") (CloseAccount (CloseAccountData (account "silent"))) committed)
    acquired <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-rollback-oracle")
    connection <- either (fail . show) pure acquired
    rows <- Oracle.readCategoryLog connection "account"
    effects <- Connection.use connection (Session.statement () effectCountStatement) >>= either (fail . show) pure
    Connection.release connection
    let forAccount observed name = [row | row <- observed, row.streamName == StreamName ("account-" <> name)]
        cells =
          [ ("commit-persists-event", case commitResult of Right (Right (SqlCommandCommitted result ())) -> result.eventsAppended == 1 && length (forAccount rows "commit") == 1; _ -> False),
            ("rollback-leaves-no-event", case rollbackResult of Right (Right (SqlCommandRolledBack ())) -> null (forAccount rowsAfterRollback "rollback"); _ -> False),
            ("rollback-id-reusable", case retryResult of Right (Right (SqlCommandCommitted result ())) -> result.eventsAppended == 1; _ -> False),
            ("sql-error-leaves-no-event", case errorResult of Right (Left _) -> null (forAccount rows "error"); Left _ -> null (forAccount rows "error"); _ -> False),
            ("silent-skips-callback", case (openSilent, closeSilent, silentResult) of (Right (Right _), Right (Right _), Right (Right (SqlCommandNoOp result))) -> result.eventsAppended == 0 && length (forAccount rows "silent") == 2; _ -> False),
            ("sql-effects-atomic", effects == 2)
          ]
    recordCells context cells

effectCountStatement :: Statement.Statement () Int64
effectCountStatement =
  Statement.preparable
    "SELECT count(*) FROM kenshou_keiro.controlled_effects"
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

occRetryAndExhaustion :: Scenario
occRetryAndExhaustion =
  fixtureRoundtrip
    { id = either (error . show) id (parseScenarioId "keiro/command/correctness/occ-retry-and-exhaustion"),
      summary = "Checks optimistic conflicts retry through the configured budget and then exhaust.",
      knobs =
        [ KnobSpec (knobName "command.retry-limit") "Optimistic conflict retry budget" KnobInt (VInt 3) (IntRange 0 16) [],
          KnobSpec (knobName "command.retry-backoff-micros") "Base retry backoff" KnobInt (VInt 5000) (IntRange 0 100000) [],
          KnobSpec (knobName "command.injected-conflicts") "Number of foreign appends in the pre-append hook" KnobInt (VInt 2) (IntRange 0 32) []
        ],
      run = runOcc
    }

runOcc :: RunContext -> IO ScenarioReport
runOcc context =
  withFixtureEnv settings \fixture ->
    withStore settings \foreignStore -> do
      let account = AccountId "occ"
          target = accountStream account
          eventStream = accountEventStream SnapNever
          retryLimit = fromIntegral (knobInt context.knobs (knobName "command.retry-limit"))
          conflicts = fromIntegral (knobInt context.knobs (knobName "command.injected-conflicts"))
          backoff = fromIntegral (knobInt context.knobs (knobName "command.retry-backoff-micros"))
          KeiroRunner runFixture = fixture.runner
      initial <- runFixture (runCommand defaultRunCommandOptions eventStream target (OpenAccount (OpenAccountData account 10)))
      hookCount <- newIORef (0 :: Int)
      let hook = do
            attemptNumber <- atomicModifyIORef' hookCount (\n -> (n + 1, n + 1))
            when (attemptNumber <= conflicts) do
              result <- runStoreIO foreignStore (runCommand defaultRunCommandOptions eventStream target (Deposit (DepositData account 1 "foreign")))
              case result of
                Right (Right _) -> pure ()
                other -> fail ("foreign conflict append failed: " <> show (fmap (fmap (.eventsAppended)) other))
          options =
            defaultRunCommandOptions
              { retryLimit = retryLimit,
                retryBackoffMicros = backoff,
                beforeAppend = hook
              }
      outcome <- runFixture (runCommand options eventStream target (Deposit (DepositData account 2 "client")))
      attempts <- readIORef hookCount
      acquired <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-occ-oracle")
      connection <- either (fail . show) pure acquired
      rows <- Oracle.readCategoryLog connection "account"
      Connection.release connection
      let shouldSucceed = conflicts <= retryLimit
          expectedAttempts = min (conflicts + 1) (retryLimit + 1)
          accepted = case outcome of Right (Right result) -> result.eventsAppended == 1; _ -> False
          exhausted = case outcome of Right (Left (RetryExhausted count _)) -> count == retryLimit + 1; _ -> False
          cells =
            [ ("initial-open", case initial of Right (Right _) -> True; _ -> False),
              ("retry-outcome", if shouldSucceed then accepted else exhausted),
              ("hook-attempt-count", attempts == expectedAttempts),
              ("foreign-append-count", length rows == 1 + min conflicts (retryLimit + 1) + if shouldSucceed then 1 else 0),
              ("model-equals-log", case Oracle.modelFromLog rows of Right model -> Model.totalMoney model == 10 + min conflicts (retryLimit + 1) + if shouldSucceed then 2 else 0; _ -> False)
            ]
      recordCells context cells
  where
    settings = defaultConnectionSettings (requirePostgres context).connectionString

idempotentEventIds :: Scenario
idempotentEventIds =
  fixtureRoundtrip
    { id = either (error . show) id (parseScenarioId "keiro/command/correctness/idempotent-event-ids"),
      summary = "Checks repeated command identifiers append only once.",
      knobs = [KnobSpec (knobName "command.sabotage") "Disable caller event identifiers to test the oracle" KnobText (VText "none") (OneOf (VText "none" :| [VText "omit-event-ids"])) []],
      run = runIdempotent
    }

runIdempotent :: RunContext -> IO ScenarioReport
runIdempotent context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let account = AccountId "idempotent"
        target = accountStream account
        eventStream = accountEventStream SnapNever
        openId = Workload.opEventId (unSeed context.seed) (Workload.Op (-1) 0 (Workload.ActOpen account 10)) 0
        depositId = Workload.opEventId (unSeed context.seed) (Workload.Op 0 0 (Workload.ActDeposit account 2)) 0
        sabotage = knobText context.knobs (knobName "command.sabotage") == "omit-event-ids"
        depositOptions = defaultRunCommandOptions {eventIds = if sabotage then [] else [depositId]}
        KeiroRunner runFixture = fixture.runner
    opened <- runFixture (runCommand defaultRunCommandOptions {eventIds = [openId]} eventStream target (OpenAccount (OpenAccountData account 10)))
    firstDeposit <- runFixture (runCommand depositOptions eventStream target (Deposit (DepositData account 2 "first")))
    repeatedDeposit <- runFixture (runCommand depositOptions eventStream target (Deposit (DepositData account 2 "first")))
    repeatedOpen <- runFixture (runCommand defaultRunCommandOptions {eventIds = [openId]} eventStream target (OpenAccount (OpenAccountData account 10)))
    acquired <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-idempotence-oracle")
    connection <- either (fail . show) pure acquired
    rows <- Oracle.readCategoryLog connection "account"
    Connection.release connection
    let openedOnce = case opened of Right (Right result) -> result.eventsAppended == 1; _ -> False
        firstAccepted = case firstDeposit of Right (Right result) -> result.eventsAppended == 1; _ -> False
        duplicateRejected = case repeatedDeposit of Right (Left (StoreFailed (DuplicateEvent _))) -> True; _ -> False
        openRejected = case repeatedOpen of Right (Left CommandRejected) -> True; _ -> False
        matchingIds = length [() | row <- rows, row.eventId == depositId]
        cells =
          [ ("open-accepted", openedOnce),
            ("first-deposit-accepted", firstAccepted),
            ("deposit-duplicate-rejected", duplicateRejected),
            ("open-repetition-rejected", openRejected),
            ("event-id-once", matchingIds == 1),
            ("stream-version-once", length rows == 2)
          ]
    recordCells context cells

fixtureRoundtrip :: Scenario
fixtureRoundtrip =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/command/correctness/fixture-roundtrip"),
      revision = 1,
      summary = "Checks account command decisions, the durable log, and an inline balance projection.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs =
        [ KnobSpec (knobName "workload.operations") "Number of generated account operations" KnobInt (VInt 500) (IntRange 1 100000) []
        ],
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
      run = runRoundtrip
    }

knobName :: Text -> KnobName
knobName = either (error . show) id . mkKnobName

runRoundtrip :: RunContext -> IO ScenarioReport
runRoundtrip context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let KeiroRunner runFixture = fixture.runner
    _ <- runFixture ensureFixtureReadModels >>= either (fail . show) pure
    let spec = Workload.defaultWorkloadSpec {Workload.accounts = 10, Workload.mix = Workload.OpMix 5 3 0 0}
        operations = take (fromIntegral (knobInt context.knobs (knobName "workload.operations"))) (Workload.workerOps (unSeed context.seed) spec 0 1)
        allOps = Workload.setupOps spec <> operations
        stream = accountEventStream (SnapEvery 10)
    (expected, decisionsMatch) <- foldM (submit fixture stream) (Model.emptyModel, True) allOps
    acquired <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-oracle")
    connection <- either (fail . show) pure acquired
    rows <- Oracle.readCategoryLog connection "account"
    balances <- Oracle.readBalanceTable connection
    Connection.release connection
    let logModel = Oracle.modelFromLog rows
        versions = Map.fromListWith max [(AccountId (Text.drop 8 name), row.streamVersion) | row <- rows, let StreamName name = row.streamName]
        Model.Model expectedAccounts = expected
        balanceMatches =
          Map.size balances == Map.size expectedAccounts
            && all
              ( \(accountId, account) ->
                  Map.lookup accountId balances
                    == Just (fromIntegral account.balance, fromIntegral account.entries, Map.findWithDefault 0 accountId versions)
              )
              (Map.toList expectedAccounts)
        cells =
          [ ("log-is-well-formed", Oracle.logWellFormed rows),
            ("model-equals-log", logModel == Right expected && decisionsMatch),
            ("inline-read-model-equals-log", balanceMatches),
            ("money-is-conserved", Model.totalMoney expected == sum [fromIntegral balance | (balance, _, _) <- Map.elems balances])
          ]
    recordCells context cells
  where
    submit fixture stream (model, allMatched) op =
      foldM (submitLeg fixture stream) (model, allMatched) (Workload.opCommands (unSeed context.seed) op)
    submitLeg fixture stream (model, allMatched) (choice, identifier) =
      case choice of
        Left _ -> pure (model, allMatched)
        Right (target, command) -> do
          let options = defaultRunCommandOptions {eventIds = [identifier]}
              KeiroRunner runFixture = fixture.runner
          outcome <- runFixture (runCommandWithProjections options stream target command [accountBalanceProjection])
          case (Model.decide model command, outcome) of
            (Model.ModelAccepts event, Right (Right result))
              | result.eventsAppended == 1 -> pure (Model.apply event model, allMatched)
            (Model.ModelRejects, Right (Left CommandRejected)) -> pure (model, allMatched)
            (Model.ModelNoOp, Right (Right result))
              | result.eventsAppended == 0 -> pure (model, allMatched)
            _ -> pure (model, False)

recordCells :: RunContext -> [(Text, Bool)] -> IO ScenarioReport
recordCells context cells = do
  checkedAt <- getCurrentTime
  mapM_ (writeCell checkedAt) cells
  let failed = [label | (label, False) <- cells]
  putSummary context Verdicts "fixture-roundtrip" (object ["checks" .= length cells, "failures" .= failed])
  pure $ if null failed then passed else failedWith failed "keiro fixture roundtrip failed"
  where
    writeCell checkedAt (label, held) = do
      let verdict =
            Verdict
              { checker = "keiro-fixture-" <> label,
                invariant = label,
                cls = Contract,
                status = if held then Held else Violated,
                reason = Nothing,
                summary = if held then "Expected result observed" else "Expected result did not match",
                counts = Map.singleton "events" 1,
                parameters = object [],
                counterExamples = [],
                counterExamplesTruncated = False,
                inputs = [],
                replay = Nothing,
                checkedAt = checkedAt,
                durationMillis = 0
              }
      _ <- writeVerdict (context.outDir </> "verdicts") (RunInfo context.runId context.scenario) verdict
      pure ()
