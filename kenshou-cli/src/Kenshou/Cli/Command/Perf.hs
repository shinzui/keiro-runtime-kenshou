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
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Kenshou.Core.Bundle (allScenarios)
import Kenshou.Core.Canonical (canonicalEncode, sha256Hex)
import Kenshou.Core.Cli
import Kenshou.Core.Cohort qualified as Cohort
import Kenshou.Measure.Compare.Policy qualified as Policy
import Kenshou.Measure.Perf (validateProfilePolicy)
import Kenshou.Perf.Artifacts (sealPerfDirectory, verifyPerfManifest)
import Kenshou.Perf.Plan
import Kenshou.Perf.Prepared qualified as Prepared
import Kenshou.Perf.Request
import Kenshou.Perf.Source
import Kenshou.Plan.Catalog (fromScenario)
import Kenshou.Plan.Change.Git qualified as Git
import Kenshou.Plan.Components qualified as Graph
import Kenshou.Plan.Suite (Suite (..), readSuite)
import Kenshou.Remote.Payload qualified as Payload
import Kenshou.Remote.Payload.Publish (digestFile)
import Kenshou.Remote.Payload.Publisher qualified as Publisher
import Kenshou.Remote.Store (Bucket (..), ObjectName (..), ObjectStore (..))
import Kenshou.Remote.Store.File (newFileStore)
import Kenshou.Remote.Store.Gcs (newGcsStore, newTokenProvider)
import Options.Applicative hiding (value)
import Options.Applicative qualified as Options
import System.Directory (createDirectory, createDirectoryIfMissing, doesFileExist, doesPathExist, getCurrentDirectory, listDirectory, makeAbsolute, renameFile)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO (stderr)
import System.IO.Temp (withSystemTempDirectory, withTempDirectory)
import System.Process (readProcessWithExitCode)

data PerfFailure = PerfFailure Int Text deriving stock (Show)

instance Exception PerfFailure

perfCommand :: CliCommand
perfCommand =
  CliCommand
    { name = "perf",
      description = "Plan and prepare scoped runtime performance comparisons",
      group = Execution,
      hidden = False,
      parser =
        hsubparser
          ( command "plan" (info (planParser <**> helper) (progDesc "Resolve exact source commits and explain performance scope without building or leasing"))
              <> command "prepare" (info (prepareParser <**> helper) (progDesc "Check independent build inputs and publish both exact-revision payloads without leasing"))
          )
    }

planParser :: Parser (CliEnv -> IO ExitCode)
planParser =
  runPlan
    <$> strOption (long "request" <> metavar "FILE" <> help "kenshou.perf-request/v1 document")
    <*> strOption (long "out" <> metavar "DIRECTORY" <> help "New directory for pinned planning inputs and manifest")

prepareParser :: Parser (CliEnv -> IO ExitCode)
prepareParser =
  runPrepare
    <$> strOption (long "request" <> metavar "FILE")
    <*> strOption (long "out" <> metavar "DIRECTORY")
    <*> strOption (long "cache" <> metavar "DIRECTORY" <> Options.value ".dev/perf-payload-cache" <> showDefault)
    <*> strOption (long "control-bucket" <> metavar "BUCKET" <> Options.value "tan-nb-exp-cells-control" <> showDefault)

data ArmInputs = ArmInputs
  { armDescriptor :: Cohort.CohortDescriptor,
    armLock :: Value,
    armInventory :: Prepared.BuildInventory,
    armBounds :: Prepared.BuildInventory,
    armIdentity :: Cohort.CohortIdentity,
    armFlake :: FilePath,
    armDescriptorFile :: FilePath,
    armBuildKey :: Text
  }

runPrepare :: FilePath -> FilePath -> FilePath -> Text -> CliEnv -> IO ExitCode
runPrepare requestPath destination cachePath bucketName environment = guarded do
  started <- getCurrentTime
  unless (not (Text.null bucketName) && Text.all (\c -> c `elem` ['a' .. 'z'] || c `elem` ['0' .. '9'] || c `elem` ['-', '.']) bucketName) (throwIO (PerfFailure 2 "invalid control bucket"))
  occupied <- doesPathExist destination
  when occupied (throwIO (PerfFailure 2 "preparation output already exists"))
  _ <- ByteString.readFile requestPath >>= (decode "request" :: ByteString.ByteString -> IO PerfRequest)
  dirty <- process "git" ["status", "--porcelain"]
  unless (Text.null dirty) (throwIO (PerfFailure 4 "preparation requires a clean committed harness"))
  revision <- Text.strip <$> process "git" ["rev-parse", "HEAD"]
  root <- getCurrentDirectory
  output <- makeAbsolute destination
  cache <- makeAbsolute cachePath
  let evidence = output </> "evidence"
      work = output </> "work"
      harness = work </> "harness"
      bucket = Bucket bucketName
  createDirectoryIfMissing True (takeDirectory output)
  createDirectory output
  createDirectory evidence
  createDirectory work
  plan <- createPlan requestPath (evidence </> "planning") environment (Just (revision, False))
  planned <- getCurrentTime
  inputs <- ByteString.readFile (evidence </> "planning" </> "inputs.json") >>= decode "pinned planning inputs"
  -- Clone the committed harness, not the mutable working directory. Generated
  -- projects, locks and Cabal caches are siblings outside that checkout.
  _ <- loggedProcess (work </> "clone.log") "git" ["clone", "--quiet", "--no-hardlinks", root, harness]
  _ <- loggedProcess (work </> "checkout.log") "git" ["-C", harness, "checkout", "--quiet", "--detach", Text.unpack revision]
  baseline <- resolveArm output harness revision "baseline"
  candidate <- if plan.request.baselineRevision == plan.request.candidateRevision then pure baseline else resolveArm output harness revision "candidate"
  targets <- requireInput (targetPackages plan.request baseline.armDescriptor)
  requireInput (Prepared.compareInventories targets baseline.armInventory candidate.armInventory)
  requireInput (Prepared.compareInventories targets baseline.armBounds candidate.armBounds)
  resolutionFinished <- getCurrentTime
  progress "both inventories and declared bounds checked; publishing payloads"
  store <- openPerfStore bucket
  createDirectoryIfMissing True cache
  (baselinePayload, baselineHit) <- publishArm store bucket cache harness revision baseline
  (candidatePayload, candidateHit) <- if baseline.armBuildKey == candidate.armBuildKey then pure (baselinePayload, True) else publishArm store bucket cache harness revision candidate
  published <- getCurrentTime
  let arm resolved payload = Prepared.PreparedArm resolved.armDescriptor resolved.armLock resolved.armBounds resolved.armInventory (toJSON payload) resolved.armBuildKey
      prepared = Prepared.PerfPrepared plan inputs revision (arm baseline baselinePayload) (arm candidate candidatePayload)
  requireInput (Prepared.validatePrepared prepared)
  encodeFile (evidence </> "prepared.json") prepared
  encodeFile
    (evidence </> "preparation-summary.json")
    ( object
        [ "baselineCacheHit" .= baselineHit,
          "candidateCacheHit" .= candidateHit,
          "preparedSha256" .= Prepared.preparedDigest prepared,
          "startedAt" .= started,
          "payloadsReadyAt" .= published,
          "stageSeconds"
            .= object
              [ "planning" .= (realToFrac (diffUTCTime planned started) :: Double),
                "resolutionAndBounds" .= (realToFrac (diffUTCTime resolutionFinished planned) :: Double),
                "publication" .= (realToFrac (diffUTCTime published resolutionFinished) :: Double),
                "payloadPreparation" .= (realToFrac (diffUTCTime published started) :: Double)
              ]
        ]
    )
  sealPerfDirectory evidence >>= requireInput
  verifyPerfManifest evidence >>= requireInput
  LazyByteString.putStrLn (encode (object ["prepared" .= (evidence </> "prepared.json"), "preparedSha256" .= Prepared.preparedDigest prepared, "baselineCacheHit" .= baselineHit, "candidateCacheHit" .= candidateHit]))
  pure ExitSuccess

resolveArm :: FilePath -> FilePath -> Text -> Text -> IO ArmInputs
resolveArm output harness revision arm = do
  let evidence = output </> "evidence" </> "planning"
      work = output </> "work" </> Text.unpack arm
      flake = work </> "build"
      descriptorPath = flake </> "cohort.json"
      lockPath = flake </> "source-lock.json"
  createDirectory work
  createDirectory flake
  descriptor <- ByteString.readFile (evidence </> Text.unpack arm <> "-cohort.json") >>= decode "generated cohort"
  encodeFile descriptorPath (descriptor :: Cohort.CohortDescriptor)
  _ <- loggedProcess (work </> "source-lock.log") "bash" [harness </> "scripts" </> "payload-lock.sh", "--descriptor", descriptorPath, "--out", lockPath]
  lock <- ByteString.readFile lockPath >>= decode "source lock"
  names <- listDirectory harness
  packages <- filterMIO (\name -> doesFileExist (harness </> name </> name <> ".cabal")) (filter (Text.isPrefixOf "kenshou-" . Text.pack) names)
  boundsProject <- requireInput (Prepared.renderBoundsProject [harness </> name </> name <> ".cabal" | name <- packages] descriptor)
  let projectPath = work </> "bounds.project"
      planPath = work </> "bounds-dist" </> "cache" </> "plan.json"
  Text.IO.writeFile projectPath boundsProject
  _ <- loggedProcess (work </> "resolution.log") "cabal" ["build", "all", "--dry-run", "--project-file=" <> projectPath, "--builddir=" <> work </> "bounds-dist"]
  initialPlan <- ByteString.readFile planPath >>= decode "initial bounds plan"
  _ <- requireInput (Prepared.cabalInventory harness revision initialPlan)
  cacheDocument <- loggedProcess (work </> "cabal-path.log") "cabal" ["path", "--ignore-project", "--remote-repo-cache", "--output-format=json"] >>= decodeText "Cabal cache location"
  repoCache <- either (throwIO . PerfFailure 4 . Text.pack) pure (parseEither (withObject "CabalPaths" (.: "remote-repo-cache")) cacheDocument :: Either String FilePath)
  _ <-
    loggedProcess
      (work </> "resolved-lock.log")
      "python3"
      [harness </> "scripts" </> "perf-resolved-lock.py", "--plan", planPath, "--index", repoCache </> "hackage.haskell.org" </> "01-index.tar", "--cohort-lock", lockPath, "--out", flake </> "resolved-lock.json"]
  wrapper <- requireInput (generatedFlake harness revision descriptor)
  Text.IO.writeFile (flake </> "flake.nix") wrapper
  _ <- loggedProcess (work </> "flake-lock.log") "nix" ["flake", "lock", "path:" <> flake]
  let attribute = "path:" <> flake <> "#packages.x86_64-linux.kenshou-" <> Text.unpack (Cohort.unCohortName descriptor.descriptorName)
  inventory <- loggedProcess (work </> "build-inventory.log") "nix" ["eval", "--json", attribute <> ".buildInventory"] >>= decodeText "Nix inventory"
  identity <- loggedProcess (work </> "cohort-identity.log") "nix" ["eval", "--json", attribute <> ".cohortIdentity"] >>= decodeText "Nix identity"
  descriptorBytes <- ByteString.readFile descriptorPath
  _ <- requireInput (Publisher.validateCohortIdentity descriptor (Text.drop 7 (sha256Hex descriptorBytes)) identity)
  let actualConstraints = Text.intercalate ", " [entry.name <> " ==" <> entry.version | entry <- (inventory :: Prepared.BuildInventory).packages, not ("kenshou-" `Text.isPrefixOf` entry.name)]
  Text.IO.writeFile (work </> "nix-bounds.project") (boundsProject <> "\nconstraints: " <> actualConstraints <> "\n")
  _ <- loggedProcess (work </> "bounds.log") "cabal" ["build", "all", "--dry-run", "--project-file=" <> work </> "nix-bounds.project", "--builddir=" <> work </> "nix-bounds-dist"]
  cabalPlan <- ByteString.readFile (work </> "nix-bounds-dist" </> "cache" </> "plan.json") >>= decode "bounds plan"
  bounds <- requireInput (Prepared.cabalInventory harness revision cabalPlan)
  boundsIdentity <- either (throwIO . PerfFailure 4 . Text.pack . show) pure (Cohort.identityFromPlan descriptor (Text.drop 7 (sha256Hex descriptorBytes)) cabalPlan)
  unless (null (Cohort.checkCohort descriptor boundsIdentity)) (throwIO (PerfFailure 4 "independent bounds plan differs from the generated cohort"))
  requireInput (Prepared.validateArmInventories descriptor inventory bounds)
  encodeFile (work </> "build-inventory.json") inventory
  encodeFile (work </> "bounds-inventory.json") bounds
  let key = Prepared.buildKeyFor revision descriptor lock inventory bounds
  pure (ArmInputs descriptor lock inventory bounds identity flake descriptorPath key)

generatedFlake :: FilePath -> Text -> Cohort.CohortDescriptor -> Either Text Text
generatedFlake harness revision descriptor = do
  unless (not (any (`elem` ['\n', '\r', ' ', '"', '\\']) harness) && not ("${" `Text.isInfixOf` Text.pack harness) && immutableRevision revision) (Left "unsafe pinned harness path")
  let quote = Text.Encoding.decodeUtf8 . canonicalEncode . String
      location = "git+file://" <> Text.pack harness <> "?rev=" <> revision
  pure
    ( Text.unlines
        [ "{",
          "  inputs.harness.url = " <> quote location <> ";",
          "  outputs = { self, harness }: let",
          "    inputs = harness.inputs // { self = harness; };",
          "    pkgs = import inputs.nixpkgs { system = \"x86_64-linux\"; };",
          "  in { packages.x86_64-linux." <> quote ("kenshou-" <> Cohort.unCohortName descriptor.descriptorName) <> " = import (harness + \"/nix/kenshou/packages.nix\") {",
          "    inherit inputs pkgs; cohort = " <> quote (Cohort.unCohortName descriptor.descriptorName) <> "; variant = \"default\";",
          "    descriptorFile = ./cohort.json; lockFile = ./source-lock.json; resolvedLockFile = ./resolved-lock.json; strictBounds = true;",
          "  }; };",
          "}"
        ]
    )

publishArm :: ObjectStore -> Bucket -> FilePath -> FilePath -> Text -> ArmInputs -> IO (Payload.PayloadDescriptor, Bool)
publishArm store bucket cache harness revision arm = do
  let cached = cache </> Text.unpack (Text.drop 7 arm.armBuildKey) <> ".json"
  exists <- doesFileExist cached
  if exists
    then do
      payload <- ByteString.readFile cached >>= decode "cached payload"
      unless ((payload :: Payload.PayloadDescriptor).cohortIdentity == arm.armIdentity && payload.harness == Payload.Harness revision False && payload.variant == "default") (throwIO (PerfFailure 4 "cached payload identity mismatch"))
      withSystemTempDirectory "kenshou-perf-cache-check-" \temporary -> do
        let bundleObject = ObjectName ("payloads/sha256/" <> payload.cell.bundle.sha256 <> ".nar.zst")
            file = temporary </> "bundle.nar.zst"
        unless (payload.cell.bundle.uri == "gs://" <> bucket.unBucket <> "/payloads/sha256/" <> payload.cell.bundle.sha256 <> ".nar.zst") (throwIO (PerfFailure 4 "cached payload belongs to another bucket"))
        found <- store.downloadTo bucket bundleObject file
        when (found == Nothing) (throwIO (PerfFailure 4 "cached payload bundle is missing"))
        (digest, bytes) <- digestFile file
        unless ((digest, bytes) == (payload.cell.bundle.sha256, payload.cell.bundle.bytes)) (throwIO (PerfFailure 4 "cached bundle digest/size mismatch"))
      progress "reused verified published payload"
      pure (payload, True)
    else do
      result <- Publisher.publishPreparedPayload store (Publisher.PreparedPublishOptions harness revision ("path:" <> arm.armFlake) arm.armDescriptorFile (Cohort.unCohortName arm.armDescriptor.descriptorName) "default" bucket (arm.armFlake </> "payload.json"))
      payload <- case result of
        Left problem -> do
          encodeFile (takeDirectory arm.armFlake </> "publication-failure.json") (object ["error" .= show problem])
          throwIO (PerfFailure 4 (Text.pack (show problem)))
        Right value -> pure value
      withTempDirectory cache ".pending-" \temporary -> do
        let staged = temporary </> "payload.json"
        encodeFile staged payload
        renameFile staged cached
      pure (payload, False)

loggedProcess :: FilePath -> String -> [String] -> IO Text
loggedProcess logPath executable arguments = do
  (status, output, errors) <- readProcessWithExitCode executable arguments ""
  Text.IO.writeFile logPath (Text.pack output <> Text.pack errors)
  case status of
    ExitSuccess -> pure (Text.pack output)
    _ -> throwIO (PerfFailure 4 (Text.pack executable <> " failed; retained log: " <> Text.pack logPath <> "\n" <> Text.take 2000 (Text.pack errors)))

decodeText :: (FromJSON a) => Text -> Text -> IO a
decodeText label = decode label . Text.Encoding.encodeUtf8

filterMIO :: (a -> IO Bool) -> [a] -> IO [a]
filterMIO predicate values = fmap (map fst . filter snd) (traverse (\item -> (item,) <$> predicate item) values)

openPerfStore :: Bucket -> IO ObjectStore
openPerfStore bucket =
  lookupEnv "KENSHOU_CELL_STORE" >>= \case
    Nothing -> newTokenProvider bucket >>= newGcsStore
    Just setting -> case Text.stripPrefix "file:" (Text.pack setting) of
      Just root | not (Text.null root) -> newFileStore (Text.unpack root)
      _ -> throwIO (PerfFailure 2 "KENSHOU_CELL_STORE must be file:<directory> or unset")

runPlan :: FilePath -> FilePath -> CliEnv -> IO ExitCode
runPlan requestPath output environment = guarded do
  plan <- createPlan requestPath output environment Nothing
  LazyByteString.putStrLn (encode plan)
  pure ExitSuccess

createPlan :: FilePath -> FilePath -> CliEnv -> Maybe (Text, Bool) -> IO PerfPlan
createPlan requestPath output environment pinnedHarness = do
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
    (harnessRevision, harnessDirty) <- case pinnedHarness of
      Just snapshot -> pure snapshot
      Nothing -> do
        revision <- Text.strip <$> process "git" ["rev-parse", "HEAD"]
        status <- process "git" ["status", "--porcelain"]
        pure (revision, not (Text.null status))
    let inputs =
          object
            [ "request" .= request,
              "template" .= descriptor,
              "templateSha256" .= sha256Hex descriptorBytes,
              "baselineSource" .= baseline,
              "candidateSource" .= candidate,
              "harness" .= object ["revision" .= harnessRevision, "dirty" .= harnessDirty],
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
    ByteString.writeFile (output </> "template.json") descriptorBytes
    encodeFile (output </> "request.json") request
    encodeFile (output </> "inputs.json") inputs
    encodeFile (output </> "plan.json") plan
    encodeFile (output </> "baseline-cohort.json") baselineDescriptor
    encodeFile (output </> "candidate-cohort.json") candidateDescriptor
    sealPerfDirectory output >>= requireInput
    progress ("planned " <> Text.pack (show (length plan.selected)) <> " configurations; scope " <> plan.coverage)
    pure plan
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
