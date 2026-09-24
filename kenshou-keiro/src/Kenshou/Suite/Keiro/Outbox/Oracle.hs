module Kenshou.Suite.Keiro.Outbox.Oracle
  ( perKeyOrder,
    boundedDuplicates,
    disjointIntervals,
  )
where

import Data.List (sortOn)
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

-- Each row must have non-overlapping callback intervals. Coverage is checked
-- separately against the rows the scenario actually enqueued.
disjointIntervals :: (Ord row, Ord time) => [(time, time, [row])] -> Bool
disjointIntervals intervals =
  all (\(startAt, endAt, _) -> startAt <= endAt) intervals
    && all noOverlap (Map.elems byRow)
  where
    byRow = Map.fromListWith (<>) [(row, [(startAt, endAt)]) | (startAt, endAt, rows) <- intervals, row <- rows]
    noOverlap rows = and (zipWith (\(_, previousEnd) (nextStart, _) -> previousEnd <= nextStart) ordered (drop 1 ordered))
      where
        ordered = sortOn fst rows
