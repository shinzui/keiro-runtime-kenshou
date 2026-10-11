{-# LANGUAGE FieldSelectors #-}

module Kenshou.Cli.Command.Perf (perfCommand, validateProfilePolicy) where

import Control.Exception (Exception, IOException, catch, displayException, throwIO)
import Control.Monad (unless, when)
import Data.Aeson hiding (decode)
import Data.Aeson.Types (parseEither)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.Text.IO qualified as Text.IO
import Kenshou.Core.Bundle (allScenarios)
import Kenshou.Core.Canonical (canonicalEncode, sha256Hex)
import Kenshou.Core.Cli
import Kenshou.Core.Cohort qualified as Cohort
import Kenshou.Core.Id (newRunId)
import Kenshou.Core.Manifest (writeManifest)
import Kenshou.Measure.Compare.Policy qualified as Policy
import Kenshou.Measure.Perf (validateProfilePolicy)
import Kenshou.Perf.Plan
import Kenshou.Perf.Request
import Kenshou.Perf.Source
import Kenshou.Plan.Catalog (fromScenario)
import Kenshou.Plan.Change.Git qualified as Git
import Kenshou.Plan.Components qualified as Graph
import Kenshou.Plan.Suite (Suite (..), readSuite)
import Options.Applicative hiding (value)
import System.Directory (createDirectory, createDirectoryIfMissing, doesPathExist)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO (stderr)
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)

data PerfFailure = PerfFailure Int Text deriving stock (Show)

instance Exception PerfFailure

perfCommand :: CliCommand
perfCommand =
  CliCommand
    { name = "perf",
      description = "Plan scoped runtime performance comparisons",
      group = Execution,
      hidden = False,
      parser = hsubparser (command "plan" (info (planParser <**> helper) (progDesc "Resolve exact source commits and explain performance scope without building or leasing")))
    }

planParser :: Parser (CliEnv -> IO ExitCode)
planParser =
  runPlan
    <$> strOption (long "request" <> metavar "FILE" <> help "kenshou.perf-request/v1 document")
    <*> strOption (long "out" <> metavar "DIRECTORY" <> help "New directory for pinned planning inputs and manifest")

runPlan :: FilePath -> FilePath -> CliEnv -> IO ExitCode
runPlan requestPath output environment = guarded do
  occupied <- doesPathExist output
  when occupied (throwIO (PerfFailure 2 "output already exists; choose a new planning directory"))
  requestBytes <- ByteString.readFile requestPath
  request <- decode "request" requestBytes
  descriptorBytes <- ByteString.readFile request.cohortTemplate
  descriptor <- decode "cohort template" descriptorBytes
  expectedPackages <- requireInput (targetPackages request descriptor)
  graph <- either (throwIO . PerfFailure 2 . (.errorText)) pure Graph.embeddedGraph
  let nodes = [component | component <- graph.components, any (`elem` expectedPackages) component.packages]
  unless (all (\package -> any (elem package . (.packages)) nodes) expectedPackages) (throwIO (PerfFailure 2 "target packages are not represented in the component graph"))
  profilesBytes <- ByteString.readFile "policies/performance/catalog.v1.json"
  profiles <- decode "performance catalog" profilesBytes
  unless (all (`elem` map (.name) profiles.profiles) request.profiles) (throwIO (PerfFailure 2 "unknown requested performance profile"))
  suiteBytes <- ByteString.readFile ("suites/" <> Text.unpack request.suite <> ".json")
  suite <- readSuite ("suites/" <> Text.unpack request.suite <> ".json") >>= requireInput
  unless (suite.name == request.suite) (throwIO (PerfFailure 2 "suite name differs from request"))
  policies <- traverse loadPolicy (nub (map (.policy) profiles.profiles))
  let policyMap = Map.fromList [(Text.pack path, sha256Hex (canonicalEncode value)) | (path, value, _) <- policies]
  mapM_ (checkPolicy policies) profiles.profiles
  let catalog = map fromScenario (allScenarios environment.registry)
  mapM_ (requireInput . validateProfile catalog) profiles.profiles
  sourceProject <- resolveProject request.project
  unless (all ((== sourceProject.repository) . (.repository)) nodes) (throwIO (PerfFailure 2 "target graph nodes belong to another repository"))
  withSystemTempDirectory "kenshou-perf-source-" \checkout -> do
    progress "verifying requested commits in the registered HTTPS upstream"
    _ <- process "git" ["init", "--quiet", checkout]
    mapM_ (fetch checkout sourceProject.location) (nub [request.baselineRevision, request.candidateRevision])
    baseline <- inspect checkout request descriptor sourceProject.location request.baselineRevision
    candidate <- if request.baselineRevision == request.candidateRevision then pure baseline else inspect checkout request descriptor sourceProject.location request.candidateRevision
    baselineDescriptor <- requireInput (descriptorForSnapshot request descriptor "baseline" baseline)
    candidateDescriptor <- requireInput (descriptorForSnapshot request descriptor "candidate" candidate)
    changedText <- process "git" ["-C", checkout, "diff", "--no-renames", "--name-only", "-z", Text.unpack request.baselineRevision, Text.unpack request.candidateRevision]
    let paths = map Text.unpack (filter (not . Text.null) (Text.splitOn "\0" changedText))
    (mapped, _) <- Git.changesFromUpstream graph (Git.UpstreamDiff sourceProject.repository checkout request.baselineRevision request.candidateRevision) >>= requireInput
    let (changes, unknown, documentation) = conservativeChanges graph sourceProject.repository paths mapped
    plan <- requireInput (planPerformance request graph catalog profiles changes unknown documentation policyMap Map.empty)
    harnessRevision <- Text.strip <$> process "git" ["rev-parse", "HEAD"]
    harnessStatus <- process "git" ["status", "--porcelain"]
    let inputs =
          object
            [ "request" .= request,
              "template" .= descriptor,
              "templateSha256" .= sha256Hex descriptorBytes,
              "baselineSource" .= baseline,
              "candidateSource" .= candidate,
              "harness" .= object ["revision" .= harnessRevision, "dirty" .= not (Text.null harnessStatus)],
              "graph" .= graph,
              "scenarioCatalog" .= catalog,
              "profileCatalog" .= profiles,
              "suite" .= either (const Null) id (eitherDecodeStrict' suiteBytes :: Either String Value),
              "policies" .= Map.fromList [(path, document) | (path, document, _) <- policies],
              "changedPaths" .= paths
            ]
    createDirectoryIfMissing True (takeDirectory output)
    -- Exclusive creation also rejects a concurrent writer racing the preflight.
    createDirectory output
    encodeFile (output </> "request.json") request
    encodeFile (output </> "inputs.json") inputs
    encodeFile (output </> "plan.json") plan
    encodeFile (output </> "baseline-cohort.json") baselineDescriptor
    encodeFile (output </> "candidate-cohort.json") candidateDescriptor
    runId <- newRunId
    manifest <- writeManifest output runId Map.empty
    encodeFile (output </> "manifest.json") manifest
    progress ("planned " <> Text.pack (show (length plan.selected)) <> " configurations; scope " <> plan.coverage)
    LazyByteString.putStrLn (encode plan)
    pure ExitSuccess
  where
    loadPolicy path = do
      bytes <- ByteString.readFile path
      parsed <- requireInput (Policy.decodePolicy bytes)
      document <- decode "comparison policy" bytes
      pure (path, document, parsed)
    checkPolicy policies profile = case [policy | (path, _, policy) <- policies, path == profile.policy] of
      [policy] -> requireInput (validateProfilePolicy profile policy)
      _ -> throwIO (PerfFailure 2 "profile policy is missing")

data SourceProject = SourceProject {repository :: Text, location :: Text}

resolveProject :: Text -> IO SourceProject
resolveProject uri = do
  let qualified = Text.unpack (Text.drop 7 uri)
  raw <- process "mori" ["registry", "show", qualified, "--full", "--json"]
  document <- requireInput (either (Left . Text.pack) Right (eitherDecodeStrict' (Text.Encoding.encodeUtf8 raw)))
  repositories <- requireInput (either (Left . Text.pack) Right (parseEither (withObject "Mori project" (.: "repositories")) document :: Either String [Value]))
  case repositories of
    [repository] -> requireInput (either (Left . Text.pack) Right (parseEither parseRepository repository))
    _ -> throwIO (PerfFailure 2 "source project must identify exactly one upstream repository")
  where
    parseRepository = withObject "Mori repository" \value -> do
      repository <- value .: "name"
      github <- value .:? "github"
      git <- value .:? "git"
      location <- case (github :: Maybe Text, git :: Maybe Text) of
        (Just hosted, _) | length (Text.splitOn "/" hosted) == 2 && Text.all (\c -> c `elem` ("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_/" :: String)) hosted -> pure ("https://github.com/" <> hosted <> ".git")
        (Nothing, Just url) | "https://" `Text.isPrefixOf` url && not (Text.any (`elem` ['@', '#', '?', '\n', '\r']) url) -> pure url
        _ -> fail "registered upstream must use HTTPS Git"
      pure (SourceProject repository location)

fetch :: FilePath -> Text -> Text -> IO ()
fetch checkout location revision = do
  _ <- process "git" ["-c", "credential.interactive=false", "-C", checkout, "fetch", "--quiet", "--no-tags", "--depth=1", Text.unpack location, Text.unpack revision]
  actual <- Text.strip <$> process "git" ["-C", checkout, "rev-parse", Text.unpack revision <> "^{commit}"]
  unless (actual == revision) (throwIO (PerfFailure 2 "upstream revision does not identify the requested commit"))

inspect :: FilePath -> PerfRequest -> Cohort.CohortDescriptor -> Text -> Text -> IO SourceSnapshot
inspect checkout request descriptor location revision = do
  pathsText <- process "git" ["-C", checkout, "ls-tree", "-r", "--name-only", "-z", Text.unpack revision]
  let paths = filter (".cabal" `Text.isSuffixOf`) (Text.splitOn "\0" pathsText)
  manifests <- traverse readManifest paths
  requireInput (sourceSnapshot request descriptor location revision [manifest | Right manifest <- manifests])
  where
    readManifest path = do
      contents <- process "git" ["-C", checkout, "show", Text.unpack revision <> ":" <> Text.unpack path]
      pure (parsePackageManifest (Text.unpack path) contents)

process :: String -> [String] -> IO Text
process executable arguments = do
  (status, output, errors) <- readProcessWithExitCode executable arguments ""
  case status of
    ExitSuccess -> pure (Text.pack output)
    _ -> throwIO (PerfFailure 4 (Text.pack executable <> ": " <> Text.strip (Text.pack errors)))

decode :: (FromJSON a) => Text -> ByteString.ByteString -> IO a
decode label bytes = requireInput (either (Left . ((label <> ": ") <>) . Text.pack) Right (eitherDecodeStrict' bytes))

requireInput :: Either Text a -> IO a
requireInput = either (throwIO . PerfFailure 2) pure

progress :: Text -> IO ()
progress = Text.IO.hPutStrLn stderr . ("kenshou perf: " <>)

guarded :: IO ExitCode -> IO ExitCode
guarded operation = operation `catch` failure `catch` ioFailure
  where
    failure (PerfFailure code message) = progress message >> pure (ExitFailure code)
    ioFailure (problem :: IOException) = progress (Text.pack (displayException problem)) >> pure (ExitFailure 4)
