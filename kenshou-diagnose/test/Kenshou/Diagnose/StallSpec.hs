module Kenshou.Diagnose.StallSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (wait, withAsync)
import Control.Exception (bracket, finally, try)
import Control.Monad ((>=>))
import Data.Aeson (eitherDecodeFileStrict')
import Data.Int (Int64)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word32, Word64)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Kenshou.Core.Context (RunContext (..), newRunState)
import Kenshou.Core.Dimension (Dimensions (..), PgDurability (..), PgVersion (..))
import Kenshou.Core.Env (PostgresRequirement (..))
import Kenshou.Core.Env.Postgres (PostgresEnv (..), withPostgresEnv)
import Kenshou.Core.Id (parseRunId, parseScenarioId)
import Kenshou.Core.Log (nullLogger)
import Kenshou.Core.RunSpec (PostgresSpec (..))
import Kenshou.Diagnose.LockGraph (GraphEdge (..), LockGraph (..), buildGraph)
import Kenshou.Diagnose.Postgres
import Kenshou.Diagnose.Stall qualified as Stall
import Kenshou.Diagnose.Stall.Classify (classify)
import Kenshou.Diagnose.Stall.Types
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "Kenshou.Diagnose.Stall" do
  mapM_
    fixtureCase
    [ ("deadlock", Deadlock),
      ("lock-wait", LockWait),
      ("pool-starvation", PoolStarvation),
      ("blocked-indefinitely", BlockedIndefinitely),
      ("idle-spin", IdleSpin),
      ("unknown", Unknown),
      ("postgres-unavailable", Unknown)
    ]

  it "finds a three-session wait cycle as one cycle" do
    let row pid blockers = ActivityRow pid "test" "active" (Just "Lock") (Just "transactionid") (Just 1) (Just 1) blockers "UPDATE test"
        graph = buildGraph [row 10 [11], row 11 [12], row 12 [10]] []
    graph.cycles `shouldBe` [[10, 11, 12]]

  it "reconstructs signed advisory lock keys" do
    let original = -2 :: Int64
        bits = fromIntegral original :: Word64
        high = fromIntegral (bits `div` 0x100000000) :: Word32
        low = fromIntegral bits :: Word32
    reconstructAdvisoryKey high low `shouldBe` original

  describe "PostgreSQL capture" do
    it "finds a real row-lock edge on PostgreSQL 18" (lockCaptureCase Pg18)
    it "finds a real row-lock edge on PostgreSQL 17" do
      available <- lookupEnv "KENSHOU_PG17_BIN"
      maybe (pendingWith "KENSHOU_PG17_BIN is not set") (const (lockCaptureCase Pg17)) available

  it "captures and aborts a silent scenario at the deadline" $ withSystemTempDirectory "kenshou-watchdog" \directory -> do
    runId <- either (expectationFailure . show >=> const (fail "invalid run id")) pure (parseRunId "01997f3a-5b7c-7e21-8a44-0d6c2f9b1e55")
    scenario <- either (expectationFailure . show >=> const (fail "invalid scenario id")) pure (parseScenarioId "selftest/diagnose/concurrency/watchdog")
    state <- newRunState
    let runContext = RunContext runId scenario undefined undefined undefined undefined undefined undefined undefined directory undefined state
        config = Stall.defaultWatchdogConfig {Stall.deadlineSeconds = 0.2, Stall.pollIntervalSeconds = 0.05, Stall.captureStacks = False}
    result <- try @Stall.StallDetected $ Stall.withWatchdog runContext config \watchdog -> do
      _ <- Stall.newProgress watchdog "work" True
      threadDelay 2_000_000
    result `shouldSatisfy` either (const True) (const False)
    doesFileExist (directory </> "diagnosis" </> "stall-1.json") `shouldReturn` True

fixtureCase :: (FilePath, StallClass) -> Spec
fixtureCase (name, expected) = it ("classifies the " <> name <> " snapshot") do
  decoded <- eitherDecodeFileStrict' ("test/fixtures/snapshots/" <> name <> ".json")
  case decoded of
    Left err -> expectationFailure err
    Right snapshot -> do
      let (actual, secondary, _) = classify snapshot
      actual `shouldBe` expected
      sort secondary `shouldSatisfy` (if expected == Unknown then null else elem expected)

lockCaptureCase :: PgVersion -> IO ()
lockCaptureCase version = withSystemTempDirectory "kenshou-diagnose-lock" \directory -> do
  runId <- either (expectationFailure . show >=> const (fail "invalid run id")) pure (parseRunId "01997f3a-5b7c-7e21-8a44-0d6c2f9b1e55")
  let requirement = PostgresRequirement [] [] False
      dimensions = Dimensions Nothing Nothing (Just PgFsyncOff) (Just version)
  result <- withPostgresEnv nullLogger directory runId requirement (PostgresEphemeral []) dimensions exerciseLockCapture
  case result of
    Left err -> expectationFailure (show err)
    Right () -> pure ()

exerciseLockCapture :: PostgresEnv -> IO ()
exerciseLockCapture environment =
  withConnection environment.connectionString "kenshou-diagnose-holder" \holder ->
    withConnection environment.connectionString "kenshou-diagnose-waiter" \waiter ->
      withConnection environment.connectionString "kenshou-diagnose-capture" \capture -> do
        expectSession holder (sql "CREATE TABLE diagnose_capture (id int primary key)")
        expectSession holder (sql "INSERT INTO diagnose_capture VALUES (1)")
        holderPid <- connectionPid holder
        waiterPid <- connectionPid waiter
        expectSession holder (sql "BEGIN")
        expectSession holder (sql "UPDATE diagnose_capture SET id=id WHERE id=1")
        expectSession waiter (sql "BEGIN")
        withAsync (expectSession waiter (sql "UPDATE diagnose_capture SET id=id WHERE id=1")) \waiterUpdate -> do
          finally
            ( do
                threadDelay 500_000
                activity <- captureActivity capture >>= either (expectationFailure . Text.unpack >=> const (fail "activity capture failed")) pure
                locks <- captureLocks capture >>= either (expectationFailure . Text.unpack >=> const (fail "lock capture failed")) pure
                let graph = buildGraph activity locks
                graph.edges `shouldSatisfy` any (\edge -> edge.waiter == waiterPid && edge.blocker == holderPid)
            )
            (expectSession holder (sql "ROLLBACK"))
          wait waiterUpdate
        _ <- Connection.use waiter (sql "ROLLBACK")
        pure ()

withConnection :: Text -> Text -> (Connection.Connection -> IO value) -> IO value
withConnection connectionString applicationName = bracket acquire Connection.release
  where
    acquire = do
      result <- Connection.acquire (Settings.connectionString connectionString <> Settings.applicationName applicationName)
      either (ioError . userError . show) pure result

expectSession :: Connection.Connection -> Session.Session value -> IO value
expectSession connection session = Connection.use connection session >>= either (ioError . userError . show) pure

connectionPid :: Connection.Connection -> IO Int
connectionPid connection = do
  raw <- expectSession connection (Session.statement () pidStatement)
  case reads (Text.unpack raw) of
    [(pid, "")] -> pure pid
    _ -> expectationFailure ("invalid backend pid " <> Text.unpack raw) >> fail "invalid backend pid"

pidStatement :: Statement.Statement () Text
pidStatement = Statement.unpreparable "SELECT pg_backend_pid()::text" Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.text)))

sql :: Text -> Session.Session ()
sql statement = Session.statement () (Statement.unpreparable statement Encoders.noParams Decoders.noResult)
