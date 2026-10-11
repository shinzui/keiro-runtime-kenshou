module PerfPublicationSpec (spec) where

import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy.Char8 qualified as Bytes
import Data.Either (isLeft)
import Data.Text (Text)
import Data.Time (getCurrentTime)
import Kenshou.Core.Canonical (sha256Hex)
import Kenshou.Core.Id (newRunId)
import Kenshou.Perf.Artifacts (sealPerfDirectory)
import Kenshou.Remote.Perf.Publication
import Kenshou.Remote.Store
import Kenshou.Remote.Store.File (newFileStore)
import System.Directory (createDirectory, doesPathExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "performance evidence publication" do
  it "retrieves every artifact, permits an identical retry and rejects a changed existing object" $ withSystemTempDirectory "perf-publication" \root -> do
    let directory = root </> "evidence"
        bucket = Bucket "evidence"
        prefix = "performance/fixture"
    createDirectory directory
    Bytes.writeFile (directory </> "result.json") "retained result"
    sealPerfDirectory directory >>= either (fail . show) pure
    store <- newFileStore (root </> "store")
    published <- publishEvidence store bucket prefix directory
    published `shouldBe` Right "gs://evidence/performance/fixture/manifest.json"
    publishEvidence store bucket prefix directory `shouldReturn` published
    verifyPublication store bucket prefix directory `shouldReturn` Right ()
    digest <- sha256Hex . Bytes.toStrict <$> Bytes.readFile (directory </> "manifest.json")
    retrieveEvidence store bucket prefix digest (root </> "retrieved") `shouldReturn` Right ()
    Bytes.readFile (root </> "retrieved/result.json") `shouldReturn` "retained result"
    retrieveEvidence store bucket prefix "sha256:wrong" (root </> "wrong") >>= (`shouldSatisfy` isLeft)
    current <- store.statObject bucket (ObjectName (prefix <> "/result.json")) >>= maybe (fail "missing published result") pure
    _ <- store.putObject bucket (ObjectName (prefix <> "/result.json")) "application/json" (GenerationIs current.generation) "changed result"
    verifyPublication store bucket prefix directory >>= (`shouldSatisfy` isLeft)
    publishEvidence store bucket prefix directory >>= (`shouldSatisfy` isLeft)
  it "rejects local tampering and unsafe destinations before uploading any object" $ withSystemTempDirectory "perf-publication-rejection" \root -> do
    let directory = root </> "evidence"
        bucket = Bucket "evidence"
    createDirectory directory
    Bytes.writeFile (directory </> "result.json") "sealed"
    sealPerfDirectory directory >>= either (fail . show) pure
    store <- newFileStore (root </> "store")
    publishEvidence store bucket "performance/../escape" directory >>= (`shouldSatisfy` isLeft)
    store.listObjects bucket "" `shouldReturn` []
    Bytes.appendFile (directory </> "result.json") "tampered"
    publishEvidence store bucket "performance/fixture" directory >>= (`shouldSatisfy` isLeft)
    store.listObjects bucket "" `shouldReturn` []
  it "rejects a pinned manifest containing an escaping path before creating its target" $ withSystemTempDirectory "perf-retrieval-escape" \root -> do
    store <- newFileStore (root </> "store")
    identifier <- newRunId
    now <- getCurrentTime
    let manifest = encode (object ["schema" .= ("kenshou.artifact-manifest/v1" :: Text), "algorithm" .= ("sha256" :: Text), "runId" .= identifier, "createdAt" .= now, "files" .= [object ["path" .= ("../escape" :: Text), "sha256" .= ("sha256:wrong" :: Text), "bytes" .= (1 :: Int), "mediaType" .= ("text/plain" :: Text)]]])
    _ <- store.putObject (Bucket "evidence") (ObjectName "performance/fixture/manifest.json") "application/json" DoesNotExist manifest
    retrieveEvidence store (Bucket "evidence") "performance/fixture" (sha256Hex (Bytes.toStrict manifest)) (root </> "retrieved") >>= (`shouldSatisfy` isLeft)
    doesPathExist (root </> "escape") `shouldReturn` False
