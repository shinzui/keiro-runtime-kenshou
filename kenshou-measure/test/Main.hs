module Main (main) where

import Kenshou.Measure.ClockSpec qualified
import Kenshou.Measure.HistogramSpec qualified
import Kenshou.Measure.LoadSpec qualified
import Kenshou.Measure.RecorderSpec qualified
import Kenshou.Measure.SamplerSpec qualified
import Kenshou.Measure.SamplesSpec qualified
import Test.Hspec (hspec)

main :: IO ()
main = hspec do
  Kenshou.Measure.ClockSpec.spec
  Kenshou.Measure.HistogramSpec.spec
  Kenshou.Measure.LoadSpec.spec
  Kenshou.Measure.SamplesSpec.spec
  Kenshou.Measure.RecorderSpec.spec
  Kenshou.Measure.SamplerSpec.spec
