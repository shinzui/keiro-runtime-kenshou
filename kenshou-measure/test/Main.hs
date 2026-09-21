module Main (main) where

import Test.Hspec (describe, hspec, it, shouldBe)

main :: IO ()
main = hspec $ describe "Kenshou.Measure" $ it "loads the package" $ True `shouldBe` True
