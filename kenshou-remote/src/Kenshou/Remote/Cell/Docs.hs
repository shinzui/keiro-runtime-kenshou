module Kenshou.Remote.Cell.Docs
  ( CellPhase (..),
    CellOutcome (..),
    CellNodes (..),
    CellImages (..),
    CellBuckets (..),
    CellDescriptor (..),
    CellPostgres (..),
    CellBroker (..),
    OtlpEndpoint (..),
    OtlpSinks (..),
    CellDriver (..),
    CellEnvironment (..),
    WorkObject (..),
    PgDatabase (..),
    PgReset (..),
    BrokerReset (..),
    CachePolicy (..),
    ResetBlock (..),
    Limits (..),
    Requirements (..),
    CollectOptions (..),
    Submission (..),
    LogChunks (..),
    CellStatus (..),
    Rejected (..),
    CellRunResult (..),
    ManifestPayload (..),
    Artifact (..),
    CellManifest (..),
  )
where

import Control.Monad (unless)
import Data.Aeson (FromJSON (..), Object, ToJSON (..), Value (..), object, withObject, withText, (.!=), (.:), (.:?), (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Kenshou.Core.Id (RunId)
import Kenshou.Remote.Payload (CellPayload)
import Text.Read (readMaybe)

data CellPhase = Accepted | Resetting | Fetching | Running | Publishing | Sealed
  deriving stock (Eq, Show)

data CellOutcome = Completed | InfrastructureFailure | Cancelled | TimedOut
  deriving stock (Eq, Show)

data CellNodes = CellNodes
  { postgres :: !Text,
    drivers :: ![Text],
    monitoring :: !Text,
    -- | The optional broker role, present on cells that run one.
    broker :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

data CellImages = CellImages
  { driver :: !Text,
    postgres :: !Text,
    monitoring :: !Text,
    broker :: !Text
  }
  deriving stock (Eq, Show)

data CellBuckets = CellBuckets
  { control :: !Text,
    results :: !Text
  }
  deriving stock (Eq, Show)

data CellDescriptor = CellDescriptor
  { name :: !Text,
    project :: !Text,
    zone :: !Text,
    postgresMajor :: !Int,
    instances :: !CellNodes,
    addresses :: !CellNodes,
    shape :: !Value,
    images :: !CellImages,
    buckets :: !CellBuckets
  }
  deriving stock (Eq, Show)

data CellPostgres = CellPostgres
  { major :: !Int,
    host :: !Text,
    port :: !Int,
    database :: !Text,
    user :: !Text,
    connectionString :: !Text
  }
  deriving stock (Eq, Show)

data CellBroker = CellBroker
  { bootstrapServers :: !Text,
    adminUrl :: !Text,
    implementation :: !Text,
    version :: !Text
  }
  deriving stock (Eq, Show)

data OtlpEndpoint = OtlpEndpoint
  { grpc :: !Text,
    http :: !Text
  }
  deriving stock (Eq, Show)

data OtlpSinks = OtlpSinks
  { nullEndpoint :: !OtlpEndpoint,
    fileEndpoint :: !OtlpEndpoint
  }
  deriving stock (Eq, Show)

data CellDriver = CellDriver
  { index :: !Int,
    host :: !Text
  }
  deriving stock (Eq, Show)

data CellEnvironment = CellEnvironment
  { cell :: !Text,
    runId :: !RunId,
    leaseId :: !RunId,
    postgres :: !CellPostgres,
    broker :: !(Maybe CellBroker),
    otlp :: !(Maybe OtlpSinks),
    victoriaMetricsUrl :: !Text,
    drivers :: ![CellDriver],
    clockSkewBoundMicros :: !(Maybe Int),
    faultHook :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

data WorkObject = WorkObject
  { sha256 :: !Text,
    bytes :: !Int64,
    mediaType :: !Text
  }
  deriving stock (Eq, Show)

data PgDatabase = PgDatabase
  { name :: !Text,
    owner :: !Text,
    template :: !Text
  }
  deriving stock (Eq, Show)

data PgReset = PgReset
  { major :: !Int,
    databases :: ![PgDatabase],
    settings :: !(Map Text Text)
  }
  deriving stock (Eq, Show)

newtype BrokerReset = BrokerReset {wipe :: Bool}
  deriving stock (Eq, Show)

data CachePolicy = Cold | Warm
  deriving stock (Eq, Show)

data ResetBlock = ResetBlock
  { cachePolicy :: !CachePolicy,
    postgres :: !(Maybe PgReset),
    broker :: !(Maybe BrokerReset)
  }
  deriving stock (Eq, Show)

data Limits = Limits
  { wallClockSeconds :: !Int64,
    memoryMaxBytes :: !Int64,
    outputMaxBytes :: !Int64
  }
  deriving stock (Eq, Show)

data Requirements = Requirements
  { minAgentVersion :: !Text,
    capabilities :: !(Maybe [Text])
  }
  deriving stock (Eq, Show)

data CollectOptions = CollectOptions
  { traces :: !Bool,
    profiles :: !Bool
  }
  deriving stock (Eq, Show)

data Submission = Submission
  { runId :: !RunId,
    leaseId :: !RunId,
    payload :: !CellPayload,
    work :: !WorkObject,
    env :: !(Map Text Text),
    reset :: !ResetBlock,
    limits :: !Limits,
    requires :: !Requirements,
    collect :: !(Maybe CollectOptions),
    labels :: !(Map Text Text)
  }
  deriving stock (Eq, Show)

data LogChunks = LogChunks
  { stdout :: !Int,
    stderr :: !Int
  }
  deriving stock (Eq, Show)

data CellStatus = CellStatus
  { runId :: !RunId,
    phase :: !CellPhase,
    leaseSequence :: !(Maybe Int),
    updatedAt :: !UTCTime,
    phaseStartedAt :: !(Maybe UTCTime),
    logChunks :: !LogChunks,
    outcome :: !(Maybe CellOutcome),
    manifestSha256 :: !(Maybe Text),
    reasons :: !(Maybe [Text])
  }
  deriving stock (Eq, Show)

data Rejected = Rejected
  { runId :: !RunId,
    reason :: !Text,
    at :: !UTCTime
  }
  deriving stock (Eq, Show)

data CellRunResult = CellRunResult
  { runId :: !RunId,
    cell :: !Text,
    leaseId :: !RunId,
    leaseSequence :: !Int,
    outcome :: !CellOutcome,
    entryExitCode :: !(Maybe Int),
    entrySignal :: !(Maybe Int),
    reasons :: ![Text]
  }
  deriving stock (Eq, Show)

data ManifestPayload = ManifestPayload
  { sha256 :: !Text,
    storePath :: !Text
  }
  deriving stock (Eq, Show)

data Artifact = Artifact
  { path :: !Text,
    sha256 :: !Text,
    bytes :: !Int64,
    mediaType :: !Text
  }
  deriving stock (Eq, Show)

data CellManifest = CellManifest
  { runId :: !RunId,
    cell :: !Text,
    leaseId :: !RunId,
    leaseSequence :: !Int,
    sealedAt :: !UTCTime,
    agentVersion :: !Text,
    payload :: !ManifestPayload,
    outcome :: !CellOutcome,
    retentionSeconds :: !Int64,
    artifacts :: ![Artifact]
  }
  deriving stock (Eq, Show)

instance ToJSON CellPhase where
  toJSON = toJSON . renderPhase

instance FromJSON CellPhase where
  parseJSON = withText "cell phase" \case
    "accepted" -> pure Accepted
    "resetting" -> pure Resetting
    "fetching" -> pure Fetching
    "running" -> pure Running
    "publishing" -> pure Publishing
    "sealed" -> pure Sealed
    _ -> fail "unknown cell phase"

renderPhase :: CellPhase -> Text
renderPhase Accepted = "accepted"
renderPhase Resetting = "resetting"
renderPhase Fetching = "fetching"
renderPhase Running = "running"
renderPhase Publishing = "publishing"
renderPhase Sealed = "sealed"

instance ToJSON CellOutcome where
  toJSON = toJSON . renderOutcome

instance FromJSON CellOutcome where
  parseJSON = withText "cell outcome" \case
    "completed" -> pure Completed
    "infrastructure-failure" -> pure InfrastructureFailure
    "cancelled" -> pure Cancelled
    "timed-out" -> pure TimedOut
    _ -> fail "unknown cell outcome"

renderOutcome :: CellOutcome -> Text
renderOutcome Completed = "completed"
renderOutcome InfrastructureFailure = "infrastructure-failure"
renderOutcome Cancelled = "cancelled"
renderOutcome TimedOut = "timed-out"

instance ToJSON CellNodes where
  toJSON nodes = object (["postgres" .= nodes.postgres, "drivers" .= nodes.drivers, "monitoring" .= nodes.monitoring] <> maybe [] (\name -> ["broker" .= name]) nodes.broker)

instance FromJSON CellNodes where
  parseJSON = withObject "cell nodes" \value -> do
    nodes <- CellNodes <$> value .: "postgres" <*> value .: "drivers" <*> value .: "monitoring" <*> value .:? "broker"
    unless (not (Text.null nodes.postgres) && not (null nodes.drivers) && all (not . Text.null) nodes.drivers && not (Text.null nodes.monitoring) && maybe True (not . Text.null) nodes.broker) (fail "invalid cell nodes")
    pure nodes

instance ToJSON CellImages where
  toJSON images = object ["driver" .= images.driver, "postgres" .= images.postgres, "monitoring" .= images.monitoring, "broker" .= images.broker]

instance FromJSON CellImages where
  parseJSON = withObject "cell images" \value -> do
    images <- CellImages <$> value .: "driver" <*> value .: "postgres" <*> value .: "monitoring" <*> value .: "broker"
    unless (all (not . Text.null) [images.driver, images.postgres, images.monitoring]) (fail "invalid cell images")
    pure images

instance ToJSON CellBuckets where
  toJSON buckets = object ["control" .= buckets.control, "results" .= buckets.results]

instance FromJSON CellBuckets where
  parseJSON = withObject "cell buckets" \value -> do
    buckets <- CellBuckets <$> value .: "control" <*> value .: "results"
    unless (not (Text.null buckets.control) && not (Text.null buckets.results)) (fail "invalid cell buckets")
    pure buckets

instance ToJSON CellDescriptor where
  toJSON descriptor =
    object
      [ "schema" .= ("cell.descriptor/v1" :: Text),
        "name" .= descriptor.name,
        "project" .= descriptor.project,
        "zone" .= descriptor.zone,
        "postgresMajor" .= descriptor.postgresMajor,
        "instances" .= descriptor.instances,
        "addresses" .= descriptor.addresses,
        "shape" .= descriptor.shape,
        "images" .= descriptor.images,
        "buckets" .= descriptor.buckets,
        "agentProtocol" .= ("cell.protocol/v1" :: Text)
      ]

instance FromJSON CellDescriptor where
  parseJSON = withObject "cell descriptor" \value -> do
    expectSchema "cell.descriptor/v1" value
    protocol <- value .: "agentProtocol"
    unless (protocol == ("cell.protocol/v1" :: Text)) (fail "unsupported cell agent protocol")
    descriptor <- CellDescriptor <$> value .: "name" <*> value .: "project" <*> value .: "zone" <*> value .: "postgresMajor" <*> value .: "instances" <*> value .: "addresses" <*> value .: "shape" <*> value .: "images" <*> value .: "buckets"
    unless (validName descriptor.name && Text.length descriptor.name <= 41 && not (Text.null descriptor.project) && not (Text.null descriptor.zone) && descriptor.postgresMajor `elem` [17, 18] && all validIpv4 (descriptor.addresses.postgres : descriptor.addresses.monitoring : descriptor.addresses.drivers) && validShape descriptor.shape) (fail "invalid cell descriptor")
    pure descriptor

instance ToJSON CellPostgres where
  toJSON postgres = object ["major" .= postgres.major, "host" .= postgres.host, "port" .= postgres.port, "database" .= postgres.database, "user" .= postgres.user, "connectionString" .= postgres.connectionString]

instance FromJSON CellPostgres where
  parseJSON = withObject "cell PostgreSQL" \value -> do
    postgres <- CellPostgres <$> value .: "major" <*> value .: "host" <*> value .: "port" <*> value .: "database" <*> value .: "user" <*> value .: "connectionString"
    unless (postgres.major `elem` [17, 18] && validIpv4 postgres.host && postgres.port >= 1 && postgres.port <= 65535 && all (not . Text.null) [postgres.database, postgres.user, postgres.connectionString]) (fail "invalid cell PostgreSQL endpoint")
    pure postgres

instance ToJSON CellBroker where
  toJSON broker = object ["bootstrapServers" .= broker.bootstrapServers, "adminUrl" .= broker.adminUrl, "implementation" .= broker.implementation, "version" .= broker.version]

instance FromJSON CellBroker where
  parseJSON = withObject "cell broker" \value -> do
    broker <- CellBroker <$> value .: "bootstrapServers" <*> value .: "adminUrl" <*> value .: "implementation" <*> value .: "version"
    unless (all (not . Text.null) [broker.bootstrapServers, broker.implementation, broker.version] && validUri broker.adminUrl) (fail "invalid cell broker")
    pure broker

instance ToJSON OtlpEndpoint where
  toJSON endpoint = object ["grpc" .= endpoint.grpc, "http" .= endpoint.http]

instance FromJSON OtlpEndpoint where
  parseJSON = withObject "cell OTLP endpoint" \value -> do
    endpoint <- OtlpEndpoint <$> value .: "grpc" <*> value .: "http"
    unless (validUri endpoint.grpc && validUri endpoint.http) (fail "invalid cell OTLP endpoint")
    pure endpoint

instance ToJSON OtlpSinks where
  toJSON sinks = object ["null" .= sinks.nullEndpoint, "file" .= sinks.fileEndpoint]

instance FromJSON OtlpSinks where
  parseJSON = withObject "cell OTLP sinks" \value -> OtlpSinks <$> value .: "null" <*> value .: "file"

instance ToJSON CellDriver where
  toJSON driver = object ["index" .= driver.index, "host" .= driver.host]

instance FromJSON CellDriver where
  parseJSON = withObject "cell driver" \value -> do
    driver <- CellDriver <$> value .: "index" <*> value .: "host"
    unless (driver.index >= 0 && validIpv4 driver.host) (fail "invalid cell driver")
    pure driver

instance ToJSON CellEnvironment where
  toJSON environment =
    object $
      [ "schema" .= ("cell.environment/v1" :: Text),
        "cell" .= environment.cell,
        "runId" .= environment.runId,
        "leaseId" .= environment.leaseId,
        "postgres" .= environment.postgres,
        "broker" .= environment.broker,
        "otlp" .= environment.otlp,
        "metrics" .= object ["victoriaMetricsUrl" .= environment.victoriaMetricsUrl],
        "drivers" .= environment.drivers
      ]
        <> catMaybes
          [ ("clock" .=) . object . pure . ("skewBoundMicros" .=) <$> environment.clockSkewBoundMicros,
            ("faultHook" .=) <$> environment.faultHook
          ]

instance FromJSON CellEnvironment where
  parseJSON = withObject "cell environment" \value -> do
    expectSchema "cell.environment/v1" value
    metrics <- value .: "metrics"
    clock <- value .:? "clock"
    url <- metrics .: "victoriaMetricsUrl"
    skew <- traverse (.: "skewBoundMicros") clock
    environment <- CellEnvironment <$> value .: "cell" <*> value .: "runId" <*> value .: "leaseId" <*> value .: "postgres" <*> value .: "broker" <*> value .: "otlp" <*> pure url <*> value .: "drivers" <*> pure skew <*> value .:? "faultHook"
    unless (validName environment.cell && validUri environment.victoriaMetricsUrl && not (null environment.drivers) && maybe True (>= 0) environment.clockSkewBoundMicros && maybe True (not . Text.null) environment.faultHook) (fail "invalid cell environment")
    pure environment

instance ToJSON WorkObject where
  toJSON work = object ["sha256" .= work.sha256, "bytes" .= work.bytes, "mediaType" .= work.mediaType]

instance FromJSON WorkObject where
  parseJSON = withObject "cell work object" \value -> do
    work <- WorkObject <$> value .: "sha256" <*> value .: "bytes" <*> value .: "mediaType"
    unless (validDigest work.sha256 && work.bytes >= 0 && not (Text.null work.mediaType)) (fail "invalid cell work object")
    pure work

instance ToJSON PgDatabase where
  toJSON database = object ["name" .= database.name, "owner" .= database.owner, "template" .= database.template]

instance FromJSON PgDatabase where
  parseJSON = withObject "cell PostgreSQL database" \value -> do
    database <- PgDatabase <$> value .: "name" <*> value .: "owner" <*> value .: "template"
    unless (all validPgName [database.name, database.owner, database.template]) (fail "invalid cell PostgreSQL database")
    pure database

instance ToJSON PgReset where
  toJSON reset = object ["major" .= reset.major, "databases" .= reset.databases, "settings" .= reset.settings]

instance FromJSON PgReset where
  parseJSON = withObject "cell PostgreSQL reset" \value -> do
    reset <- PgReset <$> value .: "major" <*> value .: "databases" <*> value .: "settings"
    unless (reset.major `elem` [17, 18] && unique reset.databases && validStringMap reset.settings) (fail "invalid cell PostgreSQL reset")
    pure reset

instance ToJSON BrokerReset where
  toJSON reset = object ["wipe" .= reset.wipe]

instance FromJSON BrokerReset where
  parseJSON = withObject "cell broker reset" \value -> BrokerReset <$> value .: "wipe"

instance ToJSON CachePolicy where
  toJSON Cold = toJSON ("cold" :: Text)
  toJSON Warm = toJSON ("warm" :: Text)

instance FromJSON CachePolicy where
  parseJSON = withText "cell cache policy" \case
    "cold" -> pure Cold
    "warm" -> pure Warm
    _ -> fail "unknown cell cache policy"

instance ToJSON ResetBlock where
  toJSON reset =
    object $
      ["cachePolicy" .= reset.cachePolicy]
        <> catMaybes
          [ ("postgres" .=) <$> reset.postgres,
            ("broker" .=) <$> reset.broker
          ]

instance FromJSON ResetBlock where
  parseJSON = withObject "cell reset" \value -> ResetBlock <$> value .: "cachePolicy" <*> value .:? "postgres" <*> value .:? "broker"

instance ToJSON Limits where
  toJSON limits = object ["wallClockSeconds" .= limits.wallClockSeconds, "memoryMaxBytes" .= limits.memoryMaxBytes, "outputMaxBytes" .= limits.outputMaxBytes]

instance FromJSON Limits where
  parseJSON = withObject "cell limits" \value -> do
    limits <- Limits <$> value .: "wallClockSeconds" <*> value .: "memoryMaxBytes" <*> value .: "outputMaxBytes"
    unless (limits.wallClockSeconds > 0 && limits.memoryMaxBytes > 0 && limits.outputMaxBytes > 0) (fail "invalid cell limits")
    pure limits

instance ToJSON Requirements where
  toJSON requirements =
    object $
      [ "protocol" .= ("cell.protocol/v1" :: Text),
        "minAgentVersion" .= requirements.minAgentVersion
      ]
        <> catMaybes [("capabilities" .=) <$> requirements.capabilities]

instance FromJSON Requirements where
  parseJSON = withObject "cell requirements" \value -> do
    protocol <- value .: "protocol"
    unless (protocol == ("cell.protocol/v1" :: Text)) (fail "unsupported cell protocol")
    requirements <- Requirements <$> value .: "minAgentVersion" <*> value .:? "capabilities"
    unless (validVersion requirements.minAgentVersion && maybe True (\items -> unique items && all (not . Text.null) items) requirements.capabilities) (fail "invalid cell requirements")
    pure requirements

instance ToJSON Submission where
  toJSON submission =
    object
      ( [ "schema" .= ("cell.submission/v1" :: Text),
          "runId" .= submission.runId,
          "leaseId" .= submission.leaseId,
          "payload" .= submission.payload,
          "work" .= submission.work,
          "env" .= submission.env,
          "reset" .= submission.reset,
          "limits" .= submission.limits,
          "requires" .= submission.requires,
          "labels" .= submission.labels
        ]
          <> maybe [] (\options -> ["collect" .= object (["traces" .= options.traces] <> ["profiles" .= True | options.profiles])]) submission.collect
      )

instance FromJSON Submission where
  parseJSON = withObject "cell submission" \value -> do
    expectSchema "cell.submission/v1" value
    submission <- Submission <$> value .: "runId" <*> value .: "leaseId" <*> value .: "payload" <*> value .: "work" <*> value .: "env" <*> value .: "reset" <*> value .: "limits" <*> value .: "requires" <*> (value .:? "collect" >>= traverse parseCollect) <*> value .: "labels"
    unless (validStringMap submission.env && validStringMap submission.labels) (fail "invalid cell submission map keys")
    pure submission
    where
      parseCollect = withObject "cell collection options" \options -> CollectOptions <$> options .: "traces" <*> (options .:? "profiles" .!= False)

instance ToJSON LogChunks where
  toJSON chunks = object ["stdout" .= chunks.stdout, "stderr" .= chunks.stderr]

instance FromJSON LogChunks where
  parseJSON = withObject "cell log chunks" \value -> do
    chunks <- LogChunks <$> value .: "stdout" <*> value .: "stderr"
    unless (chunks.stdout >= 0 && chunks.stderr >= 0) (fail "negative cell log chunk count")
    pure chunks

instance ToJSON CellStatus where
  toJSON status =
    object $
      [ "schema" .= ("cell.status/v1" :: Text),
        "runId" .= status.runId,
        "phase" .= status.phase,
        "updatedAt" .= status.updatedAt,
        "logChunks" .= status.logChunks
      ]
        <> catMaybes
          [ ("leaseSequence" .=) <$> status.leaseSequence,
            ("phaseStartedAt" .=) <$> status.phaseStartedAt,
            ("outcome" .=) <$> status.outcome,
            ("manifestSha256" .=) <$> status.manifestSha256,
            ("reasons" .=) <$> status.reasons
          ]

instance FromJSON CellStatus where
  parseJSON = withObject "cell status" \value -> do
    expectSchema "cell.status/v1" value
    status <- CellStatus <$> value .: "runId" <*> value .: "phase" <*> value .:? "leaseSequence" <*> value .: "updatedAt" <*> value .:? "phaseStartedAt" <*> value .: "logChunks" <*> value .:? "outcome" <*> value .:? "manifestSha256" <*> value .:? "reasons"
    unless (maybe True (>= 0) status.leaseSequence && maybe True validDigest status.manifestSha256 && maybe True (all (not . Text.null)) status.reasons) (fail "invalid cell status fields")
    unless (if status.phase == Sealed then status.outcome /= Nothing && status.manifestSha256 /= Nothing else status.outcome == Nothing && status.manifestSha256 == Nothing) (fail "cell status terminal fields disagree with phase")
    pure status

instance ToJSON Rejected where
  toJSON rejected = object ["schema" .= ("cell.rejected/v1" :: Text), "runId" .= rejected.runId, "reason" .= rejected.reason, "at" .= rejected.at]

instance FromJSON Rejected where
  parseJSON = withObject "cell rejection" \value -> do
    expectSchema "cell.rejected/v1" value
    rejected <- Rejected <$> value .: "runId" <*> value .: "reason" <*> value .: "at"
    unless (not (Text.null rejected.reason)) (fail "empty cell rejection reason")
    pure rejected

instance ToJSON CellRunResult where
  toJSON result =
    object
      [ "schema" .= ("cell.run-result/v1" :: Text),
        "runId" .= result.runId,
        "cell" .= result.cell,
        "leaseId" .= result.leaseId,
        "leaseSequence" .= result.leaseSequence,
        "outcome" .= result.outcome,
        "entryExitCode" .= result.entryExitCode,
        "entrySignal" .= result.entrySignal,
        "reasons" .= result.reasons
      ]

instance FromJSON CellRunResult where
  parseJSON = withObject "cell run result" \value -> do
    expectSchema "cell.run-result/v1" value
    result <- CellRunResult <$> value .: "runId" <*> value .: "cell" <*> value .: "leaseId" <*> value .: "leaseSequence" <*> value .: "outcome" <*> value .: "entryExitCode" <*> value .: "entrySignal" <*> value .: "reasons"
    unless (validName result.cell && result.leaseSequence >= 0 && all (not . Text.null) result.reasons) (fail "invalid cell run result")
    pure result

instance ToJSON ManifestPayload where
  toJSON payload = object ["kind" .= ("nix-nar-bundle" :: Text), "sha256" .= payload.sha256, "storePath" .= payload.storePath]

instance FromJSON ManifestPayload where
  parseJSON = withObject "manifest payload" \value -> do
    kind <- value .: "kind"
    unless (kind == ("nix-nar-bundle" :: Text)) (fail "unsupported manifest payload kind")
    payload <- ManifestPayload <$> value .: "sha256" <*> value .: "storePath"
    unless (validDigest payload.sha256 && validStorePath payload.storePath) (fail "invalid manifest payload")
    pure payload

instance ToJSON Artifact where
  toJSON artifact = object ["path" .= artifact.path, "sha256" .= artifact.sha256, "bytes" .= artifact.bytes, "mediaType" .= artifact.mediaType]

instance FromJSON Artifact where
  parseJSON = withObject "cell artifact" \value -> do
    artifact <- Artifact <$> value .: "path" <*> value .: "sha256" <*> value .: "bytes" <*> value .: "mediaType"
    unless (validArtifactPath artifact.path && validDigest artifact.sha256 && artifact.bytes >= 0 && not (Text.null artifact.mediaType)) (fail "invalid cell artifact")
    pure artifact

instance ToJSON CellManifest where
  toJSON manifest =
    object
      [ "schema" .= ("cell.artifact-manifest/v1" :: Text),
        "layout" .= (1 :: Int),
        "runId" .= manifest.runId,
        "cell" .= manifest.cell,
        "leaseId" .= manifest.leaseId,
        "leaseSequence" .= manifest.leaseSequence,
        "sealedAt" .= manifest.sealedAt,
        "agentVersion" .= manifest.agentVersion,
        "payload" .= manifest.payload,
        "outcome" .= manifest.outcome,
        "retention" .= object ["policy" .= ("bucket-retention" :: Text), "retentionSeconds" .= manifest.retentionSeconds],
        "artifacts" .= manifest.artifacts
      ]

instance FromJSON CellManifest where
  parseJSON = withObject "cell manifest" \value -> do
    expectSchema "cell.artifact-manifest/v1" value
    layout <- value .: "layout"
    unless (layout == (1 :: Int)) (fail "unsupported cell manifest layout")
    retention <- value .: "retention"
    policy <- retention .: "policy"
    unless (policy == ("bucket-retention" :: Text)) (fail "unsupported cell retention policy")
    seconds <- retention .: "retentionSeconds"
    manifest <- CellManifest <$> value .: "runId" <*> value .: "cell" <*> value .: "leaseId" <*> value .: "leaseSequence" <*> value .: "sealedAt" <*> value .: "agentVersion" <*> value .: "payload" <*> value .: "outcome" <*> pure seconds <*> value .: "artifacts"
    unless (validName manifest.cell && manifest.leaseSequence >= 0 && manifest.retentionSeconds >= 0 && validVersion manifest.agentVersion && not (null manifest.artifacts) && all ((/= "manifest.json") . (.path)) manifest.artifacts && Set.size (Set.fromList (map (.path) manifest.artifacts)) == length manifest.artifacts) (fail "invalid cell manifest")
    pure manifest

expectSchema :: Text -> Object -> Parser ()
expectSchema expected value = do
  schema <- value .: "schema"
  unless (schema == expected) (fail "unsupported cell document schema")

validName :: Text -> Bool
validName value = Text.length value >= 3 && Text.length value <= 63 && Text.head value `elem` (['a' .. 'z'] <> ['0' .. '9']) && Text.all (\character -> character `elem` (['a' .. 'z'] <> ['0' .. '9'] <> "-")) value

validShape :: Value -> Bool
validShape (Object fields) = all (`KeyMap.member` fields) ["postgres", "driver", "monitoring", "scheduling"]
validShape _ = False

validIpv4 :: Text -> Bool
validIpv4 value = case traverse (readMaybe . Text.unpack) (Text.splitOn "." value) :: Maybe [Int] of
  Just [first, second, third, fourth] -> all (\piece -> piece >= 0 && piece <= 255) [first, second, third, fourth]
  _ -> False

validUri :: Text -> Bool
validUri value = case Text.breakOn ":" value of
  (scheme, rest) ->
    not (Text.null scheme)
      && Text.length rest > 1
      && Text.head scheme `elem` (['a' .. 'z'] <> ['A' .. 'Z'])
      && Text.all (\character -> character `elem` (['a' .. 'z'] <> ['A' .. 'Z'] <> ['0' .. '9'] <> "+.-")) scheme

validDigest :: Text -> Bool
validDigest value = Text.length value == 64 && Text.all (\character -> character `elem` (['0' .. '9'] <> ['a' .. 'f'])) value

validVersion :: Text -> Bool
validVersion value = case Text.splitOn "." value of
  [major, minor, patch] -> all (\piece -> not (Text.null piece) && Text.all (\character -> character `elem` ['0' .. '9']) piece) [major, minor, patch]
  _ -> False

validStorePath :: Text -> Bool
validStorePath value = case Text.stripPrefix "/nix/store/" value of
  Just suffix -> let (digest, name) = Text.breakOn "-" suffix in Text.length digest == 32 && Text.all (\character -> character `elem` (['a' .. 'z'] <> ['0' .. '9'])) digest && Text.length name > 1 && not (Text.any (== '/') name)
  Nothing -> False

validArtifactPath :: Text -> Bool
validArtifactPath value =
  not (Text.null value)
    && not (Text.isPrefixOf "/" value)
    && not (Text.any (`elem` ['\\', '\0']) value)
    && all (\part -> not (Text.null part) && part /= "." && part /= "..") (Text.splitOn "/" value)

validPgName :: Text -> Bool
validPgName value = case Text.uncons value of
  Just (first, rest) -> Text.length value <= 63 && first `elem` ['a' .. 'z'] && Text.all (\character -> character `elem` (['a' .. 'z'] <> ['0' .. '9'] <> "_")) rest
  Nothing -> False

validStringMap :: Map Text Text -> Bool
validStringMap = all validKey . Map.keys
  where
    validKey value = case Text.uncons value of
      Just (first, rest) -> first `elem` (['A' .. 'Z'] <> ['a' .. 'z'] <> "_") && Text.all (\character -> character `elem` (['A' .. 'Z'] <> ['a' .. 'z'] <> ['0' .. '9'] <> "_.-")) rest
      Nothing -> False

unique :: (Eq value) => [value] -> Bool
unique [] = True
unique (first : rest) = first `notElem` rest && unique rest
