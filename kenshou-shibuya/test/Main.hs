module Main (main) where

import Data.Either (isLeft)
import Kenshou.Suite.Shibuya.Cohort (CoreLine (..), coreLine, knownOnReleasedCore, rev)
import Kenshou.Suite.Shibuya.Knobs (parseConcurrency, parseOrdering, parseStrategy)
import Shibuya.Policy (Concurrency (..), OrderingPolicy (..), validatePolicy)
import Test.Hspec

main :: IO ()
main = hspec $ do
  describe "cohort capability probe" $ do
    it "agrees with the linked shibuya-core policy" $
      case coreLine of
        CoreReleased0903 -> isLeft (validatePolicy Unordered (Async 0)) `shouldBe` False
        CoreLifecycleRemediated -> isLeft (validatePolicy Unordered (Async 0)) `shouldBe` True
    it "retains a released-only defect only on the released line" $
      (case coreLine of CoreReleased0903 -> knownOnReleasedCore (rev 3 "REV-3-F2") /= Nothing; CoreLifecycleRemediated -> knownOnReleasedCore (rev 3 "REV-3-F2") == Nothing) `shouldBe` True
  describe "configuration parsers" $ do
    it "parses all concurrency forms, including invalid policy bounds for the runtime to reject" $ do
      parseConcurrency "serial" `shouldBe` Right Serial
      parseConcurrency "ahead:4" `shouldBe` Right (Ahead 4)
      parseConcurrency "async:-1" `shouldBe` Right (Async (-1))
      parseConcurrency "async:garbage" `shouldSatisfy` isLeft
    it "parses ordering and supervision without accepting unknown names" $ do
      parseOrdering "partitioned-in-order" `shouldBe` Right PartitionedInOrder
      parseOrdering "unknown" `shouldSatisfy` isLeft
      parseStrategy "stop-all-on-failure" `shouldSatisfy` isRight
      parseStrategy "unknown" `shouldSatisfy` isLeft
  where
    isRight = not . isLeft
