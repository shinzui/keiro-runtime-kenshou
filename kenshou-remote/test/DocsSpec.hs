module DocsSpec (spec) where

import Data.Aeson (ToJSON, Value (..), eitherDecode, encode, object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Either (isLeft, isRight)
import Data.Text (Text)
import Kenshou.Remote.Cell.Docs (Artifact, CellDescriptor, CellEnvironment, CellManifest (..), CellRunResult, CellStatus, Rejected, Submission)
import Test.Hspec

spec :: Spec
spec = describe "cell owner documents" do
  it "decodes status, rejection, run result and manifest fixtures without changing their JSON" do
    checkFixture "cell.status.v1.json" (eitherDecode :: LazyByteString.ByteString -> Either String CellStatus)
    checkFixture "cell.rejected.v1.json" (eitherDecode :: LazyByteString.ByteString -> Either String Rejected)
    checkFixture "cell.run-result.v1.json" (eitherDecode :: LazyByteString.ByteString -> Either String CellRunResult)
    checkFixture "cell.artifact-manifest.v1.json" (eitherDecode :: LazyByteString.ByteString -> Either String CellManifest)

  it "decodes the owner descriptor and environment fixtures without changing their JSON" do
    checkFixture "cell.descriptor.v1.json" (eitherDecode :: LazyByteString.ByteString -> Either String CellDescriptor)
    checkFixture "cell.environment.v1.json" (eitherDecode :: LazyByteString.ByteString -> Either String CellEnvironment)

  it "decodes the generic owner submission, including its non-Kenshou payload" do
    checkFixture "cell.submission.v1.json" (eitherDecode :: LazyByteString.ByteString -> Either String Submission)

  it "ignores future status fields while enforcing sealed terminal fields" do
    bytes <- LazyByteString.readFile "test/golden/cell/cell.status.v1.json"
    case eitherDecode bytes :: Either String Value of
      Right (Object fields) -> do
        let extended = Object (KeyMap.insert "futureField" (Bool True) fields)
        (eitherDecode (encode extended) :: Either String CellStatus) `shouldSatisfy` isRight
      _ -> expectationFailure "invalid status fixture"
    let incomplete = "{\"schema\":\"cell.status/v1\",\"runId\":\"0199a3c2-7b1e-7c44-9d0a-3f5e2a61b7c9\",\"phase\":\"sealed\",\"updatedAt\":\"2026-09-25T12:00:00Z\",\"logChunks\":{\"stdout\":0,\"stderr\":0},\"outcome\":\"completed\"}"
    (eitherDecode incomplete :: Either String CellStatus) `shouldSatisfy` isLeft

  it "accepts a nonterminal status without a verdict" do
    bytes <- LazyByteString.readFile "test/golden/cell/cell.status.v1.json"
    case eitherDecode bytes :: Either String Value of
      Right (Object fields) -> do
        let running = Object (KeyMap.insert "phase" (String "running") (KeyMap.delete "manifestSha256" (KeyMap.delete "outcome" fields)))
        case eitherDecode (encode running) :: Either String CellStatus of
          Left failure -> expectationFailure failure
          Right status -> toJSON status `shouldBe` running
      _ -> expectationFailure "invalid status fixture"

  it "preserves optional broker, OTLP, clock and fault-hook environment fields" do
    bytes <- LazyByteString.readFile "test/golden/cell/cell.environment.v1.json"
    case eitherDecode bytes :: Either String Value of
      Right (Object fields) -> do
        let endpoint = object ["grpc" .= ("http://10.0.0.4:4317" :: String), "http" .= ("http://10.0.0.4:4318" :: String)]
            broker = object ["bootstrapServers" .= ("10.0.0.5:9092" :: String), "adminUrl" .= ("http://10.0.0.5:9644" :: String), "implementation" .= ("redpanda" :: String), "version" .= ("25.1.0" :: String)]
            extended = Object (KeyMap.insert "faultHook" (String "/run/cell/fault-hook") (KeyMap.insert "clock" (object ["skewBoundMicros" .= (250 :: Int)]) (KeyMap.insert "otlp" (object ["null" .= endpoint, "file" .= endpoint]) (KeyMap.insert "broker" broker fields))))
        case eitherDecode (encode extended) :: Either String CellEnvironment of
          Left failure -> expectationFailure failure
          Right environment -> toJSON environment `shouldBe` extended
      _ -> expectationFailure "invalid environment fixture"

  it "rejects an artifact path that escapes the fetched tree" do
    let escaped = "{\"path\":\"../outside\",\"sha256\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"bytes\":1,\"mediaType\":\"application/json\"}"
    (eitherDecode escaped :: Either String Artifact) `shouldSatisfy` isLeft

  it "rejects ambiguous artifact paths and duplicate manifest entries" do
    bytes <- LazyByteString.readFile "test/golden/cell/cell.artifact-manifest.v1.json"
    let badPaths = ["a//b", "a/./b", "a/../b", "a\\b", "/a/b"] :: [Text]
    mapM_ (\path -> (eitherDecode (encode (object ["path" .= path, "sha256" .= ("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" :: String), "bytes" .= (1 :: Int), "mediaType" .= ("application/json" :: String)])) :: Either String Artifact) `shouldSatisfy` isLeft) badPaths
    case eitherDecode bytes :: Either String CellManifest of
      Right manifest -> do
        let duplicate = manifest {artifacts = manifest.artifacts <> take 1 manifest.artifacts}
        (eitherDecode (encode duplicate) :: Either String CellManifest) `shouldSatisfy` isLeft
      _ -> expectationFailure "invalid cell manifest fixture"

checkFixture :: (ToJSON document) => FilePath -> (LazyByteString.ByteString -> Either String document) -> IO ()
checkFixture name decoder = do
  bytes <- LazyByteString.readFile ("test/golden/cell/" <> name)
  case decoder bytes of
    Left failure -> expectationFailure failure
    Right document -> Right (toJSON document) `shouldBe` (eitherDecode bytes :: Either String Value)
