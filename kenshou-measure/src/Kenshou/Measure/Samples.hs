module Kenshou.Measure.Samples
  ( ClockKind (..),
    SampleHeader (..),
    SampleRecord (..),
    SampleWriter,
    SampleFileReport (..),
    openSampleWriter,
    writeSampleBlock,
    closeSampleWriter,
    sampleWriterBackpressure,
    readSamples,
  )
where

import Control.Concurrent.Async (Async, async, wait)
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Data.Bits
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Builder
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Word
import Kenshou.Measure.Clock (Origin (..))
import System.IO

data ClockKind = MonotonicClock | WallClock
  deriving stock (Eq, Show)

data SampleHeader = SampleHeader
  { origin :: !Origin,
    clockKind :: !ClockKind,
    operation :: !Text,
    processLabel :: !Text
  }
  deriving stock (Eq, Show)

data SampleRecord = SampleRecord
  { intendedStartNs :: !Word64,
    actualStartNs :: !Word64,
    endNs :: !Word64,
    outcomeCode :: !Word8,
    units :: !Word64
  }
  deriving stock (Eq, Show)

data SampleCommand = WriteBlock !Word16 ![SampleRecord] | Stop !(MVar ())

data SampleWriter = SampleWriter
  { queue :: !(TBQueue SampleCommand),
    worker :: !(Async ()),
    backpressure :: !(IORef Word64)
  }

data SampleFileReport = SampleFileReport
  { header :: !SampleHeader,
    recordsRead :: !Word64,
    ignoredBytes :: !Word64
  }
  deriving stock (Eq, Show)

openSampleWriter :: FilePath -> SampleHeader -> IO SampleWriter
openSampleWriter path header = do
  handle <- openBinaryFile path WriteMode
  ByteString.hPut handle (builderBytes (headerBuilder header))
  queue <- newTBQueueIO 256
  backpressure <- newIORef 0
  worker <- async (writerLoop handle queue)
  pure SampleWriter {queue, worker, backpressure}

writeSampleBlock :: SampleWriter -> Word16 -> [SampleRecord] -> IO ()
writeSampleBlock _ _ [] = pure ()
writeSampleBlock writer workerId records = do
  wasFull <- atomically do
    full <- isFullTBQueue writer.queue
    writeTBQueue writer.queue (WriteBlock workerId records)
    pure full
  whenFull wasFull do
    modifyIORef' writer.backpressure (+ 1)
  where
    whenFull True action = action
    whenFull False _ = pure ()

closeSampleWriter :: SampleWriter -> IO ()
closeSampleWriter writer = do
  stopped <- newEmptyMVar
  atomically (writeTBQueue writer.queue (Stop stopped))
  takeMVar stopped
  wait writer.worker

sampleWriterBackpressure :: SampleWriter -> IO Word64
sampleWriterBackpressure = readIORef . (.backpressure)

writerLoop :: Handle -> TBQueue SampleCommand -> IO ()
writerLoop handle queue = do
  command <- atomically (readTBQueue queue)
  case command of
    WriteBlock workerId records -> ByteString.hPut handle (encodeBlock workerId records) >> writerLoop handle queue
    Stop stopped -> hFlush handle >> hClose handle >> putMVar stopped ()

encodeBlock :: Word16 -> [SampleRecord] -> ByteString
encodeBlock _ [] = ByteString.empty
encodeBlock workerId records@(firstRecord : _) =
  builderBytes $
    word16LE workerId
      <> word32LE (fromIntegral (length records))
      <> word32LE (fromIntegral (ByteString.length payload))
      <> word64LE first
      <> byteString payload
  where
    first = firstRecord.intendedStartNs
    payload = builderBytes (recordsBuilder first records)

recordsBuilder :: Word64 -> [SampleRecord] -> Builder
recordsBuilder _ [] = mempty
recordsBuilder previous (record : rest) =
  putVarWord (zigZag (wordDelta record.intendedStartNs previous))
    <> putVarWord (record.actualStartNs - min record.actualStartNs record.intendedStartNs)
    <> putVarWord (record.endNs - min record.endNs record.actualStartNs)
    <> word8 record.outcomeCode
    <> putVarWord record.units
    <> recordsBuilder record.intendedStartNs rest

readSamples :: FilePath -> (SampleRecord -> IO ()) -> IO SampleFileReport
readSamples path consume = do
  bytes <- ByteString.readFile path
  case parseHeader bytes of
    Left message -> ioError (userError (Text.unpack message))
    Right (header, bodyOffset) -> do
      (count, ignored) <- readBlocks bytes bodyOffset consume
      pure (SampleFileReport header count ignored)

readBlocks :: ByteString -> Int -> (SampleRecord -> IO ()) -> IO (Word64, Word64)
readBlocks bytes = go 0
  where
    totalLength = ByteString.length bytes
    go count offset consume
      | offset == totalLength = pure (count, 0)
      | offset + 18 > totalLength = pure (count, fromIntegral (totalLength - offset))
      | otherwise = case parseBlockHeader bytes offset of
          Left _ -> pure (count, fromIntegral (totalLength - offset))
          Right (recordCount, payloadBytes, first, payloadOffset)
            | payloadOffset + payloadBytes > totalLength -> pure (count, fromIntegral (totalLength - offset))
            | otherwise -> case parseRecords bytes payloadOffset payloadBytes recordCount first of
                Left _ -> pure (count, fromIntegral (totalLength - offset))
                Right records -> mapM_ consume records >> go (count + fromIntegral (length records)) (payloadOffset + payloadBytes) consume

parseBlockHeader :: ByteString -> Int -> Either Text (Int, Int, Word64, Int)
parseBlockHeader bytes offset = do
  _workerId <- word16At bytes offset
  count <- word32At bytes (offset + 2)
  payloadBytes <- word32At bytes (offset + 6)
  first <- word64At bytes (offset + 10)
  pure (fromIntegral count, fromIntegral payloadBytes, first, offset + 18)

parseRecords :: ByteString -> Int -> Int -> Int -> Word64 -> Either Text [SampleRecord]
parseRecords bytes offset payloadLength count first = do
  (records, finalOffset) <- go [] offset first count
  ensure (finalOffset == offset + payloadLength) "sample block payload length mismatch"
  pure (reverse records)
  where
    limit = offset + payloadLength
    go records current _ 0 = Right (records, current)
    go records current previous remaining = do
      ensure (current < limit) "truncated sample block"
      (delta, afterDelta) <- readVarWord bytes current limit
      (lag, afterLag) <- readVarWord bytes afterDelta limit
      (service, afterService) <- readVarWord bytes afterLag limit
      outcome <- word8AtLimit bytes afterService limit
      (units, afterUnits) <- readVarWord bytes (afterService + 1) limit
      let intended = addSigned previous (unZigZag delta)
          actual = intended + lag
          record = SampleRecord intended actual (actual + service) outcome units
      go (record : records) afterUnits intended (remaining - 1)

headerBuilder :: SampleHeader -> Builder
headerBuilder header =
  byteString "KSMP"
    <> word16LE 1
    <> word16LE 0
    <> word64LE header.origin.monoNs
    <> int64LE header.origin.wallUnixNs
    <> word8 (case header.clockKind of MonotonicClock -> 0; WallClock -> 1)
    <> textBuilder header.operation
    <> textBuilder header.processLabel

parseHeader :: ByteString -> Either Text (SampleHeader, Int)
parseHeader bytes = do
  ensure (ByteString.take 4 bytes == "KSMP") "invalid sample magic"
  version <- word16At bytes 4
  ensure (version == 1) "unsupported sample version"
  flags <- word16At bytes 6
  ensure (flags == 0) "unsupported sample flags"
  mono <- word64At bytes 8
  wall <- fromIntegral <$> word64At bytes 16
  clockByte <- word8At bytes 24
  clock <- case clockByte of 0 -> Right MonotonicClock; 1 -> Right WallClock; _ -> Left "unknown sample clock"
  (operation, afterOperation) <- textAt bytes 25
  (processLabel, bodyOffset) <- textAt bytes afterOperation
  pure (SampleHeader (Origin mono wall) clock operation processLabel, bodyOffset)

textBuilder :: Text -> Builder
textBuilder value = word16LE (fromIntegral (ByteString.length encoded)) <> byteString encoded
  where
    encoded = Text.encodeUtf8 value

textAt :: ByteString -> Int -> Either Text (Text, Int)
textAt bytes offset = do
  lengthValue <- word16At bytes offset
  let start = offset + 2
      end = start + fromIntegral lengthValue
  ensure (end <= ByteString.length bytes) "truncated sample text"
  case Text.decodeUtf8' (ByteString.take (fromIntegral lengthValue) (ByteString.drop start bytes)) of
    Left _ -> Left "invalid UTF-8 in sample header"
    Right value -> Right (value, end)

builderBytes :: Builder -> ByteString
builderBytes = LazyByteString.toStrict . toLazyByteString

putVarWord :: Word64 -> Builder
putVarWord value
  | value < 0x80 = word8 (fromIntegral value)
  | otherwise = word8 (fromIntegral (value .&. 0x7f) .|. 0x80) <> putVarWord (value `shiftR` 7)

readVarWord :: ByteString -> Int -> Int -> Either Text (Word64, Int)
readVarWord bytes = go 0 0
  where
    go bitOffset accumulator offset limit
      | bitOffset >= 64 = Left "varint is too long"
      | offset >= limit = Left "truncated varint"
      | otherwise =
          let byte = ByteString.index bytes offset
              value = accumulator .|. (fromIntegral (byte .&. 0x7f) `shiftL` bitOffset)
           in if byte .&. 0x80 == 0 then Right (value, offset + 1) else go (bitOffset + 7) value (offset + 1) limit

wordDelta :: Word64 -> Word64 -> Int64
wordDelta current previous = fromIntegral current - fromIntegral previous

addSigned :: Word64 -> Int64 -> Word64
addSigned value delta = fromIntegral (fromIntegral value + delta :: Int64)

zigZag :: Int64 -> Word64
zigZag value = fromIntegral ((value `shiftL` 1) `xor` (value `shiftR` 63))

unZigZag :: Word64 -> Int64
unZigZag value = fromIntegral (value `shiftR` 1) `xor` negate (fromIntegral (value .&. 1))

word8At :: ByteString -> Int -> Either Text Word8
word8At bytes offset = word8AtLimit bytes offset (ByteString.length bytes)

word8AtLimit :: ByteString -> Int -> Int -> Either Text Word8
word8AtLimit bytes offset limit
  | offset < limit = Right (ByteString.index bytes offset)
  | otherwise = Left "truncated sample file"

word16At :: ByteString -> Int -> Either Text Word16
word16At bytes offset = fromIntegral <$> littleEndianAt bytes offset 2

word32At :: ByteString -> Int -> Either Text Word32
word32At bytes offset = fromIntegral <$> littleEndianAt bytes offset 4

word64At :: ByteString -> Int -> Either Text Word64
word64At bytes offset = littleEndianAt bytes offset 8

littleEndianAt :: ByteString -> Int -> Int -> Either Text Word64
littleEndianAt bytes offset width
  | offset + width > ByteString.length bytes = Left "truncated sample file"
  | otherwise = Right $ foldr (.|.) 0 [fromIntegral (ByteString.index bytes (offset + index)) `shiftL` (8 * index) | index <- [0 .. width - 1]]

ensure :: Bool -> Text -> Either Text ()
ensure condition message = if condition then Right () else Left message
