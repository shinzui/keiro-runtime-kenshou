module Kenshou.Telemetry.Sink
  ( SinkStats (..),
    SinkHandle (..),
    sinkApplication,
    withSink,
    runSinkRole,
  )
where

import Codec.Compression.GZip qualified as GZip
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, waitCatch)
import Control.Exception (bracket)
import Control.Monad (void)
import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef
import Data.ProtoLens (decodeMessage)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Kenshou.Core.Role (ControlMessage (..), RoleContext (..), WorkerInit (..), WorkerMessage (..))
import Kenshou.Telemetry.Spec (SinkFault (..), renderSinkFault)
import Lens.Micro ((^.))
import Network.HTTP.Types (status200, status404, status503)
import Network.Socket (close)
import Network.Wai (Application, Request (..), responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp (defaultSettings, openFreePort, runSettingsSocket)
import Proto.Opentelemetry.Proto.Collector.Trace.V1.TraceService (ExportTraceServiceRequest)
import Proto.Opentelemetry.Proto.Collector.Trace.V1.TraceService_Fields qualified as TraceService
import Proto.Opentelemetry.Proto.Trace.V1.Trace_Fields qualified as Trace

data SinkStats = SinkStats {requests :: Int, bytes :: Integer, spansReceived :: Int}
  deriving stock (Eq, Show)

instance ToJSON SinkStats where
  toJSON stats = object ["requests" .= stats.requests, "bytes" .= stats.bytes, "spansReceived" .= stats.spansReceived]

instance FromJSON SinkStats where
  parseJSON = withObject "SinkStats" (\value -> SinkStats <$> value .: "requests" <*> value .: "bytes" <*> value .: "spansReceived")

data SinkHandle = SinkHandle
  { endpoint :: Text,
    setFault :: SinkFault -> IO (),
    snapshot :: IO SinkStats
  }

sinkApplication :: IORef SinkFault -> IORef SinkStats -> Application
sinkApplication faultRef statsRef request respond
  | requestMethod request /= "POST" || pathInfo request `notElem` [["v1", "traces"], ["v1", "metrics"]] = respond (responseLBS status404 [] "not found")
  | otherwise = do
      fault <- readIORef faultRef
      case fault of
        SinkDelay200ms -> threadDelay 200000
        SinkDelay2000ms -> threadDelay 2000000
        SinkHang -> threadDelay 120000000
        _ -> pure ()
      body <- strictRequestBody request
      let decodedBody = if lookup "Content-Encoding" (requestHeaders request) == Just "gzip" then GZip.decompress body else body
          spans = if pathInfo request == ["v1", "traces"] then countSpans decodedBody else 0
      atomicModifyIORef' statsRef \stats -> (SinkStats (stats.requests + 1) (stats.bytes + fromIntegral (LazyByteString.length body)) (stats.spansReceived + spans), ())
      respond (responseLBS (if fault == SinkStatus503 then status503 else status200) [("Content-Type", "application/x-protobuf")] "")

withSink :: SinkFault -> (SinkHandle -> IO value) -> IO value
withSink initialFault action = bracket acquire release use
  where
    acquire = do
      faultRef <- newIORef initialFault
      statsRef <- newIORef (SinkStats 0 0 0)
      (port, socket) <- openFreePort
      if initialFault == SinkRefuse
        then close socket >> pure (SinkHandle (url port) (writeIORef faultRef) (readIORef statsRef), Nothing)
        else do
          server <- async (runSettingsSocket defaultSettings socket (sinkApplication faultRef statsRef))
          pure (SinkHandle (url port) (writeIORef faultRef) (readIORef statsRef), Just (server, socket))
    release (_, Nothing) = pure ()
    release (_, Just (server, socket)) = cancel server >> void (waitCatch server) >> close socket
    use (handle, _) = action handle
    url port = "http://127.0.0.1:" <> Text.pack (show port)

runSinkRole :: RoleContext -> IO ()
runSinkRole context = withSink initialFault \sink -> do
  context.send (WrkCustom "ready" (object ["endpoint" .= sink.endpoint]))
  loop sink
  stats <- sink.snapshot
  context.send (WrkCustom "sink-stats" (toJSON stats))
  where
    loop sink =
      context.receive >>= \case
        Just (CtlCustom "fault" (String raw)) -> case parseFault raw of
          Nothing -> context.send (WrkError ("unknown sink fault: " <> raw))
          Just fault -> sink.setFault fault >> loop sink
        Just (CtlCustom "snapshot" _) -> sink.snapshot >>= context.send . WrkCustom "sink-stats" . toJSON >> loop sink
        Just (CtlStop _) -> pure ()
        Just _ -> loop sink
        Nothing -> pure ()
    initialFault = maybe SinkHealthy id (parseMaybe (withObject "sink arguments" (\value -> value .: "fault" >>= maybe (fail "unknown sink fault") pure . parseFault)) context.init.args)

countSpans :: LazyByteString.ByteString -> Int
countSpans body = case decodeMessage (LazyByteString.toStrict body) :: Either String ExportTraceServiceRequest of
  Left _ -> 0
  Right request ->
    sum
      [ Vector.length (scope ^. Trace.vec'spans)
      | resource <- Vector.toList (request ^. TraceService.vec'resourceSpans),
        scope <- Vector.toList (resource ^. Trace.vec'scopeSpans)
      ]

parseFault :: Text -> Maybe SinkFault
parseFault raw = lookup raw [(renderSinkFault fault, fault) | fault <- [SinkHealthy, SinkDelay200ms, SinkDelay2000ms, SinkStatus503, SinkHang, SinkRefuse]]
