module Kenshou.Suite.Shibuya.Fixture.RestartLoop
  ( RestartPolicy (..),
    runWithRestartLoop,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (STM, atomically)
import Data.Time.Clock (NominalDiffTime)
import Effectful (Eff, IOE, Limit (..), Persistence (..), UnliftStrategy (..), liftIO, withEffToIO, (:>))
import Shibuya.App (AppConfig, QueueProcessor, runApp, stopApp, waitApp)
import Shibuya.Core.Metrics (ProcessorId)
import Shibuya.Telemetry.Effect (Tracing)
import System.Timeout (timeout)

data RestartPolicy = RestartPolicy
  { initialBackoff :: !NominalDiffTime,
    maxBackoff :: !NominalDiffTime,
    maxRestarts :: !(Maybe Int)
  }
  deriving stock (Eq, Show)

-- | Restart only after an application has ended. The builder may reopen a
-- durable source or replace adapters before the next run.
runWithRestartLoop ::
  (IOE :> es, Tracing :> es) =>
  RestartPolicy ->
  STM Bool ->
  (Int -> Eff es [(ProcessorId, QueueProcessor es)]) ->
  AppConfig ->
  Eff es Int
runWithRestartLoop policy stopRequested buildProcessors appConfig = go 0
  where
    go restarts = do
      stopped <- liftIO $ atomically stopRequested
      if stopped
        then pure restarts
        else do
          processors <- buildProcessors restarts
          result <- runApp appConfig processors
          case result of
            Left err -> liftIO $ ioError (userError (show err))
            Right handle -> do
              withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO ->
                let awaitEnd = do
                      done <- timeout 100000 (runInIO (waitApp handle))
                      stoppedNow <- atomically stopRequested
                      if stoppedNow || done /= Nothing then pure () else awaitEnd
                 in liftIO awaitEnd
              stopApp handle
              stoppedAfter <- liftIO $ atomically stopRequested
              if stoppedAfter || maybe False (restarts >=) policy.maxRestarts
                then pure restarts
                else do
                  let delay = min policy.maxBackoff (policy.initialBackoff * fromIntegral (2 ^ restarts :: Integer))
                  liftIO $ threadDelay (max 0 (floor (delay * 1000000)))
                  go (restarts + 1)
