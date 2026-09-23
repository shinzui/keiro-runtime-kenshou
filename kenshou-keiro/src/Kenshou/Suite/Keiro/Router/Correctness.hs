module Kenshou.Suite.Keiro.Router.Correctness (scenarios) where

import Control.Monad (forM, forM_, when)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Effectful (liftIO)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Keiro.Command (CommandResult (..), RunCommandOptions (..), defaultRunCommandOptions, runCommand)
import Keiro.ProcessManager (PMCommand (..), RejectedCommandPolicy (..), WorkerOptions (..), defaultWorkerOptions)
import Keiro.Router (deterministicRouterCommandId, runDeclarativeRouterWorkerWith, runRouterWorkerWith)
import Keiro.Router.Selection (EmptySelectionPolicy (..), RouterSelectionFailure (..), SelectionFailurePolicy (..))
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobInt, knobText, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Command.Correctness (recordCells)
import Kenshou.Suite.Keiro.Fixture.Account
import Kenshou.Suite.Keiro.Fixture.Bonus
import Kenshou.Suite.Keiro.Fixture.Bridge
import Kenshou.Suite.Keiro.Fixture.Domain
import Kenshou.Suite.Keiro.Fixture.Model qualified as Model
import Kenshou.Suite.Keiro.Fixture.Oracle qualified as Oracle
import Kenshou.Suite.Keiro.Fixture.Projection (ensureFixtureReadModels)
import Kenshou.Suite.Keiro.Fixture.Runtime
import Kiroku.Store (defaultConnectionSettings, runStoreIO, withStore)
import Kiroku.Store.Read (readCategory)
import Kiroku.Store.Types (CategoryName (..), EventType (..), GlobalPosition (..), StreamName (..))
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..), deadLetterCodeText)

scenarios :: [Scenario]
scenarios = [fanoutExactlyOnce, perTargetIndependentCommits, stableUnionUnderDrift, declarativeSelectionPolicies]

declarativeSelectionPolicies :: Scenario
declarativeSelectionPolicies =
  fanoutExactlyOnce
    { id = either (error . show) id (parseScenarioId "keiro/router/correctness/declarative-selection-policies"),
      summary = "Checks empty and failed declarative selection decisions before dispatch.",
      tier = TierStandard,
      knobs =
        [ KnobSpec (knobName "router.empty-policy") "Comma-separated empty policies" KnobText (VText "ack,retry,dead-letter,halt") AnyValue [],
          KnobSpec (knobName "router.failure-policy") "Comma-separated failure policies" KnobText (VText "retry,dead-letter,halt") AnyValue [],
          KnobSpec (knobName "router.recipient-limit") "Distinct recipient limit" KnobInt (VInt 8) (IntRange 1 100) []
        ],
      run = runDeclarativePolicies
    }

runDeclarativePolicies :: RunContext -> IO ScenarioReport
runDeclarativePolicies context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let KeiroRunner runFixture = fixture.runner
        accountEvents = accountEventStream SnapNever
        limit = fromIntegral (knobInt context.knobs (knobName "router.recipient-limit")) :: Int
        recipients = [AccountId ("declarative-" <> Text.pack (show i)) | i <- [0 .. limit]]
        firstRecipient = AccountId "declarative-0"
        empties = map parseEmpty (Text.splitOn "," (knobText context.knobs (knobName "router.empty-policy")))
        failures = map parseFailure (Text.splitOn "," (knobText context.knobs (knobName "router.failure-policy")))
        policies = [(empty, failure) | empty <- empties, failure <- failures]
    _ <- runFixture ensureFixtureReadModels >>= either (fail . show) pure
    opened <- traverse (\account -> runFixture (runCommand defaultRunCommandOptions accountEvents (accountStream account) (OpenAccount (OpenAccountData account 0)))) recipients
    declared <- forM (zip [0 :: Int ..] policies) \(index, _) -> do
      let bonusId = BonusId ("selection-" <> Text.pack (show index))
      runFixture (runCommand defaultRunCommandOptions bonusEventStream (bonusStream bonusId) (DeclareBonus (DeclareBonusData bonusId "all" 3)))
    sourceBatch <- runFixture (readCategory (CategoryName "bonus") (GlobalPosition 0) 100) >>= either (fail . show) pure
    let sourceEvents = Vector.toList sourceBatch
    cells <- forM (zip3 [0 :: Int ..] policies sourceEvents) \(index, (emptyPolicy, failurePolicy), source) -> do
      let bonusId = BonusId ("selection-" <> Text.pack (show index))
          bonus = BonusDeclaredData bonusId "all" 3
          one = bonusCommands bonus [firstRecipient]
          cases =
            [ ("empty", Right [], emptyDecision emptyPolicy),
              ("query", Left (SelectionQueryFailed "scripted"), failureDecision failurePolicy "keiro.router.selection.query_failed"),
              ("conflict", Right (one <> [PMCommand (accountCommandStream firstRecipient) (CreditBonus (CreditBonusData firstRecipient bonusId 4))]), failureDecision failurePolicy "keiro.router.selection.target_conflict"),
              ("overflow", Right (bonusCommands bonus recipients), failureDecision failurePolicy "keiro.router.selection.recipient_overflow"),
              ("equal", Right (one <> one), ExpectAck)
            ]
      forM cases \(label, selection, expected) -> do
        contract <- either (fail . show) pure (bonusSelectionContract emptyPolicy failurePolicy (fromIntegral limit))
        acknowledgements <- newIORef []
        let router = declarativeBonusRouterWith accountEvents contract (\_ -> pure selection)
            adapter = listAdapter "declarative-router" acknowledgements [(source, Nothing)]
        _ <- runFixture (runDeclarativeRouterWorkerWith defaultWorkerOptions defaultRunCommandOptions router adapter decodeBonusDeclared) >>= either (fail . show) pure
        acks <- readIORef acknowledgements
        pure (Text.pack (show index) <> "-" <> label, case acks of [ack] -> matches expected ack.decision; _ -> False)
    acquired <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-declarative-oracle")
    connection <- either (fail . show) pure acquired
    accountRows <- Oracle.readCategoryLog connection "account"
    Connection.release connection
    let credits = [row | row <- accountRows, row.eventType == EventType "BonusCredited"]
        setupOkay = all (\case Right (Right result) -> result.eventsAppended == 1; _ -> False) opened && all (\case Right (Right result) -> result.eventsAppended == 1; _ -> False) declared
        finalCells =
          [ ("source-setup", setupOkay && length sourceEvents == length policies),
            ("only-equal-duplicates-dispatch", length credits == length policies && all (\row -> row.streamName == accountStreamName firstRecipient) credits)
          ]
    recordCells context (concat cells <> finalCells)
  where
    parseEmpty = \case
      "ack" -> EmptyAck
      "retry" -> EmptyRetry
      "dead-letter" -> EmptyDeadLetter
      "halt" -> EmptyHalt
      value -> error ("unknown empty policy: " <> Text.unpack value)
    parseFailure = \case
      "retry" -> FailureRetry
      "dead-letter" -> FailureDeadLetter
      "halt" -> FailureHalt
      value -> error ("unknown failure policy: " <> Text.unpack value)
    emptyDecision = \case
      EmptyAck -> ExpectAck
      EmptyRetry -> ExpectRetry
      EmptyDeadLetter -> ExpectDeadLetter "keiro.router.selection.empty"
      EmptyHalt -> ExpectHalt
    failureDecision policy code = case policy of
      FailureRetry -> ExpectRetry
      FailureDeadLetter -> ExpectDeadLetter code
      FailureHalt -> ExpectHalt
    matches expected decision = case (expected, decision) of
      (ExpectAck, AckOk) -> True
      (ExpectRetry, AckRetry _) -> True
      (ExpectHalt, AckHalt _) -> True
      (ExpectDeadLetter expectedCode, AckDeadLetter (ApplicationFailure actualCode _)) -> deadLetterCodeText actualCode == expectedCode
      _ -> False

data ExpectedAck = ExpectAck | ExpectRetry | ExpectHalt | ExpectDeadLetter Text

stableUnionUnderDrift :: Scenario
stableUnionUnderDrift =
  fanoutExactlyOnce
    { id = either (error . show) id (parseScenarioId "keiro/router/correctness/stable-union-under-drift"),
      summary = "Checks target selection drift retains committed targets across retry.",
      knobs = [],
      run = runStableUnion
    }

runStableUnion :: RunContext -> IO ScenarioReport
runStableUnion context =
  withFixtureEnv settings \fixture ->
    withStore settings \foreignStore -> do
      let KeiroRunner runFixture = fixture.runner
          accountEvents = accountEventStream SnapNever
          first = AccountId "drift-a"
          second = AccountId "drift-b"
          third = AccountId "drift-c"
          bonus = BonusId "drift"
          accepted = \case Right (Right result) -> result.eventsAppended == 1; _ -> False
      _ <- runFixture ensureFixtureReadModels >>= either (fail . show) pure
      opened <- traverse (\account -> runFixture (runCommand defaultRunCommandOptions accountEvents (accountStream account) (OpenAccount (OpenAccountData account 0)))) [first, second, third]
      declared <- runFixture (runCommand defaultRunCommandOptions bonusEventStream (bonusStream bonus) (DeclareBonus (DeclareBonusData bonus "all" 2)))
      sourceBatch <- runFixture (readCategory (CategoryName "bonus") (GlobalPosition 0) 10) >>= either (fail . show) pure
      source <- case Vector.toList sourceBatch of [recorded] -> pure recorded; _ -> fail "expected one drift source event"
      resolveCount <- newIORef (0 :: Int)
      hookCount <- newIORef (0 :: Int)
      let resolver _ = do
            attempt <- liftIO (atomicModifyIORef' resolveCount (\n -> (n + 1, n)))
            pure (if attempt == 0 then [first, second] else [second, third])
          hook = do
            invocation <- atomicModifyIORef' hookCount (\n -> (n + 1, n + 1))
            when (invocation == 2) do
              outcome <- runStoreIO foreignStore (runCommand defaultRunCommandOptions accountEvents (accountStream second) (Deposit (DepositData second 1 "foreign")))
              case outcome of Right (Right result) | result.eventsAppended == 1 -> pure (); _ -> fail "foreign drift append failed"
          options = defaultRunCommandOptions {retryLimit = 0, beforeAppend = hook}
          router = bonusRouterWith bonusRouterName accountEvents resolver
      acknowledgementLog <- newIORef []
      let adapter = listAdapter "drift-router" acknowledgementLog [(source, Nothing), (source, Just 1)]
      _ <- runFixture (runRouterWorkerWith defaultWorkerOptions options router adapter decodeBonusDeclared) >>= either (fail . show) pure
      acks <- readIORef acknowledgementLog
      acquired <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-drift-oracle")
      connection <- either (fail . show) pure acquired
      accountRows <- Oracle.readCategoryLog connection "account"
      Connection.release connection
      let bonusCount account = length [() | row <- accountRows, row.streamName == accountStreamName account, row.eventType == EventType "BonusCredited"]
          isRetry = \case AckRetry _ -> True; _ -> False
          cells =
            [ ("source-setup", all accepted opened && case declared of Right (Right result) -> result.eventsAppended == 1; _ -> False),
              ("retry-then-ack", case acks of [retryAck, successAck] -> isRetry retryAck.decision && successAck.decision == AckOk; _ -> False),
              ("union-credited-once", all ((== 1) . bonusCount) [first, second, third]),
              ("money-is-conserved", case Oracle.modelFromLog accountRows of Right model -> Model.totalMoney model == 7; _ -> False)
            ]
      recordCells context cells
  where
    settings = defaultConnectionSettings (requirePostgres context).connectionString

perTargetIndependentCommits :: Scenario
perTargetIndependentCommits =
  fanoutExactlyOnce
    { id = either (error . show) id (parseScenarioId "keiro/router/correctness/per-target-independent-commits"),
      summary = "Checks a rejected target records one dead letter while other credits commit.",
      knobs = [],
      run = runIndependentTargets
    }

runIndependentTargets :: RunContext -> IO ScenarioReport
runIndependentTargets context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let KeiroRunner runFixture = fixture.runner
        accountEvents = accountEventStream SnapNever
        recipients = [AccountId ("target-" <> Text.pack (show i)) | i <- [0 :: Int .. 7]]
        closed = AccountId "target-3"
        bonusId = BonusId "partial"
        accepted = \case Right (Right result) -> result.eventsAppended == 1; _ -> False
    _ <- runFixture ensureFixtureReadModels >>= either (fail . show) pure
    opened <- traverse (\account -> runFixture (runCommand defaultRunCommandOptions accountEvents (accountStream account) (OpenAccount (OpenAccountData account 0)))) recipients
    closeResult <- runFixture (runCommand defaultRunCommandOptions accountEvents (accountStream closed) (CloseAccount (CloseAccountData closed)))
    declared <- runFixture (runCommand defaultRunCommandOptions bonusEventStream (bonusStream bonusId) (DeclareBonus (DeclareBonusData bonusId "all" 4)))
    sourceBatch <- runFixture (readCategory (CategoryName "bonus") (GlobalPosition 0) 10) >>= either (fail . show) pure
    acknowledgementLog <- newIORef []
    let deliveries = [(recorded, Nothing) | recorded <- Vector.toList sourceBatch]
        router = bonusRouterWith bonusRouterName accountEvents (\_ -> pure recipients)
        adapter = listAdapter "partial-router" acknowledgementLog deliveries
        options = defaultWorkerOptions {rejectedCommandPolicy = RejectedDeadLetter}
    _ <- runFixture (runRouterWorkerWith options defaultRunCommandOptions router adapter decodeBonusDeclared) >>= either (fail . show) pure
    acks <- readIORef acknowledgementLog
    acquired <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-partial-router-oracle")
    connection <- either (fail . show) pure acquired
    accountRows <- Oracle.readCategoryLog connection "account"
    deadLetters <- Oracle.readDispatchDeadLetters connection
    Connection.release connection
    let credits = [row | row <- accountRows, row.eventType == EventType "BonusCredited"]
        cells =
          [ ("targets-opened", all accepted opened && accepted closeResult && case declared of Right (Right result) -> result.eventsAppended == 1; _ -> False),
            ("seven-credits", length credits == 7 && all (\account -> length [() | row <- credits, row.streamName == accountStreamName account] == if account == closed then 0 else 1) recipients),
            ("one-dead-letter", case deadLetters of [letter] -> letter.dispatcherKind == "router" && letter.dispatcherName == bonusRouterName && letter.targetStreamName == "account-target-3" && letter.errorClass == "command_rejected"; _ -> False),
            ("acknowledged", case acks of [ack] -> ack.decision == AckOk; _ -> False),
            ("money-is-conserved", case Oracle.modelFromLog accountRows of Right model -> Model.totalMoney model == 7 * 4; _ -> False)
          ]
    recordCells context cells

knobName :: Text -> KnobName
knobName = either (error . show) id . mkKnobName

fanoutExactlyOnce :: Scenario
fanoutExactlyOnce =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/router/correctness/fanout-exactly-once"),
      revision = 1,
      summary = "Checks fanout IDs survive redelivery and target order drift, including repeated recipients.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs =
        [ KnobSpec (knobName "router.fanout") "Distinct recipients" KnobInt (VInt 16) (IntRange 1 1000) [],
          KnobSpec (knobName "router.redeliveries") "Deliveries per source event" KnobInt (VInt 3) (IntRange 1 20) [],
          KnobSpec (knobName "router.sabotage") "Change the router identity on redelivery" KnobText (VText "none") (OneOf (VText "none" :| [VText "unstable-router-name"])) []
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
      run = runFanout
    }

runFanout :: RunContext -> IO ScenarioReport
runFanout context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let KeiroRunner runFixture = fixture.runner
        accountEvents = accountEventStream SnapNever
        fanout = fromIntegral (knobInt context.knobs (knobName "router.fanout"))
        redeliveries = fromIntegral (knobInt context.knobs (knobName "router.redeliveries"))
        sabotage = knobText context.knobs (knobName "router.sabotage") == "unstable-router-name"
        recipients = [AccountId ("bonus-target-" <> Text.pack (show i)) | i <- [0 .. fanout - 1]]
        firstRecipient = AccountId "bonus-target-0"
        primary = BonusId "primary"
        repeated = BonusId "repeated"
        submitAccount account = runFixture (runCommand defaultRunCommandOptions accountEvents (accountStream account) (OpenAccount (OpenAccountData account 0)))
        accepted = \case Right (Right result) -> result.eventsAppended == 1; _ -> False
    _ <- runFixture ensureFixtureReadModels >>= either (fail . show) pure
    opened <- traverse submitAccount recipients
    declared <- forM [primary, repeated] \bonusId ->
      runFixture (runCommand defaultRunCommandOptions bonusEventStream (bonusStream bonusId) (DeclareBonus (DeclareBonusData bonusId "all" 3)))
    sourceBatch <- runFixture (readCategory (CategoryName "bonus") (GlobalPosition 0) 10) >>= either (fail . show) pure
    let sourceEvents = Vector.toList sourceBatch
        deliveries = concatMap (\recorded -> replicate redeliveries (recorded, Nothing)) sourceEvents
    resolveCount <- newIORef (0 :: Int)
    let resolver bonus = do
          attempt <- liftIO (atomicModifyIORef' resolveCount (\n -> (n + 1, n)))
          pure $
            if bonus.bonusId == repeated
              then [firstRecipient, firstRecipient]
              else if even attempt then recipients else reverse recipients
        router name = bonusRouterWith name accountEvents resolver
    acknowledgements <- newIORef []
    if sabotage
      then forM_ (zip [0 :: Int ..] deliveries) \(index, delivery) -> do
        let adapter = listAdapter "unstable-router" acknowledgements [delivery]
        runFixture (runRouterWorkerWith defaultWorkerOptions defaultRunCommandOptions (router (bonusRouterName <> "X" <> Text.pack (show index))) adapter decodeBonusDeclared) >>= either (fail . show) pure
      else do
        let adapter = listAdapter "bonus-router" acknowledgements deliveries
        runFixture (runRouterWorkerWith defaultWorkerOptions defaultRunCommandOptions (router bonusRouterName) adapter decodeBonusDeclared) >>= either (fail . show) pure
    acks <- readIORef acknowledgements
    acquired <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-router-oracle")
    connection <- either (fail . show) pure acquired
    accountRows <- Oracle.readCategoryLog connection "account"
    bonusRows <- Oracle.readCategoryLog connection "bonus"
    balances <- Oracle.readBalanceTable connection
    Connection.release connection
    let sourceId bonusId = case bonusId of BonusId value -> case [row.eventId | row <- bonusRows, row.streamName == StreamName ("bonus-" <> value)] of [identifier] -> Just identifier; _ -> Nothing
        expectedId bonusId target occurrence = do
          identifier <- sourceId bonusId
          let BonusId correlation = bonusId
          pure (deterministicRouterCommandId bonusRouterName correlation identifier (accountStreamName target) occurrence)
        existsOnce identifier = length [() | row <- accountRows, row.eventId == identifier] == 1
        primaryIds = [expectedId primary recipient 0 | recipient <- recipients]
        repeatedIds = [expectedId repeated firstRecipient occurrence | occurrence <- [0, 1]]
        allIds = primaryIds <> repeatedIds
        cells =
          [ ("accounts-opened", all accepted opened),
            ("bonuses-declared", all (\case Right (Right result) -> result.eventsAppended == 1; _ -> False) declared && length bonusRows == 2),
            ("fanout-identities", all (maybe False existsOnce) allIds),
            ("target-event-count", length accountRows == fanout * 2 + 2),
            ("all-acknowledged", length acks == length deliveries && all ((== AckOk) . (.decision)) acks),
            ("log-is-well-formed", Oracle.logWellFormed accountRows),
            ("money-and-balances", case Oracle.modelFromLog accountRows of Right model -> Model.totalMoney model == (fanout + 2) * 3 && sum [balance | (balance, _, _) <- Map.elems balances] == fromIntegral ((fanout + 2) * 3); _ -> False)
          ]
    recordCells context cells
