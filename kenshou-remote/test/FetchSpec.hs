module FetchSpec (spec) where

import Data.Aeson (encode)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Kenshou.Core.Id (RunId, newRunId, renderRunId)
import Kenshou.Remote.Cell.Docs (Artifact (..), CellManifest (..), CellOutcome (..), ManifestPayload (..), WorkObject (..))
import Kenshou.Remote.Cell.Fetch (FetchError (..), VerifyProblem (..), fetchCellRun, verifyCellTree)
import Kenshou.Remote.Cell.Submit (workObjectFor)
import Kenshou.Remote.Store (Bucket (..), ObjectName (..), ObjectStore (..), Precondition (..))
import Kenshou.Remote.Store.File (newFileStore)
import System.Directory (doesFileExist, removeFile)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "sealed cell tree fetch" do
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

hasDigestMismatch :: Either (NonEmpty VerifyProblem) CellManifest -> Bool
hasDigestMismatch (Left problems) = DigestMismatch "cell/result.json" `elem` toList problems
hasDigestMismatch _ = False

hasExtra :: Either (NonEmpty VerifyProblem) CellManifest -> Bool
hasExtra (Left problems) = Extra "unexpected.txt" `elem` toList problems
hasExtra _ = False

hasMissing :: Either (NonEmpty VerifyProblem) CellManifest -> Bool
hasMissing (Left problems) = Missing "cell/result.json" `elem` toList problems
hasMissing _ = False
