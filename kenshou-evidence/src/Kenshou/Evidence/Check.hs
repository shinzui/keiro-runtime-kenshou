module Kenshou.Evidence.Check
  ( CheckOptions (..),
    CheckError (..),
    Finding (..),
    checkBundle,
    checkBundleWithStore,
    checkDocument,
  )
where

import Control.Exception (IOException, try)
import Control.Monad (forM)
import Data.Aeson (Result (..), Value (..), fromJSON)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as ByteString
import Data.List (isPrefixOf, nub, sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Data.Time (UTCTime, defaultTimeLocale, formatTime, parseTimeM)
import Kenshou.Core.Id (ScenarioId (..), parseRunId, parseScenarioId, renderLayer)
import Kenshou.Evidence.Store (ObjectStat (..), ObjectStore (..))
import Kenshou.Evidence.Types (mkRevision, mkSha256, sha256Bytes)
import Okf.Document (OKFDocument (..), frontmatterKeys, frontmatterLookup, parseDocument, removeField)
import System.Directory (canonicalizePath, doesDirectoryExist, listDirectory)
import System.Exit (ExitCode (..))
import System.FilePath (makeRelative, splitDirectories, takeExtension, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)

data CheckOptions = CheckOptions
  { bundleRoot :: !FilePath,
    baseRef :: !(Maybe Text),
    network :: !Bool,
    deep :: !Bool
  }
  deriving stock (Eq, Show)

newtype CheckError = CheckError Text deriving stock (Eq, Show)

data Finding = Finding
  { concept :: !FilePath,
    rule :: !Text,
    message :: !Text
  }
  deriving stock (Eq, Show)

checkBundle :: CheckOptions -> IO (Either CheckError [Finding])
checkBundle = checkBundleWithStore Nothing

checkBundleWithStore :: Maybe ObjectStore -> CheckOptions -> IO (Either CheckError [Finding])
checkBundleWithStore store options = do
  result <- try (check store options) :: IO (Either IOException (Either CheckError [Finding]))
  pure $ either (Left . CheckError . Text.pack . show) id result

check :: Maybe ObjectStore -> CheckOptions -> IO (Either CheckError [Finding])
check store options = do
  exists <- doesDirectoryExist options.bundleRoot
  if not exists
    then pure (Left (CheckError "evidence bundle does not exist"))
    else do
      paths <- sort <$> conceptFiles options.bundleRoot
      current <- forM paths $ \path -> do
        content <- Text.IO.readFile (options.bundleRoot </> path)
        pure (path, content)
      let local =
            concatMap
              ( \(path, content) -> case parseDocument content of
                  Left err -> [Finding path "parse" (Text.pack (show err))]
                  Right document -> checkDocument path document
              )
              current
          references = checkReferences current
      historical <- checkHistory options
      remote <-
        if options.network
          then case store of
            Nothing -> pure (Left (CheckError "--network requires an object store and GCP project"))
            Just objectStore -> checkNetwork objectStore options.deep current
          else pure (Right [])
      pure $ do
        historyFindings <- historical
        remoteFindings <- remote
        pure (local <> references <> historyFindings <> remoteFindings)

checkReferences :: [(FilePath, Text)] -> [Finding]
checkReferences current = concatMap inspect parsed
  where
    parsed = [(path, document) | (path, content) <- current, Right document <- [parseDocument content]]
    byPath = Map.fromList parsed
    field document name = frontmatterLookup name document.frontmatter
    asText (Just (String value)) = Just value
    asText _ = Nothing
    nested name = \case
      Just (Object fields) -> KeyMap.lookup (Key.fromText name) fields
      _ -> Nothing
    paths = \case
      Just (Array values) -> [value | String value <- foldr (:) [] values]
      _ -> []
    target path scenario ref =
      let relative = Text.unpack (Text.dropWhile (== '/') ref)
       in case Map.lookup relative byPath of
            Nothing -> [Finding path "reference-targets" ("missing run target: " <> ref)]
            Just document | field document "type" /= Just (String "Verification Run") || field document "recordKind" /= Just (String "run") -> [Finding path "reference-targets" ("target is not a recorded run: " <> ref)]
            Just document -> [Finding path "reference-targets" ("target has a different scenario: " <> ref) | scenario /= Nothing, field document "scenario" /= scenario]
    inspect (path, document)
      | field document "type" == Just (String "Verification Run") =
          let previous = maybe [] (\ref -> target path (field document "scenario") ref <> checkPrevious path document ref) (asText (field document "previousRun"))
              comparison = field document "comparison"
              arms = paths (nested "baselineRuns" comparison) <> paths (nested "candidateRuns" comparison)
           in previous <> concatMap (target path (field document "scenario")) arms
      | field document "type" == Just (String "Attestation") =
          maybe [] (target path Nothing) (asText (field document "run"))
      | otherwise = []
    checkPrevious path document ref =
      let relative = Text.unpack (Text.dropWhile (== '/') ref)
       in case Map.lookup relative byPath of
            Nothing -> []
            Just previous ->
              [ Finding path "reference-targets" "previousRun must have the same scenario and compatibility key, and start earlier"
              | field document "scenario" /= field previous "scenario"
                  || field document "compatibilityKey" /= field previous "compatibilityKey"
                  || maybe
                    True
                    not
                    ( do
                        now <- asText (field document "startedAt") >>= parseUtc
                        thenTime <- asText (field previous "startedAt") >>= parseUtc
                        pure (thenTime < now)
                    )
              ]

checkNetwork :: ObjectStore -> Bool -> [(FilePath, Text)] -> IO (Either CheckError [Finding])
checkNetwork store deep current = withSystemTempDirectory "kenshou-evidence-network" $ \scratch -> do
  results <- forM current $ \(path, content) -> case parseDocument content of
    Left _ -> pure (Right [])
    Right document -> do
      let links = case frontmatterLookup "data" document.frontmatter of
            Just (Array values) -> foldr (:) [] values
            _ -> []
      fmap (fmap concat . sequence) $ forM links $ \link -> case networkLink link of
        Nothing -> pure (Right [])
        Just (uri, digest, expectedBytes) -> do
          observed <- store.statObject uri
          case observed of
            Left err -> pure (Left (CheckError (Text.pack (show err))))
            Right Nothing -> pure (Right [Finding path "network" ("object is missing: " <> uri)])
            Right (Just stat) ->
              if stat.bytes /= expectedBytes || stat.recordedSha256 /= Just digest
                then pure (Right [Finding path "network" ("object metadata differs: " <> uri)])
                else
                  if not deep
                    then pure (Right [])
                    else do
                      let destination = scratch </> "object"
                      fetched <- store.fetchObject uri destination
                      case fetched of
                        Left err -> pure (Left (CheckError (Text.pack (show err))))
                        Right () -> do
                          actual <- sha256Bytes <$> ByteString.readFile destination
                          pure (Right [Finding path "network" ("object bytes differ: " <> uri) | actual /= digest])
  pure (concat <$> sequence results)
  where
    networkLink (Object fields) = do
      String uri <- KeyMap.lookup "uri" fields
      String rawDigest <- KeyMap.lookup "digest" fields
      digest <- either (const Nothing) Just (mkSha256 rawDigest)
      rawBytes <- KeyMap.lookup "bytes" fields
      bytes <- case fromJSON rawBytes of
        Success parsed -> Just parsed
        Error _ -> Nothing
      pure (uri, digest, bytes)
    networkLink _ = Nothing

conceptFiles :: FilePath -> IO [FilePath]
conceptFiles root = do
  let descend relative = do
        let directory = root </> relative
        names <- listDirectory directory
        fmap concat $ forM names $ \name -> do
          let child = relative </> name
          isDirectory <- doesDirectoryExist (root </> child)
          if isDirectory then descend child else pure [child | takeExtension name == ".md", name /= "index.md", name /= "log.md"]
  runs <- doesDirectoryExist (root </> "runs")
  attestations <- doesDirectoryExist (root </> "attestations")
  (if runs then descend "runs" else pure []) >>= \runFiles ->
    (if attestations then descend "attestations" else pure []) >>= \attestationFiles ->
      pure (runFiles <> attestationFiles)

checkDocument :: FilePath -> OKFDocument -> [Finding]
checkDocument path document =
  let front = document.frontmatter
      field = (`frontmatterLookup` front)
      issue name detail = Finding path name detail
      textField name = case field name of
        Just (String value) -> Just value
        _ -> Nothing
      requireText name = [issue "string-typing" (name <> " must be a JSON string") | textField name == Nothing]
      digest name = case textField name of
        Nothing -> []
        Just value -> [issue "hex-shape" (name <> " must be 64 lowercase hexadecimal characters") | either (const True) (const False) (mkSha256 value)]
      revision name = case textField name of
        Nothing -> []
        Just value -> [issue "hex-shape" (name <> " must be 40 lowercase hexadecimal characters") | either (const True) (const False) (mkRevision value)]
      entries name = case field name of
        Just (Array values) -> toList values
        _ -> []
      member name value = case value of
        Object fields -> KeyMap.lookup (Key.fromText name) fields
        _ -> Nothing
      entryText name value = case member name value of
        Just (String result) -> Just result
        _ -> Nothing
      run = field "type" == Just (String "Verification Run")
      attestation = field "type" == Just (String "Attestation")
      common =
        [issue "event-keys" (name <> " is forbidden on an event") | (run || attestation), name <- ["status", "stale_after"], field name /= Nothing]
      runChecks =
        requireText "runId"
          <> requireText "scenario"
          <> requireText "startedAt"
          <> requireText "finishedAt"
          <> [issue "id-shape" "runId must be a UUIDv7" | maybe True (either (const True) (const False) . parseRunId) (textField "runId")]
          <> pathChecks textField issue
          <> timeChecks textField issue
          <> requireText "harnessRevision"
          <> revision "harnessRevision"
          <> [issue "dirty-purpose" "a dirty harness requires purpose: investigation" | field "harnessDirty" == Just (Bool True), field "purpose" /= Just (String "investigation")]
          <> concatMap
            ( \value ->
                [issue "string-typing" "data.uri must be a JSON string" | entryText "uri" value == Nothing]
                  <> [issue "hex-shape" "data.digest must be 64 lowercase hexadecimal characters" | maybe True (either (const True) (const False) . mkSha256) (entryText "digest" value)]
            )
            (entries "data")
          <> (if field "recordKind" == Just (String "run") then runOnly else [])
          <> (if field "recordKind" == Just (String "comparison") then comparisonOnly else [])
      runOnly =
        requireText "compatibilityKey"
          <> requireText "solverPlanHash"
          <> digest "compatibilityKey"
          <> digest "solverPlanHash"
          <> concatMap
            ( \value ->
                [issue "string-typing" "dimension.value must be a JSON string" | entryText "value" value == Nothing]
                  <> [issue "string-typing" "dimension.name must be a JSON string" | entryText "name" value == Nothing]
            )
            (entries "dimensions")
          <> concatMap
            ( \value ->
                [issue "hex-shape" "component.revision must be 40 lowercase hexadecimal characters" | maybe False (either (const True) (const False) . mkRevision) (entryText "revision" value)]
            )
            (entries "components")
          <> [issue "data-completeness" "run must link manifest, run-spec and run-result" | field "recordKind" == Just (String "run"), not (all (`elem` mapMaybe (entryText "kind") (entries "data")) ["manifest", "run-spec", "run-result"])]
          <> [ issue "cell-fields" "cell placement requires environment.cell, cellRun, machineType and zone"
             | field "placement" == Just (String "cell"),
               not
                 ( all
                     ( \name -> case field "environment" of
                         Just environment -> maybe False isString (member name environment)
                         _ -> False
                     )
                     ["cell", "cellRun", "machineType", "zone"]
                 )
             ]
      comparisonOnly =
        let comparison = field "comparison"
            verdict = comparison >>= member "verdict"
            expected = case verdict of
              Just (String "pass") -> Just (String "passed")
              Just (String "regression") -> Just (String "failed")
              Just (String "inconclusive") -> Just (String "inconclusive")
              Just (String "infrastructure-failure") -> Just (String "infrastructure-failure")
              _ -> Nothing
         in [issue "comparison-outcome" "comparison verdict and outcome disagree" | expected /= field "outcome"]
              <> [issue "data-completeness" "comparison must link exactly one comparison document" | mapMaybe (entryText "kind") (entries "data") /= ["comparison"]]
      attestationChecks = [issue "event-keys" (name <> " belongs only on runs") | name <- ["layer", "tier"], field name /= Nothing]
   in common <> (if run then runChecks else []) <> (if attestation then attestationChecks else [])
  where
    isString (String _) = True
    isString _ = False
    toList = foldr (:) []
    pathChecks textField issue = case (textField "scenario", textField "runId", textField "startedAt") of
      (Just scenario, Just runId, Just startedAt) -> case (parseScenarioId scenario, parseUtc startedAt) of
        (Right parsed, Just time) ->
          let expected = "runs/" <> Text.unpack (renderLayer parsed.layer) <> "/" <> formatTime defaultTimeLocale "%Y/%m" time <> "/" <> Text.unpack runId <> ".md"
           in [issue "path-consistency" ("expected " <> Text.pack expected) | path /= expected]
        _ -> []
      _ -> []
    timeChecks textField issue = case (textField "startedAt", textField "finishedAt") of
      (Just start, Just finish) -> case (parseUtc start, parseUtc finish) of
        (Just from, Just to) -> [issue "time-order" "finishedAt precedes startedAt" | to < from]
        _ -> [issue "time-order" "run timestamps must be RFC 3339 UTC"]
      _ -> []

parseUtc :: Text -> Maybe UTCTime
parseUtc = parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" . Text.unpack

checkHistory :: CheckOptions -> IO (Either CheckError [Finding])
checkHistory options = do
  gitRoot <- readProcessWithExitCode "git" ["-C", options.bundleRoot, "rev-parse", "--show-toplevel"] ""
  case gitRoot of
    (ExitFailure _, _, _) -> pure (Right [])
    (ExitSuccess, root, _) -> do
      repo <- canonicalizePath (stripNewline root)
      bundle <- canonicalizePath options.bundleRoot
      let relative = makeRelative repo bundle
      if [".."] `isPrefixOf` splitDirectories relative
        then pure (Right [])
        else do
          shallow <- readProcessWithExitCode "git" ["-C", repo, "rev-parse", "--is-shallow-repository"] ""
          if shallow /= (ExitSuccess, "false\n", "")
            then pure (Left (CheckError "immutability requires full Git history"))
            else do
              let scope = [relative </> "runs", relative </> "attestations"]
                  range = maybe "HEAD" ((<> "..HEAD") . Text.unpack) options.baseRef
              history <- readProcessWithExitCode "git" (["-C", repo, "log", "--format=%H", "--diff-filter=DMR", "--name-status", range, "--"] <> scope) ""
              case history of
                (ExitFailure _, _, err) -> pure (Left (CheckError (Text.pack err)))
                (ExitSuccess, output, _) -> do
                  let changed = [(commit, columns) | (commit, columns) <- historyLines output, any (\item -> takeExtension item == ".md" && not (isGenerated item)) (drop 1 columns)]
                  committed <- fmap concat $ forM changed $ \(commit, columns) -> case columns of
                    status : path : _ -> do
                      let relativePath = makeRelative relative path
                      if "D" `isPrefixOf` status || "R" `isPrefixOf` status
                        then pure [Finding relativePath "immutability" ("committed deletion or rename in " <> Text.pack commit)]
                        else compareVersions repo relativePath (commit <> "^:" <> path) (commit <> ":" <> path)
                    _ -> pure []
                  worktree <- readProcessWithExitCode "git" (["-C", repo, "diff", "--name-status", "HEAD", "--"] <> scope) ""
                  staged <- case worktree of
                    (ExitSuccess, changes, _) -> fmap concat $ forM (lines changes) $ \line -> case words line of
                      status : path : _
                        | takeExtension path == ".md",
                          not (isGenerated path) ->
                            let relativePath = makeRelative relative path
                             in if "D" `isPrefixOf` status || "R" `isPrefixOf` status
                                  then pure [Finding relativePath "immutability" "committed event was deleted or renamed in the working tree"]
                                  else compareVersions repo relativePath ("HEAD:" <> path) path
                      _ -> pure []
                    _ -> pure []
                  pure (Right (committed <> staged))
  where
    stripNewline = reverse . dropWhile (== '\n') . reverse
    isGenerated path = any (`elem` ["index.md", "log.md"]) (take 1 (reverse (splitDirectories path)))
    historyLines = go Nothing . lines
      where
        go _ [] = []
        go current (line : rest)
          | length line == 40 && all (`elem` ("0123456789abcdef" :: String)) line = go (Just line) rest
          | otherwise = case (current, words line) of
              (Just commit, columns@(_ : _)) -> (commit, columns) : go current rest
              _ -> go current rest
    compareVersions repo relativePath oldRef newRef = do
      old <- readVersion repo oldRef
      new <- readVersion repo newRef
      pure case (old, new) of
        (Just before, Just after) -> case (parseDocument before, parseDocument after) of
          (Right a, Right b) | allowedAppend a b -> []
          (Right a, Right b) -> [Finding relativePath "immutability" ("committed event changed: " <> Text.intercalate ", " (changedParts a b))]
          _ -> [Finding relativePath "immutability" ("committed event changed: " <> Text.pack newRef)]
        _ -> [Finding relativePath "immutability" ("committed event changed: " <> Text.pack newRef)]
    readVersion repo ref
      | ':' `elem` ref = do
          (status, output, _) <- readProcessWithExitCode "git" ["-C", repo, "show", ref] ""
          pure (if status == ExitSuccess then Just (Text.pack output) else Nothing)
      | otherwise = do
          result <- try (Text.IO.readFile (repo </> ref)) :: IO (Either IOException Text)
          pure (either (const Nothing) Just result)
    allowedAppend before after =
      before.body == after.body
        && removeVerified before == removeVerified after
        && verified before `isPrefixOf` verified after
    removeVerified document = removeField "verified" document.frontmatter
    verified document = case frontmatterLookup "verified" document.frontmatter of
      Just (Array values) -> foldr (:) [] values
      _ -> []
    changedParts before after =
      [name | name <- sort (nub (frontmatterKeys before.frontmatter <> frontmatterKeys after.frontmatter)), name /= "verified", frontmatterLookup name before.frontmatter /= frontmatterLookup name after.frontmatter]
        <> ["body" | before.body /= after.body]
        <> ["verified" | not (verified before `isPrefixOf` verified after)]
