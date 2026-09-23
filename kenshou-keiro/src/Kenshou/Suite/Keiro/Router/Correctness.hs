module Kenshou.Suite.Keiro.Router.Correctness (scenarios) where

import Control.Monad (forM, forM_)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Effectful (liftIO)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Keiro.Command (CommandResult (..), defaultRunCommandOptions, runCommand)
import Keiro.ProcessManager (defaultWorkerOptions)
import Keiro.Router (deterministicRouterCommandId, runRouterWorkerWith)
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
import Kiroku.Store (defaultConnectionSettings)
import Kiroku.Store.Read (readCategory)
import Kiroku.Store.Types (CategoryName (..), GlobalPosition (..), StreamName (..))
import Shibuya.Core.Ack (AckDecision (..))

scenarios :: [Scenario]
scenarios = [fanoutExactlyOnce]

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
