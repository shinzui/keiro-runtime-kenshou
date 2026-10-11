module PerfPublicationSpec (spec) where

import Data.ByteString.Lazy.Char8 qualified as Bytes
import Data.Either (isLeft)
import Kenshou.Perf.Artifacts (sealPerfDirectory)
import Kenshou.Remote.Perf.Publication
import Kenshou.Remote.Store
import Kenshou.Remote.Store.File (newFileStore)
import System.Directory (createDirectory)
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
