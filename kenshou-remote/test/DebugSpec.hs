module DebugSpec (spec) where

import Data.Aeson (eitherDecodeFileStrict')
import Kenshou.Remote.Cell.Debug (remoteCommand, resolveDebugRole)
import Kenshou.Remote.Cell.Docs (CellDescriptor)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import Test.Hspec

spec :: Spec
spec = describe "cell debug target" do
  it "selects only instances named by the verified descriptor" do
    decoded <- eitherDecodeFileStrict' "test/golden/cell/cell.descriptor.v1.json"
    descriptor <- either (fail . ("descriptor fixture: " <>)) pure (decoded :: Either String CellDescriptor)
    resolveDebugRole descriptor "driver" `shouldBe` Right "cell-alpha-driver-0"
    resolveDebugRole descriptor "driver-0" `shouldBe` Right "cell-alpha-driver-0"
    resolveDebugRole descriptor "postgres" `shouldBe` Right "cell-alpha-postgres"
    resolveDebugRole descriptor "monitoring" `shouldBe` Right "cell-alpha-monitoring"
    resolveDebugRole descriptor "driver-1" `shouldBe` Left "cell descriptor has no driver at that index"
    resolveDebugRole descriptor "broker" `shouldBe` Left "role must be postgres, monitoring, driver, or driver-N"

  it "preserves spaces and apostrophes in remote command arguments" do
    (code, output, failure) <- readProcessWithExitCode "/bin/sh" ["-c", remoteCommand ["printf", "%s", "two words", "it's"]] ""
    code `shouldBe` ExitSuccess
    failure `shouldBe` ""
    output `shouldBe` "two wordsit's"
