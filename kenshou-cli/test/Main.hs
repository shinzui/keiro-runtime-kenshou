module Main (main) where

import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Kenshou.Cli (runWithArgs)
import Kenshou.Cli.Version (appVersionWithGit)
import System.Exit (ExitCode (..))
import Test.Hspec (describe, hspec, it, shouldBe, shouldSatisfy)

main :: IO ()
main = hspec do
  describe "CLI exit contract" do
    it "returns success for help" do
      runWithArgs ["--help"] `shouldReturnCode` ExitSuccess

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
