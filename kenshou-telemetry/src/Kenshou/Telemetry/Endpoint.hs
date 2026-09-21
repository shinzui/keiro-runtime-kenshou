module Kenshou.Telemetry.Endpoint
  ( EndpointKind (..),
    Endpoint (..),
    reserveFreePort,
    awaitHttpReady,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Data.Aeson (FromJSON (..), ToJSON (..), Value, object, withObject, withText, (.:), (.:?), (.=))
import Data.Text (Text)
import Data.Text qualified as Text
import Network.HTTP.Client (defaultManagerSettings, httpLbs, newManager, parseRequest, responseStatus)
import Network.HTTP.Types.Status (statusCode)
import Network.Socket (close)
import Network.Wai.Handler.Warp (openFreePort)

data EndpointKind = PrometheusText | JsonDocument | HealthProbe | WebSocketPush
  deriving stock (Eq, Ord, Show)

data Endpoint = Endpoint
  { name :: Text,
    kind :: EndpointKind,
    url :: Text,
    wsHello :: Maybe Value
  }
  deriving stock (Eq, Show)

instance ToJSON EndpointKind where
  toJSON = toJSON . renderKind

instance FromJSON EndpointKind where
  parseJSON = withText "EndpointKind" (maybe (fail "unknown endpoint kind") pure . parseKind)

instance ToJSON Endpoint where
  toJSON endpoint = object ["name" .= endpoint.name, "kind" .= endpoint.kind, "url" .= endpoint.url, "wsHello" .= endpoint.wsHello]

instance FromJSON Endpoint where
  parseJSON = withObject "Endpoint" (\value -> Endpoint <$> value .: "name" <*> value .: "kind" <*> value .: "url" <*> value .:? "wsHello")

reserveFreePort :: IO Int
reserveFreePort = do
  (port, socket) <- openFreePort
  close socket
  pure port

awaitHttpReady :: Text -> Int -> IO Bool
awaitHttpReady url timeoutMs = do
  manager <- newManager defaultManagerSettings
  request <- parseRequest (Text.unpack url)
  let attempts = max 1 (timeoutMs `div` 50)
      loop 0 = pure False
      loop remaining = do
        response <- tryAny (httpLbs request manager)
        case response of
          Right value | statusCode (responseStatus value) < 500 -> pure True
          _ -> threadDelay 50_000 >> loop (remaining - 1)
  loop attempts

renderKind :: EndpointKind -> Text
renderKind PrometheusText = "prometheus-text"
renderKind JsonDocument = "json-document"
renderKind HealthProbe = "health-probe"
renderKind WebSocketPush = "websocket-push"

parseKind :: Text -> Maybe EndpointKind
parseKind value = lookup value [(renderKind kind, kind) | kind <- [PrometheusText, JsonDocument, HealthProbe, WebSocketPush]]

tryAny :: IO value -> IO (Either SomeException value)
tryAny = try
