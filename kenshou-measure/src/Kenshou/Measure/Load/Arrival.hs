module Kenshou.Measure.Load.Arrival
  ( constantSchedule,
    poissonSchedule,
    nextGapNs,
  )
where

import Data.Word (Word64)
import Kenshou.Measure.Load.Types (Arrival (..))
import System.Random.SplitMix (SMGen, nextWord64)

constantSchedule :: Double -> Word64 -> Int -> [Word64]
constantSchedule rate start count = take count [start + fromIntegral index * gap | index <- [0 :: Int ..]]
  where
    gap = max 1 (round (1_000_000_000 / rate))

poissonSchedule :: Double -> SMGen -> Word64 -> Int -> [Word64]
poissonSchedule rate generator start count = take count (drop 1 (scanl (+) start gaps))
  where
    gaps = unfold generator
    unfold current = let (gap, next) = nextGapNs (PoissonRate rate) current in gap : unfold next

nextGapNs :: Arrival -> SMGen -> (Word64, SMGen)
nextGapNs (ConstantRate rate) generator = (max 1 (round (1_000_000_000 / rate)), generator)
nextGapNs (PoissonRate rate) generator =
  (max 1 (round ((-log uniform / rate) * 1_000_000_000)), next)
  where
    (word, next) = nextWord64 generator
    uniform = (fromIntegral word + 0.5) / 18_446_744_073_709_551_616.0
