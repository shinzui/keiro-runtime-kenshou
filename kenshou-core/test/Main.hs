module Main (main) where

import Data.Text qualified as Text
import Kenshou.Core.Cohort (CohortName (..))
import Test.Hspec (describe, hspec, it, shouldBe)

main :: IO ()
main = hspec do
  describe "CohortName" do
    it "preserves the selected cohort name" do
      CohortName (Text.pack "released") `shouldBe` CohortName (Text.pack "released")
