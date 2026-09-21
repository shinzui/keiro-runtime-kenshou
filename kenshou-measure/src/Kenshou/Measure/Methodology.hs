module Kenshou.Measure.Methodology
  ( recommendedKirokuPoolSize,
    kirokuPoolRange,
    minimumTrials,
    defaultTrials,
  )
where

recommendedKirokuPoolSize :: Int
recommendedKirokuPoolSize = 12

kirokuPoolRange :: (Int, Int)
kirokuPoolRange = (10, 13)

minimumTrials, defaultTrials :: Int
minimumTrials = 3
defaultTrials = 5
