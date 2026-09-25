module MetricsSpec (spec) where

import Kenshou.Suite.Shibuya.Cohort (CoreLine (..), coreLine)
import Kenshou.Suite.Shibuya.Correctness.Metrics (counterFailures, liveFailures, readyFailures, websocketFlagFailures, websocketSlotFailures, websocketUnsubscribeFailures)
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
  it "rejects WebSocket upgrades when the endpoint is disabled on remediated metrics" $ do
    failures <- websocketFlagFailures
    failures `shouldBe` expected "REV-9-F2"
  it "suppresses updates after subscribe-all exclusions on remediated metrics" $ do
    failures <- websocketUnsubscribeFailures
    failures `shouldBe` expected "REV-9-F3"
  it "releases connection slots after repeated peer disconnects" $ do
    failures <- websocketSlotFailures
    failures `shouldBe` expected "REV-9-F1"
  where
    expected finding = case coreLine of
      CoreReleased0903 -> [finding]
      CoreLifecycleRemediated -> []
