module Kenshou.Suite.Kiroku.Knobs (storeKnobs, poolSize) where

import Data.Text (Text)
import Kenshou.Core.Knob

storeKnobs :: [KnobSpec]
storeKnobs =
  [ intKnob "kiroku.pool-size" "Store connection pool size" 10 1 64,
    intKnob "kiroku.statement-timeout-seconds" "Statement timeout, or zero to disable" 0 0 600,
    intKnob "kiroku.idle-in-transaction-timeout-seconds" "Idle transaction timeout" 30 1 3600,
    KnobSpec (name "kiroku.conn.keepalives") "Enable aggressive TCP keepalives" KnobBool (VBool False) AnyValue []
  ]

poolSize :: ResolvedKnobs -> Int
poolSize knobs = fromIntegral (knobInt knobs (name "kiroku.pool-size"))

intKnob :: Text -> Text -> Int -> Int -> Int -> KnobSpec
intKnob key description initial low high = KnobSpec (name key) description KnobInt (VInt (fromIntegral initial)) (IntRange (fromIntegral low) (fromIntegral high)) []

name :: Text -> KnobName
name = either (error . show) id . mkKnobName
