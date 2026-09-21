module Kenshou.Measure.SamplerSpec (spec) where

import Data.Text.IO qualified as Text
import Kenshou.Measure.Sampler.Host
import Kenshou.Measure.Sampler.Process
import Test.Hspec

spec :: Spec
spec = describe "Kenshou.Measure.Sampler parsers" do
  it "parses Linux process statistics after a command name containing spaces and parentheses" do
    stat <- Text.readFile "test/fixtures/proc/stat.txt"
    status <- Text.readFile "test/fixtures/proc/status.txt"
    let sample = parseProcSample stat status 17
    sample.rssBytes `shouldBe` Just (1_024 * 1_024)
    sample.rssMaxBytes `shouldBe` Just (2_048 * 1_024)
    sample.osThreads `shouldBe` Just 9
    sample.openFds `shouldBe` Just 17
    sample.cpuUserNs `shouldBe` Just 1_100_000_000
    sample.cpuSystemNs `shouldBe` Just 220_000_000
    sample.voluntaryContextSwitches `shouldBe` Just 31
    sample.nonvoluntaryContextSwitches `shouldBe` Just 7

  it "parses aggregate Linux host counters" do
    stat <- Text.readFile "test/fixtures/proc/host-stat.txt"
    loadavg <- Text.readFile "test/fixtures/proc/loadavg.txt"
    meminfo <- Text.readFile "test/fixtures/proc/meminfo.txt"
    let sample = parseHostSample stat loadavg meminfo
    sample.cpuUser `shouldBe` Just 100
    sample.cpuSteal `shouldBe` Just 8
    sample.loadAverage1 `shouldBe` Just 1.25
    sample.memAvailableBytes `shouldBe` Just (4_096 * 1_024)
