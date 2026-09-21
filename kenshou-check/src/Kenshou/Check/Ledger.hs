module Kenshou.Check.Ledger
  ( ClockSource (..),
    ClockInfo (..),
    LedgerHeader (..),
    LedgerConfig (..),
    LedgerWriter,
    defaultLedgerConfig,
    withLedger,
    record,
    recordDurable,
    flushLedger,
    sealLedger,
  )
where

import Control.Concurrent.MVar
import Control.Exception (bracket)
import Data.Aeson
import Data.Aeson.KeyMap (KeyMap)
import Data.Aeson.Types (Parser)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Kenshou.Check.Fact
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO
import System.Posix.Process (getProcessID)

data ClockSource = SameHost | Measured | Assumed deriving stock (Eq, Show)

data ClockInfo = ClockInfo
  { source :: !ClockSource,
    skewBoundMicros :: !Int64
  }
  deriving stock (Eq, Show)

data LedgerHeader = LedgerHeader
  { runId :: !Text,
    proc :: !ProcId,
    pid :: !Int,
    host :: !Text,
    startedWall :: !Int64,
    startedMono :: !Word64,
    clock :: !ClockInfo
  }
  deriving stock (Eq, Show)

data LedgerConfig = LedgerConfig
  { directory :: !FilePath,
    proc :: !ProcId,
    runId :: !Text,
    segmentBytes :: !Int,
    clock :: !ClockInfo
  }
  deriving stock (Eq, Show)

data WriterState = WriterState
  { handle :: !(Maybe Handle),
    directory :: !FilePath,
    segmentLimit :: !Int,
    segment :: !Int,
    bytes :: !Int,
    counter :: !Word64,
    header :: !LedgerHeader
  }

newtype LedgerWriter = LedgerWriter (MVar WriterState)

defaultLedgerConfig :: FilePath -> ProcId -> Text -> LedgerConfig
defaultLedgerConfig directory proc runId = LedgerConfig directory proc runId (64 * 1024 * 1024) (ClockInfo SameHost 1000)

withLedger :: LedgerConfig -> (LedgerWriter -> IO value) -> IO value
withLedger config action = bracket (openWriter config) closeWriter action

record :: LedgerWriter -> FactKind -> Text -> Int64 -> Text -> KeyMap Value -> IO ()
record = recordWith False

recordDurable :: LedgerWriter -> FactKind -> Text -> Int64 -> Text -> KeyMap Value -> IO ()
recordDurable = recordWith True

flushLedger :: LedgerWriter -> IO ()
flushLedger (LedgerWriter state) = withMVar state (maybe (pure ()) hFlush . (.handle))

sealLedger :: LedgerWriter -> IO ()
sealLedger (LedgerWriter state) = modifyMVar_ state \current -> do
  case current.handle of
    Nothing -> pure current
    Just handle -> hFlush handle >> hClose handle >> pure current {handle = Nothing}

openWriter :: LedgerConfig -> IO LedgerWriter
openWriter config = do
  createDirectoryIfMissing True config.directory
  startedWall <- wallMicros
  startedMono <- getMonotonicTimeNSec
  pid <- fromIntegral <$> getProcessID
  host <- Text.pack . maybe "unknown" id <$> lookupEnv "HOSTNAME"
  let header = LedgerHeader config.runId config.proc pid host startedWall startedMono config.clock
  (handle, bytes) <- openSegment config header 1
  LedgerWriter <$> newMVar (WriterState (Just handle) config.directory config.segmentBytes 1 bytes 0 header)

closeWriter :: LedgerWriter -> IO ()
closeWriter = sealLedger

recordWith :: Bool -> LedgerWriter -> FactKind -> Text -> Int64 -> Text -> KeyMap Value -> IO ()
recordWith durable (LedgerWriter state) kind key sequenceNumber itemId attrs = modifyMVar_ state \current -> do
  currentHandle <- maybe (ioError (userError "record: ledger is sealed")) pure current.handle
  mono <- getMonotonicTimeNSec
  wall <- wallMicros
  let nextCounter = current.counter + 1
      proc = current.header.proc
      scope = proc.role <> "/" <> Text.pack (show proc.index)
      fact = Fact kind key sequenceNumber itemId scope proc nextCounter mono wall attrs
      line = encode fact <> "\n"
      lineBytes = fromIntegral (LazyByteString.length line)
  rotated <-
    if current.counter > 0 && current.bytes + lineBytes > max 1 current.segmentLimit
      then do
        hFlush currentHandle
        hClose currentHandle
        let nextSegment = current.segment + 1
        (nextHandle, headerBytes) <- openSegmentAt current.directory current.segmentLimit current.header nextSegment
        pure current {handle = Just nextHandle, segment = nextSegment, bytes = headerBytes}
      else pure current
  rotatedHandle <- maybe (ioError (userError "record: ledger is sealed")) pure rotated.handle
  LazyByteString.hPut rotatedHandle line
  if durable then hFlush rotatedHandle else pure ()
  pure rotated {bytes = rotated.bytes + lineBytes, counter = nextCounter}

openSegment :: LedgerConfig -> LedgerHeader -> Int -> IO (Handle, Int)
openSegment config header segment = openSegmentAt config.directory config.segmentBytes header segment

openSegmentAt :: FilePath -> Int -> LedgerHeader -> Int -> IO (Handle, Int)
openSegmentAt directory _limit header segment = do
  let path = directory </> segmentName header.proc segment
  handle <- openBinaryFile path WriteMode
  hSetBuffering handle (BlockBuffering (Just (64 * 1024)))
  let line = encode header <> "\n"
  LazyByteString.hPut handle line
  pure (handle, fromIntegral (LazyByteString.length line))

segmentName :: ProcId -> Int -> FilePath
segmentName proc segment =
  Text.unpack (Text.replace "/" "-" proc.role)
    <> "-"
    <> show proc.index
    <> "."
    <> show proc.incarnation
    <> "."
    <> pad4 segment
    <> ".jsonl"
  where
    pad4 number = replicate (max 0 (4 - length rendered)) '0' <> rendered where rendered = show number

wallMicros :: IO Int64
wallMicros = round . (* 1000000) <$> getPOSIXTime

clockSourceText :: ClockSource -> Text
clockSourceText SameHost = "same-host"
clockSourceText Measured = "measured"
clockSourceText Assumed = "assumed"

instance ToJSON ClockInfo where
  toJSON value = object ["source" .= clockSourceText value.source, "skewBoundMicros" .= value.skewBoundMicros]

instance FromJSON ClockInfo where
  parseJSON = withObject "ClockInfo" \value -> do
    rawSource <- value .: "source" :: Parser Text
    source <- case rawSource of
      "same-host" -> pure SameHost
      "measured" -> pure Measured
      "assumed" -> pure Assumed
      _ -> fail "unknown clock source"
    ClockInfo source <$> value .: "skewBoundMicros"

instance ToJSON LedgerHeader where
  toJSON value =
    object
      [ "schema" .= ("kenshou.ledger/v1" :: Text),
        "runId" .= value.runId,
        "proc" .= value.proc,
        "pid" .= value.pid,
        "host" .= value.host,
        "startedWall" .= value.startedWall,
        "startedMono" .= value.startedMono,
        "clock" .= value.clock
      ]

instance FromJSON LedgerHeader where
  parseJSON = withObject "LedgerHeader" \value -> do
    schema <- value .: "schema"
    if schema /= ("kenshou.ledger/v1" :: Text) then fail "unsupported ledger schema" else pure ()
    LedgerHeader <$> value .: "runId" <*> value .: "proc" <*> value .: "pid" <*> value .: "host" <*> value .: "startedWall" <*> value .: "startedMono" <*> value .: "clock"
