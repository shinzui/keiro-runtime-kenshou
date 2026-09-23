module Kenshou.Suite.Kiroku.Fixture.Workload
  ( RunTag (..),
    runTagFromRunId,
    IdPolicy (..),
    streamNameFor,
    eventIdFor,
    payloadOf,
    mkEvents,
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Bits (shiftL, shiftR, xor, (.&.), (.|.))
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.UUID qualified as UUID
import Data.Word (Word64)
import Kenshou.Core.Id (RunId, Seed, renderRunId, unSeed)
import Kiroku.Store (EventData (..), EventId (..), EventType (..), StreamName (..))

newtype RunTag = RunTag Text deriving stock (Eq, Show)

data IdPolicy = StoreGenerated | CallerV7 | CallerRandom
  deriving stock (Eq, Show)

runTagFromRunId :: RunId -> RunTag
runTagFromRunId = RunTag . Text.take 8 . Text.filter (/= '-') . renderRunId

streamNameFor :: RunTag -> Int -> Int -> StreamName
streamNameFor (RunTag tag) category index = StreamName ("k" <> tag <> "c" <> Text.pack (show category) <> "-" <> Text.pack (show index))

eventIdFor :: Seed -> Int -> Int64 -> EventId
eventIdFor seed stream ordinal = EventId (UUID.fromWords64 high low)
  where
    streamBits = fromIntegral stream .&. 0xffffffff
    ordinalBits = fromIntegral ordinal .&. 0xffffffffffff
    randomBits = mix64 (unSeed seed `xor` (streamBits `shiftL` 32) `xor` ordinalBits)
    high = (ordinalBits `shiftL` 16) .|. 0x7000 .|. (randomBits .&. 0xfff)
    low = 0x8000000000000000 .|. (streamBits `shiftL` 30) .|. (randomBits .&. 0x3fffffff)

payloadOf :: Seed -> Int -> Int64 -> Int -> Value
payloadOf seed stream ordinal bytes = object ["data" .= Text.pack [alphabet !! fromIntegral (mix64 (basis + fromIntegral index * gamma) .&. 63) | index <- [0 .. max 0 (bytes - 11) - 1]]]
  where
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    basis = unSeed seed `xor` (fromIntegral stream `shiftL` 32) `xor` fromIntegral ordinal

mkEvents :: Seed -> IdPolicy -> Int -> Int64 -> Int -> Int -> [EventData]
mkEvents seed policy stream firstOrdinal count payloadBytes =
  [ EventData (identifier ordinal) (EventType "Workload") (payloadOf seed stream ordinal payloadBytes) Nothing Nothing Nothing
  | ordinal <- take count [firstOrdinal ..]
  ]
  where
    identifier ordinal = case policy of
      StoreGenerated -> Nothing
      CallerV7 -> Just (eventIdFor seed stream ordinal)
      CallerRandom -> Just (EventId (UUID.fromWords64 randomHigh randomLow))
        where
          randomHigh = (mix64 (unSeed seed `xor` fromIntegral stream `xor` fromIntegral ordinal) .&. 0xffffffffffff0fff) .|. 0x4000
          randomLow = (mix64 (unSeed seed + fromIntegral ordinal * gamma) .&. 0x3fffffffffffffff) .|. 0x8000000000000000

mix64 :: Word64 -> Word64
mix64 value = third `xor` (third `shiftR` 31)
  where
    first = (value `xor` (value `shiftR` 30)) * 0xbf58476d1ce4e5b9
    third = (first `xor` (first `shiftR` 27)) * 0x94d049bb133111eb

gamma :: Word64
gamma = 0x9e3779b97f4a7c15
