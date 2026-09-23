module Kenshou.Suite.Keiro.ProcessManager.Correctness (scenarios) where

import Control.Monad (forM, forM_)
import Data.IORef (newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Keiro.Command (CommandResult (..), RunCommandOptions (..), defaultRunCommandOptions, runCommand)
import Keiro.ProcessManager (defaultWorkerOptions, deterministicCommandId, runProcessManagerWorkerWith)
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
import Kiroku.Store.Types (CategoryName (..), GlobalPosition (..))
import Shibuya.Core.Ack (AckDecision (..))

scenarios :: [Scenario]
scenarios = [deterministicIdsRedelivery]

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
