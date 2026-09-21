module Main (main) where

import Kenshou.Diagnose.LeakSpec qualified
import Kenshou.Diagnose.StatsSpec qualified
import Test.Hspec (hspec)

main :: IO ()
main = hspec do
  Kenshou.Diagnose.StatsSpec.spec
  Kenshou.Diagnose.LeakSpec.spec
