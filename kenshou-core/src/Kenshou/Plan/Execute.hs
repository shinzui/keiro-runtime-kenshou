{-# LANGUAGE FieldSelectors #-}

module Kenshou.Plan.Execute
  ( ExecuteOptions (..),
    executePlan,
  )
where

import Control.Exception (finally)
import Data.Aeson
import Data.Aeson.Types (Parser)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (traverse_)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Kenshou.Core.Canonical (sha256Hex)
import Kenshou.Core.Id
import Kenshou.Core.Outcome (Outcome (..))
import Kenshou.Core.RunSpec (EnvironmentSpec, RunSpec)
import Kenshou.Core.RunSpec qualified as RunSpec
import Kenshou.Plan.Summary
import System.Directory
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Posix.Process (getProcessID)
import System.Posix.Signals (sigKILL, signalProcess)
import System.Process (createProcess, getPid, proc, readProcessWithExitCode, terminateProcess, waitForProcess)
import System.Timeout (timeout)

data ExecuteOptions = ExecuteOptions
  { planFile :: FilePath,
    outDir :: FilePath,
    resume :: Bool,
    failFast :: Bool,
    environment :: Maybe FilePath,
    timeoutFactor :: Maybe Double
  }
  deriving stock (Eq, Show)

data ExecutablePlan = ExecutablePlan {planId :: RunId, runs :: [ExecutableRun]}
  deriving stock (Eq, Show)

data ExecutableRun = ExecutableRun
  { ordinal :: Int,
    runId :: RunId,
    estimateMinutes :: Int,
    scenario :: ScenarioId,
    spec :: RunSpec
  }
  deriving stock (Eq, Show)

data ResultSummary = ResultSummary {outcome :: Outcome, blocking :: Bool, knownDefect :: Bool}
  deriving stock (Eq, Show)

executePlan :: ExecuteOptions -> IO PlanSummary
executePlan options = do
  planBytes <- ByteString.readFile options.planFile
  plan <- either (ioError . userError . Text.unpack . ("invalid run plan: " <>) . Text.pack) pure (eitherDecodeStrict' planBytes)
  environmentOverride <- traverse loadEnvironment options.environment
  createDirectoryIfMissing True options.outDir
  preparePlanCopy options planBytes
  acquireLock options.outDir
  runWithLock plan planBytes environmentOverride `finally` removeLock options.outDir
  where
    runWithLock plan _planBytes environmentOverride = do
      createDirectoryIfMissing True (options.outDir </> "specs")
      summary <- loadOrCreateSummary options plan
      executeEntries options plan environmentOverride summary

loadEnvironment :: FilePath -> IO EnvironmentSpec
loadEnvironment path = do
  bytes <- ByteString.readFile path
  either (ioError . userError . ("invalid environment document: " <>)) pure (eitherDecodeStrict' bytes)

preparePlanCopy :: ExecuteOptions -> ByteString -> IO ()
preparePlanCopy options bytes = do
  let destination = options.outDir </> "run-plan.json"
  exists <- doesFileExist destination
  if exists
    then do
      existing <- ByteString.readFile destination
      if not options.resume
        then ioError (userError "execution output already contains a plan; use --resume")
        else if sha256Hex existing /= sha256Hex bytes then ioError (userError "resume plan digest does not match run-plan.json") else pure ()
    else ByteString.writeFile destination bytes

acquireLock :: FilePath -> IO ()
acquireLock outDir = do
  let path = outDir </> ".execute.lock"
  exists <- doesFileExist path
  if exists
    then do
      contents <- readFile path
      live <- processAlive contents
      if live then ioError (userError ("executor lock is held by pid " <> contents)) else writePid path
    else writePid path
  where
    writePid path = getProcessID >>= writeFile path . show
    processAlive raw = case reads raw of
      [(pid, _)] -> do
        (code, _, _) <- readProcessWithExitCode "kill" ["-0", show (pid :: Int)] ""
        pure (code == ExitSuccess)
      _ -> pure False

removeLock :: FilePath -> IO ()
removeLock outDir = do
  let path = outDir </> ".execute.lock"
  exists <- doesFileExist path
  if exists then removeFile path else pure ()

loadOrCreateSummary :: ExecuteOptions -> ExecutablePlan -> IO PlanSummary
loadOrCreateSummary options plan = do
  let path = options.outDir </> "plan-summary.json"
  exists <- doesFileExist path
  if exists && options.resume
    then do
      bytes <- ByteString.readFile path
      either (ioError . userError . ("invalid plan summary: " <>)) pure (eitherDecodeStrict' bytes)
    else pure (emptySummary plan.planId [(run.ordinal, run.scenario) | run <- plan.runs])

executeEntries :: ExecuteOptions -> ExecutablePlan -> Maybe EnvironmentSpec -> PlanSummary -> IO PlanSummary
executeEntries options plan environmentOverride = go plan.runs
  where
    summaryPath = options.outDir </> "plan-summary.json"
    go [] summary = writeSummary summaryPath (finalizeSummary summary) >> pure (finalizeSummary summary)
    go (run : rest) summary = case findEntry run.ordinal summary.entries of
      Just entry | entry.status == Completed -> go rest summary
      _ -> do
        let priorAttempts = maybe [] (.attempts) (findEntry run.ordinal summary.entries)
        attemptId <- if null priorAttempts then pure run.runId else newRunId
        startedAt <- getCurrentTime
        let attempt = Attempt attemptId startedAt Nothing Nothing False Nothing
            running = updateEntry run.ordinal (\entry -> entry {status = Running, attempts = entry.attempts <> [attempt]}) summary
        writeSummary summaryPath running
        writeSpec options environmentOverride run
        childCode <- spawnRun options run attemptId
        finishedAt <- getCurrentTime
        result <- readResult options attemptId childCode
        let completedAttempt = attempt {finishedAt = Just finishedAt, outcome = Just result.outcome, knownDefect = result.knownDefect, childExitCode = Just (exitCodeInt childCode)}
            completed = finalizeSummary (updateEntry run.ordinal (\entry -> entry {status = Completed, attempts = priorAttempts <> [completedAttempt]}) running)
        writeSummary summaryPath completed
        if options.failFast && result.blocking && result.outcome == Failed then pure completed else go rest completed

writeSpec :: ExecuteOptions -> Maybe EnvironmentSpec -> ExecutableRun -> IO ()
writeSpec options environmentOverride run = LazyByteString.writeFile path (encode effective)
  where
    path = options.outDir </> "specs" </> pad run.ordinal <> ".json"
    effective = maybe run.spec (replaceEnvironment run.spec) environmentOverride
    pad value = let rendered = show value in replicate (4 - min 4 (length rendered)) '0' <> rendered

replaceEnvironment :: RunSpec -> EnvironmentSpec -> RunSpec
replaceEnvironment spec environment =
  RunSpec.RunSpec
    spec.runId
    spec.scenario
    spec.scenarioRevision
    spec.knobs
    spec.dimensions
    spec.seed
    spec.phases
    spec.timeoutSeconds
    environment
    spec.cohortExpectation
    spec.comparison
    spec.labels

spawnRun :: ExecuteOptions -> ExecutableRun -> RunId -> IO ExitCode
spawnRun options run runId = do
  executable <- getExecutablePath
  let specPath = options.outDir </> "specs" </> pad run.ordinal <> ".json"
  (_, _, _, processHandle) <- createProcess (proc executable ["run", "--spec", specPath, "--out", options.outDir, "--run-id", Text.unpack (renderRunId runId)])
  case options.timeoutFactor of
    Nothing -> waitForProcess processHandle
    Just factor -> do
      result <- timeout (floor (factor * fromIntegral run.estimateMinutes * 60 * 1000000)) (waitForProcess processHandle)
      case result of
        Just code -> pure code
        Nothing -> do
          terminateProcess processHandle
          stopped <- timeout 30000000 (waitForProcess processHandle)
          case stopped of
            Just _ -> pure (ExitFailure 124)
            Nothing -> do
              traverse_ (signalProcess sigKILL) =<< getPid processHandle
              _ <- waitForProcess processHandle
              pure (ExitFailure 124)
  where
    pad value = let rendered = show value in replicate (4 - min 4 (length rendered)) '0' <> rendered

readResult :: ExecuteOptions -> RunId -> ExitCode -> IO ResultSummary
readResult options runId _childCode = do
  let path = options.outDir </> Text.unpack (renderRunId runId) </> "run-result.json"
  exists <- doesFileExist path
  if not exists
    then pure (ResultSummary Errored True False)
    else do
      bytes <- ByteString.readFile path
      pure (either (const (ResultSummary Errored True False)) (\value -> value) (eitherDecodeStrict' bytes))

findEntry :: Int -> [SummaryEntry] -> Maybe SummaryEntry
findEntry ordinal = foldr (\entry found -> if entry.ordinal == ordinal then Just entry else found) Nothing

updateEntry :: Int -> (SummaryEntry -> SummaryEntry) -> PlanSummary -> PlanSummary
updateEntry ordinal update summary = summary {entries = fmap (\entry -> if entry.ordinal == ordinal then update entry else entry) summary.entries}

exitCodeInt :: ExitCode -> Int
exitCodeInt ExitSuccess = 0
exitCodeInt (ExitFailure value) = value

instance FromJSON ExecutablePlan where
  parseJSON = withObject "ExecutablePlan" \value -> do
    schema <- value .: "schema"
    if schema /= ("kenshou.run-plan/v1" :: Text) then fail "unsupported run-plan schema" else pure ()
    ExecutablePlan <$> value .: "planId" <*> value .: "runs"

instance FromJSON ExecutableRun where
  parseJSON = withObject "ExecutableRun" \value -> do
    ordinal <- value .: "ordinal"
    runId <- value .: "runId"
    estimateMinutes <- value .: "estimateMinutes"
    spec <- value .: "spec"
    let scenario = spec.scenario
    pure ExecutableRun {ordinal, runId, estimateMinutes, scenario, spec}

instance FromJSON ResultSummary where
  parseJSON = withObject "ResultSummary" \value -> do
    outcome <- value .: "outcome"
    blocking <- value .:? "blocking" .!= True
    defect <- value .:? "knownDefect" :: Parser (Maybe Value)
    pure (ResultSummary outcome blocking (isJust defect))
