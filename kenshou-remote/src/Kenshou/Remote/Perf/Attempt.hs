module Kenshou.Remote.Perf.Attempt
  ( TrialExecutor,
    executeAttempt,
    verifyAttempt,
    verifyAttemptInputs,
  )
where

import Control.Monad (unless)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither)
import Data.List (find, nub, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Id (renderRunId, renderScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.RunSpec (ComparisonMembership (..), RunSpec (..))
import Kenshou.Measure.Compare
import Kenshou.Measure.Compare.Compatibility (VaryingAxis)
import Kenshou.Measure.Compare.Policy (Policy)
import Kenshou.Measure.Perf
import Kenshou.Perf.Plan (PerfProfile (..), PlannedProfile (..))
import Kenshou.Perf.Result
import Kenshou.Plan.RunPlan (PlannedRun (..), RunPlan (..), TrialInfo (..))
import Kenshou.Remote.Perf.Journal (LeaseIdentity)
import Kenshou.Remote.Perf.Runner (ComparisonHooks (..))
import System.Directory (canonicalizePath, createDirectoryIfMissing, doesFileExist, renameFile)
import System.FilePath (isAbsolute, makeRelative, splitDirectories, (</>))

-- The adapter persists cell work before submission. Calling it again for the
-- same entry reconciles the existing low-level journal under the SAME lease.
-- It returns a verified nested run directory, retaining the outer cell tree.
type TrialExecutor = PlannedRun -> IO (Either Text FilePath)

data Observation = Observation PlannedRun (Maybe FilePath) [AdmissionProblem]

executeAttempt :: LeaseIdentity -> PlannedProfile -> RunPlan -> Policy -> NonEmpty VaryingAxis -> FilePath -> ComparisonHooks -> TrialExecutor -> IO ConfigurationResult
executeAttempt lease entry schedule policy axes directory callbacks execute = do
  createDirectoryIfMissing True directory
  let inputs = attemptInputs lease entry schedule
  immutable (directory </> "attempt.json") inputs
  validateSchedule entry schedule
  paths <- loadPaths directory
  validatePaths directory schedule paths
  failures <- loadFailures directory schedule paths
  atomicPaths directory paths
  collect paths failures [] [0 .. entry.profile.minimumPairs - 1] >>= continue entry.profile.minimumPairs
  where
    collect paths failures observations [] = pure (paths, failures, observations)
    collect paths failures observations (index : rest) = do
      let runs = filter (maybe False ((== index) . (.index)) . (.trial)) schedule.runs
      (changed, rejected, appended) <- runEntries paths failures runs
      collect changed rejected (observations <> appended) rest
    runEntries paths failures [] = pure (paths, failures, [])
    runEntries paths failures (run : rest) = do
      let identifier = renderRunId run.runId
      located <- case (Map.lookup identifier paths, Map.lookup identifier failures) of
        (Just relative, _) -> pure (Right (directory </> relative))
        (_, Just reason) -> pure (Left reason)
        _ -> execute run
      (changed, rejected, observation) <- case located of
        Left reason -> do
          let rejected = Map.insert identifier reason failures
          atomicJSON (directory </> "trial-failures.json") rejected
          pure (paths, rejected, Observation run Nothing [InvalidPerformanceEvidence reason])
        Right path -> do
          relative <- relativePath directory path
          let changed = Map.insert (renderRunId run.runId) relative paths
          atomicPaths directory changed
          observation <- admitTrial entry.profile run path
          mapM_ callbacks.recordRuntimeFailure (runtimeProblems observation)
          pure (changed, failures, observation)
      (final, finalFailures, appended) <- runEntries changed rejected rest
      pure (final, finalFailures, observation : appended)
    continue next (paths, failures, observations)
      | length (validPairs observations) >= entry.profile.minimumPairs = finish directory entry policy axes observations
      | next >= entry.profile.minimumPairs + entry.profile.replacementPairs = finish directory entry policy axes observations
      | otherwise = do
          callbacks.reserveReplacement next
          updated <- collect paths failures observations [next]
          continue (next + 1) updated

-- Replay uses only retained paths and rechecks every trial, including failures.
-- It never submits work or overwrites the original comparison bytes.
verifyAttempt :: PlannedProfile -> RunPlan -> Policy -> NonEmpty VaryingAxis -> FilePath -> ConfigurationResult -> IO Bool
verifyAttempt entry schedule policy axes directory retained = do
  validateSchedule entry schedule
  paths <- loadPaths directory
  validatePaths directory schedule paths
  failures <- loadFailures directory schedule paths
  observations <-
    traverse
      ( \run -> case Map.lookup (renderRunId run.runId) paths of
          Nothing -> pure (Observation run Nothing [InvalidPerformanceEvidence (Map.findWithDefault "trial has no retained result" (renderRunId run.runId) failures)])
          Just relative -> admitTrial entry.profile run (directory </> relative)
      )
      [run | run <- schedule.runs, Map.member (renderRunId run.runId) paths || Map.member (renderRunId run.runId) failures]
  recomputed <- finish directory entry policy axes observations
  pure (same recomputed retained)
  where
    same left right =
      left.profile == right.profile
        && left.workloadSha256 == right.workloadSha256
        && left.performanceVerdict == right.performanceVerdict
        && left.infrastructureState == right.infrastructureState
        && all (`elem` right.runtimeFailures) left.runtimeFailures
        && left.validPairs == right.validPairs
        && left.attempts == right.attempts
        && case (left.comparison, right.comparison) of
          (Just a, Just b) -> semanticComparison a == semanticComparison b
          (Nothing, Nothing) -> True
          _ -> False

verifyAttemptInputs :: LeaseIdentity -> PlannedProfile -> RunPlan -> FilePath -> IO ()
verifyAttemptInputs lease entry schedule directory = do
  validateSchedule entry schedule
  header <- eitherDecodeFileStrict' (directory </> "attempt.json") >>= either (ioError . userError) pure
  unless (header == attemptInputs lease entry schedule) (ioError (userError "retained attempt header differs from its journaled lease or pinned workload"))
  paths <- loadPaths directory
  validatePaths directory schedule paths
  _ <- loadFailures directory schedule paths
  pure ()

attemptInputs :: LeaseIdentity -> PlannedProfile -> RunPlan -> Value
attemptInputs lease entry schedule = object ["schema" .= ("kenshou.perf-attempt/v1" :: Text), "lease" .= lease, "workloadSha256" .= entry.workloadSha256, "plan" .= schedule]

admitTrial :: PerfProfile -> PlannedRun -> FilePath -> IO Observation
admitTrial profile run directory = do
  admitted <- verifyPerformanceRun profile directory
  result <- eitherDecodeFileStrict' (directory </> "run-result.json")
  spec <- eitherDecodeFileStrict' (directory </> "run-spec.json") :: IO (Either String RunSpec)
  let binding = do
        document <- either (Left . Text.pack) Right result
        effective <- either (Left . Text.pack) Right spec
        either (Left . Text.pack) Right (parseEither (withObject "runtime result" (.: "runId")) document) >>= \identifier ->
          unless (identifier == run.runId) (Left "retained result has a different run ID")
        unless
          ( effective.runId == Just run.runId
              && effective.scenario == run.spec.scenario
              && effective.seed == run.spec.seed
              && effective.scenarioRevision == Just profile.scenarioRevision
              && effective.phases == Just zeroPhases
              && effective.timeoutSeconds == Just profile.timeoutSeconds
              && knobs (toJSON effective) == knobs (toJSON run.spec)
              && Map.fromList effective.dimensions == Map.fromList run.spec.dimensions
          )
          (Left "retained runtime inputs differ from the pinned trial")
      problems = either id (const []) admitted <> either (\reason -> [InvalidPerformanceEvidence reason]) (const []) binding
  pure (Observation run (Just directory) problems)
  where
    knobs (Object fields) = KeyMap.lookup "knobs" fields
    knobs _ = Nothing

runtimeProblems :: Observation -> [Text]
runtimeProblems (Observation _ _ problems) = [reason | RuntimeWorkFailure reason <- problems]

validPairs :: [Observation] -> [Int]
validPairs observations = filter valid (sort (nub [trial.index | Observation run _ _ <- observations, Just trial <- [run.trial]]))
  where
    valid index = case [observation | observation@(Observation run _ _) <- observations, maybe False ((== index) . (.index)) run.trial] of
      [Observation a (Just _) ap, Observation b (Just _) bp] ->
        fmap (.arm) a.trial /= fmap (.arm) b.trial && all runtimeOnly (ap <> bp)
      _ -> False
    runtimeOnly (RuntimeWorkFailure _) = True
    runtimeOnly _ = False

finish :: FilePath -> PlannedProfile -> Policy -> NonEmpty VaryingAxis -> [Observation] -> IO ConfigurationResult
finish root entry policy axes observations = do
  let chosen = take entry.profile.minimumPairs (validPairs observations)
      path index arm = case find (\(Observation run _ _) -> maybe False (\trial -> trial.index == index && trial.arm == arm) run.trial) observations of
        Just (Observation _ (Just directory) _) -> directory
        _ -> error "valid pair lacks a retained arm"
      failures = nub (concatMap runtimeProblems observations)
      attempts = [object ["runId" .= run.runId, "path" .= fmap (makeRelative root) directory, "problems" .= map (Text.replace (Text.pack root) "." . Text.pack . show) problems] | Observation run directory problems <- observations]
      make verdict infrastructure comparison = ConfigurationResult entry.profile.name entry.workloadSha256 verdict infrastructure failures (length chosen) entry.profile.minimumPairs attempts comparison
  if length chosen < entry.profile.minimumPairs
    then pure (make "inconclusive" "failed" Nothing)
    else do
      compared <- compareRuns policy axes (map (`path` "baseline") chosen) (map (`path` "candidate") chosen)
      case compared of
        Left (CompareError _) -> pure (make "inconclusive" "failed" Nothing)
        Right comparison ->
          pure
            ( make
                (case comparison.verdict of VerdictPass -> "pass"; VerdictRegression -> "regression"; _ -> "inconclusive")
                (if comparison.verdict == VerdictInfrastructureFailure || length chosen < entry.profile.minimumPairs then "failed" else "healthy")
                (Just (toJSON comparison))
            )

validateSchedule :: PlannedProfile -> RunPlan -> IO ()
validateSchedule entry schedule = do
  let runs = schedule.runs
      identifiers = map (.runId) runs
      expected = entry.profile.minimumPairs + entry.profile.replacementPairs
      trials = [(trial.index, trial.arm) | run <- runs, Just trial <- [run.trial]]
      ordering = [(index, arm) | index <- [0 .. expected - 1], arm <- if even index then ["baseline", "candidate"] else ["candidate", "baseline"]]
      seeds = [nub [run.spec.seed | run <- runs, maybe False ((== index) . (.index)) run.trial] | index <- [0 .. expected - 1]]
  unless
    ( length runs == 2 * expected
        && nub identifiers == identifiers
        && trials == ordering
        && map (.ordinal) runs == [1 .. 2 * expected]
        && all ((== 1) . length) seeds
        && all (\run -> run.spec.runId == Just run.runId && maybe False ((== expected) . (.of_)) run.trial) runs
        && all memberMatches runs
    )
    (ioError (userError "attempt must contain the full fixed paired schedule"))
  unless (all matches runs) (ioError (userError "attempt workload differs from its pinned profile"))
  where
    memberMatches run = case (run.trial, run.spec.comparison) of
      (Just trial, Just membership) -> membership.group == trial.group && membership.arm == trial.arm && membership.trial == trial.index && membership.position == run.ordinal - 1
      _ -> False
    matches run =
      renderScenarioId run.spec.scenario == entry.profile.scenario
        && run.spec.scenarioRevision == Just entry.profile.scenarioRevision
        && run.spec.seed /= Nothing
        && run.spec.phases == Just zeroPhases
        && run.spec.timeoutSeconds == Just entry.profile.timeoutSeconds
        && Map.fromList run.spec.dimensions == entry.profile.dimensions
        && case toJSON run.spec of
          Object fields -> KeyMap.lookup "knobs" fields == Just (toJSON entry.profile.knobs)
          _ -> False

validatePaths :: FilePath -> RunPlan -> Map Text FilePath -> IO ()
validatePaths directory schedule paths = do
  unless
    (all (`elem` map (renderRunId . (.runId)) schedule.runs) (Map.keys paths))
    (ioError (userError "retained trial path names an unplanned run"))
  mapM_
    ( \relative -> do
        actual <- relativePath directory (directory </> relative)
        unless (actual == relative) (ioError (userError "retained trial path contains a directory alias"))
    )
    (Map.elems paths)

loadPaths :: FilePath -> IO (Map Text FilePath)
loadPaths directory = do
  let path = directory </> "trial-paths.json"
  exists <- doesFileExist path
  paths <- if exists then eitherDecodeFileStrict' path >>= either (ioError . userError) pure else pure Map.empty
  unless (all safe (Map.elems paths)) (ioError (userError "unsafe retained trial path"))
  pure paths
  where
    safe path = not (null path) && not (isAbsolute path) && all (`notElem` ["..", ".", ""]) (splitDirectories path)

loadFailures :: FilePath -> RunPlan -> Map Text FilePath -> IO (Map Text Text)
loadFailures directory schedule paths = do
  let path = directory </> "trial-failures.json"
  exists <- doesFileExist path
  failures <- if exists then eitherDecodeFileStrict' path >>= either (ioError . userError) pure else pure Map.empty
  unless (all (`elem` map (renderRunId . (.runId)) schedule.runs) (Map.keys failures) && all (`Map.notMember` paths) (Map.keys failures) && all (not . Text.null) (Map.elems failures)) (ioError (userError "retained trial failure has an unknown, conflicting or empty identity"))
  pure failures

relativePath :: FilePath -> FilePath -> IO FilePath
relativePath root path = do
  absoluteRoot <- canonicalizePath root
  absolutePath <- canonicalizePath path
  let relative = makeRelative absoluteRoot absolutePath
  unless (relative /= absolutePath && ".." `notElem` splitDirectories relative) (ioError (userError "trial evidence escaped its attempt directory"))
  pure relative

atomicPaths :: FilePath -> Map Text FilePath -> IO ()
atomicPaths directory paths = do
  atomicJSON (directory </> "trial-paths.json") paths

atomicJSON :: (ToJSON document) => FilePath -> document -> IO ()
atomicJSON destination document = do
  let temporary = destination <> ".next"
  encodeFile temporary document
  renameFile temporary destination

immutable :: FilePath -> Value -> IO ()
immutable path document = do
  exists <- doesFileExist path
  if exists
    then do
      retained <- eitherDecodeFileStrict' path >>= either (ioError . userError) pure
      unless (retained == document) (ioError (userError "attempt lease, workload or schedule changed"))
    else atomicJSON path document
