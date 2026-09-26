module Kenshou.Suite.Shibuya.Concurrency.PgmqShutdownRelease (scenario) where

import Control.Concurrent.Async (wait, withAsync)
import Control.Exception (SomeException, displayException, try)
import Data.Aeson (Value (..), object, (.=))
import Data.ByteString.Char8 qualified as ByteString
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as Text
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Data.Vector qualified as Vector
import Effectful (Limit (..), Persistence (..), UnliftStrategy (..), liftIO, withEffToIO)
import Kenshou.Check.Fault.Network (armResponseBarrier, proxiedConnectionString, queryBarrierReached, releaseResponseBarrier, withTcpProxy)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension (PgDurability (..), PgVersion (..), noDimensions, postgresDimensions)
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Suite.Shibuya.Fixture.Pgmq (PgmqFixture (..), queueLeaseRows, queueRows, runPgmqStack, withPgmqConnectionPool, withPgmqFixture)
import Pgmq.Effectful (Message (..), MessageBody (..), ReadMessage (..), SendMessage (..), readMessage, sendMessage)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Pgmq (PgmqAdapterConfig (..), PollingConfig (..), defaultConfig, mkPgmqAdapterEnv, pgmqAdapter)
import Streamly.Data.Stream qualified as Stream
import System.Timeout (timeout)

scenario :: Scenario
scenario =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/pgmq-adapter/concurrency/shutdown-releases-read-chunk"),
      revision = 1,
      summary = "A read chunk held on the wire is released promptly when shutdown reaches the adapter first.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions = postgresDimensions (PgDurable :| []) (Pg18 :| [Pg17]) noDimensions,
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaPgmq] [] False)},
      knownDefect = Nothing,
      run = runShutdownRelease
    }

runShutdownRelease :: RunContext -> IO ScenarioReport
runShutdownRelease context = do
  outcome <- try @SomeException $ timeout 20000000 $ withPgmqFixture context "shutdown_release" 2 $ \source -> do
    let postgres = requirePostgres context
        endpoint = maybe (error "PostgreSQL TCP endpoint unavailable") (\(host, port) -> pure (Text.unpack host, fromIntegral port)) postgres.tcpEndpoint
        marker = "kenshou_shutdown_release_probe"
    sent <- runPgmqStack source.pool (sendMessage (SendMessage source.queue (MessageBody (String marker)) Nothing))
    either (ioError . userError . show) (const (pure ())) sent
    withTcpProxy endpoint $ \proxy -> do
      let connection = proxiedConnectionString postgres proxy
          config = (defaultConfig source.queue) {batchSize = 1, visibilityTimeout = 8, polling = StandardPolling 0.05}
      withPgmqConnectionPool connection 2 $ \consumerPool -> do
        barrier <- armResponseBarrier proxy (ByteString.pack (Text.unpack marker))
        result <- runPgmqStack consumerPool $ do
          adapterResult <- pgmqAdapter (mkPgmqAdapterEnv consumerPool) config
          case adapterResult of
            Left err -> error (show err)
            Right adapter -> withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO -> liftIO $
              withAsync (runInIO (Stream.toList adapter.source)) $ \reader -> do
                reached <- timeout 5000000 (queryBarrierReached barrier)
                before <- queueLeaseRows source
                runInIO adapter.shutdown
                releaseResponseBarrier proxy barrier
                delivered <- timeout 5000000 (wait reader)
                after <- queueLeaseRows source
                observedAt <- getCurrentTime
                pure (reached /= Nothing, before, delivered, after, observedAt)
        (reached, before, delivered, after, observedAt) <- either (ioError . userError . show) pure result
        visible <- runPgmqStack source.pool (readMessage (ReadMessage source.queue 8 (Just 1) Nothing))
        returned <- either (ioError . userError . show) (pure . Vector.toList) visible
        remaining <- queueRows source
        pure (reached, before, delivered, after, observedAt, returned, remaining)
  case outcome of
    Left err -> pure (failedWith ["shutdown-release-exception"] (Text.pack (displayException err)))
    Right Nothing -> pure (failedWith ["shutdown-release-timeout"] "The read-to-shutdown control exceeded 20 seconds")
    Right (Just (reached, before, delivered, after, observedAt, returned, remaining)) -> do
      let readBefore = [readCount | (_, readCount, _) <- before, readCount > 0]
          readAfter = [readCount | (_, readCount, _) <- after, readCount > 0]
          secondsRemaining = [realToFrac (diffUTCTime vt observedAt) :: Double | (_, readCount, vt) <- after, readCount > 0]
          returnCounts = map (.readCount) returned
          failures =
            ["response-barrier-not-reached" | not reached]
              <> ["read-not-visible-at-barrier" | readBefore /= [1]]
              <> ["source-delivered-after-shutdown" | maybe True (not . null) delivered]
              <> ["read-count-changed-during-release" | readAfter /= [1]]
              <> ["chunk-not-released-promptly" | not (all (<= 0.5) secondsRemaining) || null secondsRemaining]
              <> ["released-row-not-redelivered" | returnCounts /= [2]]
              <> ["source-row-not-durable" | remaining /= 1]
      putSummary context Verdicts "pgmq-shutdown-release" $
        object
          [ "responseBarrierReached" .= reached,
            "readCountsAtBarrier" .= readBefore,
            "adapterDeliveredAfterShutdown" .= fmap length delivered,
            "readCountsAfterRelease" .= readAfter,
            "remainingVisibilitySeconds" .= secondsRemaining,
            "readCountsOnImmediateRedelivery" .= returnCounts,
            "remainingRows" .= remaining
          ]
      pure $ if null failures then passed else failedWith failures (Text.intercalate "; " failures)
