module Kenshou.Env.Kafka.RedpandaContainer (withRedpandaContainer) where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, bracket, displayException, throwIO, try)
import Control.Monad (forM, unless, void)
import Data.Aeson (Value (..), decodeStrict', encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (toLower)
import Data.List (intercalate, isInfixOf)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Vector qualified as Vector
import Kafka.Types (BrokerAddress (..))
import Kenshou.Check.Fault.Network (TcpProxy, proxyPort, withTcpProxy)
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Env.Kafka.Spec (BrokerBackend (..), KafkaEnvSpec (..))
import Kenshou.Env.Kafka.Types
import Network.Socket (Family (AF_INET), SockAddr (SockAddrInet), SocketType (Stream), bind, close, defaultProtocol, socket, socketPort, tupleToHostAddress)
import System.Directory (findExecutable)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Info (os)
import System.Process (readProcessWithExitCode)

data Runtime = AppleContainer | Docker deriving stock (Eq, Show)

withRedpandaContainer :: RunContext -> KafkaEnvSpec -> FilePath -> Text -> (KafkaEnv -> IO a) -> IO a
withRedpandaContainer context spec workDir prefix action = do
  runtime <- chooseRuntime
  let listenerCount = max 1 spec.lanes
      name = "kenshou-rp-" <> Text.unpack (Text.drop 8 prefix)
      image = "docker.io/redpandadata/redpanda:v26.2.1"
  unless (Map.null spec.brokerProps) $ LazyByteString.writeFile (workDir </> "redpanda.yaml") (brokerConfig spec.brokerProps)
  writeFile (workDir </> "container-runtime") (if runtime == AppleContainer then "container" else "docker")
  writeFile (workDir </> "container-name") name
  runWithPorts runtime listenerCount name image (3 :: Int)
  where
    runWithPorts runtime listenerCount name image retries = do
      hostPorts <- forM [1 .. listenerCount] (const freePort)
      withProxies (if spec.lanes == 0 then [] else hostPorts) \proxies -> do
        let advertisedPorts = if spec.lanes == 0 then hostPorts else fmap (fromIntegral . proxyPort) proxies
            lanePorts = if spec.lanes == 0 then hostPorts else advertisedPorts
            laneValues = zipWith (\port proxy -> BrokerLane [BrokerAddress (address port)] proxy) lanePorts (if spec.lanes == 0 then [Nothing] else fmap Just proxies)
            listenerNames = ["lane" <> show index | index <- [0 .. listenerCount - 1]]
            kafkaAddr = intercalate "," (zipWith (\lane index -> lane <> "://0.0.0.0:" <> show (19092 + index)) listenerNames ([0 ..] :: [Int]))
            advertisedAddr = intercalate "," (zipWith (\lane port -> lane <> "://" <> Text.unpack (address port)) listenerNames advertisedPorts)
            publishArgs = concat (zipWith (\port index -> ["-p", "127.0.0.1:" <> show port <> ":" <> show (19092 + index)]) hostPorts ([0 ..] :: [Int]))
            mountArgs = if Map.null spec.brokerProps then [] else ["--mount", "type=bind,source=" <> workDir <> ",target=/etc/redpanda"]
            args = runtimeRunArgs runtime name (mountArgs <> publishArgs) image kafkaAddr advertisedAddr
            invoke = runRuntime runtime
            firstLane = case laneValues of lane : rest -> lane :| rest; [] -> error "Redpanda has no lane"
            probe = case firstLane of lane :| _ -> case lane.laneBrokers of value : _ -> value; [] -> error "Redpanda lane has no broker"
            await = awaitReady workDir spec.readyTimeoutSeconds probe
            status = inspect runtime name
            running = maybe False (maybe False (== "running") . lookupField (if runtime == AppleContainer then ["status", "state"] else ["State", "Status"])) <$> status
            generation = maybe "" (maybe "" id . lookupField (if runtime == AppleContainer then ["status", "startedDate"] else ["State", "StartedAt"])) <$> status
            control =
              BrokerControl
                { kill = void (invoke ["kill", name]),
                  stop = void (invoke ["stop", name]),
                  start = void (invoke ["start", name]) >> await,
                  isRunning = running,
                  generation = generation
                }
            env = KafkaEnv RedpandaContainer firstLane prefix (Just control) "redpanda:v26.2.1" workDir
        launched <- try @IOException (invoke args)
        case launched of
          Left problem -> do
            let executable = if runtime == AppleContainer then "container" else "docker"
            _ <- readProcessWithExitCode executable ["stop", name] ""
            _ <- readProcessWithExitCode executable [if runtime == AppleContainer then "delete" else "rm", name] ""
            if retries > 1 && isPortCollision problem
              then runWithPorts runtime listenerCount name image (retries - 1)
              else throwIO problem
          Right _ ->
            bracket
              (pure ())
              ( \_ -> do
                  logs <- runtimeLogs runtime name
                  writeFile (context.outDir </> "logs" </> "kafka-broker.log") logs
                  void (invoke ["stop", name])
                  unless spec.keepData (void (invoke [if runtime == AppleContainer then "delete" else "rm", name]))
              )
              (\_ -> await >> action env)

isPortCollision :: IOException -> Bool
isPortCollision problem = any (`isInfixOf` message) ["address already in use", "port is already allocated", "bind: address"]
  where
    message = fmap toLower (displayException problem)

address :: Int -> Text
address port = "127.0.0.1:" <> Text.pack (show port)

brokerConfig :: Map.Map Text Text -> LazyByteString.ByteString
brokerConfig properties =
  encode $
    object
      [ "redpanda"
          .= object
            ( ["data_directory" .= String "/var/lib/redpanda/data", "developer_mode" .= Bool True]
                <> [Key.fromText key .= fromMaybe (String value) (decodeStrict' (Text.encodeUtf8 value)) | (key, value) <- Map.toAscList properties]
            )
      ]

chooseRuntime :: IO Runtime
chooseRuntime = do
  apple <- findExecutable "container"
  docker <- findExecutable "docker"
  preference <- lookupEnv "KENSHOU_KAFKA_RUNTIME"
  case (preference, os, apple, docker) of
    (Just "container", "darwin", Just _, _) -> pure AppleContainer
    (Just "docker", _, _, Just _) -> pure Docker
    (Nothing, "darwin", Just _, _) -> pure AppleContainer
    (Nothing, _, _, Just _) -> pure Docker
    _ -> ioError (userError "private Redpanda requires Apple Container on macOS or Docker on Linux; check KENSHOU_KAFKA_RUNTIME")

runtimeRunArgs :: Runtime -> String -> [String] -> String -> String -> String -> [String]
runtimeRunArgs runtime name publishArgs image kafkaAddr advertisedAddr =
  ["run", "-d", "--name", name]
    <> (if runtime == AppleContainer then ["--platform", "linux/arm64", "-c", "2", "-m", "2G"] else [])
    <> publishArgs
    <> [ image,
         "redpanda",
         "start",
         "--node-id",
         "0",
         "--kafka-addr",
         kafkaAddr,
         "--advertise-kafka-addr",
         advertisedAddr,
         "--rpc-addr",
         "0.0.0.0:33145",
         "--advertise-rpc-addr",
         "127.0.0.1:33145",
         "--mode",
         "dev-container",
         "--smp",
         "1",
         "--default-log-level=info"
       ]

runRuntime :: Runtime -> [String] -> IO String
runRuntime runtime args = do
  let executable = if runtime == AppleContainer then "container" else "docker"
  (code, out, err) <- readProcessWithExitCode executable args ""
  case code of
    ExitSuccess -> pure out
    ExitFailure _ -> ioError (userError (executable <> " " <> unwords args <> ": " <> err))

runtimeLogs :: Runtime -> String -> IO String
runtimeLogs runtime name = do
  let executable = if runtime == AppleContainer then "container" else "docker"
  (_, out, err) <- readProcessWithExitCode executable ["logs", name] ""
  pure (out <> err)

inspect :: Runtime -> String -> IO (Maybe Value)
inspect runtime name = do
  let executable = if runtime == AppleContainer then "container" else "docker"
  (code, out, _) <- readProcessWithExitCode executable ["inspect", name] ""
  pure case code of
    ExitSuccess -> case decodeStrict' (ByteString.pack out) of
      Just (Array values) -> case Vector.toList values of value : _ -> Just value; [] -> Nothing
      _ -> Nothing
    ExitFailure _ -> Nothing

lookupField :: [Text] -> Value -> Maybe Text
lookupField [] (String value) = Just value
lookupField (key : rest) (Object value) = KeyMap.lookup (Key.fromText key) value >>= lookupField rest
lookupField _ _ = Nothing

freePort :: IO Int
freePort = bracket (socket AF_INET Stream defaultProtocol) close \socketValue -> do
  bind socketValue (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
  fromIntegral <$> socketPort socketValue

withProxies :: [Int] -> ([TcpProxy] -> IO a) -> IO a
withProxies [] action = action []
withProxies (port : rest) action =
  withTcpProxy (pure ("127.0.0.1", fromIntegral port)) \proxy ->
    withProxies rest (action . (proxy :))

awaitReady :: FilePath -> Int -> BrokerAddress -> IO ()
awaitReady workDir seconds (BrokerAddress broker) = loop (seconds * 2)
  where
    loop 0 = ioError (userError ("Redpanda did not become ready at " <> Text.unpack broker))
    loop remaining = do
      (code, _, _) <- readProcessWithExitCode "rpk" ["--config", workDir </> "rpk.yaml", "-X", "brokers=" <> Text.unpack broker, "topic", "list"] ""
      case code of
        ExitSuccess -> pure ()
        ExitFailure _ -> threadDelay 500000 >> loop (remaining - 1)
