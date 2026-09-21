module Kenshou.Diagnose.ProfileSpec (spec) where

import Data.List (isPrefixOf)
import Kenshou.Diagnose.Profile
import Test.Hspec

spec :: Spec
spec = describe "Kenshou.Diagnose.Profile" do
  it "assembles closure-type flags with a bounded event log" do
    let flags = rtsFlags ClosureType "session/kenshou.eventlog" 10
    flags `shouldContain` ["-hT", "-i10.0", "-l-agu", "-olsession/kenshou.eventlog", "--eventlog-flush-interval=5"]

  it "keeps scheduler events opt-in" do
    rtsFlags (Eventlog "gu") "events" 10 `shouldSatisfy` not . any (== "-l-agus")
    rtsFlags (Eventlog "gus") "events" 10 `shouldContain` ["-l-agus"]

  it "selects source and retainer breakdowns for profiled libraries" do
    rtsFlags (Profiled 'r') "profiled" 5 `shouldSatisfy` any ("-hr" `isPrefixOf`)
