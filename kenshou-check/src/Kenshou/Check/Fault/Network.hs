module Kenshou.Check.Fault.Network
  ( TcpProxy,
    ProxyMode (..),
    withTcpProxy,
    proxyPort,
    setProxyMode,
    resetConnections,
    proxyFault,
    proxiedConnectionString,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception (SomeException, bracket, bracketOnError, catch, finally)
import Control.Monad (forever, unless, void)
import Data.Aeson (object, (.=))
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Check.Fault
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Network.Socket
import Network.Socket.ByteString qualified as Socket

data ProxyMode = Forward | Latency Int | Throttle Int | Stall | Blackhole | RefuseNew
  deriving stock (Eq, Show)

data TcpProxy = TcpProxy
  { listening :: !Socket,
    port :: !PortNumber,
    mode :: !(TVar ProxyMode),
    connections :: !(MVar [Socket]),
    acceptor :: !(Async ())
  }

withTcpProxy :: IO (HostName, PortNumber) -> (TcpProxy -> IO value) -> IO value
withTcpProxy upstream = bracket (startProxy upstream) stopProxy

proxyPort :: TcpProxy -> PortNumber
proxyPort = (.port)

setProxyMode :: TcpProxy -> ProxyMode -> IO ()
setProxyMode proxy mode = atomically (writeTVar proxy.mode mode)

resetConnections :: TcpProxy -> IO Int
resetConnections proxy = modifyMVar proxy.connections \connections -> do
  mapM_ reset connections
  pure ([], length connections)
  where
    reset socket = (setSocketOption socket Linger 0 >> close socket) `catch` ignore

proxyFault :: TcpProxy -> ProxyMode -> Fault
proxyFault proxy mode =
  Fault
    { name = "tcp-" <> modeName mode,
      target = "tcp-proxy",
      availability = pure Available,
      inject = do
        previous <- readTVarIO proxy.mode
        setProxyMode proxy mode
        pure (FaultHandle (setProxyMode proxy previous) (object ["mode" .= modeName mode]))
    }

proxiedConnectionString :: PostgresEnv -> TcpProxy -> Text
proxiedConnectionString postgres proxy = postgres.connectionString <> " host=127.0.0.1 port=" <> Text.pack (show (fromIntegral proxy.port :: Int))

startProxy :: IO (HostName, PortNumber) -> IO TcpProxy
startProxy upstream = do
  listening <- socket AF_INET Stream defaultProtocol
  setSocketOption listening ReuseAddr 1
  bind listening (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
  listen listening 128
  port <- socketPort listening
  mode <- newTVarIO Forward
  connections <- newMVar []
  acceptor <- async (acceptLoop upstream listening mode connections)
  pure (TcpProxy listening port mode connections acceptor)

stopProxy :: TcpProxy -> IO ()
stopProxy proxy = do
  cancel proxy.acceptor
  close proxy.listening `catch` ignore
  void (resetConnections proxy)

acceptLoop upstream listening mode connections = forever do
  (downstream, _) <- accept listening
  current <- readTVarIO mode
  if current == RefuseNew
    then close downstream
    else void . async $ do
      (host, port) <- upstream
      upstreamSocket <- connectTo host port
      modifyMVar_ connections (pure . (downstream :) . (upstreamSocket :))
      race_ (pump mode downstream upstreamSocket) (pump mode upstreamSocket downstream) `finally` do
        close downstream `catch` ignore
        close upstreamSocket `catch` ignore

connectTo host port = do
  addresses <- getAddrInfo (Just defaultHints {addrSocketType = Stream}) (Just host) (Just (show (fromIntegral port :: Int)))
  case addresses of
    [] -> ioError (userError "proxy upstream did not resolve")
    address : _ -> bracketOnError (socket (addrFamily address) Stream defaultProtocol) close \socket -> connect socket (addrAddress address) >> pure socket

pump mode source destination = do
  chunk <- Socket.recv source 32768
  unless (ByteString.null chunk) do
    awaitMode mode chunk
    current <- readTVarIO mode
    case current of
      Blackhole -> pure ()
      RefuseNew -> Socket.sendAll destination chunk
      _ -> Socket.sendAll destination chunk
    pump mode source destination

awaitMode mode chunk =
  readTVarIO mode >>= \case
    Forward -> pure ()
    Latency millis -> threadDelay (millis * 1000)
    Throttle bytesPerSecond -> threadDelay (max 1 (ByteString.length chunk * 1000000 `div` max 1 bytesPerSecond))
    Stall -> atomically do current <- readTVar mode; check (current /= Stall)
    Blackhole -> pure ()
    RefuseNew -> pure ()

modeName :: ProxyMode -> Text
modeName Forward = "forward"
modeName (Latency _) = "latency"
modeName (Throttle _) = "throttle"
modeName Stall = "stall"
modeName Blackhole = "blackhole"
modeName RefuseNew = "refuse-new"

ignore :: SomeException -> IO ()
ignore _ = pure ()
