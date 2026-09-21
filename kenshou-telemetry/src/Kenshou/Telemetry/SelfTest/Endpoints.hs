module Kenshou.Telemetry.SelfTest.Endpoints (withSyntheticEndpoints) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, waitCatch)
import Control.Exception (bracket)
import Control.Monad (forever, void)
import Data.Aeson (encode, object, (.=))
import Data.Text qualified as Text
import Kenshou.Telemetry.Endpoint
import Network.HTTP.Types (status200, status404)
import Network.Socket (close)
import Network.Wai (Application, pathInfo, responseLBS)
import Network.Wai.Handler.Warp (defaultSettings, openFreePort, runSettingsSocket)
import Network.Wai.Handler.WebSockets (websocketsOr)
import Network.WebSockets qualified as WebSockets

withSyntheticEndpoints :: Bool -> (Endpoint -> IO ()) -> IO value -> IO value
withSyntheticEndpoints False _ action = action
withSyntheticEndpoints True register action = bracket acquire release \(port, _) -> do
  let base = Text.pack ("127.0.0.1:" <> show port)
  register (Endpoint "synthetic-json" JsonDocument ("http://" <> base <> "/metrics") Nothing)
  register (Endpoint "synthetic-push" WebSocketPush ("ws://" <> base <> "/ws/metrics") Nothing)
  action
  where
    acquire = do
      (port, socket) <- openFreePort
      server <- async (runSettingsSocket defaultSettings socket application)
      pure (port, (server, socket))
    release (_, (server, socket)) = cancel server >> void (waitCatch server) >> close socket

application :: Application
application = websocketsOr WebSockets.defaultConnectionOptions websocket http
  where
    http request respond
      | pathInfo request == ["metrics"] = respond (responseLBS status200 [("Content-Type", "application/json")] (encode (object ["operations" .= (1 :: Int)])))
      | otherwise = respond (responseLBS status404 [] "not found")
    websocket pending = do
      connection <- WebSockets.acceptRequest pending
      forever do
        WebSockets.sendTextData connection (encode (object ["operations" .= (1 :: Int)]))
        threadDelay 100_000
