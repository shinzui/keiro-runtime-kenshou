module Main (main) where

import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString.Char8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Canonical (sha256Hex)
import Kenshou.Core.Id (parseRunId)
import Kenshou.Core.Manifest (writeManifest)
import Kenshou.Evidence.Publish (PublishError (..), PublishOptions (..), UploadMode (..), publishRunData)
import Kenshou.Evidence.Source (loadRunSource)
import Kenshou.Evidence.Store (ObjectStat (..), ObjectStore (..), PutResult (..), StoreError (..), directoryStore, gcloudStoreWith, memoryStore)
import Kenshou.Evidence.Types (DataKind (..), DataLink (..), Sha256 (..), mkRevision, mkSha256, sha256Bytes)
import System.Directory (Permissions (..), getPermissions, setPermissions)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

main :: IO ()
main = hspec do
  describe "gcloudStore" do
    it "requires the active project and reads size and SHA-256 metadata" do
      withSystemTempDirectory "kenshou-gcloud-store" $ \root -> do
        let executable = root </> "fake-gcloud"
            Sha256 digest = sha256Bytes "sealed"
            script = "#!/bin/sh\nif [ \"$1\" = config ]; then printf 'tan-nb-exp\\n'; exit 0; fi\nprintf '{\"size\":\"6\",\"metadata\":{\"kenshou-sha256\":\"" <> Text.unpack digest <> "\"}}\\n'\n"
        writeFile executable script
        permissions <- getPermissions executable
        setPermissions executable permissions {executable = True}
        let matching = gcloudStoreWith executable "tan-nb-exp"
            mismatched = gcloudStoreWith executable "other-project"
        matching.statObject "gs://bucket/object" `shouldReturn` Right (Just (ObjectStat 6 (Just (Sha256 digest))))
        mismatch <- mismatched.statObject "gs://bucket/object"
        mismatch `shouldSatisfy` isLeft

  describe "publishRunData" do
    it "publishes all verified run files and links the required ones" do
      withSystemTempDirectory "kenshou-publish" $ \root -> do
        writeRunFixture root
        source <- loadRunSource root >>= either (fail . show) pure
        store <- memoryStore
        let options = PublishOptions "gs://bucket/runs" UploadMissing True False
        published <- publishRunData store options root source
        case published of
          Left err -> expectationFailure (show err)
          Right links -> map (.kind) links `shouldBe` [RunSpecData, RunResultData, ManifestData]
        publishRunData store options root source `shouldReturn` published
        let verifyOnly = options {uploadMode = VerifyOnly}
        publishRunData store verifyOnly root source `shouldReturn` published
        original <- ByteString.readFile (root </> "run-result.json")
        ByteString.Char8.appendFile (root </> "run-result.json") "changed"
        conflicted <- publishRunData store options root source
        conflicted `shouldSatisfy` isLeft
        store.fetchObject ("gs://bucket/runs/01997f3a-5b7c-7e21-8a44-0d6c2f9b1e55/run-result.json") (root </> "retained-result.json") `shouldReturn` Right ()
        retained <- ByteString.readFile (root </> "retained-result.json")
        retained `shouldBe` original

    it "refuses a non-durable destination before publishing" do
      withSystemTempDirectory "kenshou-publish" $ \root -> do
        writeRunFixture root
        source <- loadRunSource root >>= either (fail . show) pure
        store <- memoryStore
        publishRunData store (PublishOptions "file:///tmp" UploadMissing False False) root source
          `shouldReturn` Left (InvalidBaseUri "file:///tmp")

  describe "loadRunSource" do
    it "accepts a complete kernel run and rejects extra or changed files" do
      withSystemTempDirectory "kenshou-run-source" $ \root -> do
        writeRunFixture root
        loaded <- loadRunSource root
        loaded `shouldSatisfy` isRight
        ByteString.Char8.writeFile (root </> "unlisted.log") "unlisted"
        loadRunSource root >>= (`shouldSatisfy` isLeft)
        ByteString.Char8.writeFile (root </> "unlisted.log") ""
        -- The manifest must list even empty files.
        loadRunSource root >>= (`shouldSatisfy` isLeft)

    it "rejects modified bytes covered by the manifest" do
      withSystemTempDirectory "kenshou-run-source" $ \root -> do
        writeRunFixture root
        ByteString.Char8.appendFile (root </> "run-result.json") " "
        loadRunSource root >>= (`shouldSatisfy` isLeft)

  describe "evidence digest types" do
    it "accepts only lowercase fixed-length hexadecimal digests and revisions" do
      mkSha256 ("a" <> mconcat (replicate 63 "0")) `shouldBe` Right (Sha256 ("a" <> mconcat (replicate 63 "0")))
      mkSha256 (mconcat (replicate 64 "A")) `shouldSatisfy` isLeft
      mkSha256 (mconcat (replicate 63 "0")) `shouldSatisfy` isLeft
      mkRevision (mconcat (replicate 40 "f")) `shouldSatisfy` isRight
      mkRevision (mconcat (replicate 41 "f")) `shouldSatisfy` isLeft
      mkSha256 (case sha256Bytes "sample" of Sha256 digest -> digest) `shouldSatisfy` isRight

  describe "memoryStore" do
    it "reuses identical content and refuses conflicting content under one URI" do
      withSystemTempDirectory "kenshou-memory-store" $ \root -> do
        let first = root </> "first"
            second = root </> "second"
            uri = "gs://bucket/runs/id/result.json"
        ByteString.Char8.writeFile first "original"
        ByteString.Char8.writeFile second "different"
        store <- memoryStore
        store.putObjectIfAbsent first uri "application/json" `shouldReturn` Right ObjectCreated
        store.putObjectIfAbsent first uri "application/json" `shouldReturn` Right ObjectPresent
        store.putObjectIfAbsent second uri "application/json" `shouldReturn` Left (ObjectConflict uri)
        store.fetchObject uri (root </> "fetched") `shouldReturn` Right ()
        ByteString.readFile (root </> "fetched") `shouldReturn` "original"

  describe "directoryStore" do
    it "publishes create-only bytes and reports the observed digest" do
      withSystemTempDirectory "kenshou-directory-store" $ \root -> do
        let store = directoryStore (root </> "objects")
            source = root </> "source"
            other = root </> "other"
            uri = "gs://bucket/runs/id/manifest.json"
        ByteString.Char8.writeFile source "sealed"
        ByteString.Char8.writeFile other "changed"
        store.putObjectIfAbsent source uri "application/json" `shouldReturn` Right ObjectCreated
        store.putObjectIfAbsent source uri "application/json" `shouldReturn` Right ObjectPresent
        store.putObjectIfAbsent other uri "application/json" `shouldReturn` Left (ObjectConflict uri)
        result <- store.statObject uri
        result `shouldSatisfy` \case
          Right (Just ObjectStat {bytes = 6, recordedSha256 = Just _}) -> True
          _ -> False
        store.fetchObject uri (root </> "fetched") `shouldReturn` Right ()
        ByteString.readFile (root </> "fetched") `shouldReturn` "sealed"

    it "rejects URI paths that could escape the object root" do
      withSystemTempDirectory "kenshou-directory-store" $ \root -> do
        let store = directoryStore root
        store.statObject "file:///tmp/result.json" `shouldReturn` Left (InvalidObjectUri "file:///tmp/result.json")
        store.statObject "gs://bucket/../escape" `shouldReturn` Left (InvalidObjectUri "gs://bucket/../escape")

isLeft :: Either left right -> Bool
isLeft = either (const True) (const False)

isRight :: Either left right -> Bool
isRight = not . isLeft

writeRunFixture :: FilePath -> IO ()
writeRunFixture root = do
  let runId = "01997f3a-5b7c-7e21-8a44-0d6c2f9b1e55" :: Text
      spec = object ["schema" .= ("kenshou.run-spec/v1" :: Text), "runId" .= runId, "scenario" .= ("selftest/kernel/correctness/always-pass" :: Text), "seed" .= (7 :: Int)]
      specBytes = LazyByteString.toStrict (encode spec)
      cohort = object ["schema" .= ("kenshou.cohort-identity/v1" :: Text), "cohort" .= ("fixture" :: Text), "compiler" .= ("ghc" :: Text), "cabalVersion" .= ("3.14" :: Text), "os" .= ("darwin" :: Text), "arch" .= ("aarch64" :: Text), "planHash" .= ("sha256:" :: Text), "descriptorSha256" .= ("sha256:" :: Text), "components" .= ([] :: [Value])]
      result =
        object
          [ "schema" .= ("kenshou.run-result/v1" :: Text),
            "runId" .= runId,
            "scenario" .= ("selftest/kernel/correctness/always-pass" :: Text),
            "outcome" .= ("passed" :: Text),
            "seed" .= (7 :: Int),
            "spec" .= object ["sha256" .= sha256Hex specBytes],
            "timings" .= object ["startedAt" .= ("2026-09-26T00:00:00Z" :: Text), "endedAt" .= ("2026-09-26T00:00:01Z" :: Text)],
            "cohort" .= cohort,
            "fingerprint" .= object [],
            "compatibility" .= object []
          ]
  ByteString.writeFile (root </> "run-spec.json") specBytes
  LazyByteString.writeFile (root </> "run-result.json") (encode result)
  parsed <- either (fail . show) pure (parseRunId runId)
  manifest <- writeManifest root parsed Map.empty
  LazyByteString.writeFile (root </> "manifest.json") (encode manifest)
