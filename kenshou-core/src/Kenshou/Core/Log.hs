module Kenshou.Core.Log
  ( Severity (..),
    Logger,
    withLogger,
    logAt,
    nullLogger,
  )
where

import Data.Aeson (Value, encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text.IO qualified as Text.IO
import Data.Time (getCurrentTime)
import Kenshou.Core.Id (RunId, renderRunId)
import System.IO (BufferMode (LineBuffering), Handle, IOMode (AppendMode), hSetBuffering, stderr, withFile)
import System.Posix.Process (getProcessID)

data Severity = Debug | Info | Warning | Error deriving stock (Eq, Ord, Show)

newtype Logger = Logger (Severity -> Text -> [(Text, Value)] -> IO ())

withLogger :: FilePath -> RunId -> (Logger -> IO value) -> IO value
withLogger path runId action = withFile path AppendMode \handle -> do
  hSetBuffering handle LineBuffering
  action (fileLogger handle runId)

fileLogger :: Handle -> RunId -> Logger
fileLogger handle runId = Logger \severity message fields -> do
  now <- getCurrentTime
  pid <- getProcessID
  LazyByteString.hPutStr handle $
    encode
      ( object
          [ "ts" .= now,
            "level" .= severityText severity,
            "msg" .= message,
            "fields" .= object [Key.fromText name .= value | (name, value) <- fields],
            "runId" .= renderRunId runId,
            "process" .= show pid
          ]
      )
      <> "\n"
  Text.IO.hPutStrLn stderr ("[" <> severityText severity <> "] " <> message)

logAt :: Logger -> Severity -> Text -> [(Text, Value)] -> IO ()
logAt (Logger write) = write

nullLogger :: Logger
nullLogger = Logger \_ _ _ -> pure ()

severityText :: Severity -> Text
severityText Debug = "debug"
severityText Info = "info"
severityText Warning = "warning"
severityText Error = "error"
