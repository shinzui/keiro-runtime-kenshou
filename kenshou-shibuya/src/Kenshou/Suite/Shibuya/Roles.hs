module Kenshou.Suite.Shibuya.Roles (roles, runGcMode) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, poll)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (displayException, finally, throwIO)
import Control.Monad (replicateM_)
import Data.Aeson (Value, object, withObject, (.:), (.=))
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (IOE, liftIO, runEff)
import Kenshou.Core.Role (ControlMessage (..), RoleContext (..), RoleName, WorkerInit (..), WorkerMessage (..), WorkerRole (..), mkRoleName)
import Kenshou.Suite.Shibuya.Fixture.PgmqProducer qualified as PgmqProducer
import Kenshou.Suite.Shibuya.Fixture.PgmqWorker qualified as PgmqWorker
import Shibuya.Adapter (Adapter (..))
import Shibuya.App (AppConfig (..), SupervisionStrategy (..), defaultAppConfig, mkProcessor, runApp, waitApp)
import Shibuya.Core.Ack (AckDecision (..), HaltReason (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested, mkIngested)
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Core.Types (MessageId (..), mkEnvelope)
import Shibuya.Handler (Handler)
import Shibuya.Telemetry.Effect (Tracing, runTracingNoop)
import Streamly.Data.Stream qualified as Stream
import System.Mem (performMajorGC)
import System.Timeout (timeout)

roles :: [WorkerRole]
roles = [WorkerRole gcRoleName "Probes Shibuya caller liveness after dropping an application handle." gcProbe, PgmqWorker.role, PgmqProducer.role]

gcRoleName :: RoleName
gcRoleName = either (error . Text.unpack) id (mkRoleName "shibuya/gc-probe")

gcProbe :: RoleContext -> IO ()
gcProbe context = do
  mode <- either (ioError . userError) pure (parseEither parseMode context.init.args)
  context.send WrkReady
  awaitStart
  runGcMode mode
  context.send (WrkCustom "survived" (object ["mode" .= mode]))
  awaitStop
  where
    awaitStart =
      context.receive >>= \case
        Just CtlStart -> pure ()
        Just (CtlStop _) -> ioError (userError "GC probe stopped before start")
        Nothing -> ioError (userError "GC probe parent disconnected before start")
        _ -> awaitStart
    awaitStop =
      context.receive >>= \case
        Just (CtlStop _) -> pure ()
        Nothing -> ioError (userError "GC probe parent disconnected before stop")
        _ -> awaitStop

runGcMode :: Text -> IO ()
runGcMode mode =
  case mode of
    "live-idle" -> liveIdle
    "finite-ignore" -> finished IgnoreFailures (finite 5) (const (pure AckOk))
    "finite-stop-all" -> finished StopAllOnFailure (finite 5) (const (pure AckOk))
    "halted" -> finished IgnoreFailures oneThenIdle (const (pure (AckHalt (HaltFatal "gc probe"))))
    "failed-source" -> finished IgnoreFailures failedSource (const (pure AckOk))
    _ -> ioError (userError ("unknown GC probe mode: " <> Text.unpack mode))

parseMode :: Value -> Parser Text
parseMode = withObject "GC probe arguments" (.: "mode")

-- The completed AppHandle goes out of scope before collections. Holding it in
-- the harness would mask the childless-supervisor regression.
finished :: SupervisionStrategy -> Adapter '[Tracing, IOE] ByteString -> Handler '[Tracing, IOE] ByteString -> IO ()
finished strategy adapter handler = do
  runEff $ runTracingNoop $ do
    result <- runApp defaultAppConfig {strategy = strategy} [(ProcessorId "gc-probe", mkProcessor adapter handler)]
    case result of
      Left err -> liftIO $ ioError (userError (show err))
      Right app -> waitApp app
  collections

liveIdle :: IO ()
liveIdle = do
  started <- newEmptyMVar
  caller <- async $ runEff $ runTracingNoop $ do
    result <- runApp defaultAppConfig [(ProcessorId "gc-probe-idle", mkProcessor idleSource (const (pure AckOk)))]
    case result of
      Left err -> liftIO $ ioError (userError (show err))
      Right app -> liftIO (putMVar started ()) >> waitApp app
  ( do
      ready <- timeout 5000000 (takeMVar started)
      case ready of
        Nothing -> ioError (userError "idle application did not start")
        Just () -> pure ()
      collections
      outcome <- poll caller
      case outcome of
        Nothing -> pure ()
        Just (Left err) -> throwIO (userError ("idle caller died during GC: " <> displayException err))
        Just (Right ()) -> ioError (userError "idle application finished during GC")
    )
    `finally` cancel caller

collections :: IO ()
collections = do
  replicateM_ 50 $ threadDelay 10000 >> performMajorGC
  threadDelay 200000

message :: Int -> Ingested '[Tracing, IOE] ByteString
message index = mkIngested (mkEnvelope (MessageId (Text.pack ("gc-" <> show index))) "payload") (AckHandle (const (pure ())))

finite :: Int -> Adapter '[Tracing, IOE] ByteString
finite count = Adapter "gc-probe:finite" (Stream.fromList (map message [1 .. count])) (pure ())

failedSource :: Adapter '[Tracing, IOE] ByteString
failedSource = Adapter "gc-probe:failed" (Stream.fromEffect (liftIO (ioError (userError "scripted source failure")))) (pure ())

oneThenIdle :: Adapter '[Tracing, IOE] ByteString
oneThenIdle = Adapter "gc-probe:halt" (Stream.unfoldrM step (0 :: Int)) (pure ())
  where
    step 0 = pure (Just (message 0, 1))
    step _ = liftIO (threadDelay 60000000) >> pure Nothing

idleSource :: Adapter '[Tracing, IOE] ByteString
idleSource = Adapter "gc-probe:idle" (Stream.fromEffect (liftIO (threadDelay 60000000) >> pure (message 0))) (pure ())
