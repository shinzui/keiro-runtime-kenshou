module PerfLockSpec (spec) where

import Control.Exception (IOException, try)
import Kenshou.Remote.Perf.Lock
import System.Directory (createDirectory, createDirectoryLink)
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (proc, readCreateProcessWithExitCode)
import Test.Hspec

spec :: Spec
spec = describe "performance client locking" do
  it "fences another process and releases ownership after a client exception" $ withSystemTempDirectory "perf-lock" \directory -> do
    executable <- getExecutablePath
    withPerformanceLock directory do
      (code, _, _) <- readCreateProcessWithExitCode (proc executable ["--perf-lock", directory]) ""
      code `shouldBe` ExitFailure 1
    _ <- try @IOException (withPerformanceLock directory (ioError (userError "interrupted client")))
    (code, output, _) <- readCreateProcessWithExitCode (proc executable ["--perf-lock", directory]) ""
    code `shouldBe` ExitSuccess
    output `shouldBe` "locked\n"
  it "fences two clients in one process, including directory aliases" $ withSystemTempDirectory "perf-lock-alias" \root -> do
    let target = root </> "target"
        alias = root </> "alias"
    createDirectory target
    createDirectoryLink target alias
    withPerformanceLock target $
      withPerformanceLock alias (pure ()) `shouldThrow` anyIOException
    withPerformanceLock target (pure ()) `shouldReturn` ()
