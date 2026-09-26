module Kenshou.Suite.Shibuya.Concurrency.PgmqPoolStarvation (scenario) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, displayException, try)
import Control.Monad (unless, when)
import Data.Aeson (Value (..), object, (.=))
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as Text
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Effectful (Eff, IOE, liftIO, (:>))
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension (PgDurability (..), PgVersion (..), noDimensions, postgresDimensions)
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (CohortScope (..), KnownDefect (..), PackageCondition (..), Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Suite.Shibuya.Fixture.Pgmq (PgmqFixture (..), activeLongPolls, queueRows, runPgmqStack, withPgmqFixture)
import Pgmq.Effectful (MessageBody (..), SendMessage (..), sendMessage)
import Shibuya.Adapter.Pgmq (PgmqAdapterConfig (..), PgmqAdapterEnv (..), PollingConfig (..), defaultConfig, directDeadLetter, mkPgmqAdapterEnv, pgmqAdapter)
import Shibuya.App (defaultAppConfig, defaultShutdownConfig, mkProcessor, runApp, stopAppGracefully, waitApp)
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..))
import Shibuya.Core.Metrics (ProcessorId (..))
import System.Timeout (timeout)

scenario :: Scenario
scenario =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/pgmq-adapter/concurrency/long-poll-pool-starvation"),
      revision = 1,
      summary = "Two long-polling processors share a two-connection pool while acknowledging and moving messages to a DLQ.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions = postgresDimensions (PgDurable :| []) (Pg18 :| [Pg17]) noDimensions,
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaPgmq] [] False)},
      knownDefect =
        Just $
          KnownDefect
            { reference = "mori://shinzui/shibuya-pgmq-adapter/okf/bug-reports/concepts/BUG-1",
              summary = "Long polls can defer AckOk and transactional dead-letter acknowledgement until shutdown",
              expectedFailures = ["acknowledgement-deadline"],
              appliesTo = OnlyWhen (VersionBelow "shibuya-pgmq-adapter" "0.16.1.0" :| [])
            },
      run = runPoolStarvation
    }

data PoolEvidence = PoolEvidence
  { firstCalls :: !Int,
    secondCalls :: !Int,
    ackFailures :: !Int,
    firstAckSeconds :: !(Maybe Double),
    secondAckSeconds :: !(Maybe Double),
    overallUpperBoundSeconds :: !(Maybe Double),
    beforeStopFirstRows :: !Int,
    beforeStopSecondRows :: !Int,
    beforeStopDeadLetterRows :: !Int,
    beforeStopActiveLongPolls :: !Int,
    firstRows :: !Int,
    secondRows :: !Int,
    deadLetterRows :: !Int,
    drained :: !Bool,
    completed :: !Bool
  }

runPoolStarvation :: RunContext -> IO ScenarioReport
runPoolStarvation context = do
  outcome <- try @SomeException $
    timeout 45000000 $
      withPgmqFixture context "poll_first" 2 $ \first ->
        withPgmqFixture context "poll_second" 2 $ \second ->
          withPgmqFixture context "poll_dlq" 2 $ \dlq -> runArms first second dlq
  case outcome of
    Left err -> pure (failedWith ["long-poll-exception"] (Text.pack (displayException err)))
    Right Nothing -> pure (failedWith ["long-poll-timed-out"] "Two long-polling processors did not finish within 45 seconds")
    Right (Just evidence) -> do
      let failures =
            ["first-handler-count" | evidence.firstCalls /= 1]
              <> ["second-handler-count" | evidence.secondCalls /= 1]
              <> ["ack-failure-hook-fired" | evidence.ackFailures /= 0]
              <> ["first-source-not-drained" | evidence.firstRows /= 0]
              <> ["second-source-not-drained" | evidence.secondRows /= 0]
              <> ["dead-letter-copy-count" | evidence.deadLetterRows /= 1]
              <> ["application-did-not-drain" | not evidence.drained]
              <> ["acknowledgement-deadline" | not evidence.completed]
      putSummary context Verdicts "pgmq-long-poll-pool" $
        object
          [ "poolSize" .= (2 :: Int),
            "polling" .= ("long:5:100" :: Text.Text),
            "acquisitionTimeoutSeconds" .= (5 :: Int),
            "firstHandlerCalls" .= evidence.firstCalls,
            "secondHandlerCalls" .= evidence.secondCalls,
            "ackFailureCalls" .= evidence.ackFailures,
            "firstAckSeconds" .= evidence.firstAckSeconds,
            "secondAckSeconds" .= evidence.secondAckSeconds,
            "acknowledgementUpperBoundSeconds" .= evidence.overallUpperBoundSeconds,
            "beforeStopFirstRows" .= evidence.beforeStopFirstRows,
            "beforeStopSecondRows" .= evidence.beforeStopSecondRows,
            "beforeStopDeadLetterRows" .= evidence.beforeStopDeadLetterRows,
            "beforeStopActiveLongPolls" .= evidence.beforeStopActiveLongPolls,
            "firstSourceRows" .= evidence.firstRows,
            "secondSourceRows" .= evidence.secondRows,
            "deadLetterRows" .= evidence.deadLetterRows,
            "completed" .= evidence.completed
          ]
      pure $ if null failures then passed else failedWith failures (Text.intercalate "; " failures)

runArms :: PgmqFixture -> PgmqFixture -> PgmqFixture -> IO PoolEvidence
runArms first second dlq = do
  let observedFirst = PgmqFixture second.pool first.queue
  firstCalls <- newIORef (0 :: Int)
  secondCalls <- newIORef (0 :: Int)
  firstAt <- newIORef Nothing
  secondAt <- newIORef Nothing
  firstAckAt <- newIORef Nothing
  secondAckAt <- newIORef Nothing
  ackFailures <- newIORef (0 :: Int)
  let environment =
        (mkPgmqAdapterEnv first.pool)
          { onAckFailure = \_ _ -> atomicModifyIORef' ackFailures (\n -> (n + 1, ()))
          }
      firstConfig = (defaultConfig first.queue) {polling = LongPolling 5 100}
      secondConfig =
        (defaultConfig second.queue)
          { polling = LongPolling 5 100,
            deadLetterConfig = Just (directDeadLetter dlq.queue True)
          }
      finalState = do
        sourceRows <- queueRows observedFirst
        otherRows <- queueRows second
        deadLetters <- queueRows dlq
        now <- getCurrentTime
        whenZero sourceRows firstAckAt now
        whenZero otherRows secondAckAt now
        pure (sourceRows == 0 && otherRows == 0 && deadLetters == 1)
  result <- runPgmqStack first.pool $ do
    firstAdapter <- pgmqAdapter environment firstConfig
    secondAdapter <- pgmqAdapter environment secondConfig
    case (firstAdapter, secondAdapter) of
      (Right firstSource, Right secondSource) -> do
        started <-
          runApp
            defaultAppConfig
            [ (ProcessorId "pgmq-long-poll-first", mkProcessor firstSource (\_ -> recordCall firstCalls firstAt >> pure AckOk)),
              (ProcessorId "pgmq-long-poll-second", mkProcessor secondSource (\_ -> recordCall secondCalls secondAt >> pure (AckDeadLetter (PoisonPill "pool contention"))))
            ]
        case started of
          Left err -> error (show err)
          Right handle -> do
            pollsReady <- liftIO $ timeout 8000000 (waitUntil ((>= 2) <$> activeLongPolls second))
            case pollsReady of
              Nothing -> do
                _ <- stopAppGracefully defaultShutdownConfig handle
                waitApp handle
                error "two long polls were not active together"
              Just () -> do
                liftIO $ send first second
                completed <- liftIO $ timeout 25000000 (waitUntil finalState)
                observedAt <- liftIO getCurrentTime
                beforeStop <- liftIO $ (,,,) <$> queueRows observedFirst <*> queueRows second <*> queueRows dlq <*> activeLongPolls second
                drained <- stopAppGracefully defaultShutdownConfig handle
                waitApp handle
                case completed of
                  Nothing -> pure (observedAt, drained, False, beforeStop)
                  Just () -> pure (observedAt, drained, True, beforeStop)
      (Left err, _) -> error (show err)
      (_, Left err) -> error (show err)
  (observedAt, drained, completed, (beforeFirst, beforeSecond, beforeDlq, beforePolls)) <- either (ioError . userError . show) pure result
  countFirst <- readIORef firstCalls
  countSecond <- readIORef secondCalls
  failureCount <- readIORef ackFailures
  startedFirst <- readIORef firstAt
  startedSecond <- readIORef secondAt
  completedFirst <- readIORef firstAckAt
  completedSecond <- readIORef secondAckAt
  sourceRows <- queueRows observedFirst
  otherRows <- queueRows second
  deadLetters <- queueRows dlq
  pure $
    PoolEvidence
      countFirst
      countSecond
      failureCount
      (latency startedFirst completedFirst)
      (latency startedSecond completedSecond)
      (if completed then Just (maximum (0 : [realToFrac (diffUTCTime observedAt began) | Just began <- [startedFirst, startedSecond]])) else Nothing)
      (fromIntegral beforeFirst)
      (fromIntegral beforeSecond)
      (fromIntegral beforeDlq)
      (fromIntegral beforePolls)
      (fromIntegral sourceRows)
      (fromIntegral otherRows)
      (fromIntegral deadLetters)
      drained
      completed

whenZero :: Int64 -> IORef (Maybe UTCTime) -> UTCTime -> IO ()
whenZero rows observedAt now =
  when (rows == 0) $ atomicModifyIORef' observedAt (\value -> (Just (maybe now id value), ()))

latency :: Maybe UTCTime -> Maybe UTCTime -> Maybe Double
latency (Just began) (Just ended) = Just (realToFrac (diffUTCTime ended began))
latency _ _ = Nothing

recordCall :: (IOE :> es) => IORef Int -> IORef (Maybe UTCTime) -> Eff es ()
recordCall calls startedAt = liftIO $ do
  now <- getCurrentTime
  atomicModifyIORef' calls (\n -> (n + 1, ()))
  atomicModifyIORef' startedAt (\value -> (Just (maybe now id value), ()))

send :: PgmqFixture -> PgmqFixture -> IO ()
send first second = do
  firstSent <- runPgmqStack second.pool (sendMessage (SendMessage first.queue (MessageBody (String "first")) Nothing))
  secondSent <- runPgmqStack second.pool (sendMessage (SendMessage second.queue (MessageBody (String "second")) Nothing))
  either (ioError . userError . show) (const (pure ())) firstSent
  either (ioError . userError . show) (const (pure ())) secondSent

waitUntil :: IO Bool -> IO ()
waitUntil condition = do
  ready <- condition
  unless ready $ threadDelay 10000 >> waitUntil condition
