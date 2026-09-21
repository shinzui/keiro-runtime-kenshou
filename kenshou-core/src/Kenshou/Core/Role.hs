module Kenshou.Core.Role
  ( RoleName,
    WorkerRole (..),
    PostgresConnInfo (..),
    WorkerInit (..),
    ControlMessage (..),
    WorkerMessage (..),
    RoleContext (..),
    mkRoleName,
    renderRoleName,
  )
where

import Data.Aeson
import Data.Aeson.Types (Pair, Parser)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Kenshou.Core.Dimension (Dimensions)
import Kenshou.Core.Id (RunId, ScenarioId, Seed)
import Kenshou.Core.Knob (ResolvedKnobs)
import Kenshou.Core.Log (Logger)
import Kenshou.Core.Phase (PhaseName (..), renderPhaseName)

newtype RoleName = RoleName Text deriving stock (Eq, Ord, Show)

data WorkerRole = WorkerRole
  { name :: RoleName,
    summary :: Text,
    run :: RoleContext -> IO ()
  }

data PostgresConnInfo = PostgresConnInfo {connectionString :: Text, adminConnectionString :: Text} deriving stock (Eq, Show)

data WorkerInit = WorkerInit
  { runId :: RunId,
    scenario :: ScenarioId,
    role :: RoleName,
    instanceName :: Text,
    seed :: Seed,
    knobs :: ResolvedKnobs,
    dimensions :: Dimensions,
    postgres :: Maybe PostgresConnInfo,
    kafka :: Maybe Value,
    telemetry :: Maybe Value,
    outDir :: FilePath,
    args :: Value
  }
  deriving stock (Eq, Show)

data ControlMessage = CtlInit WorkerInit | CtlStart | CtlPhase PhaseName | CtlStop Int | CtlCustom Text Value deriving stock (Eq, Show)

data WorkerMessage = WrkReady | WrkProgress Int64 UTCTime | WrkFacts [Value] | WrkCustom Text Value | WrkDone (Maybe Text) | WrkError Text deriving stock (Eq, Show)

data RoleContext = RoleContext
  { init :: WorkerInit,
    receive :: IO (Maybe ControlMessage),
    send :: WorkerMessage -> IO (),
    logger :: Logger
  }

mkRoleName :: Text -> Either Text RoleName
mkRoleName value = case Text.splitOn "/" value of
  [layer, role] | not (Text.null layer) && not (Text.null role) -> Right (RoleName value)
  _ -> Left "role name must be <layer>/<name>"

renderRoleName :: RoleName -> Text
renderRoleName (RoleName value) = value

instance ToJSON RoleName where toJSON = toJSON . renderRoleName

instance FromJSON RoleName where parseJSON = withText "RoleName" (either (fail . Text.unpack) pure . mkRoleName)

instance ToJSON PostgresConnInfo where toJSON value = object ["connectionString" .= value.connectionString, "adminConnectionString" .= value.adminConnectionString]

instance FromJSON PostgresConnInfo where parseJSON = withObject "PostgresConnInfo" \value -> PostgresConnInfo <$> value .: "connectionString" <*> value .: "adminConnectionString"

instance ToJSON WorkerInit where
  toJSON value = object ["schema" .= ("kenshou.worker-init/v1" :: Text), "runId" .= value.runId, "scenario" .= value.scenario, "role" .= value.role, "instance" .= value.instanceName, "seed" .= value.seed, "knobs" .= value.knobs, "dimensions" .= value.dimensions, "postgres" .= value.postgres, "kafka" .= value.kafka, "telemetry" .= value.telemetry, "outDir" .= value.outDir, "args" .= value.args]

instance FromJSON WorkerInit where
  parseJSON = withObject "WorkerInit" \value -> do
    schema <- value .: "schema"
    if schema /= ("kenshou.worker-init/v1" :: Text) then fail "unsupported worker-init schema" else pure ()
    WorkerInit <$> value .: "runId" <*> value .: "scenario" <*> value .: "role" <*> value .: "instance" <*> value .: "seed" <*> value .: "knobs" <*> value .: "dimensions" <*> value .:? "postgres" <*> value .:? "kafka" <*> value .:? "telemetry" <*> value .: "outDir" <*> value .: "args"

instance ToJSON ControlMessage where
  toJSON (CtlInit value) = tagged "init" ["init" .= value]
  toJSON CtlStart = tagged "start" []
  toJSON (CtlPhase name) = tagged "phase" ["name" .= renderPhaseName name]
  toJSON (CtlStop grace) = tagged "stop" ["graceMillis" .= grace]
  toJSON (CtlCustom name payload) = tagged "custom" ["name" .= name, "payload" .= payload]

instance FromJSON ControlMessage where
  parseJSON = withObject "ControlMessage" \value -> do
    version <- value .: "v"
    if version /= (1 :: Int) then fail "unsupported worker protocol version" else pure ()
    messageType <- value .: "type" :: Parser Text
    case messageType of
      "init" -> CtlInit <$> value .: "init"
      "start" -> pure CtlStart
      "phase" -> CtlPhase <$> (value .: "name" >>= parsePhase)
      "stop" -> CtlStop <$> value .: "graceMillis"
      "custom" -> CtlCustom <$> value .: "name" <*> value .: "payload"
      _ -> fail "unknown control message"

instance ToJSON WorkerMessage where
  toJSON WrkReady = tagged "ready" []
  toJSON (WrkProgress count at) = tagged "progress" ["count" .= count, "at" .= at]
  toJSON (WrkFacts batch) = tagged "facts" ["batch" .= batch]
  toJSON (WrkCustom name payload) = tagged "custom" ["name" .= name, "payload" .= payload]
  toJSON (WrkDone detail) = tagged "done" ["detail" .= detail]
  toJSON (WrkError message) = tagged "error" ["message" .= message]

instance FromJSON WorkerMessage where
  parseJSON = withObject "WorkerMessage" \value -> do
    version <- value .: "v"
    if version /= (1 :: Int) then fail "unsupported worker protocol version" else pure ()
    messageType <- value .: "type" :: Parser Text
    case messageType of
      "ready" -> pure WrkReady
      "progress" -> WrkProgress <$> value .: "count" <*> value .: "at"
      "facts" -> WrkFacts <$> value .: "batch"
      "custom" -> WrkCustom <$> value .: "name" <*> value .: "payload"
      "done" -> WrkDone <$> value .:? "detail"
      "error" -> WrkError <$> value .: "message"
      _ -> fail "unknown worker message"

tagged :: Text -> [Pair] -> Value
tagged messageType fields = object (["v" .= (1 :: Int), "type" .= messageType] <> fields)

parsePhase :: Text -> Parser PhaseName
parsePhase "warm-up" = pure WarmUp
parsePhase "steady" = pure Steady
parsePhase "drain" = pure Drain
parsePhase _ = fail "unknown phase"
