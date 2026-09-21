module Kenshou.Diagnose.RenderSpec (spec) where

import Control.Monad ((>=>))
import Data.Aeson (Result (..), eitherDecodeFileStrict', fromJSON)
import Data.Text.IO qualified as Text
import Kenshou.Diagnose.Document (Diagnosis (..))
import Kenshou.Diagnose.Leak (analyseRunDirectory, defaultLeakSpec)
import Kenshou.Diagnose.Profile
import Kenshou.Diagnose.Render
import Kenshou.Diagnose.Stall.Types (StallReport)
import Test.Hspec

spec :: Spec
spec = describe "diagnosis rendering goldens" do
  it "renders the leaking run" do
    result <- analyseRunDirectory "test/fixtures/run-leaking" defaultLeakSpec 0
    report <- either (expectationFailure . show >=> const (fail "leak analysis failed")) pure result
    golden <- Text.readFile "test/golden/diagnose-leak.txt"
    renderLeakReport report `shouldBe` golden

  it "renders the stalled run" do
    decoded <- eitherDecodeFileStrict' "test/fixtures/run-stalled/diagnosis/stall-1.json" :: IO (Either String Diagnosis)
    document <- either (expectationFailure >=> const (fail "stall document failed")) pure decoded
    report <- case fromJSON document.body of
      Error err -> expectationFailure err >> fail "stall report failed"
      Success value -> pure (value :: StallReport)
    golden <- Text.readFile "test/golden/diagnose-stall.txt"
    renderStallReport report `shouldBe` golden

  it "renders a profile session" do
    let report = ProfileReport "session" ClosureType "ordinary" ["-hT"] "kenshou" (Just "run") (Just "sha256") 10582 False 0
    golden <- Text.readFile "test/golden/diagnose-profile.txt"
    renderProfileReport report `shouldBe` golden
