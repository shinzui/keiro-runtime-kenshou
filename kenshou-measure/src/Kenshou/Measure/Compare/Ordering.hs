module Kenshou.Measure.Compare.Ordering
  ( Arm (..),
    PairedOrdering (..),
    TrialSlot (..),
    pairedSchedule,
    validateInterleaving,
  )
where

import Data.List (sortOn)
import Data.Text (Text)
import Data.Time (UTCTime)
import Data.Word (Word64)
import System.Random.SplitMix (mkSMGen, nextWord64)

data Arm = Baseline | Candidate deriving stock (Eq, Ord, Show)

data PairedOrdering = ABBA | BAAB deriving stock (Eq, Show)

data TrialSlot = TrialSlot {position :: Int, pairIndex :: Int, arm :: Arm, pairSeed :: Word64}
  deriving stock (Eq, Show)

pairedSchedule :: PairedOrdering -> Int -> Word64 -> [TrialSlot]
pairedSchedule ordering pairs seed = concat (zipWith slots [0 .. max 0 pairs - 1] seeds)
  where
    seeds = randomWords (mkSMGen seed)
    randomWords generator = let (value, next) = nextWord64 generator in value : randomWords next
    slots pair pairSeed =
      let firstBaseline = case ordering of ABBA -> even pair; BAAB -> odd pair
          arms = if firstBaseline then [Baseline, Candidate] else [Candidate, Baseline]
          start = pair * 2
       in zipWith (\offset arm -> TrialSlot (start + offset) pair arm pairSeed) [0, 1] arms

validateInterleaving :: [(Arm, Int, UTCTime)] -> Either Text ()
validateInterleaving trials =
  let ordered = sortOn (\(_, _, started) -> started) trials
      pairs = foldr collect [] ordered
      collect (arm, pair, _) accumulated = case lookup pair accumulated of
        Nothing -> (pair, [arm]) : accumulated
        Just _ -> fmap (\entry@(key, arms) -> if key == pair then (key, arm : arms) else entry) accumulated
      validPair (_, arms) = length arms == 2 && Baseline `elem` arms && Candidate `elem` arms
      firstArms = [arm | (arm, _, _) <- ordered]
      balanced = abs (length (filter (== Baseline) (take (length firstArms `div` 2) firstArms)) - length firstArms `div` 4) <= 1
   in if all validPair pairs && balanced then Right () else Left "runs are not paired and interleaved"
