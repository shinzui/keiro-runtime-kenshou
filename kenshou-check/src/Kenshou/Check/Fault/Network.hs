module Kenshou.Check.Fault.Network
  ( TcpProxy,
    QueryBarrier,
    ProxyMode (..),
    withTcpProxy,
    proxyPort,
    setProxyMode,
    armQueryBarrier,
    armResponseBarrier,
    queryBarrierReached,
    releaseQueryBarrier,
    releaseResponseBarrier,
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
import Control.Monad (forever, unless, void, when)
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
    queryBarrier :: !(TVar (Maybe QueryBarrier)),
    responseBarrier :: !(TVar (Maybe QueryBarrier)),
    connections :: !(MVar [Socket]),
    acceptor :: !(Async ())
  }

data QueryBarrier = QueryBarrier
  { needle :: !ByteString.ByteString,
    reached :: !(MVar ()),
    resume :: !(MVar ()),
    armed :: !(TVar Bool)
  }

withTcpProxy :: IO (HostName, PortNumber) -> (TcpProxy -> IO value) -> IO value
withTcpProxy upstream = bracket (startProxy upstream) stopProxy

proxyPort :: TcpProxy -> PortNumber
proxyPort = (.port)

setProxyMode :: TcpProxy -> ProxyMode -> IO ()
setProxyMode proxy mode = atomically (writeTVar proxy.mode mode)

-- | Hold the first downstream SQL request containing the supplied bytes before
-- forwarding it to PostgreSQL. The caller can change database state after
-- 'queryBarrierReached' and then release the exact request boundary.
armQueryBarrier :: TcpProxy -> ByteString.ByteString -> IO QueryBarrier
armQueryBarrier proxy = armBarrier proxy.queryBarrier

-- | Hold the first upstream response containing the supplied bytes before
-- forwarding it to the client. Useful for stopping an adapter after PostgreSQL
-- has read a row but before the adapter receives that row.
armResponseBarrier :: TcpProxy -> ByteString.ByteString -> IO QueryBarrier
armResponseBarrier proxy = armBarrier proxy.responseBarrier

armBarrier :: TVar (Maybe QueryBarrier) -> ByteString.ByteString -> IO QueryBarrier
armBarrier barrierSlot needle = do
  reached <- newEmptyMVar
  resume <- newEmptyMVar
  armed <- newTVarIO True
  let barrier = QueryBarrier needle reached resume armed
  atomically (writeTVar barrierSlot (Just barrier))
  pure barrier

queryBarrierReached :: QueryBarrier -> IO ()
queryBarrierReached = readMVar . (.reached)

releaseQueryBarrier :: TcpProxy -> QueryBarrier -> IO ()
releaseQueryBarrier proxy = releaseBarrier proxy.queryBarrier

releaseResponseBarrier :: TcpProxy -> QueryBarrier -> IO ()
releaseResponseBarrier proxy = releaseBarrier proxy.responseBarrier

releaseBarrier :: TVar (Maybe QueryBarrier) -> QueryBarrier -> IO ()
releaseBarrier barrierSlot barrier = do
  atomically (writeTVar barrierSlot Nothing)
  void (tryPutMVar barrier.resume ())

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
  queryBarrier <- newTVarIO Nothing
  responseBarrier <- newTVarIO Nothing
  connections <- newMVar []
  acceptor <- async (acceptLoop upstream listening mode queryBarrier responseBarrier connections)
  pure (TcpProxy listening port mode queryBarrier responseBarrier connections acceptor)

stopProxy :: TcpProxy -> IO ()
stopProxy proxy = do
  cancel proxy.acceptor
  close proxy.listening `catch` ignore
  void (resetConnections proxy)

acceptLoop :: IO (HostName, PortNumber) -> Socket -> TVar ProxyMode -> TVar (Maybe QueryBarrier) -> TVar (Maybe QueryBarrier) -> MVar [Socket] -> IO ()
acceptLoop upstream listening mode queryBarrier responseBarrier connections = forever do
  (downstream, _) <- accept listening
  current <- readTVarIO mode
  if current == RefuseNew
    then close downstream
    else void . async $ do
      (host, port) <- upstream
      upstreamSocket <- connectTo host port
      modifyMVar_ connections (pure . (downstream :) . (upstreamSocket :))
      race_ (pump mode queryBarrier downstream upstreamSocket) (pump mode responseBarrier upstreamSocket downstream) `finally` do
        close downstream `catch` ignore
        close upstreamSocket `catch` ignore

connectTo host port = do
  addresses <- getAddrInfo (Just defaultHints {addrSocketType = Stream}) (Just host) (Just (show (fromIntegral port :: Int)))
  case addresses of
    [] -> ioError (userError "proxy upstream did not resolve")
    address : _ -> bracketOnError (socket (addrFamily address) Stream defaultProtocol) close \socket -> connect socket (addrAddress address) >> pure socket

pump :: TVar ProxyMode -> TVar (Maybe QueryBarrier) -> Socket -> Socket -> IO ()
pump mode barrier source destination = go ByteString.empty
  where
    go carry = do
      chunk <- Socket.recv source 32768
      unless (ByteString.null chunk) do
        nextCarry <- pauseOnQuery barrier carry chunk
        awaitMode mode chunk
        current <- readTVarIO mode
        case current of
          Blackhole -> pure ()
          RefuseNew -> Socket.sendAll destination chunk
          _ -> Socket.sendAll destination chunk
        go nextCarry

pauseOnQuery :: TVar (Maybe QueryBarrier) -> ByteString.ByteString -> ByteString.ByteString -> IO ByteString.ByteString
pauseOnQuery currentBarrier carry chunk =
  readTVarIO currentBarrier >>= \case
    Nothing -> pure ByteString.empty
    Just barrier -> do
      let combined = carry <> chunk
          keep = max 0 (ByteString.length barrier.needle - 1)
          nextCarry = ByteString.drop (max 0 (ByteString.length combined - keep)) combined
      when (barrier.needle `ByteString.isInfixOf` combined) do
        claimed <- atomically do
          pending <- readTVar barrier.armed
          when pending (writeTVar barrier.armed False)
          pure pending
        when claimed do
          putMVar barrier.reached ()
          takeMVar barrier.resume
      pure nextCarry

awaitMode mode chunk =
  readTVarIO mode >>= \case
    Forward -> pure ()
    Latency millis -> do
      threadDelay (millis * 1000)
      atomically do
        current <- readTVar mode
        check (current /= Stall)
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
