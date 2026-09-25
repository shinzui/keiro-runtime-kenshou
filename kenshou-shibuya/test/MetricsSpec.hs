module MetricsSpec (spec) where

import Kenshou.Suite.Shibuya.Cohort (CoreLine (..), coreLine)
import Kenshou.Suite.Shibuya.Correctness.Metrics (counterFailures, liveFailures, readyFailures)
import Test.Hspec (Spec, describe, it, shouldBe)

spec :: Spec
spec = describe "metrics health lifecycle" $ do
  it "reports a failed configured processor as unready on remediated cores" $ do
    failures <- readyFailures
    failures `shouldBe` expected "REV-8-F1"
  it "reports a stopped master as not live on remediated cores" $ do
    failures <- liveFailures
    failures `shouldBe` expected "REV-8-F2"
  it "exposes identical counters for one retry and one success" $ do
    failures <- counterFailures
    failures `shouldBe` ["REV-7-A2"]
  where
    expected finding = case coreLine of
      CoreReleased0903 -> [finding]
      CoreLifecycleRemediated -> []
