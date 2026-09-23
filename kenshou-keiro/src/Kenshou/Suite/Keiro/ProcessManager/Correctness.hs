module Kenshou.Suite.Keiro.ProcessManager.Correctness (scenarios) where

import Control.Monad (forM, forM_)
import Data.IORef (newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Data.UUID qualified as UUID
import Data.Vector qualified as Vector
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Keiro.Command (CommandError (..), CommandResult (..), RunCommandOptions (..), defaultRunCommandOptions, runCommand)
import Keiro.ProcessManager (RejectedCommandPolicy (..), WorkerOptions (..), defaultWorkerOptions, deterministicCommandId, runProcessManagerOnce, runProcessManagerWorkerWith)
import Keiro.Timer (TimerId (..))
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId, unSeed)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobInt, knobText, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Command.Correctness (recordCells)
import Kenshou.Suite.Keiro.Fixture.Account
import Kenshou.Suite.Keiro.Fixture.Bridge
import Kenshou.Suite.Keiro.Fixture.Domain
import Kenshou.Suite.Keiro.Fixture.Model qualified as Model
import Kenshou.Suite.Keiro.Fixture.Oracle qualified as Oracle
import Kenshou.Suite.Keiro.Fixture.Runtime
import Kenshou.Suite.Keiro.Fixture.Transfer
import Kenshou.Suite.Keiro.Fixture.Workload qualified as Workload
import Kiroku.Store (defaultConnectionSettings)
import Kiroku.Store.Read (readCategory)
import Kiroku.Store.Types (CategoryName (..), GlobalPosition (..), RecordedEvent (..), StreamName (..))
import Shibuya.Core.Ack (AckDecision (..))

scenarios :: [Scenario]
scenarios = [deterministicIdsRedelivery, timersCommitWithManagerAppend, orderInsensitiveJoin]

orderInsensitiveJoin :: Scenario
orderInsensitiveJoin =
  deterministicIdsRedelivery
    { id = either (error . show) id (parseScenarioId "keiro/process-manager/correctness/order-insensitive-join"),
      summary = "Checks the saga accepts both source orders and the strict variant rejects announce-first.",
      knobs = [],
      run = runOrderInsensitive
    }

runOrderInsensitive :: RunContext -> IO ScenarioReport
runOrderInsensitive context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let KeiroRunner runFixture = fixture.runner
        accountEvents = accountEventStream SnapNever
        source :: Int -> AccountId
        source i = AccountId ("join-source-" <> Text.pack (show i))
        destination :: Int -> AccountId
        destination i = AccountId ("join-destination-" <> Text.pack (show i))
        transfer :: Int -> TransferId
        transfer i = TransferId ("join-" <> Text.pack (show i))
        accepted = \case Right (Right result) -> result.eventsAppended == 1; _ -> False
        submit account command = runFixture (runCommand defaultRunCommandOptions accountEvents (accountStream account) command)
    seeded <- forM [0 :: Int, 1] \i -> do
      openSource <- submit (source i) (OpenAccount (OpenAccountData (source i) 10))
      openDestination <- submit (destination i) (OpenAccount (OpenAccountData (destination i) 0))
      debit <- submit (source i) (DebitTransfer (DebitTransferData (source i) (transfer i) (destination i) 3 4102444800))
      announce <- submit (destination i) (AnnounceTransfer (AnnounceTransferData (destination i) (transfer i)))
      pure (all accepted [openSource, openDestination, debit, announce])
    categoryEvents <- runFixture (readCategory (CategoryName "account") (GlobalPosition 0) 20) >>= either (fail . show) pure
    let decoded = [pair | recorded <- Vector.toList categoryEvents, Just pair <- [decodeTransferSignal recorded]]
        byKind :: Int -> Text -> [RecordedEvent]
        byKind i kind =
          [ recorded
          | (recorded, signal) <- decoded,
            case signal of
              SignalDebited d -> kind == "debit" && d.transferId == transfer i
              SignalAnnounced d -> kind == "announce" && d.transferId == transfer i
          ]
    (strictInput, ordered) <- case (byKind 0 "announce", byKind 0 "debit", byKind 1 "debit", byKind 1 "announce") of
      ([announce0], [debit0], [debit1], [announce1]) -> pure (announce0, [announce0, debit0, debit1, announce1])
      _ -> fail "expected exactly one of each transfer source event"
    ackLog <- newIORef []
    let adapter = listAdapter "join-manager" ackLog [(recorded, Nothing) | recorded <- ordered]
    _ <- runFixture (runProcessManagerWorkerWith defaultWorkerOptions defaultRunCommandOptions (transferManager accountEvents (const [])) adapter decodeTransferSignal) >>= either (fail . show) pure
    tolerantAcks <- readIORef ackLog
    strictHaltLog <- newIORef []
    let strictManager = strictTransferManager accountEvents
        haltAdapter = listAdapter "strict-halt" strictHaltLog [(strictInput, Nothing)]
    _ <- runFixture (runProcessManagerWorkerWith defaultWorkerOptions defaultRunCommandOptions strictManager haltAdapter decodeTransferSignal) >>= either (fail . show) pure
    strictHaltAcks <- readIORef strictHaltLog
    strictDeadLog <- newIORef []
    let deadAdapter = listAdapter "strict-dead-letter" strictDeadLog [(strictInput, Nothing)]
        deadOptions = defaultWorkerOptions {rejectedCommandPolicy = RejectedDeadLetter}
    _ <- runFixture (runProcessManagerWorkerWith deadOptions defaultRunCommandOptions strictManager deadAdapter decodeTransferSignal) >>= either (fail . show) pure
    strictDeadAcks <- readIORef strictDeadLog
    acquired <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-join-oracle")
    connection <- either (fail . show) pure acquired
    accountRows <- Oracle.readCategoryLog connection "account"
    tolerantRows <- Oracle.readCategoryLog connection "pm:transferSaga"
    strictRows <- Oracle.readCategoryLog connection "pm:transferSagaStrict"
    deadLetters <- Oracle.readDispatchDeadLetters connection
    Connection.release connection
    let isHalt = \case AckHalt _ -> True; _ -> False
        cells =
          [ ("source-setup", and seeded && length decoded == 4),
            ("both-orders-joined", length tolerantRows == 4 && all (\i -> length [() | row <- tolerantRows, row.streamName == StreamName ("pm:transferSaga-join-" <> Text.pack (show i))] == 2) [0 :: Int, 1]),
            ("target-effects", length accountRows == 12 && case Oracle.modelFromLog accountRows of Right model -> Model.totalMoney model == 20; _ -> False),
            ("tolerant-acks", length tolerantAcks == 4 && all ((== AckOk) . (.decision)) tolerantAcks),
            ("strict-halt", case strictHaltAcks of [ack] -> isHalt ack.decision; _ -> False),
            ("strict-dead-letter", case (strictDeadAcks, deadLetters) of ([ack], [letter]) -> ack.decision == AckOk && letter.dispatcherKind == "process-manager" && letter.dispatcherName == "transferSagaStrict" && letter.emitIndex == -1; _ -> False),
            ("strict-no-saga-event", null strictRows)
          ]
    recordCells context cells

timersCommitWithManagerAppend :: Scenario
timersCommitWithManagerAppend =
  deterministicIdsRedelivery
    { id = either (error . show) id (parseScenarioId "keiro/process-manager/correctness/timers-commit-with-manager-append"),
      summary = "Checks timer writes commit with the manager event and rejected replay cannot move the timer.",
      knobs = [],
      run = runTimerAtomicity
    }

runTimerAtomicity :: RunContext -> IO ScenarioReport
runTimerAtomicity context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let KeiroRunner runFixture = fixture.runner
        accountEvents = accountEventStream SnapNever
        source = AccountId "timer-source"
        destination = AccountId "timer-destination"
        transfer = TransferId "timer-transfer"
        deadline = 4102444800 :: Int
        manager = transferManager accountEvents (const [])
        submit account command = runFixture (runCommand defaultRunCommandOptions accountEvents (accountStream account) command)
        debit due = DebitTransfer (DebitTransferData source transfer destination 2 due)
        accepted = \case Right (Right result) -> result.eventsAppended == 1; _ -> False
    openedSource <- submit source (OpenAccount (OpenAccountData source 10))
    openedDestination <- submit destination (OpenAccount (OpenAccountData destination 0))
    firstDebit <- submit source (debit deadline)
    initialEvents <- runFixture (readCategory (CategoryName "account") (GlobalPosition 0) 20) >>= either (fail . show) pure
    firstRecorded <- case [recorded | recorded <- Vector.toList initialEvents, case decodeTransferSignal recorded of Just (_, SignalDebited _) -> True; _ -> False] of
      [recorded] -> pure recorded
      other -> fail ("expected one debited input, observed " <> show (length other))
    firstSignal <- maybe (fail "first debit did not decode") (pure . snd) (decodeTransferSignal firstRecorded)
    firstReaction <- runFixture (runProcessManagerOnce defaultRunCommandOptions manager firstRecorded firstSignal)
    redelivery <- runFixture (runProcessManagerOnce defaultRunCommandOptions manager firstRecorded firstSignal)
    secondDebit <- submit source (debit (deadline + 600))
    laterEvents <- runFixture (readCategory (CategoryName "account") (GlobalPosition 0) 30) >>= either (fail . show) pure
    secondRecorded <- case [recorded | recorded <- Vector.toList laterEvents, recorded.eventId /= firstRecorded.eventId, case decodeTransferSignal recorded of Just (_, SignalDebited _) -> True; _ -> False] of
      [recorded] -> pure recorded
      other -> fail ("expected one second debited input, observed " <> show (length other))
    secondSignal <- maybe (fail "second debit did not decode") (pure . snd) (decodeTransferSignal secondRecorded)
    rejected <- runFixture (runProcessManagerOnce defaultRunCommandOptions manager secondRecorded secondSignal)
    acquired <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-timer-oracle")
    connection <- either (fail . show) pure acquired
    timers <- Oracle.readTimers connection
    sagaRows <- Oracle.readCategoryLog connection "pm:transferSaga"
    accountRows <- Oracle.readCategoryLog connection "account"
    Connection.release connection
    let TimerId uuid = transferTimeoutTimerId transfer
        cells =
          [ ("source-setup", all accepted [openedSource, openedDestination, firstDebit, secondDebit]),
            ("first-reaction-accepted", case firstReaction of Right (Right _) -> True; _ -> False),
            ("redelivery-idempotent", case redelivery of Right (Right _) -> True; _ -> False),
            ("second-debit-rejected", case rejected of Right (Left CommandRejected) -> True; _ -> False),
            ("timer-committed-once", case timers of [timer] -> timer.timerId == UUID.toText uuid && timer.processManagerName == transferManagerName && timer.correlationId == "timer-transfer" && timer.status == "scheduled" && timer.fireAt == posixSecondsToUTCTime (fromIntegral deadline); _ -> False),
            ("manager-event-once", length sagaRows == 1),
            ("target-effects-once", length accountRows == 6)
          ]
    recordCells context cells

knobName :: Text -> KnobName
knobName = either (error . show) id . mkKnobName

deterministicIdsRedelivery :: Scenario
deterministicIdsRedelivery =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/process-manager/correctness/deterministic-ids-redelivery"),
      revision = 1,
      summary = "Checks redelivery keeps manager and target effects unique.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs =
        [ KnobSpec (knobName "pm.redeliveries") "Deliveries per source event" KnobInt (VInt 3) (IntRange 1 20) [],
          KnobSpec (knobName "pm.sabotage") "Change the manager identity on redelivery" KnobText (VText "none") (OneOf (VText "none" :| [VText "unstable-manager-name"])) []
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
      run = runDeterministic
    }

runDeterministic :: RunContext -> IO ScenarioReport
runDeterministic context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let KeiroRunner runFixture = fixture.runner
        accountEvents = accountEventStream SnapNever
        transferCount = 50
        redeliveries = fromIntegral (knobInt context.knobs (knobName "pm.redeliveries"))
        sabotage = knobText context.knobs (knobName "pm.sabotage") == "unstable-manager-name"
        transferAt i = TransferId ("transfer-" <> Text.pack (show i))
        sourceAt i = AccountId ("source-" <> Text.pack (show i))
        destinationAt i = AccountId ("destination-" <> Text.pack (show i))
        sourceId i leg = Workload.opEventId (unSeed context.seed) (Workload.Op 0 (fromIntegral i) (Workload.ActTransfer (transferAt i) (sourceAt i) (destinationAt i) 2)) leg
        submit account command options = runFixture (runCommand options accountEvents (accountStream account) command)
        accepted = \case Right (Right result) -> result.eventsAppended == 1; _ -> False
    setup <- forM [0 .. transferCount - 1] \i -> do
      sourceOpen <- submit (sourceAt i) (OpenAccount (OpenAccountData (sourceAt i) 10)) defaultRunCommandOptions
      destinationOpen <- submit (destinationAt i) (OpenAccount (OpenAccountData (destinationAt i) 0)) defaultRunCommandOptions
      debit <- submit (sourceAt i) (DebitTransfer (DebitTransferData (sourceAt i) (transferAt i) (destinationAt i) 2 4102444800)) defaultRunCommandOptions {eventIds = [sourceId i 0]}
      announce <- submit (destinationAt i) (AnnounceTransfer (AnnounceTransferData (destinationAt i) (transferAt i))) defaultRunCommandOptions {eventIds = [sourceId i 1]}
      pure (all accepted [sourceOpen, destinationOpen, debit, announce])
    sourceBatch <- runFixture (readCategory (CategoryName "account") (GlobalPosition 0) 1000) >>= either (fail . show) pure
    let sourceEvents = filter (maybe False (const True) . decodeTransferSignal) (Vector.toList sourceBatch)
        deliveries = concatMap (\recorded -> replicate redeliveries (recorded, Nothing)) sourceEvents
    acknowledgementLog <- newIORef []
    if sabotage
      then forM_ (zip [0 :: Int ..] deliveries) \(index, delivery) -> do
        let name = transferManagerName <> "X" <> Text.pack (show index)
            adapter = listAdapter "unstable-manager" acknowledgementLog [delivery]
        runFixture (runProcessManagerWorkerWith defaultWorkerOptions defaultRunCommandOptions (renamedTransferManager name accountEvents) adapter decodeTransferSignal) >>= either (fail . show) pure
      else do
        let adapter = listAdapter "transfer-manager" acknowledgementLog deliveries
        runFixture (runProcessManagerWorkerWith defaultWorkerOptions defaultRunCommandOptions (transferManager accountEvents (const [])) adapter decodeTransferSignal) >>= either (fail . show) pure
    acknowledgements <- readIORef acknowledgementLog
    acquired <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-pm-oracle")
    connection <- either (fail . show) pure acquired
    accountRows <- Oracle.readCategoryLog connection "account"
    sagaRows <- Oracle.readCategoryLog connection "pm:transferSaga"
    Connection.release connection
    let findId rows identifier = length [() | row <- rows, row.eventId == identifier] == 1
        expectedFor i =
          let TransferId correlation = transferAt i
              debitId = sourceId i 0
              announceId = sourceId i 1
           in findId sagaRows (deterministicCommandId transferManagerName correlation debitId (-1))
                && findId sagaRows (deterministicCommandId transferManagerName correlation announceId (-1))
                && findId accountRows (deterministicCommandId transferManagerName correlation debitId 0)
                && findId accountRows (deterministicCommandId transferManagerName correlation debitId 1)
        expectedEffects = all expectedFor [0 .. transferCount - 1]
        cells =
          [ ("source-setup", and setup && length sourceEvents == transferCount * 2),
            ("exactly-once-target-effects", expectedEffects && length sagaRows == transferCount * 2 && length accountRows == transferCount * 6),
            ("all-acknowledged", length acknowledgements == length deliveries && all ((== AckOk) . (.decision)) acknowledgements),
            ("log-is-well-formed", Oracle.logWellFormed accountRows && Oracle.logWellFormed sagaRows),
            ("money-is-conserved", case Oracle.modelFromLog accountRows of Right model -> Model.totalMoney model == transferCount * 10; _ -> False)
          ]
    recordCells context cells
