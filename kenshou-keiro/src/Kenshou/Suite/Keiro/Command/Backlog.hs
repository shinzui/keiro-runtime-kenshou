-- | Pure analysis of the write-side pipeline's durable stage counts.
--
-- The steady-state soak samples 'StageCounts' while writers run and while the
-- downstream workers drain. This module turns those samples into the two
-- diagnostic answers finding 44 needs: whether a stage fell behind the offered
-- load during the steady window (a capacity deficit), and whether the backlog
-- left at writer stop drains, and how fast. Neither answer is a correctness
-- verdict; durable effects are still judged by the scenario's SQL checks.
module Kenshou.Suite.Keiro.Command.Backlog
  ( StageSample (..),
    StageTrend (..),
    CapacityClass (..),
    DrainReport (..),
    leastSquaresSlope,
    steadyTrends,
    classifyCapacity,
    drainReport,
    renderCapacity,
  )
where

import Data.Int (Int64)
import Data.Text (Text)
import Kenshou.Suite.Keiro.Fixture.Oracle (StageCounts (..), stageBacklog)

data StageSample = StageSample
  { seconds :: !Double,
    phase :: !Text,
    counts :: !StageCounts
  }
  deriving stock (Eq, Show)

-- | One downstream stage over the analysed steady window: the rate at which
-- work arrived for it, the rate at which it completed work, and the slope of
-- its backlog. All rates are per second.
data StageTrend = StageTrend
  { stage :: !Text,
    arrivalPerSecond :: !Double,
    completionPerSecond :: !Double,
    backlogSlopePerSecond :: !Double
  }
  deriving stock (Eq, Show)

data CapacityClass
  = InsufficientSamples
  | WithinCapacity
  | FallingBehind ![Text]
  deriving stock (Eq, Show)

data DrainReport = DrainReport
  { backlogAtStop :: ![(Text, Int64)],
    backlogAtEnd :: ![(Text, Int64)],
    elapsedSeconds :: !Double,
    quiescentAfterSeconds :: !(Maybe Double),
    -- | Seconds the remaining backlog would need at the observed drain rate of
    -- its slowest stage; 'Nothing' when quiescent or when a backlogged stage
    -- made no progress.
    projectedRemainingSeconds :: !(Maybe Double)
  }
  deriving stock (Eq, Show)

-- | Ordinary least-squares slope of @y@ over @x@; 'Nothing' for fewer than
-- two distinct @x@ values.
leastSquaresSlope :: [(Double, Double)] -> Maybe Double
leastSquaresSlope points
  | n < 2 || denominator == 0 = Nothing
  | otherwise = Just (numerator / denominator)
  where
    n = fromIntegral (length points) :: Double
    meanX = sum (map fst points) / n
    meanY = sum (map snd points) / n
    numerator = sum [(x - meanX) * (y - meanY) | (x, y) <- points]
    denominator = sum [(x - meanX) ^ (2 :: Int) | (x, _) <- points]

-- | Trends over the second half of the steady samples, which excludes the
-- start-up transient while workers attach to their subscriptions.
steadyTrends :: Int64 -> [StageSample] -> [StageTrend]
steadyTrends fanout samples
  | length window < 2 = []
  | otherwise =
      [ trend "credit" (.transferDebited) (.transferCredited) 1,
        trend "confirm" (.transferDebited) (.transferConfirmed) 1,
        trend "saga" (.transferDebited) (.sagaEvents) 2,
        trend "bonus" (.bonusDeclared) (.bonusCredited) (fromIntegral fanout),
        trend "activity" (.accountEvents) (.activityApplied) 1
      ]
  where
    steady = [sample | sample <- samples, sample.phase == "steady"]
    window = case steady of
      [] -> []
      first : _ ->
        let end = maximum (map (.seconds) steady)
            middle = first.seconds + (end - first.seconds) / 2
         in [sample | sample <- steady, sample.seconds >= middle]
    series field = [(sample.seconds, fromIntegral (field sample.counts)) | sample <- window]
    slopeOf field = maybe 0 id (leastSquaresSlope (series field))
    backlogOf name sample = maybe 0 fromIntegral (lookup name (stageBacklog fanout sample.counts))
    trend name arrival completion multiplier =
      StageTrend
        { stage = name,
          arrivalPerSecond = multiplier * slopeOf arrival,
          completionPerSecond = slopeOf completion,
          backlogSlopePerSecond = maybe 0 id (leastSquaresSlope [(sample.seconds, backlogOf name sample) | sample <- window])
        }

-- | A stage falls behind when its backlog grows by more than five percent of
-- its arrival rate (and by more than one item every ten seconds) across the
-- analysed window. At least five samples are required for a decision.
classifyCapacity :: Int -> [StageTrend] -> CapacityClass
classifyCapacity sampleCount trends
  | sampleCount < 5 || null trends = InsufficientSamples
  | null behind = WithinCapacity
  | otherwise = FallingBehind behind
  where
    behind = [trend.stage | trend <- trends, trend.backlogSlopePerSecond > max 0.1 (0.05 * trend.arrivalPerSecond)]

drainReport :: Int64 -> StageCounts -> StageCounts -> Double -> Maybe Double -> DrainReport
drainReport fanout atStop atEnd elapsed quiescentAfter =
  DrainReport
    { backlogAtStop = stopBacklog,
      backlogAtEnd = endBacklog,
      elapsedSeconds = elapsed,
      quiescentAfterSeconds = quiescentAfter,
      projectedRemainingSeconds = projected
    }
  where
    stopBacklog = stageBacklog fanout atStop
    endBacklog = stageBacklog fanout atEnd
    remaining = [(name, left, maybe 0 id (lookup name stopBacklog)) | (name, left) <- endBacklog, left > 0]
    -- Arrivals continue during the drain only until writers stop, so the
    -- backlog decrease over the drain is the drain rate of each stage.
    perStage = [(fromIntegral left :: Double) / ((fromIntegral (start - left) :: Double) / elapsed) | (_, left, start) <- remaining, start > left, elapsed > 0]
    projected
      | null remaining = Nothing
      | length perStage /= length remaining = Nothing
      | otherwise = Just (maximum perStage)

renderCapacity :: CapacityClass -> Text
renderCapacity = \case
  InsufficientSamples -> "insufficient-samples"
  WithinCapacity -> "within-capacity"
  FallingBehind _ -> "falling-behind"
