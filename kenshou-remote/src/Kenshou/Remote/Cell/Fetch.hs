module Kenshou.Remote.Cell.Fetch
  ( FetchError (..),
    VerifyProblem (..),
    fetchCellRun,
    verifyCellTree,
    verifyCellRun,
    verifyCellRunWithStatus,
  )
where

import Control.Exception (bracket)
import Control.Monad (forM)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson (FromJSON, Value (..), eitherDecode)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as ByteString
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Int (Int64)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, listToMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Kenshou.Core.Id (RunId, renderRunId)
import Kenshou.Core.Manifest (Manifest (..), ManifestFile (..), verifyManifest)
import Kenshou.Remote.Cell.Docs (Artifact (..), CellManifest (..), CellPhase (..), CellRunResult (..), CellStatus (..), ManifestPayload (..), Submission (..), WorkObject (..))
import Kenshou.Remote.Payload (Bundle (..), CellPayload (..))
import Kenshou.Remote.Store (Bucket, ObjectMeta (..), ObjectName (..), ObjectStore (..))
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory, pathIsSymbolicLink, removeFile, renameFile)
import System.FilePath (takeDirectory, (</>))
import System.IO (IOMode (ReadMode), hClose, openBinaryTempFile, withBinaryFile)

data VerifyProblem
  = InvalidManifest !Text
  | Missing !Text
  | Extra !Text
  | DigestMismatch !Text
  | SizeMismatch !Text
  | UnsafeEntry !Text
  | PayloadMismatch !Text
  | ManifestsDisagree !Text
  | NestedManifestProblem !Text
  | RunResultMismatch !Text
  | StatusDigestMismatch
  | StatusMismatch !Text
  deriving stock (Eq, Show)

data FetchError
  = Unsealed
  | ManifestProblem !Text
  | ObjectSetMismatch ![Text] ![Text] -- missing, extra
  | ObjectChanged !Text
  | ObjectCorrupt !Text
  | VerificationFailed !(NonEmpty VerifyProblem)
  deriving stock (Eq, Show)

fetchCellRun :: ObjectStore -> Bucket -> RunId -> FilePath -> IO (Either FetchError FilePath)
fetchCellRun store bucket identifier outDir = do
  let prefix = "runs/" <> renderRunId identifier <> "/"
      manifestObject = ObjectName (prefix <> "manifest.json")
      tree = outDir </> Text.unpack (renderRunId identifier) </> "tree"
  sealed <- store.getObject bucket manifestObject
  case sealed of
    Nothing -> pure (Left Unsealed)
    Just (manifestBytes, manifestMeta) -> case eitherDecode manifestBytes :: Either String CellManifest of
      Left failure -> pure (Left (ManifestProblem (Text.pack failure)))
      Right manifest
        | manifest.runId /= identifier -> pure (Left (ManifestProblem "manifest run ID differs from result prefix"))
        | otherwise -> do
            listed <- store.listObjects bucket prefix
            let actual = Set.fromList [object.unObjectName | (object, _) <- listed]
                expected = Set.fromList ((prefix <> "manifest.json") : [prefix <> artifact.path | artifact <- manifest.artifacts])
                absent = Set.toList (expected Set.\\ actual)
                unexpected = Set.toList (actual Set.\\ expected)
            if not (null absent && null unexpected)
              then pure (Left (ObjectSetMismatch absent unexpected))
              else case lookup manifestObject listed of
                Nothing -> pure (Left Unsealed)
                Just listedManifest | listedManifest.generation /= manifestMeta.generation -> pure (Left (ObjectChanged "manifest.json"))
                Just _ -> do
                  createDirectoryIfMissing True tree
                  rootSymbolic <- pathIsSymbolicLink tree
                  if rootSymbolic
                    then pure (Left (VerificationFailed (UnsafeEntry "tree" :| [])))
                    else do
                      (_, unsafe) <- listTree tree
                      case unsafe of
                        first : rest -> pure (Left (VerificationFailed (UnsafeEntry first :| map UnsafeEntry rest)))
                        [] -> do
                          writeVerified tree "manifest.json" manifestBytes
                          fetched <- traverse (fetchArtifact store bucket prefix tree listed) manifest.artifacts
                          case firstFailure fetched of
                            Just failure -> pure (Left failure)
                            Nothing -> do
                              verified <- verifyCellTree tree
                              pure case verified of
                                Left problems -> Left (VerificationFailed problems)
                                Right _ -> Right tree

fetchArtifact :: ObjectStore -> Bucket -> Text -> FilePath -> [(ObjectName, ObjectMeta)] -> Artifact -> IO (Maybe FetchError)
fetchArtifact store bucket prefix tree listed artifact = do
  let name = ObjectName (prefix <> artifact.path)
      target = tree </> Text.unpack artifact.path
  case lookup name listed of
    Nothing -> pure (Just (ObjectChanged artifact.path))
    Just meta
      | meta.size /= artifact.bytes -> pure (Just (ObjectCorrupt artifact.path))
      | otherwise -> do
          existing <- doesFileExist target
          valid <- if existing then matches target artifact else pure False
          if valid
            then pure Nothing
            else withTemporary target \temporary -> do
              fetched <- store.downloadTo bucket name temporary
              case fetched of
                Nothing -> pure (Just (ObjectChanged artifact.path))
                Just got
                  | got.generation /= meta.generation -> pure (Just (ObjectChanged artifact.path))
                  | otherwise -> do
                      sound <- matches temporary artifact
                      if sound
                        then renameFile temporary target >> pure Nothing
                        else pure (Just (ObjectCorrupt artifact.path))

verifyCellTree :: FilePath -> IO (Either (NonEmpty VerifyProblem) CellManifest)
verifyCellTree tree = do
  let manifestPath = tree </> "manifest.json"
  rootExists <- doesDirectoryExist tree
  if not rootExists
    then pure (Left (Missing "manifest.json" :| []))
    else do
      rootSymbolic <- pathIsSymbolicLink tree
      if rootSymbolic
        then pure (Left (UnsafeEntry "tree" :| []))
        else do
          exists <- doesFileExist manifestPath
          if not exists
            then pure (Left (Missing "manifest.json" :| []))
            else do
              symbolic <- pathIsSymbolicLink manifestPath
              if symbolic
                then pure (Left (UnsafeEntry "manifest.json" :| []))
                else do
                  bytes <- LazyByteString.readFile manifestPath
                  case eitherDecode bytes :: Either String CellManifest of
                    Left failure -> pure (Left (InvalidManifest (Text.pack failure) :| []))
                    Right manifest -> do
                      (files, unsafe) <- listTree tree
                      let actual = Set.fromList files
                          expected = Set.fromList ("manifest.json" : map (.path) manifest.artifacts)
                          missing = map Missing (Set.toList (expected Set.\\ actual))
                          extra = map Extra (Set.toList (actual Set.\\ expected))
                      damaged <- fmap concat $ forM manifest.artifacts \artifact -> do
                        if Set.member artifact.path actual
                          then do
                            (digest, size) <- digestFile (tree </> Text.unpack artifact.path)
                            pure ([DigestMismatch artifact.path | digest /= artifact.sha256] <> [SizeMismatch artifact.path | size /= artifact.bytes])
                          else pure []
                      let problems = map UnsafeEntry unsafe <> missing <> extra <> damaged
                      pure case problems of
                        [] -> Right manifest
                        first : rest -> Left (first :| rest)

-- This is the evidence gate after the cell-level size and digest verification.
-- Validate nested paths before calling the kernel verifier, whose standalone
-- entry point assumes its manifest came from a trusted local run directory.
verifyCellRun :: FilePath -> IO (Either (NonEmpty VerifyProblem) CellManifest)
verifyCellRun tree = do
  verified <- verifyCellTree tree
  case verified of
    Left problems -> pure (Left problems)
    Right manifest -> do
      let byPath = Map.fromList [(artifact.path, artifact) | artifact <- manifest.artifacts]
      submission <- readRequired tree byPath "submission/submission.json" :: IO (Either VerifyProblem Submission)
      result <- readRequired tree byPath "cell/result.json" :: IO (Either VerifyProblem CellRunResult)
      case (submission, result) of
        (Right submitted, Right cellResult) -> do
          let identityProblems =
                [PayloadMismatch "submission run, lease or payload differs from cell manifest" | submitted.runId /= manifest.runId || submitted.leaseId /= manifest.leaseId || submitted.payload.bundle.sha256 /= manifest.payload.sha256 || submitted.payload.storePath /= manifest.payload.storePath]
                  <> [RunResultMismatch "cell result differs from cell manifest" | cellResult.runId /= manifest.runId || cellResult.cell /= manifest.cell || cellResult.leaseId /= manifest.leaseId || cellResult.leaseSequence /= manifest.leaseSequence || cellResult.outcome /= manifest.outcome]
          workProblems <- checkWork tree byPath submitted
          let nested = nestedManifestPaths manifest.artifacts
              nestedIds = Set.fromList (map fst nested)
              outputIds = Set.fromList [run | artifact <- manifest.artifacts, "output" : run : _file : _ <- [Text.splitOn "/" artifact.path]]
              absentNested = [NestedManifestProblem ("output/" <> run <> "/manifest.json: missing") | run <- Set.toList (outputIds Set.\\ nestedIds)]
          nestedProblems <- concat <$> traverse (checkNested tree byPath manifest.payload.sha256) nested
          let problems = identityProblems <> workProblems <> absentNested <> nestedProblems
          pure case problems of
            [] -> Right manifest
            first : rest -> Left (first :| rest)
        _ -> pure (Left (firstProblems submission result))

verifyCellRunWithStatus :: CellStatus -> FilePath -> IO (Either (NonEmpty VerifyProblem) CellManifest)
verifyCellRunWithStatus status tree = do
  verified <- verifyCellRun tree
  case verified of
    Left problems -> pure (Left problems)
    Right manifest -> do
      (digest, _) <- digestFile (tree </> "manifest.json")
      let problems =
            [StatusMismatch "status is not sealed or names another cell run" | status.phase /= Sealed || status.runId /= manifest.runId]
              <> [StatusMismatch "status sequence or outcome differs from cell manifest" | status.leaseSequence /= Just manifest.leaseSequence || status.outcome /= Just manifest.outcome]
              <> [StatusDigestMismatch | status.manifestSha256 /= Just digest]
      pure case problems of
        [] -> Right manifest
        first : rest -> Left (first :| rest)

readRequired :: (FromJSON document) => FilePath -> Map.Map Text Artifact -> Text -> IO (Either VerifyProblem document)
readRequired tree byPath relative = case Map.lookup relative byPath of
  Nothing -> pure (Left (Missing relative))
  Just _ -> do
    bytes <- LazyByteString.readFile (tree </> Text.unpack relative)
    pure case eitherDecode bytes of
      Left failure -> Left (InvalidManifest (relative <> ": " <> Text.pack failure))
      Right document -> Right document

firstProblems :: Either VerifyProblem left -> Either VerifyProblem right -> NonEmpty VerifyProblem
firstProblems left right = case catMaybes [either Just (const Nothing) left, either Just (const Nothing) right] of
  first : rest -> first :| rest
  [] -> InvalidManifest "missing required cell document" :| []

checkWork :: FilePath -> Map.Map Text Artifact -> Submission -> IO [VerifyProblem]
checkWork tree byPath submitted = case Map.lookup "submission/work" byPath of
  Nothing -> pure [Missing "submission/work"]
  Just artifact -> do
    (digest, size) <- digestFile (tree </> "submission" </> "work")
    pure [PayloadMismatch "submission work differs from its declared digest or size" | digest /= submitted.work.sha256 || size /= submitted.work.bytes || artifact.sha256 /= submitted.work.sha256 || artifact.bytes /= submitted.work.bytes]

nestedManifestPaths :: [Artifact] -> [(Text, Text)]
nestedManifestPaths artifacts =
  [(run, artifact.path) | artifact <- artifacts, ["output", run, "manifest.json"] <- [Text.splitOn "/" artifact.path]]

checkNested :: FilePath -> Map.Map Text Artifact -> Text -> (Text, Text) -> IO [VerifyProblem]
checkNested tree byPath bundleDigest (run, path) = do
  decoded <- readRequired tree byPath path :: IO (Either VerifyProblem Manifest)
  case decoded of
    Left problem -> pure [problem]
    Right nested
      | renderRunId nested.runId /= run -> pure [NestedManifestProblem (path <> ": run ID differs from directory")]
      | otherwise -> do
          let relativeFiles = map (Text.pack . (.path)) nested.files
          if any (not . safeRelative) relativeFiles || length relativeFiles /= Set.size (Set.fromList relativeFiles)
            then pure [NestedManifestProblem (path <> ": unsafe or duplicate nested path")]
            else do
              let prefix = "output/" <> run <> "/"
                  expected = sort (path : map (prefix <>) relativeFiles)
                  actual = sort [name | name <- Map.keys byPath, prefix `Text.isPrefixOf` name]
                  setProblem = [ManifestsDisagree (path <> ": nested file set differs from cell manifest") | expected /= actual]
                  metadataProblems =
                    [ ManifestsDisagree (full <> ": digest or size differs between manifests")
                    | file <- nested.files,
                      let full = prefix <> Text.pack file.path,
                      Just artifact <- [Map.lookup full byPath],
                      Just artifact.sha256 /= Text.stripPrefix "sha256:" file.sha256 || fromIntegral artifact.bytes /= file.bytes
                    ]
              checked <- verifyManifest (tree </> "output" </> Text.unpack run)
              let kernelProblems = case checked of
                    Left problems -> [NestedManifestProblem (path <> ": " <> Text.pack (show problems))]
                    Right () -> []
              fingerprintProblems <- checkFingerprint tree prefix run bundleDigest
              pure (setProblem <> metadataProblems <> kernelProblems <> fingerprintProblems)

checkFingerprint :: FilePath -> Text -> Text -> Text -> IO [VerifyProblem]
checkFingerprint tree prefix run expected = do
  let relative = prefix <> "run-result.json"
  present <- doesFileExist (tree </> Text.unpack relative)
  if not present
    then pure [RunResultMismatch (relative <> ": missing")]
    else do
      bytes <- LazyByteString.readFile (tree </> Text.unpack relative)
      pure case eitherDecode bytes :: Either String Value of
        Left failure -> [RunResultMismatch (relative <> ": " <> Text.pack failure)]
        Right value ->
          [RunResultMismatch (relative <> ": run ID differs from directory") | resultRunId value /= Just run]
            <> [RunResultMismatch (relative <> ": payload fingerprint differs from submission") | fingerprintDigest value /= Just expected]

resultRunId :: Value -> Maybe Text
resultRunId (Object result) = do
  String identifier <- KeyMap.lookup "runId" result
  pure identifier
resultRunId _ = Nothing

fingerprintDigest :: Value -> Maybe Text
fingerprintDigest (Object result) = do
  Object fingerprint <- KeyMap.lookup "fingerprint" result
  Object cell <- KeyMap.lookup "cell" fingerprint
  Object payload <- KeyMap.lookup "payload" cell
  String digest <- KeyMap.lookup "bundleSha256" payload
  pure digest
fingerprintDigest _ = Nothing

safeRelative :: Text -> Bool
safeRelative value =
  not (Text.null value)
    && not (Text.isPrefixOf "/" value)
    && not (Text.any (`elem` ['\\', '\0']) value)
    && all (\part -> not (Text.null part) && part /= "." && part /= "..") (Text.splitOn "/" value)

listTree :: FilePath -> IO ([Text], [Text])
listTree root = go ""
  where
    go relative = do
      let directory = if Text.null relative then root else root </> Text.unpack relative
      names <- listDirectory directory
      parts <- forM names \name -> do
        let path = if Text.null relative then Text.pack name else relative <> "/" <> Text.pack name
            full = root </> Text.unpack path
        symbolic <- pathIsSymbolicLink full
        if symbolic
          then pure ([], [path])
          else do
            directoryEntry <- doesDirectoryExist full
            if directoryEntry
              then go path
              else do
                regular <- doesFileExist full
                pure (if regular then [path] else [], if regular then [] else [path])
      pure (concatMap fst parts, concatMap snd parts)

matches :: FilePath -> Artifact -> IO Bool
matches path artifact = do
  (digest, size) <- digestFile path
  pure (digest == artifact.sha256 && size == artifact.bytes)

digestFile :: FilePath -> IO (Text, Int64)
digestFile path = withBinaryFile path ReadMode (go SHA256.init 0)
  where
    go context size handle = do
      chunk <- ByteString.hGetSome handle 65536
      if ByteString.null chunk
        then pure (TextEncoding.decodeUtf8 (Base16.encode (SHA256.finalize context)), size)
        else do
          let nextContext = SHA256.update context chunk
              nextSize = size + fromIntegral (ByteString.length chunk)
          nextContext `seq` nextSize `seq` go nextContext nextSize handle

writeVerified :: FilePath -> FilePath -> LazyByteString.ByteString -> IO ()
writeVerified root relative bytes = do
  let target = root </> relative
  withTemporary target \temporary -> LazyByteString.writeFile temporary bytes >> renameFile temporary target

withTemporary :: FilePath -> (FilePath -> IO value) -> IO value
withTemporary target action = do
  createDirectoryIfMissing True (takeDirectory target)
  bracket (openBinaryTempFile (takeDirectory target) ".kenshou-fetch-") cleanup \(temporary, handle) -> do
    hClose handle
    action temporary
  where
    cleanup (temporary, _) = do
      exists <- doesFileExist temporary
      if exists then removeFile temporary else pure ()

firstFailure :: [Maybe failure] -> Maybe failure
firstFailure = listToMaybe . catMaybes
