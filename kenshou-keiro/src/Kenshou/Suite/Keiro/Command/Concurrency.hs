module Kenshou.Suite.Keiro.Command.Concurrency (scenarios) where

import Control.Concurrent.Async (async, wait)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Concurrent.STM (atomically)
import Control.Monad (replicateM)
import Data.Aeson (object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.ByteString qualified as ByteString
import Data.Foldable (traverse_)
import Data.IORef (atomicModifyIORef', newIORef)
import Data.List (findIndex, nub)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (addUTCTime, getCurrentTime)
import GHC.Clock (getMonotonicTimeNSec)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Hedgehog (Gen, forAll)
import Hedgehog qualified
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Keiro.Command (CommandError (..), CommandResult (..), RunCommandOptions (..), defaultRunCommandOptions, runCommand)
import Kenshou.Check.Model (ModelRun (..), runModel)
import Kenshou.Check.Model.Linearizability (Completion (..), LinResult (..), Operation (..), SeqModel (..), checkLinearizable, defaultLinConfig)
import Kenshou.Check.Process (ProgressSnapshot (..), awaitMark, awaitReady, childPid, killChild, progress, roleProcess, sendCommand, spawn, withSupervisor)
import Kenshou.Check.Scenario (finishWithVerdicts, withCheck)
import Kenshou.Check.Verdict (InvariantClass (..))
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId, unSeed)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobInt, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Command.Correctness (recordCells)
import Kenshou.Suite.Keiro.Fixture.Account
import Kenshou.Suite.Keiro.Fixture.Domain
import Kenshou.Suite.Keiro.Fixture.Model qualified as Model
import Kenshou.Suite.Keiro.Fixture.Oracle qualified as Oracle
import Kenshou.Suite.Keiro.Fixture.Runtime
import Kenshou.Suite.Keiro.Fixture.Workload qualified as Workload
import Kiroku.Store (defaultConnectionSettings)
import Kiroku.Store.Error (StoreError (..))
import Kiroku.Store.Types (StreamVersion (..))
import System.FilePath ((</>))

scenarios :: [Scenario]
scenarios = [identicalCommandsOneBatch, hotStreamContention, sigkillIdempotentResubmission, modelBasedParallelCommands, seedDivergenceDetection]

seedDivergenceDetection :: Scenario
seedDivergenceDetection =
  identicalCommandsOneBatch
    { id = either (error . show) id (parseScenarioId "keiro/snapshot/correctness/seed-divergence-detection"),
      summary = "Checks sampled snapshot seed verification reports a corrupt seed without rejecting the command.",
      knobs = [KnobSpec (knobName "snapshot.seed-verify-sample-rate") "Verify one in N snapshot seeds" KnobInt (VInt 1) (IntRange 0 1) []],
      run = runSeedDivergence
    }

runSeedDivergence :: RunContext -> IO ScenarioReport
runSeedDivergence context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture ->
    withCheck context \check -> withSupervisor check \supervisor -> do
      let KeiroRunner runFixture = fixture.runner
          seed = unSeed context.seed
          account = AccountId "0"
          accountEvents = accountEventStream (SnapEvery 1)
          workload = take 100 (Workload.workerOps seed Workload.defaultWorkloadSpec {Workload.accounts = 1} 0 1)
          isDepositOp operation = case operation.action of Workload.ActDeposit {} -> True; _ -> False
          rate = fromIntegral (knobInt context.knobs (knobName "snapshot.seed-verify-sample-rate")) :: Int
      startIndex <- maybe (fail "no deposit in first 100 seeded operations") pure (findIndex isDepositOp workload)
      let operation = workload !! startIndex
          eventId = Workload.opEventId seed operation 0
          args = object ["worker" .= (0 :: Int), "workers" .= (1 :: Int), "startIndex" .= startIndex, "count" .= (1 :: Int), "accounts" .= (1 :: Int), "seedVerifySampleRate" .= rate, "postSubmissionDelayMicros" .= (1000000 :: Int)]
      opened <- runFixture (runCommand defaultRunCommandOptions accountEvents (accountStream account) (OpenAccount (OpenAccountData account 10000)))
      acquired <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-seed-divergence-oracle")
      connection <- either (fail . show) pure acquired
      before <- Oracle.readSnapshots connection
      _ <- Connection.use connection (Session.statement () corruptSnapshot) >>= either (fail . show) pure
      corrupted <- Oracle.readSnapshots connection
      spec <- roleProcess check "keiro/command-writer" 0 args
      child <- spawn supervisor spec
      awaitReady child 10000
      sendCommand child CtlStart
      awaitMark child "submission" 30000
      reported <- atomically (progress child)
      after <- Oracle.readCategoryLog connection "account"
      Connection.release connection
      stderr <- ByteString.readFile (context.outDir </> "logs" </> "keiro-command-writer-0.0.stderr.log")
      let snapshotKey = accountStreamName account
          outcome = do
            payload <- Map.lookup "submission" reported.marks
            parseMaybe (withObject "submission" (.: "outcomes")) payload :: Maybe [Text]
          hasMarker = "keiro.snapshot.seed.divergence" `ByteString.isInfixOf` stderr
          cells =
            [ ("snapshot-created", case (opened, Map.lookup snapshotKey before) of (Right (Right result), Just (1, _)) -> result.eventsAppended == 1; _ -> False),
              ("snapshot-corrupted", Map.lookup snapshotKey before /= Map.lookup snapshotKey corrupted),
              ("command-succeeds", case outcome of Just [value] -> "SubmitAppended" `Text.isPrefixOf` value; _ -> False),
              ("sampling-diagnostic", hasMarker == (rate == 1)),
              ("durable-append", length [() | row <- after, row.eventId == eventId] == 1 && Oracle.logWellFormed after)
            ]
      recordCells context cells

corruptSnapshot :: Statement.Statement () ()
corruptSnapshot =
  Statement.preparable
    "UPDATE keiro.keiro_snapshots sn SET state = jsonb_set(sn.state, '{registers,balance}', '999999'::jsonb) FROM kiroku.streams s WHERE s.stream_id = sn.stream_id AND s.stream_name = 'account-0'"
    Encoders.noParams
    Decoders.noResult

data ModelObservation = ModelAccepted !Int | ModelRejected | ModelNoOp
  deriving stock (Eq, Show)

modelBasedParallelCommands :: Scenario
modelBasedParallelCommands =
  identicalCommandsOneBatch
    { id = either (error . show) id (parseScenarioId "keiro/command/concurrency/model-based-parallel-commands"),
      summary = "Generates parallel account command histories and checks them against the reference model.",
      knobs =
        [ KnobSpec (knobName "model.tests") "Generated histories" KnobInt (VInt 100) (IntRange 1 1000) [],
          KnobSpec (knobName "model.branches") "Concurrent branches" KnobInt (VInt 3) (IntRange 2 4) []
        ],
      run = runModelBasedParallel
    }

runModelBasedParallel :: RunContext -> IO ScenarioReport
runModelBasedParallel context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture ->
    withCheck context \check -> do
      executionCounter <- newIORef (0 :: Int)
      let KeiroRunner runFixture = fixture.runner
          branchCount = fromIntegral (knobInt context.knobs (knobName "model.branches")) :: Int
          testCount = fromIntegral (knobInt context.knobs (knobName "model.tests")) :: Int
          accountEvents = accountEventStream SnapNever
          property = do
            branches <- forAll (replicateM branchCount (Gen.list (Range.linear 3 5) genCommandSpec))
            execution <- Hedgehog.evalIO (atomicModifyIORef' executionCounter (\n -> (n + 1, n)))
            let account i = AccountId ("parallel-" <> Text.pack (show execution) <> "-" <> Text.pack (show i))
                accounts = map account [0 :: Int .. 2]
                initial = foldl (\state acc -> Model.apply (AccountOpened (AccountOpenedData acc 20)) state) Model.emptyModel accounts
                command (accountIndex, choice, amount) =
                  let target = account accountIndex
                   in case choice of
                        0 -> OpenAccount (OpenAccountData target amount)
                        1 -> Deposit (DepositData target amount "parallel")
                        2 -> Withdraw (WithdrawData target amount)
                        _ -> CloseAccount (CloseAccountData target)
                runOne branch spec = do
                  let chosen = command spec
                      target = commandAccountId chosen
                  invoked <- fromIntegral <$> getMonotonicTimeNSec
                  result <- runFixture (runCommand defaultRunCommandOptions {retryLimit = 32} accountEvents (accountStream target) chosen)
                  completed <- fromIntegral <$> getMonotonicTimeNSec
                  let outcome = case result of
                        Right (Right response) | response.eventsAppended == 1 -> let StreamVersion version = response.streamVersion in Returned (ModelAccepted (fromIntegral version))
                        Right (Right response) | response.eventsAppended == 0 -> Returned ModelNoOp
                        Right (Left CommandRejected) -> Returned ModelRejected
                        _ -> Failed
                  pure (Operation (Text.pack (show branch)) (case target of AccountId value -> value) chosen invoked (Just completed) outcome)
                runBranch gate branch specs = do
                  readMVar gate
                  traverse (runOne branch) specs
                model = SeqModel initial modelStep (==)
                modelStep current chosen = case Model.decide current chosen of
                  Model.ModelAccepts event ->
                    let next = Model.apply event current
                     in (ModelAccepted (Model.lookupAccount (commandAccountId chosen) next).entries, next)
                  Model.ModelNoOp -> (ModelNoOp, current)
                  Model.ModelRejects -> (ModelRejected, current)
            opened <- Hedgehog.evalIO (traverse (\acc -> runFixture (runCommand defaultRunCommandOptions accountEvents (accountStream acc) (OpenAccount (OpenAccountData acc 20)))) accounts)
            Hedgehog.assert (all (\case Right (Right result) -> result.eventsAppended == 1; _ -> False) opened)
            gate <- Hedgehog.evalIO newEmptyMVar
            workers <- Hedgehog.evalIO (traverse (\(branch, specs) -> async (runBranch gate branch specs)) (zip [0 :: Int ..] branches))
            Hedgehog.evalIO (putMVar gate ())
            histories <- Hedgehog.evalIO (concat <$> traverse wait workers)
            Hedgehog.assert (all (\case Operation {completion = Returned _} -> True; _ -> False) histories)
            let groups = [[operation | operation <- histories, operation.key == case acc of AccountId value -> value] | acc <- accounts]
            Hedgehog.assert (all ((== Linearizable) . checkLinearizable defaultLinConfig model) groups)
            acquired <- Hedgehog.evalIO (Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-parallel-oracle"))
            connection <- Hedgehog.evalIO (either (fail . show) pure acquired)
            rows <- Hedgehog.evalIO (Oracle.readCategoryLog connection "account")
            Hedgehog.evalIO (Connection.release connection)
            let ownRows = [row | row <- rows, row.streamName `elem` map accountStreamName accounts]
            Hedgehog.assert (Oracle.logWellFormed ownRows)
          modelRun = ModelRun "parallel-commands-linearizable" Contract testCount 20 property
      verdict <- runModel check modelRun
      finishWithVerdicts check [verdict]

genCommandSpec :: Gen (Int, Int, Int)
genCommandSpec = (,,) <$> Gen.int (Range.linear 0 2) <*> Gen.int (Range.linear 0 3) <*> Gen.int (Range.linear 0 30)

sigkillIdempotentResubmission :: Scenario
sigkillIdempotentResubmission =
  identicalCommandsOneBatch
    { id = either (error . show) id (parseScenarioId "keiro/command/concurrency/sigkill-idempotent-resubmission"),
      summary = "Kills a writer after append and checks the restarted writer confirms its duplicate id.",
      knobs = [],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      run = runSigkillResubmission
    }

runSigkillResubmission :: RunContext -> IO ScenarioReport
runSigkillResubmission context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture ->
    withCheck context \check -> withSupervisor check \supervisor -> do
      let KeiroRunner runFixture = fixture.runner
          seed = unSeed context.seed
          account = AccountId "0"
          accountEvents = accountEventStream SnapNever
          workload = take 100 (Workload.workerOps seed Workload.defaultWorkloadSpec {Workload.accounts = 1} 0 1)
          isDepositOp operation = case operation.action of Workload.ActDeposit {} -> True; _ -> False
      startIndex <- maybe (fail "no deposit in first 100 seeded operations") pure (findIndex isDepositOp workload)
      let operation = workload !! startIndex
          eventId = Workload.opEventId seed operation 0
          amount = case operation.action of Workload.ActDeposit _ value -> value; _ -> 0
          writerArgs park = object ["worker" .= (0 :: Int), "workers" .= (1 :: Int), "startIndex" .= startIndex, "count" .= (1 :: Int), "accounts" .= (1 :: Int), "parkAfterIndex" .= park]
      opened <- runFixture (runCommand defaultRunCommandOptions accountEvents (accountStream account) (OpenAccount (OpenAccountData account 10000)))
      firstSpec <- roleProcess check "keiro/command-writer" 0 (writerArgs (Just startIndex))
      first <- spawn supervisor firstSpec
      awaitReady first 10000
      sendCommand first CtlStart
      awaitMark first "parked" 30000
      acquired <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-writer-crash-oracle")
      connection <- either (fail . show) pure acquired
      beforeRows <- Oracle.readCategoryLog connection "account"
      killChild supervisor first
      secondSpec <- roleProcess check "keiro/command-writer" 1 (writerArgs (Nothing :: Maybe Int))
      second <- spawn supervisor secondSpec
      awaitReady second 10000
      sendCommand second CtlStart
      awaitMark second "submission" 30000
      acknowledged <- atomically (progress second)
      afterRows <- Oracle.readCategoryLog connection "account"
      Connection.release connection
      let duplicateFact = do
            payload <- Map.lookup "submission" acknowledged.marks
            outcomes <- parseMaybe (withObject "submission" (.: "outcomes")) payload :: Maybe [Text]
            pure (outcomes == ["SubmitDuplicate"])
          occurrences rows = length [() | row <- rows, row.eventId == eventId]
          cells =
            [ ("source-setup", case opened of Right (Right result) -> result.eventsAppended == 1; _ -> False),
              ("committed-before-kill", occurrences beforeRows == 1),
              ("restarted-writer-reported-duplicate", childPid first /= childPid second && duplicateFact == Just True),
              ("one-durable-effect", occurrences afterRows == 1 && length afterRows == 2 && Oracle.logWellFormed afterRows),
              ("final-balance", case Oracle.modelFromLog afterRows of Right model -> Model.totalMoney model == 10000 + amount; _ -> False)
            ]
      recordCells context cells

hotStreamContention :: Scenario
hotStreamContention =
  identicalCommandsOneBatch
    { id = either (error . show) id (parseScenarioId "keiro/command/concurrency/hot-stream-contention"),
      summary = "Checks accepted writes on a contended stream have distinct versions and the right balance.",
      knobs =
        [ KnobSpec (knobName "command.writers") "Concurrent writers" KnobInt (VInt 8) (IntRange 2 128) [],
          KnobSpec (knobName "command.retry-limit") "Optimistic conflict retry limit" KnobInt (VInt 3) (IntRange 0 16) [],
          KnobSpec (knobName "command.duration-seconds") "Contention duration" KnobInt (VInt 30) (IntRange 1 600) []
        ],
      run = runHotStream
    }

knobName :: Text -> KnobName
knobName = either (error . show) id . mkKnobName

runHotStream :: RunContext -> IO ScenarioReport
runHotStream context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let account = AccountId "hot-stream"
        target = accountStream account
        eventStream = accountEventStream SnapNever
        KeiroRunner runFixture = fixture.runner
        writerCount = fromIntegral (knobInt context.knobs (knobName "command.writers"))
        retryBudget = fromIntegral (knobInt context.knobs (knobName "command.retry-limit"))
        duration = fromIntegral (knobInt context.knobs (knobName "command.duration-seconds"))
    opened <- runFixture (runCommand defaultRunCommandOptions eventStream target (OpenAccount (OpenAccountData account 0)))
    gate <- newEmptyMVar
    let work writer = do
          deadline <- readMVar gate
          loop deadline writer 0 [] (0 :: Int)
        loop deadline writer index accepted unexpected = do
          now <- getCurrentTime
          if now >= deadline
            then pure (accepted, unexpected)
            else do
              let identifier = Workload.opEventId (unSeed context.seed) (Workload.Op writer index (Workload.ActDeposit account 1)) 0
                  options = defaultRunCommandOptions {eventIds = [identifier], retryLimit = retryBudget}
              outcome <- runFixture (runCommand options eventStream target (Deposit (DepositData account 1 "contention")))
              case outcome of
                Right (Right result) | result.eventsAppended == 1 -> loop deadline writer (index + 1) (result.streamVersion : accepted) unexpected
                Right (Left (RetryExhausted {})) -> loop deadline writer (index + 1) accepted unexpected
                _ -> loop deadline writer (index + 1) accepted (unexpected + 1)
    workers <- traverse (async . work) [0 .. writerCount - 1]
    start <- getCurrentTime
    putMVar gate (addUTCTime duration start)
    results <- traverse wait workers
    acquired <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-contention-oracle")
    connection <- either (fail . show) pure acquired
    rows <- Oracle.readCategoryLog connection "account"
    Connection.release connection
    let versions = concatMap fst results
        acceptedCount = length versions
        unexpectedCount = sum (map snd results)
        cells =
          [ ("initial-open", case opened of Right (Right result) -> result.eventsAppended == 1; _ -> False),
            ("accepted-versions-unique", length (nub versions) == acceptedCount),
            ("accepted-equals-log", length rows == acceptedCount + 1 && Oracle.logWellFormed rows),
            ("final-balance", case Oracle.modelFromLog rows of Right model -> Model.totalMoney model == acceptedCount; _ -> False),
            ("no-unexpected-results", unexpectedCount == 0)
          ]
    recordCells context cells

identicalCommandsOneBatch :: Scenario
identicalCommandsOneBatch =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/command/concurrency/identical-commands-one-batch"),
      revision = 1,
      summary = "Checks concurrent submissions of one event identifier append exactly once.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs =
        [ KnobSpec (either (error . show) id (mkKnobName "command.concurrency")) "Simultaneous thread clients" KnobInt (VInt 16) (IntRange 2 256) [],
          KnobSpec (knobName "command.processes") "Identical client processes (1 selects threads)" KnobInt (VInt 1) (IntRange 1 16) []
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
      run = runIdentical
    }

runIdentical :: RunContext -> IO ScenarioReport
runIdentical context | knobInt context.knobs (knobName "command.processes") > 1 = runIdenticalProcesses context
runIdentical context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let account = AccountId "concurrent-identical"
        target = accountStream account
        eventStream = accountEventStream SnapNever
        command = Deposit (DepositData account 7 "identical")
        identifier = Workload.opEventId (unSeed context.seed) (Workload.Op 0 0 (Workload.ActDeposit account 7)) 0
        options = defaultRunCommandOptions {eventIds = [identifier]}
        KeiroRunner runFixture = fixture.runner
        concurrency = fromIntegral (knobInt context.knobs (either (error . show) id (mkKnobName "command.concurrency")))
    opened <- runFixture (runCommand defaultRunCommandOptions eventStream target (OpenAccount (OpenAccountData account 0)))
    gate <- newEmptyMVar
    workers <- replicateM concurrency (async (readMVar gate >> runFixture (runCommand options eventStream target command)))
    putMVar gate ()
    results <- traverse wait workers
    acquired <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-identical-oracle")
    connection <- either (fail . show) pure acquired
    rows <- Oracle.readCategoryLog connection "account"
    Connection.release connection
    let accepted = [result.streamVersion | Right (Right result) <- results, result.eventsAppended == 1]
        duplicate = length [() | Right (Left (StoreFailed (DuplicateEvent _))) <- results]
        exhausted = length [() | Right (Left (RetryExhausted {})) <- results]
        cells =
          [ ("initial-open", case opened of Right (Right result) -> result.eventsAppended == 1; _ -> False),
            ("one-accepted", length accepted == 1 && length (nub accepted) == 1),
            ("others-duplicate-or-exhausted", length accepted + duplicate + exhausted == concurrency),
            ("no-retry-exhaustion", exhausted == 0),
            ("event-id-once", length [() | row <- rows, row.eventId == identifier] == 1),
            ("stream-version-once", length rows == 2),
            ("balance-once", case Oracle.modelFromLog rows of Right model -> Model.totalMoney model == 7; _ -> False)
          ]
    recordCells context cells

runIdenticalProcesses :: RunContext -> IO ScenarioReport
runIdenticalProcesses context =
  withFixtureEnv (defaultConnectionSettings (requirePostgres context).connectionString) \fixture ->
    withCheck context \check -> withSupervisor check \supervisor -> do
      let KeiroRunner runFixture = fixture.runner
          seed = unSeed context.seed
          account = AccountId "0"
          accountEvents = accountEventStream SnapNever
          processCount = fromIntegral (knobInt context.knobs (knobName "command.processes")) :: Int
          workload = take 100 (Workload.workerOps seed Workload.defaultWorkloadSpec {Workload.accounts = 1} 0 1)
          isDepositOp operation = case operation.action of Workload.ActDeposit {} -> True; _ -> False
      startIndex <- maybe (fail "no deposit in first 100 seeded operations") pure (findIndex isDepositOp workload)
      let operation = workload !! startIndex
          eventId = Workload.opEventId seed operation 0
          amount = case operation.action of Workload.ActDeposit _ value -> value; _ -> 0
          args = object ["worker" .= (0 :: Int), "workers" .= (1 :: Int), "startIndex" .= startIndex, "count" .= (1 :: Int), "accounts" .= (1 :: Int)]
      opened <- runFixture (runCommand defaultRunCommandOptions accountEvents (accountStream account) (OpenAccount (OpenAccountData account 10000)))
      children <- traverse (\index -> roleProcess check "keiro/command-writer" index args >>= spawn supervisor) [0 .. processCount - 1]
      traverse_ (\child -> awaitReady child 10000) children
      traverse_ (\child -> sendCommand child CtlStart) children
      traverse_ (\child -> awaitMark child "submission" 30000) children
      snapshots <- traverse (atomically . progress) children
      acquired <- Connection.acquire (Settings.connectionString (requirePostgres context).connectionString <> Settings.applicationName "kenshou-keiro-identical-process-oracle")
      connection <- either (fail . show) pure acquired
      rows <- Oracle.readCategoryLog connection "account"
      Connection.release connection
      let outcomes snapshot = do
            payload <- Map.lookup "submission" snapshot.marks
            parseMaybe (withObject "submission" (.: "outcomes")) payload :: Maybe [Text]
          reported = map outcomes snapshots
          appended = length [() | Just [value] <- reported, "SubmitAppended" `Text.isPrefixOf` value]
          duplicates = length [() | Just ["SubmitDuplicate"] <- reported]
          cells =
            [ ("source-setup", case opened of Right (Right result) -> result.eventsAppended == 1; _ -> False),
              ("distinct-processes", length (nub (map childPid children)) == processCount),
              ("one-accepted", appended == 1 && duplicates == processCount - 1),
              ("one-durable-effect", length [() | row <- rows, row.eventId == eventId] == 1 && length rows == 2 && Oracle.logWellFormed rows),
              ("final-balance", case Oracle.modelFromLog rows of Right model -> Model.totalMoney model == 10000 + amount; _ -> False)
            ]
      recordCells context cells
