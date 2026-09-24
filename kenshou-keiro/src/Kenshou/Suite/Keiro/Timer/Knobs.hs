module Kenshou.Suite.Keiro.Timer.Knobs
  ( timerKnobs,
    timerKnobName,
    timerOptionsFrom,
  )
where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (NominalDiffTime)
import Keiro.Timer (TimerWorkerConfigError (..), TimerWorkerOptions (..), defaultTimerWorkerOptions, mkTimerWorkerOptions)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), ResolvedKnobs, knobText, mkKnobName)

timerKnobName :: Text -> KnobName
timerKnobName = either (error . Text.unpack) id . mkKnobName

timerKnobs :: [KnobSpec]
timerKnobs =
  [ text "timer.max-attempts" "none",
    text "timer.requeue-stuck-after-seconds" "2",
    integer "timer.drain-limit" 1 1 100000,
    integer "timer.tick-interval-ms" 50 1 60000,
    integer "timer.worker-processes" 4 1 64,
    integer "timer.count" 5000 1 1000000,
    KnobSpec (timerKnobName "timer.clock") "Clock source" KnobText (VText "wall") (OneOf (VText "wall" :| [VText "virtual"])) []
  ]
  where
    text key def = KnobSpec (timerKnobName key) key KnobText (VText def) AnyValue []
    integer key def low high = KnobSpec (timerKnobName key) key KnobInt (VInt def) (IntRange low high) []

-- | The two nullable settings use textual knobs so "none" remains available
-- alongside numeric overrides. Keiro performs the final semantic validation.
timerOptionsFrom :: ResolvedKnobs -> Either TimerWorkerConfigError TimerWorkerOptions
timerOptionsFrom knobs = do
  attempts <- parseOptionalInt (knobText knobs (timerKnobName "timer.max-attempts"))
  requeue <- parseOptionalSeconds (knobText knobs (timerKnobName "timer.requeue-stuck-after-seconds"))
  mkTimerWorkerOptions defaultTimerWorkerOptions {maxAttempts = attempts, requeueStuckAfter = requeue}

parseOptionalInt :: Text -> Either TimerWorkerConfigError (Maybe Int)
parseOptionalInt "none" = Right Nothing
parseOptionalInt value = case reads (Text.unpack value) of
  [(number, "")] | number >= 0 -> Right (Just number)
  [(number, "")] -> Left (InvalidTimerMaxAttempts number)
  _ -> Left (InvalidTimerMaxAttempts (-1))

parseOptionalSeconds :: Text -> Either TimerWorkerConfigError (Maybe NominalDiffTime)
parseOptionalSeconds "none" = Right Nothing
parseOptionalSeconds value = case reads (Text.unpack value) of
  [(number :: Double, "")] | number > 0 -> Right (Just (realToFrac number))
  _ -> Left (InvalidTimerRequeueStuckAfter 0)
