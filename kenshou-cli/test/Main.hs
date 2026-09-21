module Main (main) where

import Data.Text qualified as Text
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

  describe "version" do
    it "includes the cabal package version and a short revision" do
      appVersionWithGit `shouldSatisfy` Text.isPrefixOf "kenshou v0.1.0.0 ("
      Text.dropAround (`elem` ['(', ')']) (Text.takeWhileEnd (/= ' ') appVersionWithGit)
        `shouldSatisfy` (\revision -> revision == "dirty" || Text.length revision == 7)

shouldReturnCode :: IO ExitCode -> ExitCode -> IO ()
shouldReturnCode action expected = action >>= (`shouldBe` expected)
