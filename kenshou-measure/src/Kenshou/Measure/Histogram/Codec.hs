module Kenshou.Measure.Histogram.Codec
  ( encodeHistogram,
    decodeHistogram,
  )
where

import Data.Bits
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Builder
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Int (Int64)
import Data.Text (Text)
import Data.Word (Word16, Word32, Word64, Word8)
import Kenshou.Measure.Histogram

encodeHistogram :: Histogram -> ByteString
encodeHistogram histogram =
  LazyByteString.toStrict . toLazyByteString $
    byteString "KHST"
      <> word16LE 1
      <> word16LE 0
      <> word64LE config.lowestDiscernible
      <> word64LE config.highestTrackable
      <> word8 (fromIntegral config.significantDigits)
      <> word64LE (totalCount histogram)
      <> word64LE (minValue histogram)
      <> word64LE (maxValue histogram)
      <> word64LE (histogramSum histogram)
      <> word64LE (overflowCount histogram)
      <> word32LE (fromIntegral (length tokens))
      <> foldMap (putVarWord . zigZag) tokens
  where
    config = histogramConfig histogram
    tokens = runLengthEncode (histogramCounts histogram)

decodeHistogram :: ByteString -> Either Text Histogram
decodeHistogram bytes = do
  ensure (ByteString.take 4 bytes == "KHST") "invalid histogram magic"
  version <- word16At bytes 4
  ensure (version == 1) "unsupported histogram version"
  flags <- word16At bytes 6
  ensure (flags == 0) "unsupported histogram flags"
  lowest <- word64At bytes 8
  highest <- word64At bytes 16
  digits <- word8At bytes 24
  count <- word64At bytes 25
  observedMinimum <- word64At bytes 33
  observedMaximum <- word64At bytes 41
  total <- word64At bytes 49
  overflow <- word64At bytes 57
  tokenCount <- word32At bytes 65
  (tokens, _) <- readTokens bytes 69 (fromIntegral tokenCount)
  let config = HistogramConfig lowest highest (fromIntegral digits)
  expectedLength <- histogramLength config
  values <- expandTokens expectedLength tokens
  histogramFromCounts config values count observedMinimum observedMaximum total overflow

histogramLength :: HistogramConfig -> Either Text Int
histogramLength = histogramArrayLength

runLengthEncode :: [Word64] -> [Int64]
runLengthEncode [] = []
runLengthEncode values = go values
  where
    go [] = []
    go (0 : rest) = let (zeros, remaining) = span (== 0) rest in negate (fromIntegral (1 + length zeros)) : go remaining
    go (value : rest) = fromIntegral value : go rest

expandTokens :: Int -> [Int64] -> Either Text [Word64]
expandTokens expected tokens = do
  values <- fmap concat $ traverse expand tokens
  ensure (length values <= expected) "histogram token stream exceeds the configured layout"
  pure (values <> replicate (expected - length values) 0)
  where
    expand value | value < 0 = Right (replicate (fromIntegral (negate value)) 0)
    expand value = Right [fromIntegral value]

readTokens :: ByteString -> Int -> Int -> Either Text ([Int64], Int)
readTokens bytes = go []
  where
    go acc offset 0 = Right (reverse acc, offset)
    go acc offset remaining = do
      (encoded, next) <- readVarWord bytes offset
      go (unZigZag encoded : acc) next (remaining - 1)

putVarWord :: Word64 -> Builder
putVarWord value
  | value < 0x80 = word8 (fromIntegral value)
  | otherwise = word8 (fromIntegral (value .&. 0x7f) .|. 0x80) <> putVarWord (value `shiftR` 7)

readVarWord :: ByteString -> Int -> Either Text (Word64, Int)
readVarWord bytes = go 0 0
  where
    go bitOffset accumulator offset
      | bitOffset >= 64 = Left "varint is too long"
      | offset >= ByteString.length bytes = Left "truncated varint"
      | otherwise =
          let byte = ByteString.index bytes offset
              value = accumulator .|. (fromIntegral (byte .&. 0x7f) `shiftL` bitOffset)
           in if byte .&. 0x80 == 0 then Right (value, offset + 1) else go (bitOffset + 7) value (offset + 1)

zigZag :: Int64 -> Word64
zigZag value = fromIntegral ((value `shiftL` 1) `xor` (value `shiftR` 63))

unZigZag :: Word64 -> Int64
unZigZag value = fromIntegral (value `shiftR` 1) `xor` negate (fromIntegral (value .&. 1))

word8At :: ByteString -> Int -> Either Text Word8
word8At bytes offset
  | offset < ByteString.length bytes = Right (ByteString.index bytes offset)
  | otherwise = Left "truncated histogram header"

word16At :: ByteString -> Int -> Either Text Word16
word16At bytes offset = fromIntegral <$> littleEndianAt bytes offset 2

word32At :: ByteString -> Int -> Either Text Word32
word32At bytes offset = fromIntegral <$> littleEndianAt bytes offset 4

word64At :: ByteString -> Int -> Either Text Word64
word64At bytes offset = littleEndianAt bytes offset 8

littleEndianAt :: ByteString -> Int -> Int -> Either Text Word64
littleEndianAt bytes offset width
  | offset + width > ByteString.length bytes = Left "truncated histogram header"
  | otherwise = Right $ foldr (.|.) 0 [fromIntegral (ByteString.index bytes (offset + index)) `shiftL` (8 * index) | index <- [0 .. width - 1]]

ensure :: Bool -> Text -> Either Text ()
ensure condition message = if condition then Right () else Left message
