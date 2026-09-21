module Kenshou.Core.Context
  ( SummarySection (..),
    ArtifactDir (..),
    Observation (..),
    Environment (..),
    RunContext (..),
    RunState,
    PhaseTiming (..),
    InfrastructureError (..),
    newRunState,
    readRunState,
    requirePostgres,
    genFor,
    withPhase,
    putSummary,
    observe,
    artifactPath,
    declareMediaType,
  )
where

import Control.Exception (Exception, bracket_)
import Data.Aeson (ToJSON (..), Value, object, (.=))
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (UTCTime, getCurrentTime)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Stack (HasCallStack)
import Kenshou.Core.Dimension (Dimensions)
import Kenshou.Core.Env.Postgres (PostgresEnv)
import Kenshou.Core.Id (RunId, ScenarioId, Seed, deriveGen)
import Kenshou.Core.Knob (ResolvedKnobs)
import Kenshou.Core.Log (Logger, Severity)
import Kenshou.Core.Phase (PhaseName, PhasePlan)
import Kenshou.Core.RunSpec (ComparisonMembership, EnvironmentSpec)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.Random.SplitMix (SMGen)

data SummarySection = Measurements | Verdicts | Diagnosis | Telemetry deriving stock (Eq, Ord, Show)

data ArtifactDir = SamplesDir | SeriesDir | VerdictsDir | DiagnosisDir | LogsDir deriving stock (Eq, Ord, Show)

data Observation = Observation {source :: Text, severity :: Severity, message :: Text, at :: UTCTime} deriving stock (Eq, Show)

data Environment = Environment {postgres :: Maybe PostgresEnv, extraPostgres :: Map Text PostgresEnv}

data PhaseTiming = PhaseTiming
  { name :: PhaseName,
    startedAt :: UTCTime,
    endedAt :: UTCTime,
    startedMonotonicNs :: Word64,
    endedMonotonicNs :: Word64
  }
  deriving stock (Eq, Show)

instance ToJSON PhaseTiming where
  toJSON timing = object ["name" .= timing.name, "startedAt" .= timing.startedAt, "endedAt" .= timing.endedAt, "startedMonotonicNs" .= timing.startedMonotonicNs, "endedMonotonicNs" .= timing.endedMonotonicNs]

data RunState = RunState
  { summaries :: IORef (Map SummarySection (Map Text Value)),
    observations :: IORef [Observation],
    phaseTimings :: IORef [PhaseTiming],
    mediaTypes :: IORef (Map FilePath Text)
  }

data RunContext = RunContext
  { runId :: RunId,
    scenario :: ScenarioId,
    knobs :: ResolvedKnobs,
    dimensions :: Dimensions,
    seed :: Seed,
    phases :: PhasePlan,
    env :: Environment,
    environmentSpec :: EnvironmentSpec,
    comparison :: Maybe ComparisonMembership,
    outDir :: FilePath,
    logger :: Logger,
    state :: RunState
  }

newtype InfrastructureError = InfrastructureError Text deriving stock (Eq, Show)

instance Exception InfrastructureError

newRunState :: IO RunState
newRunState = RunState <$> newIORef Map.empty <*> newIORef [] <*> newIORef [] <*> newIORef Map.empty

readRunState :: RunState -> IO (Map SummarySection (Map Text Value), [Observation], [PhaseTiming], Map FilePath Text)
readRunState state = (,,,) <$> readIORef state.summaries <*> readIORef state.observations <*> readIORef state.phaseTimings <*> readIORef state.mediaTypes

requirePostgres :: (HasCallStack) => RunContext -> PostgresEnv
requirePostgres context = maybe (error "requirePostgres: scenario did not declare PostgreSQL") id context.env.postgres

genFor :: RunContext -> Text -> SMGen
genFor context = deriveGen context.seed

withPhase :: RunContext -> PhaseName -> IO value -> IO value
withPhase context phase action = do
  startedAt <- getCurrentTime
  startedMono <- getMonotonicTimeNSec
  action `finallyRecord` do
    endedAt <- getCurrentTime
    endedMono <- getMonotonicTimeNSec
    modifyIORef' context.state.phaseTimings (<> [PhaseTiming phase startedAt endedAt startedMono endedMono])
  where
    finallyRecord body cleanup = bracket_ (pure ()) cleanup body

putSummary :: RunContext -> SummarySection -> Text -> Value -> IO ()
putSummary context section key value = modifyIORef' context.state.summaries (Map.alter (Just . Map.insert key value . maybe Map.empty id) section)

observe :: RunContext -> Text -> Severity -> Text -> IO ()
observe context source severity message = do
  at <- getCurrentTime
  modifyIORef' context.state.observations (<> [Observation source severity message at])

artifactPath :: RunContext -> ArtifactDir -> FilePath -> IO FilePath
artifactPath context directory name = do
  let root = context.outDir </> artifactDir directory
  createDirectoryIfMissing True root
  pure (root </> name)

declareMediaType :: RunContext -> FilePath -> Text -> IO ()
declareMediaType context path mediaType = modifyIORef' context.state.mediaTypes (Map.insert path mediaType)

artifactDir :: ArtifactDir -> FilePath
artifactDir SamplesDir = "samples"
artifactDir SeriesDir = "series"
artifactDir VerdictsDir = "verdicts"
artifactDir DiagnosisDir = "diagnosis"
artifactDir LogsDir = "logs"
