module Kenshou.Core.Run
  ( RunnerConfig (..),
    RunOutput (..),
    executeRun,
  )
where

import Control.Exception (SomeException, displayException, fromException, try)
import Control.Monad (when)
import Data.Aeson (ToJSON, Value, encode, object, (.=))
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (diffUTCTime, getCurrentTime)
import Kenshou.Core.Bundle (Registry)
import Kenshou.Core.Canonical (sha256Hex)
import Kenshou.Core.Cohort (CohortIdentity (..), PlanHash (..))
import Kenshou.Core.Compat (comparisonKey, compatInputs, seriesKey)
import Kenshou.Core.Context
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..))
import Kenshou.Core.Env.Postgres (EnvError (..), PgSettingsSnapshot, PostgresEnv (..), withPostgresEnvKeeping)
import Kenshou.Core.Fingerprint (HostFingerprint (..), collectHostFingerprint, hostValue, kenshouValue, runtimeValue)
import Kenshou.Core.Id (renderRunId, unSeed)
import Kenshou.Core.Log (Severity (Warning), withLogger)
import Kenshou.Core.Manifest (writeManifest)
import Kenshou.Core.Outcome (Outcome (..), outcomeExitCode)
import Kenshou.Core.RunResult
import Kenshou.Core.RunSpec (CohortExpectation (..), EffectiveRunSpec (..), EnvironmentSpec (..), RunSpec)
import Kenshou.Core.RunSpec.Resolve (SpecError (..), resolveRunSpec)
import Kenshou.Core.Scenario (KnownDefect (..), Scenario (..), ScenarioReport (..), cohortScopeApplies, infrastructureFailureBecause)
import System.Directory (createDirectory, createDirectoryIfMissing, doesDirectoryExist, getCurrentDirectory, renameFile)
import System.FilePath ((</>))
import System.Timeout (timeout)

data RunnerConfig = RunnerConfig
  { registry :: Registry,
    outRoot :: FilePath,
    cohort :: CohortIdentity,
    cellFingerprint :: Maybe Value,
    keepEnvironment :: Bool,
    strictKnownDefects :: Bool,
    argv :: [String]
  }

data RunOutput = RunOutput {directory :: FilePath, result :: RunResult, manifestSha256 :: Text}

executeRun :: RunnerConfig -> RunSpec -> IO (Either (NonEmpty SpecError) RunOutput)
executeRun config input = do
  resolution <- resolveRunSpec config.registry input
  case resolution of
    Left problems -> pure (Left problems)
    Right (scenario, spec) -> do
      let directory = config.outRoot </> Text.unpack (renderRunId spec.runId)
      exists <- doesDirectoryExist directory
      if exists
        then pure (Left (SpecError ("run directory already exists: " <> Text.pack directory) :| []))
        else do
          createDirectoryIfMissing True config.outRoot
          createDirectory directory
          createDirectory (directory </> "logs")
          atomicEncode (directory </> "run-spec.json") spec
          specBytes <- ByteString.readFile (directory </> "run-spec.json")
          (result, mediaTypes) <- withLogger (directory </> "logs" </> "harness.jsonl") spec.runId \logger -> do
            startedAt <- getCurrentTime
            state <- newRunState
            let context = RunContext spec.runId spec.scenario spec.knobs spec.dimensions spec.seed spec.phases (Environment Nothing Map.empty) spec.environment spec.comparison directory logger state
            (report, postgresSnapshot, extraPostgresSnapshots) <- runScenario config scenario spec context
            endedAt <- getCurrentTime
            host <- collectHostFingerprint
            when (host.revision == Nothing) (observe context "harness" Warning "harness revision is unavailable")
            (summaries, observations, phaseTimings, mediaTypes) <- readRunState state
            workingDirectory <- getCurrentDirectory
            let (defect, blocking, exitCode) = defectDisposition config.strictKnownDefects config.cohort scenario report
                schemas = maybe [] (.schemas) scenario.requires.postgres
                inputs = compatInputs spec postgresSnapshot schemas config.cohort
                compatibility = object ["algorithm" .= ("kenshou.compat-key/v1" :: Text), "comparisonKey" .= comparisonKey inputs, "seriesKey" .= seriesKey inputs, "inputs" .= inputs]
                fingerprint = object ["placement" .= spec.environment.placement, "machineProfile" .= spec.environment.machineProfile, "host" .= hostValue host, "runtime" .= runtimeValue host, "kenshou" .= kenshouValue host, "postgres" .= postgresSnapshot, "extraPostgres" .= extraPostgresSnapshots, "cell" .= config.cellFingerprint]
                invocation = object ["argv" .= config.argv, "workingDirectory" .= workingDirectory]
                result = RunResult spec.runId spec.scenario spec.scenarioRevision scenario.tier report.outcome blocking exitCode report.reason report.failures defect (unSeed spec.seed) (sha256Hex specBytes) spec.comparison startedAt endedAt (realToFrac (diffUTCTime endedAt startedAt)) phaseTimings config.cohort fingerprint compatibility summaries observations invocation
            atomicEncode (directory </> "run-result.json") result
            pure (result, mediaTypes)
          manifest <- writeManifest directory spec.runId mediaTypes
          atomicEncode (directory </> "manifest.json") manifest
          manifestBytes <- ByteString.readFile (directory </> "manifest.json")
          pure (Right (RunOutput directory result (sha256Hex manifestBytes)))

runScenario :: RunnerConfig -> Scenario -> EffectiveRunSpec -> RunContext -> IO (ScenarioReport, Maybe PgSettingsSnapshot, Map.Map Text PgSettingsSnapshot)
runScenario config scenario spec context
  | cohortMismatch config.cohort spec.cohortExpectation = pure (infrastructureFailureBecause "cohort-mismatch", Nothing, Map.empty)
  | otherwise = do
      nested <- withPrimary scenario.requires.postgres spec.environment.postgres \primary ->
        withExtras scenario.requires.extraPostgres spec.environment.extraPostgres Map.empty \extras -> do
          let environment = Environment primary extras
          report <- timed context {env = environment}
          pure (report, (.snapshot) <$> primary, fmap (.snapshot) extras)
      let provisioned = nested >>= id
      pure (either (\err -> (infrastructureFailureBecause (Text.pack (show err)), Nothing, Map.empty)) id provisioned)
  where
    withPrimary Nothing _ action = Right <$> action Nothing
    withPrimary (Just requirement) (Just postgresSpec) action = withPostgresEnvKeeping config.keepEnvironment context.logger context.outDir spec.runId requirement postgresSpec spec.dimensions (action . Just)
    withPrimary (Just _) Nothing _ = pure (Left (EnvError "PostgreSQL specification is missing"))

    withExtras [] _ accumulated action = Right <$> action accumulated
    withExtras ((name, requirement) : rest) postgresSpecs accumulated action = case Map.lookup name postgresSpecs of
      Nothing -> pure (Left (EnvError ("extra PostgreSQL specification is missing: " <> name)))
      Just postgresSpec -> do
        provisioned <- withPostgresEnvKeeping config.keepEnvironment context.logger context.outDir spec.runId requirement postgresSpec spec.dimensions \postgres ->
          withExtras rest postgresSpecs (Map.insert name postgres accumulated) action
        pure (provisioned >>= id)

    timed runContext = do
      execution <- try (timeout (spec.timeoutSeconds * 1000000) (scenario.run runContext)) :: IO (Either SomeException (Maybe ScenarioReport))
      pure case execution of
        Left exception -> case fromException exception of
          Just (InfrastructureError message) -> ScenarioReport InfrastructureFailure (Just message) []
          Nothing -> ScenarioReport Errored (Just (Text.pack (displayException exception))) []
        Right Nothing -> ScenarioReport Errored (Just ("timeout after " <> Text.pack (show spec.timeoutSeconds) <> " s")) []
        Right (Just report) -> report

cohortMismatch :: CohortIdentity -> Maybe CohortExpectation -> Bool
cohortMismatch _ Nothing = False
cohortMismatch cohort (Just expectation) = unPlanHash cohort.identityPlanHash /= expectation.planHash

defectDisposition :: Bool -> CohortIdentity -> Scenario -> ScenarioReport -> (Maybe (KnownDefect, KnownDefectStatus), Bool, Int)
defectDisposition strict cohort scenario report = case scenario.knownDefect of
  Just defect | not (cohortScopeApplies cohort defect.appliesTo) -> ordinary
  Nothing -> (Nothing, report.outcome /= Passed, outcomeExitCode report.outcome)
  Just defect ->
    let status
          | report.outcome == Failed && all (`elem` defect.expectedFailures) report.failures = DefectReproduced
          | report.outcome == Failed = DefectDifferentFailure
          | otherwise = DefectNotReproduced
        blocking = report.outcome /= Passed && status /= DefectReproduced
        exitCode = if status == DefectReproduced && not strict then 0 else outcomeExitCode report.outcome
     in (Just (defect, status), blocking, exitCode)
  where
    ordinary = (Nothing, report.outcome /= Passed, outcomeExitCode report.outcome)

atomicEncode :: (ToJSON value) => FilePath -> value -> IO ()
atomicEncode path value = do
  let temporary = path <> ".tmp"
  LazyByteString.writeFile temporary (encode value <> "\n")
  renameFile temporary path
