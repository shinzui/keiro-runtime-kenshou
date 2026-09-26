module Kenshou.Suite.Shibuya.Concurrency.PgmqLeaseSizing (scenario) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, displayException, try)
import Control.Monad (unless)
import Data.Aeson (Value (..), object, (.=))
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (addUTCTime, diffUTCTime, getCurrentTime)
import Effectful (liftIO)
import Hasql.Pool (Pool)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension (PgDurability (..), PgVersion (..), noDimensions, postgresDimensions)
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Suite.Shibuya.Fixture.Pgmq (PgmqFixture (..), effectRows, ensureEffectsTable, insertEffect, queueLeaseRow, queueRows, runPgmqStack, withPgmqConnectionPool, withPgmqFixture)
import Pgmq.Effectful (MessageBody (..), SendMessage (..), sendMessage)
import Pgmq.Effectful qualified as Pgmq
import Shibuya.Adapter.Pgmq (PgmqAdapterConfig (..), PollingConfig (..), defaultConfig, defaultPrefetchConfig, mkPgmqAdapterEnv, pgmqAdapter)
import Shibuya.App (AppConfig (..), QueueProcessor (..), defaultAppConfig, defaultShutdownConfig, mkProcessor, runApp, stopAppGracefully, waitApp)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Core.Types (Attempt (..), Envelope (..), MessageId (..))
import Shibuya.Policy (Concurrency (..))
import System.Timeout (timeout)
import Text.Read (readMaybe)

scenario :: Scenario
scenario =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/pgmq-adapter/concurrency/leased-bound-versus-visibility-timeout"),
      revision = 1,
      summary = "Compares queued lease age and duplicate effects under five- and thirty-second visibility timeouts.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = [],
      dimensions = postgresDimensions (PgDurable :| []) (Pg18 :| [Pg17]) noDimensions,
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaPgmq] [] False)},
      knownDefect = Nothing,
      run = runSizing
    }

data ArmEvidence = ArmEvidence
  { sent :: !Int,
    effects :: !Int,
    distinctEffects :: !Int,
    duplicates :: !Int,
    expiredWhileQueued :: !Int,
    maxReadToHandlerSeconds :: !Double,
    missingReadAges :: !Int,
    missingIds :: ![Text],
    remainingRows :: !Int64,
    completedWithinDeadline :: !Bool,
    stopped :: !Bool
  }

runSizing :: RunContext -> IO ScenarioReport
runSizing context = do
  result <- try @SomeException $ timeout 170000000 $ do
    unsafe <- runArm context "lease_unsafe" 5
    safe <- runArm context "lease_safe" 30
    pure (unsafe, safe)
  case result of
    Left err -> pure (failedWith ["lease-sizing-exception"] (Text.pack (displayException err)))
    Right Nothing -> pure (failedWith ["lease-sizing-timeout"] "The lease sizing arms exceeded 170 seconds")
    Right (Just (unsafe, safe)) -> do
      let failures =
            ["unsafe-message-loss" | not (null unsafe.missingIds) || unsafe.remainingRows /= 0]
              <> ["safe-message-loss" | not (null safe.missingIds) || safe.remainingRows /= 0]
              <> ["safe-duplicate-effect" | safe.duplicates /= 0]
              <> ["unsafe-schedule-not-reached" | unsafe.maxReadToHandlerSeconds <= 5]
              <> ["unsafe-delivery-deadline" | not unsafe.completedWithinDeadline]
              <> ["safe-delivery-deadline" | not safe.completedWithinDeadline]
              <> ["unsafe-stop-failed" | not unsafe.stopped]
              <> ["safe-stop-failed" | not safe.stopped]
      putSummary context Verdicts "pgmq-lease-sizing" $
        object
          [ "pipelineSeconds" .= (7.6 :: Double),
            "inboxSize" .= (100 :: Int),
            "workers" .= (4 :: Int),
            "prefetchBufferSize" .= (4 :: Int),
            "batchSize" .= (10 :: Int),
            "handlerSeconds" .= (0.2 :: Double),
            "unsafe" .= armValue unsafe,
            "safe" .= armValue safe
          ]
      pure $ if null failures then passed else failedWith failures (Text.intercalate "; " failures)

armValue :: ArmEvidence -> Value
armValue arm =
  object
    [ "sent" .= arm.sent,
      "effects" .= arm.effects,
      "distinctEffects" .= arm.distinctEffects,
      "duplicates" .= arm.duplicates,
      "expiredWhileQueued" .= arm.expiredWhileQueued,
      "maxReadToHandlerSeconds" .= arm.maxReadToHandlerSeconds,
      "missingReadAges" .= arm.missingReadAges,
      "missingIds" .= arm.missingIds,
      "remainingRows" .= arm.remainingRows,
      "completedWithinDeadline" .= arm.completedWithinDeadline,
      "stopped" .= arm.stopped
    ]

runArm :: RunContext -> Text -> Int -> IO ArmEvidence
runArm context arm visibility = withPgmqFixture context arm 10 $ \source ->
  withPgmqConnectionPool (requirePostgres context).connectionString 3 $ \oraclePool -> do
    ensureEffectsTable oraclePool
    identifiers <- sendAll source
    let oracle = PgmqFixture oraclePool source.queue
        config =
          (defaultConfig source.queue)
            { batchSize = 10,
              visibilityTimeout = fromIntegral visibility,
              polling = StandardPolling 0.05,
              prefetchConfig = Just defaultPrefetchConfig
            }
        handler message = do
          liftIO $ do
            let MessageId identifier = message.envelope.messageId
                attempt = maybe (-1) (\(Attempt index) -> fromIntegral index) message.envelope.attempt
                numericId = maybe (error "PGMQ message id was not numeric") id (readMaybe (Text.unpack identifier))
            startedAt <- getCurrentTime
            lease <- queueLeaseRow oracle numericId
            let readDelay = case lease of
                  Just (readCount, visibleAt)
                    | readCount == attempt + 1 -> Just (realToFrac (diffUTCTime startedAt (addUTCTime (negate (fromIntegral visibility)) visibleAt)))
                  _ -> Nothing
            threadDelay 200000
            completedAt <- getCurrentTime
            insertEffect oraclePool arm identifier attempt startedAt completedAt readDelay
          pure AckOk
    outcome <- runPgmqStack source.pool $ do
      adapterResult <- pgmqAdapter (mkPgmqAdapterEnv source.pool) config
      case adapterResult of
        Left err -> error (show err)
        Right adapter -> do
          let processor = (mkProcessor adapter handler) {concurrency = Async 4}
          started <- runApp defaultAppConfig {inboxSize = 100} [(ProcessorId ("pgmq-" <> arm), processor)]
          case started of
            Left err -> error (show err)
            Right handle -> do
              finished <- liftIO $ timeout 75000000 (waitUntil (allHandled oraclePool arm identifiers))
              stopped <- stopAppGracefully defaultShutdownConfig handle
              waitApp handle
              pure (finished /= Nothing, stopped)
    (finished, stopped) <- either (ioError . userError . show) pure outcome
    rows <- effectRows oraclePool arm
    remaining <- queueRows source
    let sentSet = Set.fromList identifiers
        observed = Map.fromListWith (+) [(identifier, 1 :: Int) | (identifier, _, _) <- rows]
        distinct = Set.size (Map.keysSet observed `Set.intersection` sentSet)
        readDelays = [delay | (_, _, Just delay) <- rows]
        missing = Set.toList (sentSet `Set.difference` Map.keysSet observed)
    pure $
      ArmEvidence
        (length identifiers)
        (length rows)
        distinct
        (sum [max 0 (count - 1) | (identifier, count) <- Map.toList observed, identifier `Set.member` sentSet])
        (length [() | delay <- readDelays, delay > fromIntegral visibility])
        (maximum (0 : readDelays))
        (length rows - length readDelays)
        missing
        remaining
        finished
        stopped

sendAll :: PgmqFixture -> IO [Text]
sendAll source = do
  result <- runPgmqStack source.pool $ traverse (\index -> sendMessage (SendMessage source.queue (MessageBody (Number (fromIntegral index))) Nothing)) [1 .. (240 :: Int)]
  either (ioError . userError . show) (pure . fmap (Text.pack . show . Pgmq.unMessageId)) result

allHandled :: Pool -> Text -> [Text] -> IO Bool
allHandled _ _ [] = pure True
allHandled pool arm identifiers = do
  rows <- effectRows pool arm
  pure (Set.fromList identifiers `Set.isSubsetOf` Set.fromList [identifier | (identifier, _, _) <- rows])

waitUntil :: IO Bool -> IO ()
waitUntil condition = do
  ready <- condition
  unless ready $ threadDelay 50000 >> waitUntil condition
