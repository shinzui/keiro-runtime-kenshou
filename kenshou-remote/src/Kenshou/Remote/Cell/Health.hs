module Kenshou.Remote.Cell.Health (mapCellHealth, withCellHealthFile) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Exception (IOException, catch, finally, mask_)
import Data.Aeson (Value, eitherDecodeStrict', encode, object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Data.Time (UTCTime)
import Kenshou.Core.Id (RunId)
import System.Directory (doesFileExist)
import System.IO (stderr)

-- The cell owner emits a health document for each observation window. Keep
-- only tripped gates, because an ok gate is not a run health notice.
mapCellHealth :: RunId -> Value -> Either Text [Value]
mapCellHealth expected document = either (Left . Text.pack) Right (parseEither parseDocument document)
  where
    parseDocument = withObject "cell health" \fields -> do
      schema <- fields .: "schema"
      if schema == ("cell.health/v1" :: Text) then pure () else fail "unsupported cell health schema"
      runId <- fields .: "runId"
      if runId == expected then pure () else fail "cell health run ID differs from the active cell run"
      gates <- fields .: "gates" :: Parser [Value]
      concat <$> traverse parseGate gates

    parseGate = withObject "cell health gate" \gate -> do
      name <- gate .: "name" :: Parser Text
      machine <- gate .: "machine" :: Parser Text
      status <- gate .: "status" :: Parser Text
      at <- gate .: "at" :: Parser UTCTime
      detail <- gate .:? "detail" :: Parser (Maybe Text)
      if name `elem` ["host-maintenance", "background-load", "storage-pressure", "incomplete-reset", "version-mismatch"] && not (Text.null machine)
        then pure ()
        else fail "unknown cell health gate or empty machine"
      case status of
        "ok" -> pure []
        "tripped" ->
          pure
            [ object
                [ "schema" .= ("kenshou.health-notice/v1" :: Text),
                  "source" .= ("cell-health:" <> name <> ":" <> machine),
                  "severity" .= (if name == "background-load" then "soft" else "hard" :: Text),
                  "at" .= at,
                  "detail" .= maybe ("cell health gate tripped: " <> name) (\message -> if Text.null message then "cell health gate tripped: " <> name else message) detail
                ]
            ]
        _ -> fail "unknown cell health gate status"

-- Re-read the rolling file because its producer may replace it atomically or
-- append JSON lines. Deduplicate notices across repeated health snapshots.
withCellHealthFile :: Maybe FilePath -> FilePath -> RunId -> IO result -> IO result
withCellHealthFile Nothing _ _ action = action
withCellHealthFile (Just source) destination runId action = do
  initial <- safePoll Set.empty
  latest <- newIORef initial
  thread <- forkIO (loop latest initial)
  action `finally` do
    killThread thread
    readIORef latest >>= safePoll >>= writeIORef latest
  where
    loop latest seen = do
      threadDelay 1000000
      next <- mask_ do
        updated <- safePoll seen
        writeIORef latest updated
        pure updated
      loop latest next

    safePoll seen =
      poll seen `catch` \(failure :: IOException) -> do
        TextIO.hPutStrLn stderr ("kenshou cell health: " <> Text.pack (show failure))
        pure seen

    poll seen = do
      exists <- doesFileExist source
      if not exists
        then pure seen
        else do
          bytes <- ByteString.readFile source
          foldLines seen (completeLines bytes)

    foldLines seen [] = pure seen
    foldLines seen (line : rest) = do
      case eitherDecodeStrict' line >>= firstText . mapCellHealth runId of
        Left problem -> TextIO.hPutStrLn stderr ("kenshou cell health: " <> Text.pack problem) >> foldLines seen rest
        Right notices -> do
          let new = filter (\notice -> encode notice `Set.notMember` seen) notices
          mapM_ (LazyByteString.appendFile destination . (<> "\n") . encode) new
          foldLines (foldr (Set.insert . encode) seen new) rest

    firstText = either (Left . Text.unpack) Right

completeLines :: ByteString.ByteString -> [ByteString.ByteString]
completeLines bytes | ByteString.null bytes = []
completeLines bytes = case ByteString.split 10 bytes of
  [] -> []
  parts -> filter (not . ByteString.null) (if ByteString.last bytes == 10 then parts else init parts)
