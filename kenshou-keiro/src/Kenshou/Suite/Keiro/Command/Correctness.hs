module Kenshou.Suite.Keiro.Command.Correctness (scenarios) where

import Control.Monad (foldM)
import Data.Aeson (object, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Keiro.Command (CommandError (..), CommandResult (..), RunCommandOptions (..), defaultRunCommandOptions)
import Keiro.Projection (runCommandWithProjections)
import Kenshou.Check.Verdict (InvariantClass (..), RunInfo (..), Verdict (..), VerdictStatus (..), writeVerdict)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId, unSeed)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobInt, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Suite.Keiro.Fixture.Account
import Kenshou.Suite.Keiro.Fixture.Domain
import Kenshou.Suite.Keiro.Fixture.Model qualified as Model
import Kenshou.Suite.Keiro.Fixture.Oracle qualified as Oracle
import Kenshou.Suite.Keiro.Fixture.Projection
import Kenshou.Suite.Keiro.Fixture.Runtime
import Kenshou.Suite.Keiro.Fixture.Workload qualified as Workload
import Kiroku.Store (defaultConnectionSettings)
import Kiroku.Store.Types (StreamName (..))
import System.FilePath ((</>))

scenarios :: [Scenario]
scenarios = [fixtureRoundtrip]

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
