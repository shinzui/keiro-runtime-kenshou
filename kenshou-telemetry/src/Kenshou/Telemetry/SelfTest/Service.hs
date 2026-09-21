module Kenshou.Telemetry.SelfTest.Service
  ( runSyntheticOperation,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (evaluate)
import Control.Monad (forM_)
import Data.Bits (xor)
import Data.Text qualified as Text
import Kenshou.Measure.Recorder (OpResult (OpOk))
import OpenTelemetry.Trace.Core (Tracer, addAttribute, defaultSpanArguments, inSpan')

runSyntheticOperation :: Maybe Tracer -> Int -> Int -> Int -> IO OpResult
runSyntheticOperation tracer spanCount attributeCount cpuMicros = do
  withSpans tracer spanCount attributeCount do
    _ <- evaluate (burnCpu (max 1 (cpuMicros * 40)) 0x9e3779b9)
    threadDelay cpuMicros
    pure ()
  pure (OpOk 1)

withSpans :: Maybe Tracer -> Int -> Int -> IO value -> IO value
withSpans Nothing _ _ action = action
withSpans (Just tracer) count attributeCount action = go count
  where
    go remaining
      | remaining <= 0 = action
      | otherwise =
          inSpan' tracer ("synthetic-" <> Text.pack (show remaining)) defaultSpanArguments \spanValue -> do
            forM_ [1 .. attributeCount] \index -> addAttribute spanValue ("work.attribute." <> Text.pack (show index)) index
            go (remaining - 1)

burnCpu :: Int -> Int -> Int
burnCpu 0 accumulator = accumulator
burnCpu remaining accumulator =
  let mixed = (accumulator * 1664525 + 1013904223) `xor` remaining
   in burnCpu (remaining - 1) mixed
