module MetricsSpec (spec) where

import Kenshou.Suite.Shibuya.Cohort (CoreLine (..), coreLine)
import Kenshou.Suite.Shibuya.Correctness.Metrics (counterProbe, exceptionRecoveryFailures, liveFailures, readyFailures, sustainedLoadFailures, websocketFlagFailures, websocketSlotFailures, websocketUnsubscribeFailures)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec :: Spec
spec = describe "metrics health lifecycle" $ do
  it "reports a failed configured processor as unready on remediated cores" $ do
    failures <- readyFailures
    failures `shouldBe` expected "REV-8-F1"
  it "reports a stopped master as not live on remediated cores" $ do
    failures <- liveFailures
    failures `shouldBe` expected "REV-8-F2"
  it "preserves the documented retry mapping and observes indistinguishable Prometheus samples" $ do
    result <- counterProbe
    result `shouldBe` ([], True)
  it "distinguishes steady progress from a genuinely stuck processor" $ do
    failures <- sustainedLoadFailures
    failures `shouldBe` expected "REV-7-F1"
  it "records readiness after a transient handler exception during continued work" $ do
    failures <- exceptionRecoveryFailures
    failures `shouldBe` ["transient-handler-error-sticks-failed-state"]
  it "rejects WebSocket upgrades when the endpoint is disabled on remediated metrics" $ do
    failures <- websocketFlagFailures
    failures `shouldBe` expected "REV-9-F2"
  it "suppresses updates after subscribe-all exclusions on remediated metrics" $ do
    failures <- websocketUnsubscribeFailures
    failures `shouldBe` expected "REV-9-F3"
  it "releases WebSocket slots and process resources after churn, cancellation and repeated stop" $ do
    failures <- websocketSlotFailures
    case coreLine of
      CoreReleased0903 -> do
        failures `shouldSatisfy` elem "REV-9-F1"
        failures `shouldSatisfy` all (`elem` ["REV-9-F1", "websocket-thread-baseline", "websocket-os-thread-baseline", "websocket-fd-baseline"])
      CoreLifecycleRemediated -> failures `shouldBe` []
  where
    expected finding = case coreLine of
      CoreReleased0903 -> [finding]
      CoreLifecycleRemediated -> []
