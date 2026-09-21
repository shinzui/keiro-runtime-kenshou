module Kenshou.Measure.ClockSpec (spec) where

import Kenshou.Measure.Clock
import Test.Hspec

spec :: Spec
spec = describe "Kenshou.Measure.Clock" do
  it "sleepUntilNs never returns before the deadline" do
    start <- nowNs
    let deadline = start + 2_000_000
    sleepUntilNs deadline
    finished <- nowNs
    finished `shouldSatisfy` (>= deadline)

  it "captures paired monotonic and wall-clock origins" do
    origin <- captureOrigin
    origin.monoNs `shouldSatisfy` (> 0)
    origin.wallUnixNs `shouldSatisfy` (> 0)
