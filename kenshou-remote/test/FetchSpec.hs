module FetchSpec (spec, completeTreeWith, completeTreeWithNested) where

import Data.Aeson (Value, eitherDecode, encode, object, (.=))
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Kenshou.Core.Id (RunId, newRunId, parseScenarioId, renderRunId)
import Kenshou.Core.Manifest (Manifest (..), ManifestFile (..))
import Kenshou.Core.Outcome qualified as Outcome
import Kenshou.Core.RunSpec (minimalRunSpec)
import Kenshou.Remote.Cell.Docs (Artifact (..), CellManifest (..), CellOutcome (..), CellPhase (..), CellRunResult (..), CellStatus (..), LogChunks (..), ManifestPayload (..), Submission (..), WorkObject (..))
import Kenshou.Remote.Cell.Fetch (FetchError (..), VerifyProblem (..), effectiveOutcome, fetchCellRun, verifyCellRun, verifyCellRunWithStatus, verifyCellTree)
import Kenshou.Remote.Cell.Index (CellRunIndex (..), RunLink (..), deriveCellRunIndex, writeCellRunIndex)
import Kenshou.Remote.Cell.Submit (workObjectFor)
import Kenshou.Remote.Payload (Bundle (..), CellPayload (..))
import Kenshou.Remote.Store (Bucket (..), ObjectName (..), ObjectStore (..), Precondition (..))
import Kenshou.Remote.Store.File (newFileStore)
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "sealed cell tree fetch" do
  it "round-trips the derived cell-run index fixture" do
    bytes <- LazyByteString.readFile "test/golden/cell-run.json"
    case eitherDecode bytes :: Either String CellRunIndex of
      Left failure -> expectationFailure failure
      Right index -> eitherDecode (encode index) `shouldBe` (eitherDecode bytes :: Either String Value)

  it "maps cell failures onto effective nested-run outcomes" do
    effectiveOutcome Completed True Outcome.Failed `shouldBe` Outcome.Failed
    effectiveOutcome InfrastructureFailure True Outcome.Passed `shouldBe` Outcome.InfrastructureFailure
    effectiveOutcome Cancelled True Outcome.Passed `shouldBe` Outcome.Passed
    effectiveOutcome Cancelled False Outcome.Passed `shouldBe` Outcome.Errored
    effectiveOutcome TimedOut False Outcome.Inconclusive `shouldBe` Outcome.Errored

  it "requires a seal, verifies bytes, and repairs a damaged local artifact on replay" $ withSystemTempDirectory "kenshou-fetch" \root -> do
    store <- newFileStore (root </> "store")
    identifier <- newRunId
    fetchCellRun store bucket identifier (root </> "out") `shouldReturn` Left Unsealed
    manifest <- publishFixture store identifier
    fetched <- fetchCellRun store bucket identifier (root </> "out")
    tree <- case fetched of
      Right path -> pure path
      Left failure -> expectationFailure (show failure) >> error "unreachable"
    verifyCellTree tree `shouldReturn` Right manifest
    LazyByteString.writeFile (tree </> "cell" </> "result.json") "bad"
    damaged <- verifyCellTree tree
    damaged `shouldSatisfy` hasDigestMismatch
    fetchCellRun store bucket identifier (root </> "out") `shouldReturn` Right tree
    verifyCellTree tree `shouldReturn` Right manifest
    LazyByteString.writeFile (tree </> "unexpected.txt") "extra"
    withExtra <- verifyCellTree tree
    withExtra `shouldSatisfy` hasExtra
    removeFile (tree </> "unexpected.txt")
    removeFile (tree </> "cell" </> "result.json")
    missing <- verifyCellTree tree
    missing `shouldSatisfy` hasMissing

  it "refuses an unlisted result object and a corrupt published artifact" $ withSystemTempDirectory "kenshou-fetch" \root -> do
    store <- newFileStore (root </> "store")
    identifier <- newRunId
    _ <- publishFixture store identifier
    put store identifier "stray.txt" "extra"
    result <- fetchCellRun store bucket identifier (root </> "out")
    result `shouldSatisfy` \case
      Left (ObjectSetMismatch _ [unexpected]) -> unexpected == prefix identifier <> "stray.txt"
      _ -> False
    store.deleteObject bucket (ObjectName (prefix identifier <> "stray.txt")) NoPrecondition `shouldReturn` True
    put store identifier "cell/result.json" (LazyByteString.replicate (LazyByteString.length resultBytes) 120)
    fetchCellRun store bucket identifier (root </> "out") `shouldReturn` Left (ObjectCorrupt "cell/result.json")
    doesFileExist (root </> "out" </> Text.unpack (renderRunId identifier) </> "tree" </> "cell" </> "result.json") `shouldReturn` False

  it "cross-checks the submission, cell result and nested Kenshou manifest" $ withSystemTempDirectory "kenshou-verify" \root -> do
    (tree, manifest) <- completeTree root False False False
    verifyCellRun tree `shouldReturn` Right manifest

  it "accepts cell support directories without nested run manifests" $ withSystemTempDirectory "kenshou-verify" \root -> do
    (tree, manifest) <- completeTree root False False False
    let supporting = [("output/kenshou-cell/context.json", "{}"), ("output/specs/0001.json", "{}")]
        expanded = manifest {artifacts = manifest.artifacts <> [artifactFor name bytes | (name, bytes) <- supporting]}
    mapM_
      ( \(name, bytes) -> do
          let destination = tree </> Text.unpack name
          createDirectoryIfMissing True (takeDirectory destination)
          LazyByteString.writeFile destination bytes
      )
      supporting
    LazyByteString.writeFile (tree </> "manifest.json") (encode expanded)
    verifyCellRun tree `shouldReturn` Right expanded

  it "rejects a payload identity mismatch after all file digests pass" $ withSystemTempDirectory "kenshou-verify" \root -> do
    (tree, _) <- completeTree root True False False
    result <- verifyCellRun tree
    result `shouldSatisfy` \case
      Left problems -> any isPayloadMismatch problems
      Right _ -> False

  it "requires a nested manifest and a matching nested run identifier" $ withSystemTempDirectory "kenshou-verify" \root -> do
    (tree, _) <- completeTree (root </> "wrong-id") False True False
    mismatch <- verifyCellRun tree
    mismatch `shouldSatisfy` \case
      Left problems -> any isRunResultMismatch problems
      Right _ -> False
    (otherTree, manifest) <- completeTree (root </> "missing") False False False
    case [artifact.path | artifact <- manifest.artifacts, "/manifest.json" `Text.isSuffixOf` artifact.path] of
      [nestedPath] -> do
        removeFile (otherTree </> Text.unpack nestedPath)
        let withoutNested = manifest {artifacts = filter ((/= nestedPath) . (.path)) manifest.artifacts}
        LazyByteString.writeFile (otherTree </> "manifest.json") (encode withoutNested)
        absent <- verifyCellRun otherTree
        absent `shouldSatisfy` \case
          Left problems -> any isNestedManifestProblem problems
          Right _ -> False
      _ -> expectationFailure "expected one nested manifest"

  it "rejects an unsafe nested path before calling the kernel verifier" $ withSystemTempDirectory "kenshou-verify" \root -> do
    (tree, _) <- completeTree root False False True
    result <- verifyCellRun tree
    result `shouldSatisfy` \case
      Left problems -> any isNestedManifestProblem problems
      Right _ -> False

  it "requires the final status to agree with the fetched seal" $ withSystemTempDirectory "kenshou-verify" \root -> do
    (tree, manifest) <- completeTree root False False False
    bytes <- LazyByteString.readFile (tree </> "manifest.json")
    let sealed = CellStatus manifest.runId Sealed (Just manifest.leaseSequence) manifest.sealedAt Nothing (LogChunks 0 0) (Just manifest.outcome) (Just (digestOf bytes)) (Just [])
    verifyCellRunWithStatus sealed tree `shouldReturn` Right manifest
    let wrong = CellStatus sealed.runId sealed.phase sealed.leaseSequence sealed.updatedAt sealed.phaseStartedAt sealed.logChunks sealed.outcome (Just (Text.replicate 64 "f")) sealed.reasons
    result <- verifyCellRunWithStatus wrong tree
    result `shouldSatisfy` \case
      Left problems -> StatusDigestMismatch `elem` problems
      Right _ -> False

  it "derives a durable index beside a verified cell tree" $ withSystemTempDirectory "kenshou-index" \root -> do
    (tree, manifest) <- completeTree root False False False
    derived <- deriveCellRunIndex (Bucket "results") Nothing tree
    case derived of
      Left failure -> expectationFailure (show failure)
      Right index -> do
        index.cellRun `shouldBe` manifest.runId
        index.resultsBaseUri `shouldBe` ("gs://results/runs/" <> renderRunId manifest.runId)
        index.dataBaseUri `shouldBe` (index.resultsBaseUri <> "/output")
        length index.runs `shouldBe` 1
        map (.recordedOutcome) index.runs `shouldBe` [Outcome.Passed]
        map (.effectiveOutcome) index.runs `shouldBe` [Outcome.Passed]
        destination <- writeCellRunIndex tree index
        destination `shouldBe` root </> "cell-run.json"
        stored <- LazyByteString.readFile destination
        eitherDecode stored `shouldBe` Right index

publishFixture :: ObjectStore -> RunId -> IO CellManifest
publishFixture store identifier = do
  lease <- newRunId
  now <- getCurrentTime
  let payload = ManifestPayload "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-fixture"
      work = workObjectFor "application/json" resultBytes
      artifact = Artifact "cell/result.json" work.sha256 work.bytes "application/json"
      manifest = CellManifest identifier "alpha" lease 1 now "0.1.0" payload Completed 3600 [artifact]
  put store identifier "cell/result.json" resultBytes
  put store identifier "manifest.json" (encode manifest)
  pure manifest

put :: ObjectStore -> RunId -> Text -> LazyByteString.ByteString -> IO ()
put store identifier suffix bytes = do
  _ <- store.putObject bucket (ObjectName (prefix identifier <> suffix)) "application/json" NoPrecondition bytes
  pure ()

prefix :: RunId -> Text
prefix identifier = "runs/" <> renderRunId identifier <> "/"

bucket :: Bucket
bucket = Bucket "results"

resultBytes :: LazyByteString.ByteString
resultBytes = "{\"schema\":\"cell.run-result/v1\"}"

completeTree :: FilePath -> Bool -> Bool -> Bool -> IO (FilePath, CellManifest)
completeTree root wrongPayload wrongRunId unsafeNested = do
  identifier <- newRunId
  lease <- newRunId
  completeTreeWith root identifier lease wrongPayload wrongRunId unsafeNested

completeTreeWith :: FilePath -> RunId -> RunId -> Bool -> Bool -> Bool -> IO (FilePath, CellManifest)
completeTreeWith root identifier lease wrongPayload wrongRunId unsafeNested = do
  nestedId <- newRunId
  completeTreeWithNested root identifier lease nestedId wrongPayload wrongRunId unsafeNested

completeTreeWithNested :: FilePath -> RunId -> RunId -> RunId -> Bool -> Bool -> Bool -> IO (FilePath, CellManifest)
completeTreeWithNested root identifier lease nestedId wrongPayload wrongRunId unsafeNested = do
  otherId <- newRunId
  now <- getCurrentTime
  scenario <- either (ioError . userError . Text.unpack) pure (parseScenarioId "selftest/kernel/correctness/always-pass")
  source <- LazyByteString.readFile "test/golden/cell/cell.submission.v1.json"
  fixture <- either (ioError . userError) pure (eitherDecode source :: Either String Submission)
  let workBytes = encode (object ["schema" .= ("kenshou.run-plan/v1" :: Text), "planId" .= identifier, "runs" .= [object ["ordinal" .= (1 :: Int), "runId" .= nestedId, "estimateMinutes" .= (1 :: Int), "spec" .= minimalRunSpec scenario]]])
      workInfo = workObjectFor "application/json" workBytes
      submitted = Submission identifier lease fixture.payload workInfo fixture.env fixture.reset fixture.limits fixture.requires Nothing fixture.labels
      payloadDigest = fixture.payload.bundle.sha256
      manifestDigest = if wrongPayload then Text.replicate 64 "b" else payloadDigest
      manifestPayload = ManifestPayload manifestDigest fixture.payload.storePath
      cellResult = CellRunResult identifier "alpha" lease 1 Completed (Just 0) Nothing []
      runBytes = encode (object ["schema" .= ("kenshou.run-result/v1" :: Text), "runId" .= (if wrongRunId then otherId else nestedId), "scenario" .= ("selftest/kernel/correctness/always-pass" :: Text), "outcome" .= Outcome.Passed, "fingerprint" .= object ["cell" .= object ["payload" .= object ["bundleSha256" .= payloadDigest]]]])
      nestedFile = ManifestFile (if unsafeNested then "../escape" else "run-result.json") ("sha256:" <> digestOf runBytes) (fromIntegral (LazyByteString.length runBytes)) "application/json"
      nestedManifest = Manifest nestedId now [nestedFile]
      files =
        [ ("submission/work", workBytes),
          ("submission/submission.json", encode submitted),
          ("cell/result.json", encode cellResult),
          ("output/" <> renderRunId nestedId <> "/run-result.json", runBytes),
          ("output/" <> renderRunId nestedId <> "/manifest.json", encode nestedManifest)
        ]
      artifacts = [artifactFor name bytes | (name, bytes) <- files]
      manifest = CellManifest identifier "alpha" lease 1 now "0.1.0" manifestPayload Completed 3600 artifacts
      tree = root </> "tree"
  mapM_
    ( \(name, bytes) -> do
        let destination = tree </> Text.unpack name
        createDirectoryIfMissing True (takeDirectory destination)
        LazyByteString.writeFile destination bytes
    )
    files
  LazyByteString.writeFile (tree </> "manifest.json") (encode manifest)
  pure (tree, manifest)

artifactFor :: Text -> LazyByteString.ByteString -> Artifact
artifactFor name bytes = let info = workObjectFor "application/json" bytes in Artifact name info.sha256 info.bytes "application/json"

digestOf :: LazyByteString.ByteString -> Text
digestOf bytes = (workObjectFor "application/json" bytes).sha256

isPayloadMismatch :: VerifyProblem -> Bool
isPayloadMismatch (PayloadMismatch _) = True
isPayloadMismatch _ = False

isRunResultMismatch :: VerifyProblem -> Bool
isRunResultMismatch (RunResultMismatch _) = True
isRunResultMismatch _ = False

isNestedManifestProblem :: VerifyProblem -> Bool
isNestedManifestProblem (NestedManifestProblem _) = True
isNestedManifestProblem _ = False

hasDigestMismatch :: Either (NonEmpty VerifyProblem) CellManifest -> Bool
hasDigestMismatch (Left problems) = DigestMismatch "cell/result.json" `elem` toList problems
hasDigestMismatch _ = False

hasExtra :: Either (NonEmpty VerifyProblem) CellManifest -> Bool
hasExtra (Left problems) = Extra "unexpected.txt" `elem` toList problems
hasExtra _ = False

hasMissing :: Either (NonEmpty VerifyProblem) CellManifest -> Bool
hasMissing (Left problems) = Missing "cell/result.json" `elem` toList problems
hasMissing _ = False
