module Kenshou.Suite.Shibuya.Concurrency.PgmqPrefetchShutdown (scenario) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, wait)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, displayException, try)
import Control.Monad (unless)
import Data.Aeson (Value (..), object, (.=))
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Effectful (Limit (..), Persistence (..), UnliftStrategy (..), liftIO, withEffToIO)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension (PgDurability (..), PgVersion (..), noDimensions, postgresDimensions)
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Suite.Shibuya.Fixture.Pgmq (PgmqFixture (..), queueLeaseRows, queueRows, runPgmqStack, withPgmqFixture)
import Pgmq.Effectful (MessageBody (..), SendMessage (..), sendMessage)
import Pgmq.Effectful qualified as Pgmq
import Shibuya.Adapter.Pgmq (PgmqAdapterConfig (..), PollingConfig (..), defaultConfig, defaultPrefetchConfig, mkPgmqAdapterEnv, pgmqAdapter)
import Shibuya.App (AppConfig (..), ShutdownConfig (..), defaultAppConfig, defaultShutdownConfig, mkProcessor, runApp, stopAppGracefully, waitApp)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Core.Types (Attempt (..), Envelope (..), MessageId (..))
import System.Timeout (timeout)

scenario :: Scenario
scenario =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/pgmq-adapter/concurrency/prefetch-strands-until-visibility-timeout"),
      revision = 1,
      summary = "Prefetched but unhandled deliveries remain durable and redeliver after their visibility timeout.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions = postgresDimensions (PgDurable :| []) (Pg18 :| [Pg17]) noDimensions,
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaPgmq] [] False)},
      knownDefect = Nothing,
      run = runPrefetchShutdown
    }

data ArmEvidence = ArmEvidence
  { sent :: !Int,
    readBeforeStop :: !Int,
    stranded :: !Int,
    prompt :: !Int,
    pendingAfterStop :: !Int,
    maxRemainingVisibilitySeconds :: !Double,
    firstStopDrained :: !Bool,
    restartDrained :: !Bool,
    missingHandlers :: ![Text],
    missingRedeliveries :: ![Text]
  }

runPrefetchShutdown :: RunContext -> IO ScenarioReport
runPrefetchShutdown context = do
  outcome <- try @SomeException $ timeout 90000000 $ do
    prefetch <- runArm context "prefetch" True
    control <- runArm context "plain" False
    pure (prefetch, control)
  case outcome of
    Left err -> pure (failedWith ["prefetch-exception"] (Text.pack (displayException err)))
    Right Nothing -> pure (failedWith ["prefetch-timeout"] "Prefetch shutdown arms did not finish within 90 seconds")
    Right (Just (prefetch, control)) -> do
      let failures =
            ["prefetch-did-not-read-ahead" | prefetch.readBeforeStop <= 2]
              <> ["prefetch-left-no-leased-rows" | prefetch.stranded == 0]
              <> ["prefetch-stranded-bound" | prefetch.stranded > 10]
              <> ["prefetch-visibility-bound" | prefetch.maxRemainingVisibilitySeconds > 6.5]
              <> ["prefetch-control-not-read" | control.readBeforeStop < 2]
              <> ["prefetch-did-not-increase-read-ahead" | prefetch.readBeforeStop <= control.readBeforeStop]
              <> ["prefetch-did-not-increase-stranding" | prefetch.stranded <= control.stranded]
              <> ["prefetch-stop-was-not-forced" | prefetch.firstStopDrained || control.firstStopDrained]
              <> ["prefetch-restart-not-drained" | not prefetch.restartDrained || not control.restartDrained]
              <> ["prefetch-lost-message" | not (null prefetch.missingHandlers) || not (null control.missingHandlers)]
              <> ["prefetch-did-not-redeliver" | not (null prefetch.missingRedeliveries) || not (null control.missingRedeliveries)]
      putSummary context Verdicts "pgmq-prefetch-shutdown" $
        object
          [ "prefetch" .= armValue prefetch,
            "control" .= armValue control,
            "visibilityTimeoutSeconds" .= (6 :: Int),
            "prefetchBatchSize" .= (2 :: Int),
            "controlBatchSize" .= (2 :: Int),
            "prefetchBufferSize" .= (4 :: Int)
          ]
      pure $ if null failures then passed else failedWith failures (Text.intercalate "; " failures)

armValue :: ArmEvidence -> Value
armValue evidence =
  object
    [ "sent" .= evidence.sent,
      "readBeforeStop" .= evidence.readBeforeStop,
      "stranded" .= evidence.stranded,
      "prompt" .= evidence.prompt,
      "pendingAfterStop" .= evidence.pendingAfterStop,
      "maxRemainingVisibilitySeconds" .= evidence.maxRemainingVisibilitySeconds,
      "firstStopDrained" .= evidence.firstStopDrained,
      "restartDrained" .= evidence.restartDrained,
      "missingHandlers" .= evidence.missingHandlers,
      "missingRedeliveries" .= evidence.missingRedeliveries
    ]

runArm :: RunContext -> Text -> Bool -> IO ArmEvidence
runArm context suffix prefetchEnabled = withPgmqFixture context suffix 10 $ \source -> do
  identifiers <- sendAll source
  seen <- newIORef (Map.empty :: Map Text [Maybe Attempt])
  calls <- newIORef (0 :: Int)
  entered <- newEmptyMVar
  release <- newEmptyMVar
  let config =
        (defaultConfig source.queue)
          { batchSize = 2,
            visibilityTimeout = 6,
            polling = StandardPolling 0.05,
            maxRetries = 10,
            prefetchConfig = if prefetchEnabled then Just defaultPrefetchConfig else Nothing
          }
      handler message = do
        liftIO $ do
          record seen message
          call <- atomicModifyIORef' calls (\n -> (n + 1, n))
          whenFirst call $ putMVar entered () >> takeMVar release
          threadDelay 400000
        pure AckOk
  first <- runPgmqStack source.pool $ do
    adapter <- pgmqAdapter (mkPgmqAdapterEnv source.pool) config
    case adapter of
      Left err -> error (show err)
      Right messageSource -> do
        started <- runApp defaultAppConfig {inboxSize = 1} [(ProcessorId ("pgmq-" <> suffix), mkProcessor messageSource handler)]
        case started of
          Left err -> error (show err)
          Right handle -> do
            ready <- liftIO $ timeout 5000000 (takeMVar entered)
            case ready of
              Nothing -> do
                _ <- stopAppGracefully defaultShutdownConfig {drainTimeout = 0.2} handle
                waitApp handle
                error "first handler did not start"
              Just () -> do
                readAhead <-
                  liftIO $
                    timeout
                      5000000
                      ( waitUntil $ do
                          rows <- queueLeaseRows source
                          pure (length [() | (_, readCount, _) <- rows, readCount > 0] >= (if prefetchEnabled then 3 else 2))
                      )
                case readAhead of
                  Nothing -> do
                    liftIO $ putMVar release ()
                    _ <- stopAppGracefully defaultShutdownConfig {drainTimeout = 0.2} handle
                    waitApp handle
                    error "adapter did not read the expected batch"
                  Just () -> do
                    before <- liftIO $ queueLeaseRows source
                    (after, observedAt, drained) <- withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO -> liftIO $ do
                      stopping <- async (runInIO (stopAppGracefully defaultShutdownConfig {drainTimeout = 0.2} handle))
                      threadDelay 100000
                      putMVar release ()
                      drained <- wait stopping
                      runInIO (waitApp handle)
                      after <- queueLeaseRows source
                      observedAt <- getCurrentTime
                      pure (after, observedAt, drained)
                    pure (before, after, observedAt, drained)
  (before, after, observedAt, drained) <- either (ioError . userError . show) pure first
  let strandedIds = [Text.pack (show identifier) | (identifier, readCount, vt) <- after, readCount > 0, diffUTCTime vt observedAt > 0.5]
      promptCount = length [() | (_, readCount, vt) <- after, readCount > 0, diffUTCTime vt observedAt <= 0.5]
      maxVisibilityWait = maximum (0 : [realToFrac (diffUTCTime vt observedAt) | (_, readCount, vt) <- after, readCount > 0])
      restartConfig = config {prefetchConfig = Nothing}
  restarted <- runPgmqStack source.pool $ do
    adapter <- pgmqAdapter (mkPgmqAdapterEnv source.pool) restartConfig
    case adapter of
      Left err -> error (show err)
      Right messageSource -> do
        started <- runApp defaultAppConfig [(ProcessorId ("pgmq-" <> suffix <> "-restart"), mkProcessor messageSource (\message -> liftIO (record seen message) >> pure AckOk))]
        case started of
          Left err -> error (show err)
          Right handle -> do
            finished <- liftIO $ timeout 20000000 (waitUntil ((== 0) <$> queueRows source))
            stopped <- stopAppGracefully defaultShutdownConfig handle
            waitApp handle
            pure (finished /= Nothing && stopped)
  restartDrained <- either (ioError . userError . show) pure restarted
  observations <- readIORef seen
  pure $
    ArmEvidence
      (length identifiers)
      (length [() | (_, readCount, _) <- before, readCount > 0])
      (length strandedIds)
      promptCount
      (length after)
      maxVisibilityWait
      drained
      restartDrained
      [identifier | identifier <- identifiers, Map.notMember identifier observations]
      [identifier | identifier <- strandedIds, not (any (>= Just (Attempt 1)) (Map.findWithDefault [] identifier observations))]

sendAll :: PgmqFixture -> IO [Text]
sendAll source = do
  result <- runPgmqStack source.pool $ traverse (\index -> sendMessage (SendMessage source.queue (MessageBody (Number (fromIntegral index))) Nothing)) [1 .. (20 :: Int)]
  either (ioError . userError . show) (pure . fmap (Text.pack . show . Pgmq.unMessageId)) result

record :: IORef (Map Text [Maybe Attempt]) -> Message es Value -> IO ()
record seen message = do
  let MessageId identifier = message.envelope.messageId
  atomicModifyIORef' seen (\items -> (Map.insertWith (<>) identifier [message.envelope.attempt] items, ()))

whenFirst :: Int -> IO () -> IO ()
whenFirst index action = if index == 0 then action else pure ()

waitUntil :: IO Bool -> IO ()
waitUntil condition = do
  ready <- condition
  unless ready $ threadDelay 10000 >> waitUntil condition
