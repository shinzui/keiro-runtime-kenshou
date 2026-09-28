module HealthSpec (spec) where

import Control.Concurrent (threadDelay)
import Data.Aeson (Value (..), eitherDecodeFileStrict', encode)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Kenshou.Core.Id (parseRunId)
import Kenshou.Remote.Cell.Health (mapCellHealth, withCellHealthFile)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "cell health mapping" do
  it "maps a tripped maintenance gate into a hard run notice" do
    document <- ownerHealth
    identifier <- either (error . show) pure (parseRunId "0199a3c2-7b1e-7c44-9d0a-3f5e2a61b7c9")
    case mapCellHealth identifier document of
      Left problem -> expectationFailure (show problem)
      Right [Object fields] -> do
        KeyMap.lookup "schema" fields `shouldBe` Just (String "kenshou.health-notice/v1")
        KeyMap.lookup "source" fields `shouldBe` Just (String "cell-health:host-maintenance:cell-alpha-postgres")
        KeyMap.lookup "severity" fields `shouldBe` Just (String "hard")
      Right notices -> expectationFailure ("expected one notice: " <> show notices)

  it "rejects another cell run's health document" do
    document <- ownerHealth
    identifier <- either (error . show) pure (parseRunId "0199a3f2-7c20-7f00-8a11-0c0d0e0f1011")
    mapCellHealth identifier document `shouldSatisfy` isLeft

  it "reads new complete lines while a run executes and does not duplicate notices" $
    withSystemTempDirectory "kenshou-cell-health" \root -> do
      identifier <- either (error . show) pure (parseRunId "0199a3c2-7b1e-7c44-9d0a-3f5e2a61b7c9")
      let source = root </> "cell-health.jsonl"
          destination = root </> "health-notices.jsonl"
      LazyByteString.writeFile destination ""
      line <- encode <$> ownerHealth
      withCellHealthFile (Just source) destination identifier do
        LazyByteString.writeFile source (line <> "\n" <> line <> "\n")
        threadDelay 1500000
      notices <- LazyByteString.readFile destination
      length (filter (not . LazyByteString.null) (LazyByteString.split 10 notices)) `shouldBe` 1

ownerHealth :: IO Value
ownerHealth = eitherDecodeFileStrict' "test/golden/cell/cell.health.v1.json" >>= either fail pure

isLeft :: Either Text [Value] -> Bool
isLeft (Left _) = True
isLeft _ = False
