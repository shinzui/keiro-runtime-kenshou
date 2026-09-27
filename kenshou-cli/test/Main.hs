module Main (main) where

import Data.Aeson (Value, object, (.=))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Kenshou.Cli (runWithArgs)
import Kenshou.Cli.Attest (FencingFacts (..), fencingFacts)
import Kenshou.Cli.Version (appVersionWithGit)
import System.Exit (ExitCode (..))
import Test.Hspec (describe, hspec, it, shouldBe, shouldSatisfy)

main :: IO ()
main = hspec do
  describe "Kafka fencing outcome oracle" do
    it "derives the released idle-member failure from separate worker logs" do
      fencingFacts [] [okEvent 10]
        `shouldBe` Right (FencingFacts True False False [] ["fenced-member-still-alive-and-idle"])

    it "derives a passing fatal exit from separate worker logs" do
      fencingFacts [errorEvent "KafkaResponseError RdKafkaRespErrFatal", doneEvent] [okEvent 10]
        `shouldBe` Right (FencingFacts True True True ["KafkaResponseError RdKafkaRespErrFatal"] [])

    it "keeps an unrelated consumer error blocking" do
      fencingFacts [errorEvent "unexpected Kafka error"] [okEvent 10]
        `shouldBe` Right (FencingFacts True False False ["unexpected Kafka error"] ["fencing-unexpected-error", "fencing-fatal-not-observable"])

    it "rejects malformed error evidence" do
      fencingFacts [object ["type" .= ("error" :: Text)]] [okEvent 10]
        `shouldBe` Left "an original-consumer error event has no message"

  describe "CLI exit contract" do
    it "returns success for help" do
      runWithArgs ["--help"] `shouldReturnCode` ExitSuccess

    it "returns success for command-specific help" do
      runWithArgs ["record", "--help"] `shouldReturnCode` ExitSuccess
      runWithArgs ["attest", "--help"] `shouldReturnCode` ExitSuccess
      runWithArgs ["history", "--help"] `shouldReturnCode` ExitSuccess
      runWithArgs ["run", "--help"] `shouldReturnCode` ExitSuccess

    it "reads scenario history from a bundle" do
      runWithArgs ["history", "--bundle", "../docs/verification", "--scenario", "selftest/kernel/correctness/always-pass", "--json"] `shouldReturnCode` ExitSuccess

    it "requires one record source" do
      runWithArgs ["record", "--purpose", "release"] `shouldReturnCode` ExitFailure 2
      runWithArgs ["record", "a-run", "--comparison", "comparison.json", "--purpose", "release"] `shouldReturnCode` ExitFailure 2

    it "rejects a human anomaly exception without an interactive terminal" do
      runWithArgs ["attest", "invalid", "--project", "fixture", "--accept-anomaly", "--authority", "human:fixture", "--reason", "fixture"] `shouldReturnCode` ExitFailure 2

    it "returns 2 for an unknown subcommand" do
      runWithArgs ["cohort", "bogus"] `shouldReturnCode` ExitFailure 2

    it "returns 1 when offline leak diagnosis finds growth" do
      runWithArgs ["diagnose", "leak", leakingRun] `shouldReturnCode` ExitFailure 1

    it "returns 1 when an offline stall diagnosis exists" do
      runWithArgs ["diagnose", "stall", stalledRun] `shouldReturnCode` ExitFailure 1

    it "returns 0 when no offline stall diagnosis exists" do
      runWithArgs ["diagnose", "stall", leakingRun] `shouldReturnCode` ExitSuccess

    it "returns 3 when leak evidence is insufficient" do
      runWithArgs ["diagnose", "leak", stalledRun] `shouldReturnCode` ExitFailure 3

    it "returns 4 when diagnosis input is unavailable" do
      runWithArgs ["diagnose", "leak", "test/fixtures/does-not-exist"] `shouldReturnCode` ExitFailure 4

    it "returns 2 for invalid diagnose syntax" do
      runWithArgs ["diagnose", "leak", "--bogus"] `shouldReturnCode` ExitFailure 2

    it "does not mutate a sealed run manifest" do
      before <- Text.readFile (leakingRun <> "/manifest.json")
      _ <- runWithArgs ["diagnose", "leak", leakingRun]
      after <- Text.readFile (leakingRun <> "/manifest.json")
      after `shouldBe` before

  describe "version" do
    it "includes the cabal package version and a short revision" do
      appVersionWithGit `shouldSatisfy` Text.isPrefixOf "kenshou v0.1.0.0 ("
      Text.dropAround (`elem` ['(', ')']) (Text.takeWhileEnd (/= ' ') appVersionWithGit)
        `shouldSatisfy` (\revision -> revision == "dirty" || Text.length revision == 7)

shouldReturnCode :: IO ExitCode -> ExitCode -> IO ()
shouldReturnCode action expected = action >>= (`shouldBe` expected)

leakingRun :: FilePath
leakingRun = "../kenshou-diagnose/test/fixtures/run-leaking"

stalledRun :: FilePath
stalledRun = "../kenshou-diagnose/test/fixtures/run-stalled"

okEvent :: Int -> Value
okEvent value = object ["type" .= ("custom" :: Text), "name" .= ("ok" :: Text), "payload" .= object ["value" .= value]]

errorEvent :: Text -> Value
errorEvent message = object ["type" .= ("error" :: Text), "message" .= message]

doneEvent :: Value
doneEvent = object ["type" .= ("done" :: Text)]
