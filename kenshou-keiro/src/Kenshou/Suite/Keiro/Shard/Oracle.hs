module Kenshou.Suite.Keiro.Shard.Oracle
  ( ShardTiming (..),
    failoverDeadline,
    coverageAndDisjointness,
    checkpointsMonotonic,
    recordShardCells,
    recordShardTimingCells,
  )
where

import Data.Aeson (object, (.=))
import Data.Int (Int64)
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (NominalDiffTime, getCurrentTime)
import Kenshou.Check.Scenario (CheckEnv (..), finishWithVerdicts)
import Kenshou.Check.Verdict (InvariantClass (..), Verdict (..), VerdictStatus (..))
import Kenshou.Core.Scenario (ScenarioReport)

data ShardTiming = ShardTiming
  { leaseTtl :: !NominalDiffTime,
    renewInterval :: !NominalDiffTime
  }
  deriving stock (Eq, Show)

-- | One bucket can be claimed per survivor per reconciliation pass.
failoverDeadline :: ShardTiming -> Int -> Int -> NominalDiffTime
failoverDeadline timing lost survivors =
  timing.leaseTtl + fromIntegral ((max 0 lost + max 1 survivors - 1) `div` max 1 survivors + 2) * timing.renewInterval

-- | Each sample is a bucket and its live owners. Require every bucket in
-- @[0, count)@ and exactly one owner per bucket.
coverageAndDisjointness :: Int -> [(Int, [Text])] -> Bool
coverageAndDisjointness count samples =
  count >= 0
    && length samples == count
    && length (nub (map fst samples)) == count
    && all (\(bucket, owners) -> bucket >= 0 && bucket < count && length owners == 1) samples

-- | Ordered checkpoint samples for each member may stay equal or advance.
checkpointsMonotonic :: [(Text, Int64)] -> Bool
checkpointsMonotonic = snd . foldl step (Map.empty, True)
  where
    step (previous, held) (member, position) =
      let old = Map.lookup member previous
       in (Map.insert member position previous, held && maybe True (<= position) old)

recordShardCells :: CheckEnv -> [(Text, Bool)] -> IO ScenarioReport
recordShardCells check cells = recordShardTimingCells check [(name, held, Nothing) | (name, held) <- cells]

recordShardTimingCells :: CheckEnv -> [(Text, Bool, Maybe NominalDiffTime)] -> IO ScenarioReport
recordShardTimingCells check cells = do
  now <- getCurrentTime
  let verdict (name, held, gap) =
        Verdict
          { checker = "shard-" <> name,
            invariant = name,
            cls = Contract,
            status = if held then Held else Violated,
            reason = Nothing,
            summary = if held then "Shard ownership invariant held" else "Shard ownership invariant failed",
            counts = Map.singleton "snapshots" 1,
            parameters = object ["gapMillis" .= fmap (\duration -> realToFrac duration * (1000 :: Double)) gap],
            counterExamples = [],
            counterExamplesTruncated = False,
            inputs = [],
            replay = Nothing,
            checkedAt = now,
            durationMillis = 0
          }
  finishWithVerdicts check (map verdict cells)
