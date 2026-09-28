module PayloadSpec (spec) where

import Data.Aeson (eitherDecode)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text qualified as Text
import Kenshou.Remote.Cell.Docs (WorkObject (..))
import Kenshou.Remote.Cell.Submit (workObjectFor)
import Kenshou.Remote.Payload (Bundle (..), CellPayload (..), PayloadDescriptor (..))
import Kenshou.Remote.Payload.Publish (BundlePublishError (..), publishBundle)
import Kenshou.Remote.Store (Bucket (..), ObjectName (..), ObjectStore (..), Precondition (..))
import Kenshou.Remote.Store.File (newFileStore)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "content-addressed payload publication" do
  it "publishes a checked bundle once and accepts an identical retry" $ withSystemTempDirectory "kenshou-payload" \root -> do
    store <- newFileStore (root </> "store")
    let source = root </> "bundle.nar.zst"
    LazyByteString.writeFile source bundleBytes
    descriptor <- fixtureFor bundleBytes
    publishBundle store (Bucket "control") descriptor source `shouldReturn` Right descriptor
    publishBundle store (Bucket "control") descriptor source `shouldReturn` Right descriptor
    objects <- store.listObjects (Bucket "control") "payloads/sha256/"
    length objects `shouldBe` 1
    stored <- store.getObject (Bucket "control") (objectFor descriptor)
    fmap fst stored `shouldBe` Just bundleBytes

  it "refuses a digest mismatch before creating an object" $ withSystemTempDirectory "kenshou-payload" \root -> do
    store <- newFileStore (root </> "store")
    let source = root </> "bundle.nar.zst"
    LazyByteString.writeFile source bundleBytes
    descriptor <- fixtureFor bundleBytes
    let cell = descriptor.cell
        original = cell.bundle
        wrongDigest = Text.replicate 64 "b"
        wrong = descriptor {cell = cell {bundle = original {sha256 = wrongDigest, uri = "gs://control/payloads/sha256/" <> wrongDigest <> ".nar.zst"}}}
    result <- publishBundle store (Bucket "control") wrong source
    result `shouldBe` Left (BundleDigestMismatch wrongDigest descriptor.cell.bundle.sha256)
    store.listObjects (Bucket "control") "payloads/sha256/" `shouldReturn` []

  it "refuses an incorrect declared byte count before creating an object" $ withSystemTempDirectory "kenshou-payload" \root -> do
    store <- newFileStore (root </> "store")
    let source = root </> "bundle.nar.zst"
    LazyByteString.writeFile source bundleBytes
    descriptor <- fixtureFor bundleBytes
    let cell = descriptor.cell
        original = cell.bundle
        wrong = descriptor {cell = cell {bundle = original {bytes = original.bytes + 1}}}
    publishBundle store (Bucket "control") wrong source `shouldReturn` Left (BundleBytesMismatch (original.bytes + 1) original.bytes)
    store.listObjects (Bucket "control") "payloads/sha256/" `shouldReturn` []

  it "rejects a wrong control bucket and an existing object of another size" $ withSystemTempDirectory "kenshou-payload" \root -> do
    store <- newFileStore (root </> "store")
    let source = root </> "bundle.nar.zst"
    LazyByteString.writeFile source bundleBytes
    descriptor <- fixtureFor bundleBytes
    publishBundle store (Bucket "other") descriptor source `shouldReturn` Left (BundleOutsideControlBucket descriptor.cell.bundle.uri)
    _ <- store.putObject (Bucket "control") (objectFor descriptor) "application/zstd" DoesNotExist "x"
    publishBundle store (Bucket "control") descriptor source `shouldReturn` Left (ExistingBundleSizeMismatch descriptor.cell.bundle.bytes 1)

fixtureFor :: LazyByteString.ByteString -> IO PayloadDescriptor
fixtureFor bytes = do
  encoded <- LazyByteString.readFile "test/golden/payload.json"
  fixture <- either (ioError . userError) pure (eitherDecode encoded :: Either String PayloadDescriptor)
  let work = workObjectFor "application/octet-stream" bytes
      bundle = Bundle ("gs://control/payloads/sha256/" <> work.sha256 <> ".nar.zst") work.sha256 work.bytes
      cell = fixture.cell
  pure fixture {cell = cell {bundle}}

objectFor :: PayloadDescriptor -> ObjectName
objectFor descriptor = ObjectName ("payloads/sha256/" <> descriptor.cell.bundle.sha256 <> ".nar.zst")

bundleBytes :: LazyByteString.ByteString
bundleBytes = "bundle-bytes"
