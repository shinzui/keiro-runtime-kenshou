module Kenshou.Suite.Shibuya.Correctness.PgmqAdapter (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, displayException, try)
import Data.Aeson (Value (..), object, (.=))
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as Text
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Effectful (liftIO)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension (PgDurability (..), PgVersion (..), noDimensions, postgresDimensions)
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobInt, knobText, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Suite.Shibuya.Fixture.Pgmq (PgmqFixture (..), queueRows, runPgmqStack, withPgmqFixture)
import Pgmq.Effectful (MessageBody (..), SendMessage (..), sendMessage)
import Shibuya.Adapter.Pgmq (PgmqAdapterConfig (..), PollingConfig (..), defaultConfig, mkPgmqAdapterEnv, pgmqAdapter)
import Shibuya.App (defaultAppConfig, defaultShutdownConfig, mkProcessor, runApp, stopAppGracefully, waitApp)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.Metrics (ProcessorId (..))
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [shutdownLatency]

shutdownLatency :: Scenario
shutdownLatency =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/pgmq-adapter/correctness/shutdown-latency-is-bounded-by-polling"),
      revision = 1,
      summary = "An idle PostgreSQL-backed adapter drains within its configured poll interval and can be stopped twice.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs =
        [ KnobSpec pollingKnob "Adapter polling strategy" KnobText (VText "standard:1") (OneOf (VText "standard:1" :| [VText "long:5:100"])) [],
          KnobSpec poolSizeKnob "PostgreSQL connection pool size" KnobInt (VInt 10) (IntRange 2 64) []
        ],
      dimensions = postgresDimensions (PgDurable :| []) (Pg18 :| [Pg17]) noDimensions,
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaPgmq] [] False)},
      knownDefect = Nothing,
      run = runShutdownLatency
    }
  where
    pollingKnob = either (error . Text.unpack) id (mkKnobName "pgmq-adapter.polling")
    poolSizeKnob = either (error . Text.unpack) id (mkKnobName "pgmq-adapter.pool-size")

runShutdownLatency :: RunContext -> IO ScenarioReport
runShutdownLatency context = do
  let pollMode = knobText context.knobs (name "pgmq-adapter.polling")
      poolSize = fromIntegral (knobInt context.knobs (name "pgmq-adapter.pool-size"))
      (polling, boundSeconds) = if pollMode == "long:5:100" then (LongPolling 5 100, 6 :: Double) else (StandardPolling 1, 2)
  withPgmqFixture context "shutdown" poolSize $ \fixture -> do
    probe <- runPgmqStack fixture.pool (sendMessage (SendMessage fixture.queue (MessageBody (String "shutdown-probe")) Nothing))
    case probe of
      Left err -> pure (failedWith ["pgmq-send-failed"] (Text.pack (show err)))
      Right _ -> do
        handled <- newIORef (0 :: Int)
        result <- try @SomeException $ timeout 10000000 $ runPgmqStack fixture.pool $ do
          adapterResult <- pgmqAdapter (mkPgmqAdapterEnv fixture.pool) ((defaultConfig fixture.queue) {polling})
          case adapterResult of
            Left err -> error (show err)
            Right adapter -> do
              started <- runApp defaultAppConfig [(ProcessorId "pgmq-idle-shutdown", mkProcessor adapter (\_ -> liftIO (atomicModifyIORef' handled (\n -> (n + 1, ()))) >> pure AckOk))]
              case started of
                Left err -> error (show err)
                Right handle -> do
                  liftIO $ waitForHandled handled
                  -- A completed delivery proves the source ran before the idle poll.
                  liftIO $ threadDelay 100000
                  before <- liftIO getCurrentTime
                  drained <- stopAppGracefully defaultShutdownConfig handle
                  after <- liftIO getCurrentTime
                  again <- stopAppGracefully defaultShutdownConfig handle
                  waitApp handle
                  pure (drained, again, realToFrac (diffUTCTime after before) :: Double)
        count <- readIORef handled
        remaining <- queueRows fixture
        let (failures, duration) = case result of
              Left err -> (["adapter-exception: " <> Text.pack (displayException err)], 0)
              Right Nothing -> (["adapter-shutdown-timed-out"], 0)
              Right (Just (Left err)) -> (["pgmq-runtime-error: " <> Text.pack (show err)], 0)
              Right (Just (Right (drained, again, seconds))) ->
                ( ["adapter-did-not-drain" | not drained]
                    <> ["repeated-stop-changed-result" | again /= drained]
                    <> ["shutdown-exceeded-poll-bound" | seconds > boundSeconds],
                  seconds
                )
            allFailures = failures <> ["probe-was-not-handled" | count /= 1] <> ["queue-did-not-drain" | remaining /= 0]
        putSummary context Verdicts "pgmq-shutdown-latency" $
          object ["polling" .= pollMode, "elapsedSeconds" .= duration, "boundSeconds" .= boundSeconds, "handled" .= count, "remainingRows" .= remaining]
        pure $ if null allFailures then passed else failedWith allFailures (Text.intercalate "; " allFailures)
  where
    name raw = either (error . Text.unpack) id (mkKnobName raw)

waitForHandled :: IORef Int -> IO ()
waitForHandled handled = do
  count <- readIORef handled
  if count >= 1 then pure () else threadDelay 10000 >> waitForHandled handled
