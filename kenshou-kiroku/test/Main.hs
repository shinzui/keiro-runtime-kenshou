module Main (main) where

import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Test.Hspec

main :: IO ()
main = hspec do
  describe "kiroku knobs" do
    it "declares the four store knobs" do
      length storeKnobs `shouldBe` 4
