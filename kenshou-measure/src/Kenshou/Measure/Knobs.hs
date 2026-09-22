module Kenshou.Measure.Knobs
  ( LoadDefaults (..),
    defaultLoadDefaults,
    loadKnobs,
    measureKnobs,
    loadModelFromKnobs,
  )
where

import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Word (Word64)
import Kenshou.Core.Id (Kind (..))
import Kenshou.Core.Knob
import Kenshou.Measure.Load.Types

data LoadDefaults = LoadDefaults
  { model :: Text,
    workers :: Int64,
    thinkTimeUs :: Int64,
    ratePerSecond :: Double,
    executors :: Int64,
    maxLagMs :: Int64,
    abortLagMs :: Int64
  }
  deriving stock (Eq, Show)

defaultLoadDefaults :: LoadDefaults
defaultLoadDefaults = LoadDefaults "closed" 4 0 100 256 1_000 30_000

loadKnobs :: LoadDefaults -> [KnobSpec]
loadKnobs defaults =
  [ textKnob "load.model" "Load generation model" defaults.model ["closed", "open-constant", "open-poisson"],
    intKnob "load.workers" "Closed-loop workers" defaults.workers 1 65_535,
    intKnob "load.think-time-us" "Delay between closed-loop operations" defaults.thinkTimeUs 0 60_000_000,
    doubleKnob "load.rate-per-second" "Open-loop arrival rate" defaults.ratePerSecond 0.001 10_000_000,
    intKnob "load.executors" "Maximum open-loop operations in flight" defaults.executors 1 65_535,
    intKnob "load.max-lag-ms" "Lag that marks sustained overload" defaults.maxLagMs 1 3_600_000,
    intKnob "load.abort-lag-ms" "Lag that aborts an invalid open-loop run" defaults.abortLagMs 1 3_600_000
  ]

measureKnobs :: Kind -> [KnobSpec]
measureKnobs kind =
  [ intKnob "measure.sample-interval-ms" "Time-series sampling interval" 1_000 100 60_000,
    textKnob "measure.raw-samples" "Raw sample retention" (if kind == Benchmark then "full" else "off") ["full", "sampled", "off"],
    intKnob "measure.raw-sample-one-in" "Blocks retained under sampled policy" 100 1 1_000_000,
    intKnob "measure.histogram-digits" "Histogram significant decimal digits" 3 1 5,
    intKnob "measure.interval-histogram-seconds" "Interval histogram frame duration; soaks default to one frame per day to bound retained histograms" (if kind == Soak then 86_400 else 10) 1 86_400,
    textKnob "measure.pg-statements" "PostgreSQL statement sampling" "snapshots" ["off", "snapshots", "periodic"]
  ]

loadModelFromKnobs :: ResolvedKnobs -> Either Text LoadModel
loadModelFromKnobs knobs = case knobText knobs (name "load.model") of
  "closed" -> Right (ClosedLoop (ClosedConfig workers thinkTime (if workers <= 1 then 0 else 1_000_000_000 `div` fromIntegral workers)))
  "open-constant" -> Right (OpenLoop (openConfig (ConstantRate rate)))
  "open-poisson" -> Right (OpenLoop (openConfig (PoissonRate rate)))
  value -> Left ("unknown load.model " <> value)
  where
    workers = fromIntegral (knobInt knobs (name "load.workers"))
    thinkTime = micros (knobInt knobs (name "load.think-time-us"))
    rate = knobDouble knobs (name "load.rate-per-second")
    executors = fromIntegral (knobInt knobs (name "load.executors"))
    maxLag = millis (knobInt knobs (name "load.max-lag-ms"))
    abortLag = millis (knobInt knobs (name "load.abort-lag-ms"))
    openConfig arrival = OpenConfig arrival executors 1 (OverloadConfig maxLag 3 abortLag)

intKnob :: Text -> Text -> Int64 -> Int64 -> Int64 -> KnobSpec
intKnob knobName summary def low high = KnobSpec (name knobName) summary KnobInt (VInt def) (IntRange low high) []

doubleKnob :: Text -> Text -> Double -> Double -> Double -> KnobSpec
doubleKnob knobName summary def low high = KnobSpec (name knobName) summary KnobDouble (VDouble def) (DoubleRange low high) []

textKnob :: Text -> Text -> Text -> [Text] -> KnobSpec
textKnob knobName summary def (first : rest) = KnobSpec (name knobName) summary KnobText (VText def) (OneOf (VText first :| fmap VText rest)) (fmap VText (first : rest))
textKnob knobName _ _ [] = error ("text knob has no allowed values: " <> show knobName)

name :: Text -> KnobName
name = either (error . show) id . mkKnobName

micros, millis :: Int64 -> Word64
micros value = fromIntegral value * 1_000
millis value = fromIntegral value * 1_000_000
