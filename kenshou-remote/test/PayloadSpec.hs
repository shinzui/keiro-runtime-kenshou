module PayloadSpec (spec) where

import Data.Aeson (eitherDecode, eitherDecodeStrict', object, (.=))
import Data.Aeson.Key qualified as Key
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text qualified as Text
import Kenshou.Core.Cohort (CohortDescriptor (..), CohortIdentity (..), CohortName (..), ComponentSpec (..), PackagePin (..), PackageSource (..), PlanHash (..), ResolvedComponent (..), ResolvedPackage (..))
import Kenshou.Remote.Cell.Docs (WorkObject (..))
import Kenshou.Remote.Cell.Submit (workObjectFor)
import Kenshou.Remote.Payload (Bundle (..), CellPayload (..), CohortCheck (..), Harness (..), PayloadDescriptor (..))
import Kenshou.Remote.Payload.Nix (BundleInfo (..), ClosureInfo (..), NixError (..), NixTools (..), exportBundleWith, parseClosureInfo)
import Kenshou.Remote.Payload.Publish (BundlePublishError (..), publishBundle)
import Kenshou.Remote.Payload.Publisher (PublishError (..), PublishOptions (..), PublisherDeps (..), publishPayloadWith)
import Kenshou.Remote.Store (Bucket (..), ObjectName (..), ObjectStore (..), Precondition (..))
import Kenshou.Remote.Store.File (newFileStore)
import System.Directory (Permissions (..), doesFileExist, getPermissions, listDirectory, setPermissions)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "content-addressed payload publication" do
  it "checks a Nix identity before build, then publishes its exported bundle and descriptor" $ withSystemTempDirectory "kenshou-publisher" \root -> do
    identity <- releasedIdentity
    store <- newFileStore (root </> "store")
    builds <- newIORef (0 :: Int)
    let output = root </> "payload.json"
        options = PublishOptions ".." "released" "default" (Bucket "control") output False
        storePath = "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-kenshou"
        work = workObjectFor "application/octet-stream" bundleBytes
        exported destination = do
          LazyByteString.writeFile destination bundleBytes
          pure (Right (BundleInfo destination work.sha256 work.bytes (ClosureInfo storePath "sha256-root" [storePath])))
        deps selected =
          PublisherDeps
            (\_ -> pure (Right (Harness (Text.replicate 40 "a") False)))
            (\_ -> pure (Right selected))
            (\_ -> modifyIORef' builds (+ 1) >> pure (Right storePath))
            (\_ -> exported)
    let stale = identity {identityDescriptorSha256 = Text.replicate 64 "0"}
    rejected <- publishPayloadWith (deps stale) store options
    rejected `shouldBe` Left (PublishCohortMismatch "Nix identity descriptor digest differs from the selected descriptor")
    readIORef builds `shouldReturn` 0
    store.listObjects (Bucket "control") "payloads/sha256/" `shouldReturn` []
    accepted <- publishPayloadWith (deps identity) store options
    descriptor <- case accepted of
      Left problem -> expectationFailure (show problem) >> error "unreachable"
      Right payload -> pure payload
    descriptor.cohortCheck.packagesChecked `shouldBe` 42
    descriptor.cell.bundle.sha256 `shouldBe` work.sha256
    readIORef builds `shouldReturn` 1
    stored <- store.getObject (Bucket "control") (objectFor descriptor)
    fmap fst stored `shouldBe` Just bundleBytes
    saved <- eitherDecode <$> LazyByteString.readFile output
    saved `shouldBe` Right descriptor

  it "reads the root NAR hash and complete closure from Nix metadata" do
    let root = "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-kenshou"
        dependency = "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-dependency"
        metadata =
          object
            [ Key.fromText (Text.pack root) .= object ["narHash" .= ("sha256-root" :: Text.Text)],
              Key.fromText (Text.pack dependency) .= object ["narHash" .= ("sha256-dependency" :: Text.Text)]
            ]
    parseClosureInfo root metadata `shouldBe` Right (ClosureInfo root "sha256-root" [root, dependency])
    parseClosureInfo dependency (object [Key.fromText (Text.pack root) .= object ["narHash" .= ("sha256-root" :: Text.Text)]])
      `shouldBe` Left (NixInvalidOutput "closure metadata omits the requested store path")

  it "streams a closure export through compression and removes a failed temporary bundle" $ withSystemTempDirectory "kenshou-nix-export" \root -> do
    let storePath = "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-kenshou"
        destination = root </> "bundle.nar.zst"
        tools = NixTools (root </> "nix") (root </> "nix-store") (root </> "zstd")
        exported = "exported bytes"
        work = workObjectFor "application/octet-stream" exported
    writeTool tools.nixExecutable (unlines ["#!/bin/sh", "printf '%s' '{\"" <> storePath <> "\":{\"narHash\":\"sha256-root\"}}'"])
    writeTool tools.nixStoreExecutable (unlines ["#!/bin/sh", "printf 'exported bytes'"])
    writeTool tools.zstdExecutable (unlines ["#!/bin/sh", "cat > \"$6\""])
    exportBundleWith tools storePath destination
      `shouldReturn` Right (BundleInfo destination work.sha256 work.bytes (ClosureInfo storePath "sha256-root" [storePath]))
    LazyByteString.readFile destination `shouldReturn` exported
    writeTool tools.zstdExecutable (unlines ["#!/bin/sh", "exit 7"])
    let failedDestination = root </> "failed.nar.zst"
    result <- exportBundleWith tools storePath failedDestination
    result `shouldSatisfy` \case
      Left (NixCommandFailed executable _ _ _) -> executable == tools.zstdExecutable
      _ -> False
    doesFileExist failedDestination `shouldReturn` False
    entries <- listDirectory root
    filter (Text.isPrefixOf ".kenshou-payload-" . Text.pack) entries `shouldBe` []

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

writeTool :: FilePath -> String -> IO ()
writeTool path contents = do
  writeFile path contents
  permissions <- getPermissions path
  setPermissions path permissions {executable = True}

releasedIdentity :: IO CohortIdentity
releasedIdentity = do
  contents <- ByteString.readFile "../cohort/released.json"
  descriptor <- either (ioError . userError) pure (eitherDecodeStrict' contents :: Either String CohortDescriptor)
  let resolved component =
        ResolvedComponent
          component.componentId
          component.componentMoriUri
          [ResolvedPackage pin.pinName pin.pinVersion (FromHackage Nothing) | pin <- component.componentPackages]
  pure
    ( CohortIdentity
        (CohortName "released")
        "ghc-9.12.4"
        "nix"
        "linux"
        "x86_64"
        (Just descriptor.descriptorIndexState)
        (PlanHash ("sha256:" <> Text.replicate 64 "a"))
        "5c08f30a78a7d36ab707cde925813987356bdc46d0c3626b2882814db685cf56"
        (map resolved descriptor.descriptorComponents)
        (Just "nix")
    )
