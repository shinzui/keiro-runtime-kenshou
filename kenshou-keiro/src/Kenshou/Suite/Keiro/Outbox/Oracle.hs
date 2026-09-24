module Kenshou.Suite.Keiro.Outbox.Oracle
  ( perKeyOrder,
    boundedDuplicates,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map

-- A broker log is already in append order. Only compare records of the same
-- routing key; unrelated keys may interleave freely.
perKeyOrder :: (Ord key) => [(key, Int)] -> Bool
perKeyOrder = go Map.empty
  where
    go _ [] = True
    go seen ((key, sequenceNo) : rest) =
      case Map.lookup key seen of
        Just previous | sequenceNo <= previous -> False
        _ -> go (Map.insert key sequenceNo seen) rest

-- The budget for each message is the number of recorded crash windows that
-- included it. A message outside all windows may appear only once.
boundedDuplicates :: (Ord message) => Map message Int -> [message] -> Bool
boundedDuplicates crashWindows messages =
  all withinBudget (Map.toList counts)
  where
    counts = Map.fromListWith (+) [(message, 1 :: Int) | message <- messages]
    withinBudget (message, observed) = observed <= 1 + Map.findWithDefault 0 message crashWindows
