module Main (main) where

import Data.List (find)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), renderKnobName)
import Kenshou.Telemetry.Spec (telemetryKnobs)
import Test.Hspec

main :: IO ()
main = hspec do
  describe "telemetryKnobs" do
    it "declares each shared knob once" do
      let names = fmap (renderKnobName . (.name)) telemetryKnobs
      length names `shouldBe` length (unique names)
    it "bounds the trace-id ratio to zero through one" do
      fmap (.allowed) (find ((== "otel.sampler-arg") . renderKnobName . (.name)) telemetryKnobs)
        `shouldBe` Just (DoubleRange 0 1)

unique :: (Eq value) => [value] -> [value]
unique [] = []
unique (value : values) = value : unique (filter (/= value) values)
